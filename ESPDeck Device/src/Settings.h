// Device settings persisted in NVS: Wi-Fi credentials, the device name, the setup access
// point's password, the image orientation, the sleep timeout, and the pairing (the key K and
// the bridge ID). Brightness lives with the key assignments in ImageCache.
#pragma once

#include <cstddef>
#include <cstdint>

class Settings {
public:
	// Loads everything, generating the default name and the setup password on first boot.
	void begin();

	// Wi-Fi MAC address as "aa:bb:cc:dd:ee:ff", and its last two bytes as "EEFF".
	const char *id() const        { return id_; }
	const char *idSuffix() const  { return suffix_; }

	bool        hasCredentials() const { return ssid_[0] != '\0'; }
	const char *ssid() const           { return ssid_; }
	const char *password() const       { return password_; }
	// Whether the stored credentials have ever connected.
	bool        credentialsWork() const { return verified_; }
	void        setCredentials( const char *ssid, const char *password );
	void        markCredentialsWork();

	const char *name() const { return name_; }
	bool        setName( const char *name );

	const char *apPassword() const { return apPassword_; }

	// "auto" or a transform name; the caller validates.
	const char *orientation() const { return orientation_; }
	void        setOrientation( const char *orientation );

	uint32_t    sleepTimeout() const { return sleepTimeout_; }   // seconds, 0 = never
	void        setSleepTimeout( uint32_t seconds );

	// The bridge this device is paired with, and the pairing key K.
	bool           isPaired() const     { return paired_; }
	const char    *pairedBridge() const { return bridgeID_; }
	const uint8_t *pairingKey() const   { return pairingKey_; }
	bool           setPairing( const uint8_t key[32], const char *bridgeID );
	void           clearPairing();

	static constexpr size_t kMaxName     = 32;
	static constexpr size_t kMaxBridgeID = 63;

private:
	char     id_[18]                     = {};
	char     suffix_[5]                  = {};
	char     ssid_[33]                   = {};
	char     password_[65]               = {};
	bool     verified_                   = false;
	char     name_[kMaxName + 1]         = {};
	char     apPassword_[9]              = {};
	char     orientation_[16]            = "auto";
	uint32_t sleepTimeout_               = 0;
	bool     paired_                     = false;
	char     bridgeID_[kMaxBridgeID + 1] = {};
	uint8_t  pairingKey_[32]             = {};
};
