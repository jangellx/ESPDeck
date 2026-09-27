// Connection to ESPDeck Bridge on the Mac: finds it with mDNS, connects over WebSocket,
// and reconnects with exponential backoff when it's unreachable.
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
	static void release( Message &message );

	bool isConnected() const { return state_ == State::Connected; }

	bool sendText( const char *text, size_t length );

	// Discovery prefers the bridge whose TXT "id" matches (the one we're paired with).
	void setPreferredBridge( const char *bridgeID );

	// Drops the connection. No Disconnected message follows; the caller resets its own state.
	// retrySoon skips the backoff (used to start over with a fresh hello).
	void disconnect( bool retrySoon = false );

private:
	enum class State : uint8_t {
		Idle,
		Connecting,
		Connected,
	};

	static void eventHandler( void *arg, esp_event_base_t base, int32_t eventID, void *eventData );
	void handleData( const esp_websocket_event_data_t *data );
	void enqueue( Message::Kind kind, uint8_t *data = nullptr, size_t size = 0 );

	// Discovery task. Only it calls mDNS.
	static void discoveryTask( void *arg );
	void runDiscovery();
	bool discover( const char *preferred, char *uri, size_t size );

	// Called by loop().
	void requestDiscovery();
	void abandonDiscovery();
	bool takeDiscoveryResult( bool &found, char *uri, size_t size );

	void connect( const char *uri );
	void teardown();
	void scheduleRetry();

	QueueHandle_t                 queue_                = nullptr;
	esp_websocket_client_handle_t client_               = nullptr;
	State                         state_                = State::Idle;
	uint32_t                      generation_           = 0;
	uint32_t                      nextAttempt_          = 0;
	uint32_t                      deadline_             = 0;
	uint32_t                      backoff_              = 1000;
	char                          hostname_[32]         = {};
	char                          preferred_[64]        = {};

	// Discovery requests and results, under discoveryMutex_. Results carry the request's id,
	// so one that arrives after Wi-Fi dropped is ignored.
	TaskHandle_t                  discoveryTask_        = nullptr;
	std::mutex                    discoveryMutex_;
	bool                          discovering_          = false;   // waiting for a result (loop() only)
	uint32_t                      requestID_            = 0;
	char                          requestPreferred_[64] = {};
	bool                          resultReady_          = false;
	uint32_t                      resultID_             = 0;
	bool                          resultFound_          = false;
	char                          resultURI_[96]        = {};

	// Reassembly of messages larger than the client's receive buffer. Only touched on
	// the WebSocket task, and reset in teardown() after that task has stopped.
	uint8_t                      *rxBuffer_             = nullptr;
	size_t                        rxSize_               = 0;
	uint8_t                       rxOpcode_             = 0;
};
