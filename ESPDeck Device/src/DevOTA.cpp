// See DevOTA.h.
#include <Arduino.h>
#include <ArduinoOTA.h>
#include <WiFi.h>

#include "DevOTA.h"

#include "esp_log.h"

static const char *TAG = "DevOTA";

namespace {
	char   hostname[32]       = {};
	char   passwordHash[65]   = {};
	void ( *startCallback )() = nullptr;
	void ( *endCallback )()   = nullptr;
	bool   configured         = false;   // callbacks set up
	bool   listening          = false;
	bool   running            = false;

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
			ArduinoOTA.onEnd( [] {
				ESP_LOGW( TAG, "Firmware from PlatformIO installed; restarting" );
				if( endCallback )
					endCallback();
			} );
			ArduinoOTA.onError( []( ota_error_t error ) {
				running = false;
				ESP_LOGW( TAG, "Upload from PlatformIO failed (error %d)", (int)error );
			} );
			configured = true;
		}
		ArduinoOTA.setPasswordHash( passwordHash );
		ArduinoOTA.begin();
		listening = true;
		ESP_LOGI( TAG, "Uploads from PlatformIO on, at %s", WiFi.localIP().toString().c_str() );
	}
	// Unanswered invitations time out in espota, which reports the upload as failed.
	if( !busy )
		ArduinoOTA.handle();
}

bool DevOTA::active() {
	return running;
}
