// Constants shared across the firmware. See PROTOCOL.md for the wire format.
#pragma once

#include <cstddef>
#include <cstdint>

#include "esp_app_desc.h"

// PROJECT_VER in CMakeLists.txt, by way of the app description, so OTA images and hello agree.
inline const char *firmwareVersion() {
	return esp_app_get_description()->version;
}

// The SHA-256 of the app's ELF file, in hex: tells builds with the same version apart.
inline const char *firmwareBuild() {
	static char hex[65] = {};
	if( !hex[0] )
		esp_app_get_elf_sha256( hex, sizeof( hex ) );
	return hex;
}

constexpr int         kProtocolVersion = 4;

// Bonjour service advertised by ESPDeck Bridge on the Mac (without the leading underscores;
// ESPmDNS adds them).
constexpr const char *kBridgeService  = "deckbridge";
constexpr const char *kBridgeProto    = "tcp";

constexpr uint8_t  kMaxKeys           = 32;          // Stream Deck XL
constexpr size_t   kMaxImageSize      = 64 * 1024;   // 96 px BMPs are ~27 KB, 120 px JPEGs far less
constexpr size_t   kHashSize          = 16;          // first 16 bytes of SHA-256

// Setup mode
// The dev board's RGB status LED (WS2812): GPIO 48 on the ESP32-S3-DevKitC-1 v1.0 and most
// clones, GPIO 38 on the DevKitC-1 v1.1. Some clones connect it only once the solder
// jumper marked "RGB" is bridged.
constexpr uint8_t  kStatusLedPin      = 48;

constexpr uint32_t kSetupCountdown    = 2000;        // ms into the hold before the countdown shows
constexpr uint32_t kSetupChordTime    = 5000;        // ms both corner keys are held to enter
constexpr uint32_t kSetupExitDelay    = 8000;        // ms after joining a new network before leaving
constexpr uint8_t  kSetupBrightness   = 60;

// A key pressed again this soon after its release is switch bounce, not a second press.
constexpr uint32_t kKeyBounce         = 50;          // ms

// Connecting screen
constexpr uint32_t kConnectingGrace    = 3000;       // ms after a session ends before it shows
constexpr uint32_t kConnectingDotStep  = 600;        // ms; each step is one key (~320 ms on a Mini)
constexpr uint32_t kConnectingDotColor = 0x0A84FF;   // system blue          // minimum, so the QR codes are readable

// Security and firmware updates
constexpr uint32_t kPairingTimeout    = 120000;      // ms before the deck cancels a pairing
constexpr uint32_t kPairingKeyGuard   = 1000;        // ms after the code appears before keys count
constexpr uint32_t kConfirmHold       = 1500;        // ms Confirm is held to confirm a pairing
constexpr uint32_t kAuthTimeout       = 10000;       // ms a paired device waits for the bridge's auth
constexpr size_t   kMaxPlainText      = 2048;        // bytes; longer unauthenticated messages are ignored
constexpr int      kMaxJSONDepth      = 8;           // arrays and objects; deeper messages are ignored
constexpr uint32_t kRollbackDeadline  = 600000;      // ms after boot for a new image to authenticate
constexpr uint32_t kRestartDelay      = 1000;        // ms after `installed` before restarting
constexpr size_t   kMaxFirmwareChunk  = 16 * 1024;
