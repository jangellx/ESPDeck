// Device settings persisted in NVS: Wi-Fi credentials, the device name, the image
// orientation, the sleep timeout, the pairing (the key K and the bridge ID), and the password
// hash for uploads from PlatformIO (DevOTA). Brightness lives with the key assignments in
// ImageCache. The setup access point's password isn't stored; SetupPortal makes a new one
// each time. NVS is encrypted when a new device saves its first network, unless Standard
// storage was chosen for its setup, or later when the bridge asks for it (SecureNVS).
#pragma once

#include <cstddef>
#include <cstdint>

class Settings {
public:
	// Loads everything, setting the default name on first boot.
	void begin();

	// Wi-Fi MAC address as "aa:bb:cc:dd:ee:ff", and its last two bytes as "EEFF".
	const char *id() const        { return id_; }
	const char *idSuffix() const  { return suffix_; }

	// The saved Wi-Fi network, if any.
	bool        hasCredentials() const { return ssid_[0] != '\0'; }
	const char *ssid() const           { return ssid_; }
	const char *password() const       { return password_; }
	// Whether the stored credentials have ever connected.
	bool        credentialsWork() const { return verified_; }
	// On a new device, encrypts storage first (encryptsAtSetup()), so the credentials are
	// never stored in plain flash.
	void        setCredentials( const char *ssid, const char *password );
	// The saved network has just been joined.
	void        markCredentialsWork();

	// Nothing secret stored yet: no network saved and not paired (a new or reset device).
	bool        isNew() const { return !hasCredentials() && !paired_; }
	// Standard storage (plain NVS) was chosen for setting up this device, over Improv or on
	// the setup page, so its first network doesn't encrypt storage. Kept, in plain NVS, until
	// a factory reset.
	bool        standardStorage() const { return standardStorage_; }
	// Stored only while true.
	void        setStandardStorage( bool standard );
	// Whether storing credentials now encrypts storage first: a new device with plain
	// storage and a free eFuse key block, and Standard wasn't chosen.
	bool        encryptsAtSetup() const;

	// The device's display name. Names are checked with Text::isValidName(); false (and
	// unchanged) if it isn't one.
	const char *name() const { return name_; }
	bool        setName( const char *name );

	// The name on the network (DHCP, mDNS as <hostname>.local): the one chosen from the Mac,
	// else "espdeck-eeff" from the MAC address. Taken at startup.
	const char *hostname() const { return hostname_[0] ? hostname_ : defaultHostname_; }
	bool        hasCustomHostname() const { return hostname_[0] != '\0'; }
	// Empty or null goes back to the default. False (and unchanged) for anything but 1–32
	// lowercase letters, digits and hyphens, not starting or ending with a hyphen.
	bool        setHostname( const char *hostname );

	// "auto" or a transform name; the caller validates.
	const char *orientation() const { return orientation_; }
	void        setOrientation( const char *orientation );

	// How long the deck stays lit without activity before it sleeps.
	uint32_t    sleepTimeout() const { return sleepTimeout_; }   // seconds, 0 = never
	void        setSleepTimeout( uint32_t seconds );

	// The bridge this device is paired with, and the pairing key K. Pairing again or
	// unpairing also turns uploads from PlatformIO off.
	bool           isPaired() const     { return paired_; }
	const char    *pairedBridge() const { return bridgeID_; }
	const uint8_t *pairingKey() const   { return pairingKey_; }
	bool           setPairing( const uint8_t key[32], const char *bridgeID );
	void           clearPairing();

	// SHA-256 of the ArduinoOTA password, 64 hex digits; empty while uploads are off.
	bool        hasOTAPassword() const  { return otaPasswordHash_[0] != '\0'; }
	const char *otaPasswordHash() const { return otaPasswordHash_; }
	// Empty or null turns uploads off; otherwise 64 hex digits. False for anything else.
	bool        setOTAPasswordHash( const char *hash );

	static constexpr size_t kMaxName     = 32;   // bytes, for names and hostnames
	static constexpr size_t kMaxBridgeID = 63;

private:
	static bool isValidHostname( const char *hostname );
	void        setDefaultName();

	char     id_[18]                     = {};
	char     suffix_[5]                  = {};
	char     ssid_[33]                   = {};
	char     password_[65]               = {};
	bool     verified_                   = false;
	char     name_[kMaxName + 1]         = {};
	char     hostname_[kMaxName + 1]     = {};
	char     defaultHostname_[16]        = {};
	char     orientation_[16]            = "auto";
	uint32_t sleepTimeout_               = 0;
	bool     paired_                     = false;
	char     bridgeID_[kMaxBridgeID + 1] = {};
	uint8_t  pairingKey_[32]             = {};
	char     otaPasswordHash_[65]        = {};
	bool     standardStorage_            = false;

	// Encrypts NVS before a new device's first network is saved (see Settings.cpp).
	void     encryptForSetup();
};
