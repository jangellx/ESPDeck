// ArduinoOTA for development builds only: the espdeck-dev PlatformIO environment defines
// ESPDECK_DEV_OTA and ESPDECK_OTA_PASSWORD, so `pio run -e espdeck-dev -t upload` can send a
// build straight to a dev kit over Wi-Fi, without the bridge. Release firmware (the espdeck
// environment) compiles none of it; these functions do nothing there.
//
// The upload goes by IP address or by the device's own mDNS name (espdeck-eeff.local), which
// BridgeClient already publishes; ArduinoOTA's own mDNS start is off, since a second
// MDNS.begin() would fail.
#pragma once

namespace DevOTA {
	// Remembers the hostname and the callbacks; listening starts once Wi-Fi is up.
	// onStart: an upload began (the deck shows "Updating"); onEnd: it finished, and the
	// device restarts right after.
	void begin( const char *hostname, void ( *onStart )(), void ( *onEnd )() );

	// Answers upload invitations, except while `busy` (a firmware update from the bridge is
	// running or installed), so the two never overlap. An upload runs inside this call.
	void loop( bool busy );

	// An upload is running.
	bool active();
}
