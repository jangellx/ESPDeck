// See DevOTA.h. Everything here is compiled only in the espdeck-dev environment.
#include "DevOTA.h"

#if ESPDECK_DEV_OTA

#ifndef ESPDECK_OTA_PASSWORD
#error "espdeck-dev needs ESPDECK_OTA_PASSWORD (tools/dev_ota.py sets it)"
#endif

#include <Arduino.h>
#include <ArduinoOTA.h>
#include <WiFi.h>

#include "esp_log.h"

static const char *TAG = "DevOTA";

namespace {
	char   hostname[32]     = {};
	void ( *startCallback )() = nullptr;
	void ( *endCallback )()   = nullptr;
	bool   listening        = false;
	bool   running          = false;
}

void DevOTA::begin( const char *name, void ( *onStart )(), void ( *onEnd )() ) {
	strlcpy( hostname, name, sizeof( hostname ) );
	startCallback = onStart;
	endCallback   = onEnd;
}

void DevOTA::loop( bool busy ) {
	if( !listening ) {
		if( WiFi.status() != WL_CONNECTED )
			return;
		ArduinoOTA.setHostname( hostname );
		ArduinoOTA.setPassword( ESPDECK_OTA_PASSWORD );
		ArduinoOTA.setMdnsEnabled( false );
		ArduinoOTA.onStart( [] {
			running = true;
			ESP_LOGW( TAG, "Receiving a development build" );
			if( startCallback )
				startCallback();
		} );
		ArduinoOTA.onEnd( [] {
			ESP_LOGW( TAG, "Development build installed; restarting" );
			if( endCallback )
				endCallback();
		} );
		ArduinoOTA.onError( []( ota_error_t error ) {
			running = false;
			ESP_LOGW( TAG, "Development upload failed (error %d)", (int)error );
		} );
		ArduinoOTA.begin();
		listening = true;
		ESP_LOGW( TAG, "Development build: accepting ArduinoOTA uploads on %s", WiFi.localIP().toString().c_str() );
	}
	// Unanswered invitations time out in espota, which reports the upload as failed.
	if( !busy )
		ArduinoOTA.handle();
}

bool DevOTA::active() {
	return running;
}

#else

void DevOTA::begin( const char *, void ( * )(), void ( * )() ) {}
void DevOTA::loop( bool ) {}
bool DevOTA::active() { return false; }

#endif
