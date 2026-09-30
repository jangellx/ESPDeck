// Connection to ESPDeck Bridge on the Mac: finds it with mDNS, connects over WebSocket,
// and reconnects with exponential backoff when it's unreachable.
//
// A paired device only connects to bridges whose TXT "id" is the one it paired with, and
// prefers the address where it last authenticated. An address whose handshake failed or
// stalled is avoided for kAvoidTime (except that last good one), so something else on the
// network advertising the bridge's ID can't keep the device from its real bridge. While
// connected to a bridge that knows us but can't authenticate (noKey), it keeps looking for
// another with our ID (setLookingElsewhere), and moves to one if it turns up, skipping every
// address that has answered noKey since we last authenticated (a Mac on Ethernet and Wi-Fi
// answers at two; each is tried once).
//
// mDNS queries take a few seconds, so they run on a discovery task of their own; loop()
// hands it requests and picks up the results, and never blocks.
//
// WebSocket events arrive on the client's own task and are queued; the owner drains them
// from its loop with nextMessage().
#pragma once

#include <cstddef>
#include <cstdint>
#include <mutex>

#include "esp_event.h"
#include "esp_websocket_client.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

class BridgeClient {
public:
	// A connection change or a received message, as nextMessage() hands them over.
	struct Message {
		enum class Kind : uint8_t {
			Connected,
			Disconnected,
			Text,
			Binary,
		};

		Kind      kind;
		uint8_t  *data;        // heap_caps_malloc'd; release with BridgeClient::release()
		size_t    size;
		uint32_t  generation;  // internal: drops messages from an older connection
	};

	// hostname: this device's mDNS name.
	void begin( const char *hostname );

	// Discovery, connection timeouts and reconnect backoff. Call often.
	void loop();

	// Next queued message, if any. The caller must release() Text and Binary messages.
	bool nextMessage( Message &message );
	// Frees a message's data.
	static void release( Message &message );

	// The WebSocket is open (the handshake may not have happened yet).
	bool isConnected() const { return state_ == State::Connected; }

	// Sends a text frame; false if not connected or it couldn't be sent.
	bool sendText( const char *text, size_t length );

	// The bridge we're paired with, or empty. Discovery then only accepts that TXT "id".
	void setPreferredBridge( const char *bridgeID );

	// The current connection's handshake succeeded: prefer its address from now on.
	void markAuthenticated();

	// The current connection's handshake failed or stalled: skip its address for a while
	// (unless it's the last one that authenticated). Call before disconnect().
	void avoidCurrent();

	// The bridge we're connected to has no key for us: remember its address as one to skip,
	// and every kLookInterval look for another bridge with our ID. If one turns up, this
	// connection is dropped (a Disconnected message follows) and that one connected to.
	// Off again once the connection goes; the addresses are forgotten on authentication.
	void setLookingElsewhere( bool on );

	// Drops the connection. No Disconnected message follows; the caller resets its own state.
	// retrySoon skips the backoff (used to start over with a fresh hello).
	void disconnect( bool retrySoon = false );

private:
	// The connection, as loop() drives it.
	enum class State : uint8_t {
		Idle,
		Connecting,
		Connected,
	};

	// On the WebSocket client's task.
	static void eventHandler( void *arg, esp_event_base_t base, int32_t eventID, void *eventData );
	void handleData( const esp_websocket_event_data_t *data );
	void enqueue( Message::Kind kind, uint8_t *data = nullptr, size_t size = 0 );

	// Discovery task. Only it calls mDNS.
	static void discoveryTask( void *arg );

	// A bridge's address and port.
	struct Endpoint {
		uint32_t address;   // IPv4, network byte order as lwIP keeps it
		uint16_t port;

		bool operator==( const Endpoint &other ) const { return address == other.address && port == other.port; }
	};

	// An address skipped until `until` (avoidCurrent()).
	struct Avoided {
		Endpoint endpoint;
		int64_t  until;     // esp_timer_get_time(), which doesn't wrap
	};

	// Addresses remembered for skipping; the oldest goes when full.
	static constexpr size_t kMaxAvoided = 4;
	static constexpr size_t kMaxNoKey   = 4;

	// What the discovery task is to look for: a copy of the loop's state when it was asked.
	struct Request {
		char     preferred[64];
		Endpoint lastGood;
		Avoided  avoided[kMaxAvoided];
		Endpoint skip[kMaxNoKey];   // when looking elsewhere: addresses that answered noKey
		bool     lookingElsewhere;
	};

	void runDiscovery();
	// One mDNS query; the best matching bridge, if any.
	bool discover( const Request &request, Endpoint &found );

	// Called by loop(): hand the discovery task a request, drop the one outstanding, and pick
	// up the answer to the latest (false until there is one).
	void requestDiscovery( bool lookingElsewhere = false );
	void abandonDiscovery();
	bool takeDiscoveryResult( bool &found, Endpoint &endpoint );

	// Starts a WebSocket connection to endpoint.
	void connect( const Endpoint &endpoint );
	void teardown();
	void scheduleRetry();
	void retryNow();

	QueueHandle_t                 queue_                = nullptr;
	esp_websocket_client_handle_t client_               = nullptr;
	State                         state_                = State::Idle;
	uint32_t                      generation_           = 0;
	uint32_t                      nextAttempt_          = 0;
	uint32_t                      deadline_             = 0;
	uint32_t                      backoff_              = 1000;
	char                          hostname_[32]         = {};
	char                          preferred_[64]        = {};
	Endpoint                      current_              = {};   // the connection's (or attempt's) address
	Endpoint                      lastGood_             = {};   // where the last handshake succeeded
	Avoided                       avoided_[kMaxAvoided] = {};
	bool                          lookingElsewhere_     = false;
	uint32_t                      nextLook_             = 0;
	Endpoint                      noKey_[kMaxNoKey]     = {};   // answered noKey since we last authenticated
	size_t                        noKeyNext_            = 0;
	bool                          switchPending_        = false;   // connect to switchTo_ once Disconnected is handed over
	Endpoint                      switchTo_             = {};

	// Discovery requests and results, under discoveryMutex_. Results carry the request's id,
	// so one that arrives after Wi-Fi dropped is ignored.
	TaskHandle_t                  discoveryTask_        = nullptr;
	std::mutex                    discoveryMutex_;
	bool                          discovering_          = false;   // waiting for a result (loop() only)
	uint32_t                      requestID_            = 0;
	Request                       request_              = {};
	bool                          resultReady_          = false;
	uint32_t                      resultID_             = 0;
	bool                          resultFound_          = false;
	Endpoint                      resultEndpoint_       = {};

	// Reassembly of messages larger than the client's receive buffer. Only touched on
	// the WebSocket task, and reset in teardown() after that task has stopped.
	uint8_t                      *rxBuffer_             = nullptr;
	size_t                        rxSize_               = 0;
	uint8_t                       rxOpcode_             = 0;
};
