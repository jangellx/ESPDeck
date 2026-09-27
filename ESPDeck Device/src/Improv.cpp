// Arduino headers must precede anything that pulls in lwIP, or INADDR_NONE collides.
#include <Arduino.h>
#include <WiFi.h>

#include "Improv.h"

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <vector>

#include "driver/uart.h"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_log.h"
#include "freertos/semphr.h"

#include "Config.h"

static const char *TAG = "Improv";

namespace {
	constexpr char     kHeader[]         = "IMPROV";
	constexpr size_t   kHeaderSize       = 6;
	constexpr uint8_t  kVersion          = 1;
	constexpr uint32_t kConnectTimeout   = 20000;   // ms
	constexpr uint32_t kScanStartTimeout = 10000;   // ms to get a scan going

	// Packet types
	constexpr uint8_t  kTypeState       = 0x01;
	constexpr uint8_t  kTypeError       = 0x02;
	constexpr uint8_t  kTypeRPC         = 0x03;
	constexpr uint8_t  kTypeResult      = 0x04;

	// RPC commands
	constexpr uint8_t  kSendWiFi        = 0x01;
	constexpr uint8_t  kRequestState    = 0x02;
	constexpr uint8_t  kRequestInfo     = 0x03;
	constexpr uint8_t  kRequestScan     = 0x04;

	volatile bool      gotIP            = false;   // set on the Wi-Fi event task

	// Serial output lock: log lines and Improv packets each go out whole.
	SemaphoreHandle_t  outputLock       = nullptr;

	bool canLock() {
		return !xPortInIsrContext() && xTaskGetSchedulerState() == taskSCHEDULER_RUNNING;
	}

	int lockedVprintf( const char *format, va_list args ) {
		if( !canLock() )
			return vprintf( format, args );
		xSemaphoreTakeRecursive( outputLock, portMAX_DELAY );
		int written = vprintf( format, args );
		xSemaphoreGiveRecursive( outputLock );
		return written;
	}
}

void Improv::begin( bool usbSerial ) {
	outputLock = xSemaphoreCreateRecursiveMutex();
	esp_log_set_vprintf( lockedVprintf );

	// A receive-only driver on the console UART. Logs keep going straight to the UART's
	// FIFO; with no transmit buffer, uart_write_bytes() also writes the FIFO directly, so
	// the two stay in order.
	if( !uart_is_driver_installed( UART_NUM_0 ) ) {
		esp_err_t err = uart_driver_install( UART_NUM_0, 512, 0, 0, nullptr, 0 );
		if( err != ESP_OK )
			ESP_LOGE( TAG, "UART driver: %s", esp_err_to_name( err ) );
	}

	// On the USB-Serial-JTAG port, logs go through the driver too, so both share its buffer.
	if( usbSerial && !usb_serial_jtag_is_driver_installed() ) {
		usb_serial_jtag_driver_config_t config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
		config.rx_buffer_size = 512;
		config.tx_buffer_size = 1024;
		esp_err_t err = usb_serial_jtag_driver_install( &config );
		if( err == ESP_OK )
			usb_serial_jtag_vfs_use_driver();
		else
			ESP_LOGE( TAG, "USB-Serial-JTAG driver: %s", esp_err_to_name( err ) );
		usbSerial_ = err == ESP_OK;
	}

	WiFi.onEvent( []( arduino_event_id_t, arduino_event_info_t ) { gotIP = true; }, ARDUINO_EVENT_WIFI_STA_GOT_IP );
	ESP_LOGI( TAG, "Listening on UART0%s", usbSerial_ ? " and USB" : "" );
}

bool Improv::takeProvisioned() {
	bool provisioned = provisioned_;
	provisioned_ = false;
	return provisioned;
}

// MARK: - Receiving

void Improv::loop() {
	uint8_t bytes[64];
	int     count;
	while( ( count = uart_read_bytes( UART_NUM_0, bytes, sizeof( bytes ), 0 ) ) > 0 ) {
		for( int i = 0; i < count; i++ )
			receive( uartParser_, bytes[i] );
	}
	while( usbSerial_ && ( count = usb_serial_jtag_read_bytes( bytes, sizeof( bytes ), 0 ) ) > 0 ) {
		for( int i = 0; i < count; i++ )
			receive( usbParser_, bytes[i] );
	}

	trackConnection();
	trackScan();
}

// Anything that isn't an Improv packet (a terminal's keystrokes, say) is skipped.
void Improv::receive( Parser &parser, uint8_t byte ) {
	if( parser.length < kHeaderSize ) {
		if( byte == (uint8_t)kHeader[parser.length] )
			parser.buffer[parser.length++] = byte;
		else if( byte == (uint8_t)kHeader[0] )
			parser.buffer[0] = byte, parser.length = 1;
		else
			parser.length = 0;
		return;
	}

	parser.buffer[parser.length++] = byte;
	if( parser.length < kHeaderSize + 3 )
		return;
	size_t dataLength = parser.buffer[kHeaderSize + 2];
	if( parser.length < kHeaderSize + 3 + dataLength + 1 )
		return;

	// Complete: version, type, length, data, checksum (sum of every byte before it).
	parser.length = 0;
	uint8_t sum = 0;
	for( size_t i = 0; i < kHeaderSize + 3 + dataLength; i++ )
		sum += parser.buffer[i];
	if( parser.buffer[kHeaderSize] != kVersion || sum != parser.buffer[kHeaderSize + 3 + dataLength] ) {
		ESP_LOGW( TAG, "Bad packet" );
		sendError( Error::InvalidRPC );
		return;
	}
	handlePacket( parser.buffer[kHeaderSize + 1], parser.buffer + kHeaderSize + 3, dataLength );
}

void Improv::handlePacket( uint8_t type, const uint8_t *data, size_t length ) {
	if( type != kTypeRPC )
		return;
	if( length < 2 || data[1] != length - 2 ) {
		sendError( Error::InvalidRPC );
		return;
	}
	sendError( Error::None );
	handleCommand( data[0], data + 2, length - 2 );
}

void Improv::handleCommand( uint8_t command, const uint8_t *data, size_t length ) {
	switch( command ) {
		case kSendWiFi: {
			// ssid length, ssid, password length, password
			size_t ssidLength     = length > 0 ? data[0] : 0;
			size_t passwordLength = length > 1 + ssidLength ? data[1 + ssidLength] : 0;
			if( length < 2 || ssidLength == 0 || ssidLength > 32 || length != 2 + ssidLength + passwordLength || passwordLength > 63 ) {
				sendError( Error::InvalidRPC );
				return;
			}
			char ssid[33], password[64];
			memcpy( ssid, data + 1, ssidLength );
			ssid[ssidLength] = '\0';
			memcpy( password, data + 2 + ssidLength, passwordLength );
			password[passwordLength] = '\0';
			startConnecting( ssid, password );
			memset( password, 0, sizeof( password ) );
			break;
		}

		case kRequestState: {
			State state = currentState();
			sendState( state );
			if( state == State::Provisioned )
				sendResult( kSendWiFi, {} );   // what a successful provisioning answers
			break;
		}

		case kRequestInfo:
			sendResult( kRequestInfo, { "ESPDeck", firmwareVersion(), "ESP32-S3", settings_.name() } );
			break;

		case kRequestScan:
			if( !scanWanted_ ) {
				scanWanted_   = true;
				scanDeadline_ = millis() + kScanStartTimeout;
				scanTried_    = millis() - 500;
			}
			break;

		default:
			sendError( Error::UnknownCommand );
			break;
	}
}

// MARK: - Provisioning

Improv::State Improv::currentState() const {
	if( connecting_ )
		return State::Provisioning;
	if( settings_.hasCredentials() && WiFi.status() == WL_CONNECTED )
		return State::Provisioned;
	return State::Ready;
}

// The new credentials are only saved once they work; until then the old ones stay.
void Improv::startConnecting( const char *ssid, const char *password ) {
	strlcpy( ssid_, ssid, sizeof( ssid_ ) );
	strlcpy( password_, password, sizeof( password_ ) );
	ESP_LOGI( TAG, "Joining %s", ssid_ );
	sendState( State::Provisioning );

	WiFi.disconnect( false, false );
	gotIP         = false;
	connecting_   = true;
	connectStart_ = millis();
	WiFi.begin( ssid_, password_ );
}

void Improv::trackConnection() {
	if( !connecting_ )
		return;

	if( gotIP ) {
		connecting_ = false;
		settings_.setCredentials( ssid_, password_ );
		settings_.markCredentialsWork();
		memset( password_, 0, sizeof( password_ ) );
		ESP_LOGI( TAG, "Joined %s as %s", ssid_, WiFi.localIP().toString().c_str() );
		sendState( State::Provisioned );
		// No URL: the device's only web page is the setup page, which isn't running once
		// it's on the network.
		sendResult( kSendWiFi, {} );
		provisioned_ = true;
	} else if( millis() - connectStart_ >= kConnectTimeout ) {
		connecting_ = false;
		memset( password_, 0, sizeof( password_ ) );
		ESP_LOGW( TAG, "Couldn't join %s", ssid_ );
		sendError( Error::UnableToConnect );
		sendState( State::Ready );
		if( settings_.hasCredentials() )
			WiFi.begin( settings_.ssid(), settings_.password() );   // back to the network that worked
		else
			WiFi.disconnect( false, false );
	}
}

void Improv::trackScan() {
	if( !scanWanted_ )
		return;

	// The radio refuses to scan while the station is joining a network, so keep trying for
	// a while. A scan that's already running (the setup page's) is shared.
	if( !scanning_ ) {
		uint32_t now = millis();
		if( now - scanTried_ < 500 )
			return;
		scanTried_ = now;
		scanning_  = WiFi.scanComplete() == WIFI_SCAN_RUNNING || WiFi.scanNetworks( true ) == WIFI_SCAN_RUNNING;
		if( !scanning_ && (int32_t)( now - scanDeadline_ ) >= 0 ) {
			ESP_LOGW( TAG, "Couldn't scan" );
			scanWanted_ = false;
			sendResult( kRequestScan, {} );
		}
		return;
	}

	int16_t count = WiFi.scanComplete();
	if( count == WIFI_SCAN_RUNNING )
		return;
	scanning_   = false;
	scanWanted_ = false;

	// One result per network name, strongest first, then an empty one.
	struct Network {
		String  ssid;
		int32_t rssi;
		bool    secure;
	};
	std::vector<Network> networks;
	for( int16_t i = 0; i < count; i++ ) {
		String ssid = WiFi.SSID( i );
		if( ssid.isEmpty() )
			continue;
		int32_t rssi  = WiFi.RSSI( i );
		auto    found = std::find_if( networks.begin(), networks.end(), [&]( const Network &n ) { return n.ssid == ssid; } );
		if( found == networks.end() )
			networks.push_back( { ssid, rssi, WiFi.encryptionType( i ) != WIFI_AUTH_OPEN } );
		else if( rssi > found->rssi )
			found->rssi = rssi;
	}
	if( count >= 0 )
		WiFi.scanDelete();
	std::sort( networks.begin(), networks.end(), []( const Network &a, const Network &b ) { return a.rssi > b.rssi; } );

	for( const Network &network : networks ) {
		char rssi[8];
		snprintf( rssi, sizeof( rssi ), "%d", (int)network.rssi );
		sendResult( kRequestScan, { network.ssid.c_str(), rssi, network.secure ? "YES" : "NO" } );
	}
	sendResult( kRequestScan, {} );
}

// MARK: - Sending

void Improv::sendState( State state ) {
	uint8_t value = (uint8_t)state;
	sendPacket( kTypeState, &value, 1 );
}

void Improv::sendError( Error error ) {
	uint8_t value = (uint8_t)error;
	sendPacket( kTypeError, &value, 1 );
}

// Command, length of the rest, then each string as length + bytes.
void Improv::sendResult( uint8_t command, std::initializer_list<const char *> strings ) {
	uint8_t data[255];
	size_t  length = 2;
	for( const char *string : strings ) {
		size_t size = strlen( string );
		if( length + 1 + size > sizeof( data ) )
			break;
		data[length++] = (uint8_t)size;
		memcpy( data + length, string, size );
		length += size;
	}
	data[0] = command;
	data[1] = (uint8_t)( length - 2 );
	sendPacket( kTypeResult, data, length );
}

// "IMPROV", version, type, length, data, checksum, and a newline so logs that follow start
// on their own line.
void Improv::sendPacket( uint8_t type, const uint8_t *data, size_t length ) {
	uint8_t packet[kHeaderSize + 3 + 255 + 2];
	memcpy( packet, kHeader, kHeaderSize );
	packet[kHeaderSize]     = kVersion;
	packet[kHeaderSize + 1] = type;
	packet[kHeaderSize + 2] = (uint8_t)length;
	memcpy( packet + kHeaderSize + 3, data, length );
	size_t  size = kHeaderSize + 3 + length;
	uint8_t sum  = 0;
	for( size_t i = 0; i < size; i++ )
		sum += packet[i];
	packet[size++] = sum;
	packet[size++] = '\n';

	xSemaphoreTakeRecursive( outputLock, portMAX_DELAY );
	fflush( stdout );
	uart_write_bytes( UART_NUM_0, packet, size );
	uart_wait_tx_done( UART_NUM_0, pdMS_TO_TICKS( 100 ) );
	if( usbSerial_ )
		usb_serial_jtag_write_bytes( packet, size, pdMS_TO_TICKS( 50 ) );
	xSemaphoreGiveRecursive( outputLock );
}
