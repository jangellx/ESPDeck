// Wi-Fi provisioning for setup mode: a WPA2/WPA3 access point "ESPDeck-XXXX" at 192.168.4.1
// with a new random password each time setup mode starts, a DNS server that answers every
// name with that address, and a captive-portal web page for the device name and Wi-Fi
// network (and, on a new device, whether saving that network encrypts storage). The station
// interface stays up (or keeps trying) the whole time, so an existing connection to the Mac
// survives.
//
// Only phones on the access point get answers: requests from the home network are refused,
// the page's own requests must name 192.168.4.1 as their Host (so a web page elsewhere can't
// reach it through DNS tricks), and POSTs from another origin are refused. Setup mode ends by
// itself after kIdleTimeout without a phone on the access point, if the device has a network
// that works.
//
// Everything runs from loop(); nothing blocks for long.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "Settings.h"

class SetupPortal {
public:
	explicit SetupPortal( Settings &settings ) : settings_( settings ) {}

	// Registers Wi-Fi event handlers. Call once, before start().
	void begin();

	void start();
	void stop();
	bool active() const { return active_; }

	// Serves DNS and HTTP, and follows a connection attempt started from the page.
	void loop();

	// True once, when the page's Exit button was pressed or a network saved from the page
	// has been joined (after kSetupExitDelay, so the page can show the new address).
	bool takeExitRequest();

	// True once after the page asked for a factory reset.
	bool takeResetRequest();

	// True once when setup mode has been idle for kIdleTimeout (and can be left).
	bool takeIdleTimeout();

	// The access point's name, "ESPDeck-XXXX", and its password while it's running.
	const char *apSSID() const     { return apSSID_; }
	const char *apPassword() const { return apPassword_; }

	// Exiting only makes sense with credentials that are known to work.
	bool canExit() const { return settings_.hasCredentials() && settings_.credentialsWork(); }

private:
	struct Network {
		char    ssid[33];
		int32_t rssi;
		bool    secure;
	};

	void makePassword();
	bool allowRequest( bool post );

	void handleRoot();
	void handleScan();
	void handleStatus();
	void handleSave();
	void handleExit();
	void handleUnpair();
	void handleReset();
	void handleNotFound();
	void sendJSON( int code, const char *json );

	void startScan();
	void collectScan();
	void beginConnecting();
	void restoreNetwork();
	void trackConnection();
	const char *errorText() const;

	Settings            &settings_;
	char                 apSSID_[16]       = {};
	char                 apPassword_[16]   = {};
	bool                 active_           = false;
	bool                 routesAdded_      = false;
	bool                 exitRequested_    = false;
	bool                 resetRequested_   = false;
	bool                 idleTimedOut_     = false;
	uint32_t             lastActivity_     = 0;       // millis() of the last request or phone on the access point
	uint32_t             lastStationCheck_ = 0;

	bool                 scanning_         = false;
	std::vector<Network> networks_;

	// A connection attempt started by Save & Connect. The credentials are only saved once
	// they work; until then the previous network stays.
	char                 pendingSSID_[33]     = {};
	char                 pendingPassword_[65] = {};
	char                 saveError_[96]       = {};   // why the last attempt failed, for the page
	bool                 connecting_       = false;
	bool                 joined_           = false;   // joined; leaving setup mode soon
	bool                 timedOut_         = false;
	uint32_t             connectStart_     = 0;
	uint32_t             joinedAt_         = 0;

	// Written by the Wi-Fi event task.
	volatile uint8_t     lastReason_       = 0;       // wifi_err_reason_t of the last disconnect
	volatile bool        gotIP_            = false;
};
