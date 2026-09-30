// Improv Wi-Fi over serial (https://www.improv-wifi.com/serial/, version 1): lets ESP Web
// Tools or ESPDeck Bridge, over USB, ask for the device's details, list the Wi-Fi networks
// it sees, give it credentials, and get or set its name. Three commands are ESPDeck's own:
// 0xFE answers the name of the network it's set up for, 0xFD how its storage is kept (and
// chooses Standard or encrypted storage for a new device's setup; see Settings), and 0xFC the
// bridge it's paired with (and can unpair it).
//
// It listens on UART0 (the console/COM port) always, and on the native USB port's
// USB-Serial-JTAG when that's plugged into a computer. Log output keeps flowing on both;
// a lock around the log writer keeps a log line from landing inside an Improv packet.
#pragma once

#include <cstddef>
#include <cstdint>
#include <initializer_list>

#include "Settings.h"

class Improv {
public:
	// Settings: where credentials, the name and the storage choice are kept.
	explicit Improv( Settings &settings ) : settings_( settings ) {}

	// Joining a network it was just given (it has its own timeout, and goes back after).
	bool connecting() const { return connecting_; }

	// Installs the serial drivers. usbSerial: also listen on the USB-Serial-JTAG port.
	void begin( bool usbSerial );

	// Reads commands, runs a pending connection attempt and scan. Call every loop pass.
	void loop();

	// True once, when credentials sent over Improv have connected (main leaves setup mode).
	bool takeProvisioned();

private:
	// Improv's current-state values.
	enum class State : uint8_t {
		Ready        = 0x02,   // "authorized"
		Provisioning = 0x03,
		Provisioned  = 0x04,
	};

	// Improv's error-state values.
	enum class Error : uint8_t {
		None            = 0x00,
		InvalidRPC      = 0x01,
		UnknownCommand  = 0x02,
		UnableToConnect = 0x03,
		Unknown         = 0xFF,
	};

	// One port's receive state: bytes of the packet so far.
	struct Parser {
		uint8_t buffer[6 + 3 + 255 + 1];   // header, version/type/length, data, checksum
		size_t  length = 0;
	};

	// Feeds one byte from a port; a complete packet goes to handlePacket().
	void receive( Parser &parser, uint8_t byte );
	void handlePacket( uint8_t type, const uint8_t *data, size_t length );
	void handleCommand( uint8_t command, const uint8_t *data, size_t length );

	// Joins a network with credentials from Improv; trackConnection() follows it.
	void startConnecting( const char *ssid, const char *password );
	void trackConnection();
	void trackScan();

	State currentState() const;
	// Packets out, on both ports.
	void  sendState( State state );
	void  sendError( Error error );
	void  sendResult( uint8_t command, std::initializer_list<const char *> strings );
	void  sendPacket( uint8_t type, const uint8_t *data, size_t length );

	Settings &settings_;
	bool      usbSerial_    = false;
	Parser    uartParser_;
	Parser    usbParser_;

	// A connection attempt with credentials from Improv.
	bool      connecting_   = false;
	bool      provisioned_  = false;   // for takeProvisioned()
	uint32_t  connectStart_ = 0;
	char      ssid_[33]     = {};
	char      password_[65] = {};

	bool      scanWanted_   = false;   // a scan was requested and hasn't been answered
	bool      scanning_     = false;
	uint32_t  scanDeadline_ = 0;       // millis() by which the scan must have started
	uint32_t  scanTried_    = 0;       // millis() of the last attempt to start it
};
