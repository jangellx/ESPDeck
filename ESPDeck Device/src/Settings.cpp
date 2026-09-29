#include <Preferences.h>

#include "Settings.h"

#include <cctype>
#include <cstdio>
#include <cstring>
#include <initializer_list>

#include "esp_log.h"
#include "esp_mac.h"

#include "SecureNVS.h"
#include "Text.h"

static const char *TAG = "Settings";

namespace {
	constexpr const char *kNamespace = "espdeck";

	// The upload password hash. Firmware before 4.0.0 got it from the bridge in the clear and
	// kept it under "otaHash"; that one is dropped, so updating turns uploads off once.
	constexpr const char *kOTAHashKey    = "otaHash4";
	constexpr const char *kOldOTAHashKey = "otaHash";

	// Standard storage was chosen for the setup (Settings::standardStorage()).
	constexpr const char *kStandardStorageKey = "plainStorage";

	Preferences preferences;

	void loadString( const char *key, char *out, size_t size ) {
		if( preferences.isKey( key ) )
			preferences.getString( key, out, size );
	}
}

void Settings::begin() {
	uint8_t mac[6] = {};
	esp_read_mac( mac, ESP_MAC_WIFI_STA );
	snprintf( id_, sizeof( id_ ), "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] );
	snprintf( suffix_, sizeof( suffix_ ), "%02X%02X", mac[4], mac[5] );
	snprintf( defaultHostname_, sizeof( defaultHostname_ ), "espdeck-%02x%02x", mac[4], mac[5] );

	if( !preferences.begin( kNamespace, false ) ) {
		ESP_LOGE( TAG, "Opening NVS failed; using defaults" );
		snprintf( name_, sizeof( name_ ), "ESPDeck %s", suffix_ );
		return;
	}

	loadString( "ssid", ssid_, sizeof( ssid_ ) );
	loadString( "password", password_, sizeof( password_ ) );
	verified_ = preferences.getBool( "verified", false );
	loadString( "name", name_, sizeof( name_ ) );
	loadString( "hostname", hostname_, sizeof( hostname_ ) );
	if( hostname_[0] && !isValidHostname( hostname_ ) )
		hostname_[0] = '\0';
	loadString( "orientation", orientation_, sizeof( orientation_ ) );
	sleepTimeout_ = preferences.getUInt( "sleepTimeout", 0 );
	loadString( "bridgeID", bridgeID_, sizeof( bridgeID_ ) );
	loadString( kOTAHashKey, otaPasswordHash_, sizeof( otaPasswordHash_ ) );
	if( strlen( otaPasswordHash_ ) != 64 )
		otaPasswordHash_[0] = '\0';
	paired_ = bridgeID_[0] && preferences.isKey( "pairingKey" )
	          && preferences.getBytes( "pairingKey", pairingKey_, sizeof( pairingKey_ ) ) == sizeof( pairingKey_ );
	standardStorage_ = preferences.getBool( kStandardStorageKey, false );

	// Left behind by older firmware: the setup password (now made fresh each time) and the
	// upload password hash that travelled in the clear.
	for( const char *key : { "apPassword", kOldOTAHashKey } ) {
		if( preferences.isKey( key ) )
			preferences.remove( key );
	}

	if( !Text::isValidName( name_, kMaxName ) ) {
		snprintf( name_, sizeof( name_ ), "ESPDeck %s", suffix_ );
		preferences.putString( "name", name_ );
	}
}

void Settings::setCredentials( const char *ssid, const char *password ) {
	if( encryptsAtSetup() )
		encryptForSetup();
	strlcpy( ssid_, ssid ? ssid : "", sizeof( ssid_ ) );
	strlcpy( password_, password ? password : "", sizeof( password_ ) );
	verified_ = false;
	preferences.putString( "ssid", ssid_ );
	preferences.putString( "password", password_ );
	preferences.putBool( "verified", false );
}

// A new device's first network: NVS becomes encrypted before the credentials go in. What's
// there already (the name, say) moves across. If that fails, storage stays plain, or
// becomes plain again until the next start encrypts it (SecureNVS::encryptForSetup()); either
// way the setup goes on.
void Settings::encryptForSetup() {
	ESP_LOGW( TAG, "First network on a new device: encrypting storage before saving it" );
	preferences.end();   // its handle doesn't survive NVS being set up again
	const char        *error   = nullptr;
	SecureNVS::Outcome outcome = SecureNVS::encryptForSetup( error );
	if( !preferences.begin( kNamespace, false ) )
		ESP_LOGE( TAG, "Opening NVS again failed; the settings won't be saved" );
	switch( outcome ) {
		case SecureNVS::Outcome::Encrypted:
			ESP_LOGI( TAG, "Storage is encrypted" );
			break;
		case SecureNVS::Outcome::Refused:
			ESP_LOGE( TAG, "Not encrypting storage (%s); keeping it plain", error );
			break;
		case SecureNVS::Outcome::Failed:
			ESP_LOGE( TAG, "%s Storage stays plain until the next start encrypts it.", error );
			break;
	}
}

bool Settings::encryptsAtSetup() const {
	return isNew() && !standardStorage_ && SecureNVS::ready() && SecureNVS::state() == SecureNVS::State::Plain;
}

void Settings::setStandardStorage( bool standard ) {
	if( standard == standardStorage_ )
		return;
	standardStorage_ = standard;
	if( standard )
		preferences.putBool( kStandardStorageKey, true );
	else
		preferences.remove( kStandardStorageKey );
}

void Settings::markCredentialsWork() {
	if( verified_ )
		return;
	verified_ = true;
	preferences.putBool( "verified", true );
}

bool Settings::setName( const char *name ) {
	if( !Text::isValidName( name, kMaxName ) )
		return false;
	if( strcmp( name, name_ ) != 0 ) {
		strlcpy( name_, name, sizeof( name_ ) );
		preferences.putString( "name", name_ );
	}
	return true;
}

bool Settings::isValidHostname( const char *hostname ) {
	size_t length = hostname ? strlen( hostname ) : 0;
	if( length == 0 || length > kMaxName || hostname[0] == '-' || hostname[length - 1] == '-' )
		return false;
	return strspn( hostname, "abcdefghijklmnopqrstuvwxyz0123456789-" ) == length;
}

bool Settings::setHostname( const char *hostname ) {
	if( !hostname || !hostname[0] || strcmp( hostname, defaultHostname_ ) == 0 ) {
		if( hostname_[0] ) {
			hostname_[0] = '\0';
			preferences.remove( "hostname" );
		}
		return true;
	}
	if( !isValidHostname( hostname ) )
		return false;
	if( strcmp( hostname, hostname_ ) != 0 ) {
		strlcpy( hostname_, hostname, sizeof( hostname_ ) );
		preferences.putString( "hostname", hostname_ );
	}
	return true;
}

bool Settings::setOTAPasswordHash( const char *hash ) {
	if( !hash || !hash[0] ) {
		if( hasOTAPassword() ) {
			otaPasswordHash_[0] = '\0';
			preferences.remove( kOTAHashKey );
		}
		return true;
	}
	if( strlen( hash ) != 64 || strspn( hash, "0123456789abcdefABCDEF" ) != 64 )
		return false;
	strlcpy( otaPasswordHash_, hash, sizeof( otaPasswordHash_ ) );
	for( char *c = otaPasswordHash_; *c; c++ )
		*c = (char)tolower( *c );
	preferences.putString( kOTAHashKey, otaPasswordHash_ );
	return true;
}

void Settings::setOrientation( const char *orientation ) {
	if( strcmp( orientation, orientation_ ) == 0 )
		return;
	strlcpy( orientation_, orientation, sizeof( orientation_ ) );
	preferences.putString( "orientation", orientation_ );
}

void Settings::setSleepTimeout( uint32_t seconds ) {
	if( seconds == sleepTimeout_ )
		return;
	sleepTimeout_ = seconds;
	preferences.putUInt( "sleepTimeout", sleepTimeout_ );
}

bool Settings::setPairing( const uint8_t key[32], const char *bridgeID ) {
	if( !bridgeID || !bridgeID[0] || strlen( bridgeID ) > kMaxBridgeID )
		return false;
	memcpy( pairingKey_, key, sizeof( pairingKey_ ) );
	strlcpy( bridgeID_, bridgeID, sizeof( bridgeID_ ) );
	paired_ = true;
	preferences.putBytes( "pairingKey", pairingKey_, sizeof( pairingKey_ ) );
	preferences.putString( "bridgeID", bridgeID_ );
	setOTAPasswordHash( nullptr );   // a new bridge decides about uploads afresh
	return true;
}

void Settings::clearPairing() {
	memset( pairingKey_, 0, sizeof( pairingKey_ ) );
	bridgeID_[0] = '\0';
	paired_      = false;
	preferences.remove( "pairingKey" );
	preferences.remove( "bridgeID" );
	setOTAPasswordHash( nullptr );
}
