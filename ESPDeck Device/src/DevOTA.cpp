// See DevOTA.h.
#include <Arduino.h>
#include <ArduinoOTA.h>
#include <WiFi.h>

#include <algorithm>
#include <cstring>

#include "DevOTA.h"

#include "esp_log.h"
#include "esp_task_wdt.h"

static const char *TAG = "DevOTA";

namespace {
	// Each wrong password costs the device a PBKDF2 derivation (10,000 rounds) on the main
	// loop, so after one, invitations are ignored for a while, twice as long each time.
	constexpr uint32_t kMinPenalty = 2000;    // ms
	constexpr uint32_t kMaxPenalty = 60000;

	char   hostname[32]       = {};
	char   passwordHash[65]   = {};
	void ( *startCallback )() = nullptr;
	void ( *endCallback )()   = nullptr;
	bool   configured         = false;   // callbacks set up
	bool   listening          = false;
	bool   running            = false;
	uint32_t penalty          = 0;       // ms; 0 while no password has failed
	uint32_t ignoreUntil      = 0;       // millis()

	void stop() {
		if( !listening )
			return;
		ArduinoOTA.end();
		listening = false;
		ESP_LOGI( TAG, "Uploads from PlatformIO off" );
	}
}

void DevOTA::begin( const char *name, void ( *onStart )(), void ( *onEnd )() ) {
	strlcpy( hostname, name, sizeof( hostname ) );
	startCallback = onStart;
	endCallback   = onEnd;
}

void DevOTA::setPasswordHash( const char *hash ) {
	if( strcmp( passwordHash, hash ? hash : "" ) == 0 )
		return;
	// A new password applies from the next start.
	stop();
	strlcpy( passwordHash, hash ? hash : "", sizeof( passwordHash ) );
}

void DevOTA::loop( bool busy ) {
	if( !passwordHash[0] )
		return;
	if( !listening ) {
		if( WiFi.status() != WL_CONNECTED )
			return;
		if( !configured ) {
			ArduinoOTA.setHostname( hostname );
			ArduinoOTA.setMdnsEnabled( false );
			ArduinoOTA.onStart( [] {
				running = true;
				ESP_LOGW( TAG, "Receiving firmware from PlatformIO" );
				if( startCallback )
					startCallback();
			} );
			// The upload runs inside ArduinoOTA.handle(), on the main loop, so it feeds the
			// loop's watchdog itself.
			ArduinoOTA.onProgress( []( unsigned int, unsigned int ) { esp_task_wdt_reset(); } );
			ArduinoOTA.onEnd( [] {
				ESP_LOGW( TAG, "Firmware from PlatformIO installed; restarting" );
				if( endCallback )
					endCallback();
			} );
			ArduinoOTA.onError( []( ota_error_t error ) {
				running = false;
				if( error == OTA_AUTH_ERROR ) {
					penalty     = penalty ? std::min( penalty * 2, kMaxPenalty ) : kMinPenalty;
					ignoreUntil = millis() + penalty;
					ESP_LOGW( TAG, "Wrong upload password; ignoring uploads for %u s", (unsigned)( penalty / 1000 ) );
				} else {
					ESP_LOGW( TAG, "Upload from PlatformIO failed (error %d)", (int)error );
				}
			} );
			configured = true;
		}
		ArduinoOTA.setPasswordHash( passwordHash );
		ArduinoOTA.begin();
		listening = true;
		ESP_LOGI( TAG, "Uploads from PlatformIO on, at %s", WiFi.localIP().toString().c_str() );
	}
	// Unanswered invitations time out in espota, which reports the upload as failed.
	if( !busy && (int32_t)( millis() - ignoreUntil ) >= 0 )
		ArduinoOTA.handle();
}

bool DevOTA::active() {
	return running;
}
