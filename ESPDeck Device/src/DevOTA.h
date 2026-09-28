// Uploads from PlatformIO over Wi-Fi (ArduinoOTA), for development: `pio run -t upload
// --upload-port espdeck-eeff.local` sends a build straight to the device, bridge not
// involved. Off until the bridge sets a password (the `devOTA` message, which carries the
// password's SHA-256 encrypted); only that hash is stored, and without one nothing listens.
// After a wrong password, invitations are ignored for a few seconds (longer each time), since
// checking one costs a PBKDF2 derivation on the main loop.
//
// The upload goes by IP address or by the device's own mDNS name, which BridgeClient
// already publishes; ArduinoOTA's own mDNS start is off, since a second MDNS.begin() would
// fail.
#pragma once

namespace DevOTA {
	// Remembers the hostname and the callbacks. onStart: an upload began (the deck shows
	// "Updating"); onEnd: it finished, and the device restarts right after.
	void begin( const char *hostname, void ( *onStart )(), void ( *onEnd )() );

	// The SHA-256 (64 hex digits) of the password to accept, or empty to stop listening.
	// Setting the one already in use does nothing.
	void setPasswordHash( const char *hash );

	// Listens while there's a password and Wi-Fi, and answers upload invitations, except
	// while `busy` (a firmware update from the bridge is running or installed), so the two
	// never overlap. An upload runs inside this call.
	void loop( bool busy );

	// An upload is running.
	bool active();
}
