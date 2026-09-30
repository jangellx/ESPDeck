// Arduino headers must precede lwIP's (pulled in by the WebSocket client) or INADDR_NONE collides.
#include <Arduino.h>
#include <ESPmDNS.h>
#include <WiFi.h>

#include "BridgeClient.h"

#include <algorithm>
#include <cstring>
#include <iterator>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "mdns.h"

#include "Config.h"
#include "Text.h"
#include "Timing.h"

static const char *TAG = "Bridge";

namespace {
	constexpr uint32_t kMinBackoff      = 1000;
	constexpr uint32_t kMaxBackoff      = 10000;   // a relaunched bridge is found within ~15 s
	constexpr uint32_t kConnectTimeout  = 15000;
	constexpr int      kPingInterval    = 5;       // s
	constexpr int      kPongTimeout     = 10;      // s
	constexpr size_t   kMaxMessageSize  = kMaxImageSize + 64;

	constexpr uint32_t kQueryTimeout    = 3000;    // ms per mDNS query
	constexpr size_t   kMaxResults      = 20;
	constexpr uint32_t kAvoidTime       = 600000;  // ms an address that failed a handshake is skipped
	constexpr uint32_t kLookInterval    = 30000;   // ms between looks for another bridge (setLookingElsewhere)

	constexpr uint8_t  kOpcodeText      = 0x01;
	constexpr uint8_t  kOpcodeBinary    = 0x02;

	constexpr size_t   kQueueLength     = 16;      // messages
	constexpr uint32_t kDiscoveryStack  = 4096;    // bytes
	constexpr int      kReceiveBuffer   = 4096;    // bytes; larger messages arrive in pieces
	constexpr int      kClientStack     = 6144;    // bytes, the WebSocket client's task
	constexpr int      kNetworkTimeout  = 10000;   // ms
	constexpr uint32_t kSendTimeout     = 5000;    // ms
	constexpr uint32_t kEnqueueTimeout  = 1000;    // ms
}

void BridgeClient::begin( const char *hostname ) {
	queue_ = xQueueCreate( kQueueLength, sizeof( Message ) );
	strlcpy( hostname_, hostname, sizeof( hostname_ ) );
	xTaskCreate( discoveryTask, "discovery", kDiscoveryStack, this, 1, &discoveryTask_ );
}

void BridgeClient::release( Message &message ) {
	heap_caps_free( message.data );
	message.data = nullptr;
	message.size = 0;
}

// MARK: - Connection management

void BridgeClient::loop() {
	uint32_t now = millis();

	if( WiFi.status() != WL_CONNECTED ) {
		if( discovering_ )
			abandonDiscovery();
		if( state_ != State::Idle ) {
			ESP_LOGW( TAG, "Wi-Fi lost" );
			switchPending_ = false;
			bool wasConnected = state_ == State::Connected;
			teardown();
			if( wasConnected )
				enqueue( Message::Kind::Disconnected );
			retryNow();
		}
		return;
	}

	switch( state_ ) {
		case State::Idle:
			if( discovering_ ) {
				Endpoint endpoint;
				bool     found;
				if( takeDiscoveryResult( found, endpoint ) ) {
					if( found )
						connect( endpoint );
					else
						scheduleRetry();
				}
			} else if( Timing::reached( nextAttempt_, now ) ) {
				requestDiscovery();
			}
			break;

		case State::Connecting:
			if( Timing::reached( deadline_, now ) ) {
				ESP_LOGW( TAG, "Connection timed out" );
				teardown();
				scheduleRetry();
			}
			break;

		case State::Connected:
			if( !lookingElsewhere_ )
				break;
			if( discovering_ ) {
				Endpoint endpoint;
				bool     found;
				if( takeDiscoveryResult( found, endpoint ) && found && !switchPending_ ) {
					esp_ip4_addr_t address = { endpoint.address };
					ESP_LOGI( TAG, "Another bridge with our ID at " IPSTR ":%u; trying it", IP2STR( &address ), endpoint.port );
					// nextMessage() tears this connection down as it hands over the Disconnected
					// (so the owner resets too), then connects there.
					switchTo_      = endpoint;
					switchPending_ = true;
					enqueue( Message::Kind::Disconnected );
				}
			} else if( !switchPending_ && Timing::reached( nextLook_, now ) ) {
				nextLook_ = now + kLookInterval;
				requestDiscovery( true );
			}
			break;
	}
}

void BridgeClient::setLookingElsewhere( bool on ) {
	if( on == lookingElsewhere_ )
		return;
	if( on && current_.address ) {
		if( std::find( std::begin( noKey_ ), std::end( noKey_ ), current_ ) == std::end( noKey_ ) ) {
			noKey_[noKeyNext_] = current_;
			noKeyNext_         = ( noKeyNext_ + 1 ) % kMaxNoKey;
		}
	}
	lookingElsewhere_ = on;
	nextLook_         = millis() + kLookInterval;
	if( !on && discovering_ )
		abandonDiscovery();
}

// MARK: - Discovery

void BridgeClient::requestDiscovery( bool lookingElsewhere ) {
	{
		std::lock_guard<std::mutex> lock( discoveryMutex_ );
		requestID_++;
		request_.lookingElsewhere = lookingElsewhere;
		memcpy( request_.skip, noKey_, sizeof( noKey_ ) );
		strlcpy( request_.preferred, preferred_, sizeof( request_.preferred ) );
		request_.lastGood = lastGood_;
		memcpy( request_.avoided, avoided_, sizeof( avoided_ ) );
	}
	discovering_ = true;
	xTaskNotifyGive( discoveryTask_ );
}

// A query still running when Wi-Fi drops finishes on its own; its result is ignored.
void BridgeClient::abandonDiscovery() {
	std::lock_guard<std::mutex> lock( discoveryMutex_ );
	requestID_++;
	discovering_ = false;
}

bool BridgeClient::takeDiscoveryResult( bool &found, Endpoint &endpoint ) {
	std::lock_guard<std::mutex> lock( discoveryMutex_ );
	if( !resultReady_ || resultID_ != requestID_ )
		return false;
	resultReady_ = false;
	discovering_ = false;
	found        = resultFound_;
	endpoint     = resultEndpoint_;
	return true;
}

void BridgeClient::discoveryTask( void *arg ) {
	static_cast<BridgeClient *>( arg )->runDiscovery();
}

// The discovery task's loop: one mDNS query per request, the result handed back under the mutex.
void BridgeClient::runDiscovery() {
	bool started = false;
	while( true ) {
		ulTaskNotifyTake( pdTRUE, portMAX_DELAY );

		uint32_t id;
		Request  request;
		{
			std::lock_guard<std::mutex> lock( discoveryMutex_ );
			id      = requestID_;
			request = request_;
		}

		if( !started ) {
			started = MDNS.begin( hostname_ );
			if( !started )
				ESP_LOGW( TAG, "mDNS failed to start" );
		}
		Endpoint endpoint = {};
		bool     found    = started && discover( request, endpoint );

		std::lock_guard<std::mutex> lock( discoveryMutex_ );
		resultReady_    = true;
		resultID_       = id;
		resultFound_    = found;
		resultEndpoint_ = endpoint;
	}
}

namespace {
	// Whether address is on the subnet of local/mask.
	bool sameSubnet( const esp_ip4_addr_t &address, uint32_t local, uint32_t mask ) {
		return mask && ( address.addr & mask ) == ( local & mask );
	}

	// A TXT record's value, or "" if there's none.
	const char *txtValue( const mdns_result_t *result, const char *key ) {
		for( size_t i = 0; i < result->txt_count; i++ ) {
			if( result->txt[i].key && strcmp( result->txt[i].key, key ) == 0 )
				return result->txt[i].value ? result->txt[i].value : "";
		}
		return "";
	}
}

// Paired: only the bridge we're paired with (TXT "id"), preferably at the address where it
// last authenticated. Unpaired: the first one found. A Mac on both Ethernet and Wi-Fi
// answers with several addresses; one on our own subnet is preferred. Addresses being
// avoided are skipped.
bool BridgeClient::discover( const Request &request, Endpoint &found ) {
	mdns_result_t *results = nullptr;
	esp_err_t      err     = mdns_query_ptr( kBridgeService, kBridgeProto, kQueryTimeout, kMaxResults, &results );
	if( err != ESP_OK ) {
		ESP_LOGW( TAG, "mDNS query failed: %s", esp_err_to_name( err ) );
		return false;
	}

	uint32_t local = (uint32_t)WiFi.localIP();
	uint32_t mask  = (uint32_t)WiFi.subnetMask();

	// Score each IPv4 address: the last good one counts most, then being on our subnet.
	const mdns_result_t *bestResult  = nullptr;
	esp_ip4_addr_t       bestAddress = {};
	int                  bestScore   = -1;
	int64_t              now         = esp_timer_get_time();
	for( const mdns_result_t *result = results; result; result = result->next ) {
		if( request.preferred[0] && strcasecmp( txtValue( result, "id" ), request.preferred ) != 0 )
			continue;
		for( const mdns_ip_addr_t *address = result->addr; address; address = address->next ) {
			if( address->addr.type != ESP_IPADDR_TYPE_V4 || address->addr.u_addr.ip4.addr == 0 )
				continue;
			Endpoint candidate = { address->addr.u_addr.ip4.addr, result->port };
			bool     avoided   = false;
			for( const Avoided &entry : request.avoided ) {
				if( entry.endpoint == candidate && entry.until > now )
					avoided = true;
			}
			// Looking elsewhere: not an address that has already said it has no key for us.
			if( request.lookingElsewhere ) {
				for( const Endpoint &entry : request.skip ) {
					if( entry == candidate )
						avoided = true;
				}
			}
			if( avoided )
				continue;
			bool lastGood = request.lastGood == candidate;
			int  score    = ( lastGood ? 2 : 0 ) + ( sameSubnet( address->addr.u_addr.ip4, local, mask ) ? 1 : 0 );
			if( score > bestScore ) {
				bestScore   = score;
				bestResult  = result;
				bestAddress = address->addr.u_addr.ip4;
			}
		}
	}

	bool ok = bestResult != nullptr;
	if( ok ) {
		found = { bestAddress.addr, bestResult->port };
		char host[40], id[48];
		ESP_LOGI( TAG, "Found %s (id %s) at " IPSTR ":%u%s", Text::printable( bestResult->hostname, host, sizeof( host ) ),
				  Text::printable( txtValue( bestResult, "id" ), id, sizeof( id ) ), IP2STR( &bestAddress ), bestResult->port,
				  sameSubnet( bestAddress, local, mask ) ? "" : " (not on our subnet)" );
	} else {
		ESP_LOGI( TAG, "%s not found", request.preferred[0] ? "Our ESPDeck Bridge" : "ESPDeck Bridge" );
	}
	mdns_query_results_free( results );
	return ok;
}

void BridgeClient::connect( const Endpoint &endpoint ) {
	esp_ip4_addr_t address = { endpoint.address };
	char           uri[40];
	snprintf( uri, sizeof( uri ), "ws://" IPSTR ":%u/", IP2STR( &address ), endpoint.port );
	current_ = endpoint;

	esp_websocket_client_config_t config = {};
	config.uri                    = uri;
	config.buffer_size            = kReceiveBuffer;
	config.task_stack             = kClientStack;
	config.network_timeout_ms     = kNetworkTimeout;
	// A Mac that stops answering pings (its app hung, or it's gone) is dropped within about
	// 15 s: a ping every 5 s, and no pong within 10 s of the first unanswered one aborts.
	config.ping_interval_sec      = kPingInterval;
	config.pingpong_timeout_sec   = kPongTimeout;
	config.disable_auto_reconnect = true;   // reconnects go through discovery again

	client_ = esp_websocket_client_init( &config );
	if( !client_ ) {
		ESP_LOGE( TAG, "Creating the WebSocket client failed" );
		scheduleRetry();
		return;
	}

	esp_websocket_register_events( client_, WEBSOCKET_EVENT_ANY, eventHandler, this );
	if( esp_websocket_client_start( client_ ) != ESP_OK ) {
		ESP_LOGE( TAG, "Starting the WebSocket client failed" );
		teardown();
		scheduleRetry();
		return;
	}

	ESP_LOGI( TAG, "Connecting to %s (ping every %d s, pong timeout %d s)", uri, kPingInterval, kPongTimeout );
	state_    = State::Connecting;
	deadline_ = millis() + kConnectTimeout;
}

// Stops the client and drops anything half-received; messages already queued go stale.
void BridgeClient::teardown() {
	if( lookingElsewhere_ ) {
		lookingElsewhere_ = false;
		if( discovering_ )
			abandonDiscovery();
	}
	if( client_ ) {
		esp_websocket_client_destroy( client_ );   // stops and joins the client's task
		client_ = nullptr;
	}
	heap_caps_free( rxBuffer_ );
	rxBuffer_ = nullptr;
	rxSize_   = 0;

	generation_++;
	state_ = State::Idle;
}

// The next discovery after the current backoff, which then doubles (up to kMaxBackoff).
void BridgeClient::scheduleRetry() {
	nextAttempt_ = millis() + backoff_;
	ESP_LOGI( TAG, "Retrying in %u s", (unsigned)( backoff_ / 1000 ) );
	backoff_ = std::min( backoff_ * 2, kMaxBackoff );
}

// The next discovery straight away, with the backoff reset.
void BridgeClient::retryNow() {
	backoff_     = kMinBackoff;
	nextAttempt_ = millis();
}

void BridgeClient::setPreferredBridge( const char *bridgeID ) {
	strlcpy( preferred_, bridgeID ? bridgeID : "", sizeof( preferred_ ) );
}

void BridgeClient::markAuthenticated() {
	lastGood_ = current_;
	memset( noKey_, 0, sizeof( noKey_ ) );
}

void BridgeClient::avoidCurrent() {
	if( current_.address == 0 || current_ == lastGood_ )
		return;

	// Replace the entry that expires first.
	Avoided *slot = &avoided_[0];
	for( Avoided &entry : avoided_ ) {
		if( entry.until < slot->until )
			slot = &entry;
	}
	esp_ip4_addr_t address = { current_.address };
	ESP_LOGW( TAG, "Avoiding " IPSTR ":%u for %u minutes", IP2STR( &address ), current_.port, (unsigned)( kAvoidTime / 60000 ) );
	slot->endpoint = current_;
	slot->until    = esp_timer_get_time() + (int64_t)kAvoidTime * 1000;
}

void BridgeClient::disconnect( bool retrySoon ) {
	switchPending_ = false;
	if( state_ == State::Idle )
		return;
	ESP_LOGI( TAG, "Closing the connection" );
	teardown();
	if( retrySoon )
		retryNow();
	else
		scheduleRetry();
}

bool BridgeClient::nextMessage( Message &message ) {
	while( xQueueReceive( queue_, &message, 0 ) == pdTRUE ) {
		if( message.generation != generation_ ) {
			release( message );
			continue;
		}

		switch( message.kind ) {
			case Message::Kind::Connected:
				ESP_LOGI( TAG, "Connected" );
				state_   = State::Connected;
				backoff_ = kMinBackoff;
				break;
			case Message::Kind::Disconnected:
				ESP_LOGI( TAG, "Disconnected" );
				teardown();
				if( switchPending_ ) {
					switchPending_ = false;
					connect( switchTo_ );   // looking elsewhere found another bridge
				} else {
					scheduleRetry();
				}
				// generation_ moved on, but the owner still needs to hear about this one
				message.generation = generation_;
				break;
			default:
				break;
		}
		return true;
	}
	return false;
}

bool BridgeClient::sendText( const char *text, size_t length ) {
	if( state_ != State::Connected || !client_ )
		return false;
	return esp_websocket_client_send_text( client_, text, (int)length, pdMS_TO_TICKS( kSendTimeout ) ) >= 0;
}

// MARK: - WebSocket task

// Queues a message for the owner, tagged with the current connection; frees data if the queue stays full.
void BridgeClient::enqueue( Message::Kind kind, uint8_t *data, size_t size ) {
	Message message = { kind, data, size, generation_ };
	if( xQueueSend( queue_, &message, pdMS_TO_TICKS( kEnqueueTimeout ) ) != pdTRUE ) {
		ESP_LOGW( TAG, "Message queue full; dropping a message" );
		heap_caps_free( data );
	}
}

// The WebSocket client's events, on its task.
void BridgeClient::eventHandler( void *arg, esp_event_base_t, int32_t eventID, void *eventData ) {
	BridgeClient *self = static_cast<BridgeClient *>( arg );
	auto         *data = static_cast<esp_websocket_event_data_t *>( eventData );

	switch( eventID ) {
		case WEBSOCKET_EVENT_CONNECTED:
			self->enqueue( Message::Kind::Connected );
			break;
		case WEBSOCKET_EVENT_DISCONNECTED:
		case WEBSOCKET_EVENT_CLOSED:
			self->enqueue( Message::Kind::Disconnected );
			break;
		case WEBSOCKET_EVENT_ERROR:
			ESP_LOGW( TAG, "WebSocket error" );
			break;
		case WEBSOCKET_EVENT_DATA:
			self->handleData( data );
			break;
		default:
			break;
	}
}

// A message larger than the receive buffer arrives as several DATA events with
// increasing payload_offset; stitch them together before queueing.
void BridgeClient::handleData( const esp_websocket_event_data_t *data ) {
	if( data->payload_offset == 0 ) {
		if( data->op_code != kOpcodeText && data->op_code != kOpcodeBinary )
			return;   // ping/pong/close are handled by the client

		heap_caps_free( rxBuffer_ );
		rxBuffer_ = nullptr;
		if( data->payload_len <= 0 || (size_t)data->payload_len > kMaxMessageSize ) {
			ESP_LOGW( TAG, "Ignoring a %d byte message", data->payload_len );
			return;
		}

		// One spare byte so text messages can be NUL-terminated.
		rxSize_   = (size_t)data->payload_len;
		rxOpcode_ = data->op_code;
		rxBuffer_ = (uint8_t *)heap_caps_malloc( rxSize_ + 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT );
		if( !rxBuffer_ ) {
			ESP_LOGE( TAG, "Out of memory for a %u byte message", (unsigned)rxSize_ );
			return;
		}
	}

	if( !rxBuffer_ )
		return;

	size_t offset = (size_t)data->payload_offset;
	size_t length = (size_t)data->data_len;
	if( offset + length > rxSize_ ) {
		heap_caps_free( rxBuffer_ );
		rxBuffer_ = nullptr;
		return;
	}

	memcpy( rxBuffer_ + offset, data->data_ptr, length );
	if( offset + length == rxSize_ ) {
		rxBuffer_[rxSize_] = '\0';
		enqueue( rxOpcode_ == kOpcodeText ? Message::Kind::Text : Message::Kind::Binary, rxBuffer_, rxSize_ );
		rxBuffer_ = nullptr;
	}
}
