#include <Preferences.h>

#include "Settings.h"

#include <cctype>
#include <cstdio>
#include <cstring>

#include "bootloader_random.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_random.h"

static const char *TAG = "Settings";

namespace {
	constexpr const char *kNamespace = "espdeck";

	// No 0/O, 1/l/i: the password is read off a phone screen or typed by hand.
	constexpr const char *kPasswordAlphabet = "abcdefghjkmnpqrstuvwxyz23456789";
	constexpr size_t      kPasswordLength   = 8;

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

	if( !preferences.begin( kNamespace, false ) ) {
		ESP_LOGE( TAG, "Opening NVS failed; using defaults" );
		snprintf( name_, sizeof( name_ ), "ESPDeck %s", suffix_ );
		return;
	}

	loadString( "ssid", ssid_, sizeof( ssid_ ) );
	loadString( "password", password_, sizeof( password_ ) );
	verified_ = preferences.getBool( "verified", false );
	loadString( "name", name_, sizeof( name_ ) );
	loadString( "apPassword", apPassword_, sizeof( apPassword_ ) );
	loadString( "orientation", orientation_, sizeof( orientation_ ) );
	sleepTimeout_ = preferences.getUInt( "sleepTimeout", 0 );
	loadString( "bridgeID", bridgeID_, sizeof( bridgeID_ ) );
	loadString( "otaHash", otaPasswordHash_, sizeof( otaPasswordHash_ ) );
	if( strlen( otaPasswordHash_ ) != 64 )
		otaPasswordHash_[0] = '\0';
	paired_ = bridgeID_[0] && preferences.isKey( "pairingKey" )
	          && preferences.getBytes( "pairingKey", pairingKey_, sizeof( pairingKey_ ) ) == sizeof( pairingKey_ );

	if( !name_[0] ) {
		snprintf( name_, sizeof( name_ ), "ESPDeck %s", suffix_ );
		preferences.putString( "name", name_ );
	}

	if( strlen( apPassword_ ) != kPasswordLength ) {
		// Wi-Fi isn't running yet, so esp_random() needs another entropy source to be random.
		bootloader_random_enable();
		size_t alphabet = strlen( kPasswordAlphabet );
		for( size_t i = 0; i < kPasswordLength; i++ )
			apPassword_[i] = kPasswordAlphabet[esp_random() % alphabet];
		apPassword_[kPasswordLength] = '\0';
		bootloader_random_disable();
		preferences.putString( "apPassword", apPassword_ );
	}
}

void Settings::setCredentials( const char *ssid, const char *password ) {
	strlcpy( ssid_, ssid ? ssid : "", sizeof( ssid_ ) );
	strlcpy( password_, password ? password : "", sizeof( password_ ) );
	verified_ = false;
	preferences.putString( "ssid", ssid_ );
	preferences.putString( "password", password_ );
	preferences.putBool( "verified", false );
}

void Settings::markCredentialsWork() {
	if( verified_ )
		return;
	verified_ = true;
	preferences.putBool( "verified", true );
}

bool Settings::setName( const char *name ) {
	if( !name || !name[0] || strlen( name ) > kMaxName )
		return false;
	if( strcmp( name, name_ ) != 0 ) {
		strlcpy( name_, name, sizeof( name_ ) );
		preferences.putString( "name", name_ );
	}
	return true;
}

bool Settings::setOTAPasswordHash( const char *hash ) {
	if( !hash || !hash[0] ) {
		if( hasOTAPassword() ) {
			otaPasswordHash_[0] = '\0';
			preferences.remove( "otaHash" );
		}
		return true;
	}
	if( strlen( hash ) != 64 || strspn( hash, "0123456789abcdefABCDEF" ) != 64 )
		return false;
	strlcpy( otaPasswordHash_, hash, sizeof( otaPasswordHash_ ) );
	for( char *c = otaPasswordHash_; *c; c++ )
		*c = (char)tolower( *c );
	preferences.putString( "otaHash", otaPasswordHash_ );
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
	return true;
}

void Settings::clearPairing() {
	memset( pairingKey_, 0, sizeof( pairingKey_ ) );
	bridgeID_[0] = '\0';
	paired_      = false;
	preferences.remove( "pairingKey" );
	preferences.remove( "bridgeID" );
}
