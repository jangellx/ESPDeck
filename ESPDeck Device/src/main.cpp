// ESPDeck Device: a dumb bridge between ESPDeck Bridge on the Mac (Wi-Fi/WebSocket) and a
// Stream Deck (USB HID). It forwards key presses, caches the images the Mac sends, and
// shows them when told to. It knows nothing about HomeKit or what the keys do. On its own
// it only runs the sleep timer, setup mode (Wi-Fi provisioning with QR codes on the deck),
// pairing with a bridge, and firmware updates.
//
// Wire format: PROTOCOL.md next to this project.

// Arduino headers must precede lwIP's (pulled in by the WebSocket client) or INADDR_NONE collides.
#include <Arduino.h>
#include <WiFi.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>

#include "cJSON.h"
#include "driver/usb_serial_jtag.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_littlefs.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "nvs_flash.h"

#include "AppIcon.h"
#include "BridgeClient.h"
#include "Config.h"
#include "Crypto.h"
#include "DevOTA.h"
#include "FirmwareUpdate.h"
#include "Hash.h"
#include "ImageCache.h"
#include "Improv.h"
#include "ImageData.h"
#include "KeyImage.h"
#include "KeyUploader.h"
#include "SecureNVS.h"
#include "Session.h"
#include "Settings.h"
#include "SetupPortal.h"
#include "StatusLed.h"
#include "StreamDeck.h"
#include "Text.h"

static const char *TAG = "ESPDeck";

static StreamDeck       deck;
static ImageCache       cache;
static BridgeClient     bridge;
static Settings         settings;
static SetupPortal      portal( settings );
static KeyImage         keyImage;
static KeyImage         screenImage;   // the deck's extra screen, if it has one
static KeyUploader      uploader;
static Session          session;
static FirmwareUpdate   firmware;
static StatusLed        statusLed;
static Improv           improv( settings );

// The native USB port is plugged into a computer (it stays a serial port; no Stream Deck).
static bool             computerOnUSB  = false;

// What the deck shows. Anything but Normal replaces the cached key images for a while.
enum class Screen : uint8_t {
	Normal,
	Setup,
	Pairing,
	NotPaired,
	Connecting,       // paired, but no session with the bridge yet (or any more)
	Updating,
	SetupCountdown,   // the corner keys are being held; setup mode starts when it reaches 0
};

static Screen           screen         = Screen::Normal;

// The connecting screen: shown at once until the first session after boot, and after a
// short grace period when a session ends, so a quick reconnect doesn't flash it.
static bool             hadSession     = false;
static uint32_t         sessionLostAt  = 0;       // millis()
static bool             connectingWiFi = false;   // the text says "to Mac" (Wi-Fi was up)
static uint8_t          dotStep        = 0;       // 0 … 2 × cols − 1; see stepConnectingScreen()
static uint32_t         dotMovedAt     = 0;
static ImagePtr         dotImage;                 // pre-rendered for the dot's steps
static ImagePtr         blackImage;

// The connected deck, as of its Connected event.
static bool             deckConnected  = false;
static StreamDeck::Info deckInfo       = {};

// Keys whose image must be (re)uploaded to the deck, and keys still showing one of our own
// images that must go black if they have nothing else to show; one bit per key.
static uint32_t         keysToUpload   = 0;
static uint32_t         keysToBlank    = 0;

// Key tracking, one bit per key.
static uint32_t         keysDown       = 0;       // held right now
static uint32_t         keysForwarded  = 0;       // the Mac has seen keyDown but not keyUp
static bool             swallowKeys    = false;   // forward nothing until every key is up (the wake press)

static bool             asleep         = false;
static uint32_t         lastActivity   = 0;       // millis() of the last key down or up

static bool             chordHeld      = false;   // both setup-chord keys are down…
static uint32_t         chordSince     = 0;       // …since this millis()
static uint8_t          countdownShown = 0;       // seconds on the countdown key, 0 if none
static bool             setupExitShown = false;   // the setup display includes the Exit key

// Pairing (PROTOCOL.md, "Pairing"). The deck shows the code from Comparing on, and the user
// holds Confirm; K is only stored once the bridge proves it has K too, with its auth.
enum class PairingStage : uint8_t {
	None,
	Committed,   // pairResponse sent; waiting for the Mac's nonce
	Comparing,   // the code is on the deck
	Confirmed,   // confirmed on the deck; waiting for the Mac's auth
};

static struct {
	PairingStage stage;
	uint8_t      shared[Crypto::kKeySize];
	uint8_t      macPublic[Crypto::kKeySize];
	uint8_t      devicePublic[Crypto::kKeySize];
	uint8_t      macNonce[Crypto::kNonceSize];
	uint8_t      deviceNonce[Crypto::kNonceSize];
	uint8_t      key[Crypto::kKeySize];
	char         code[7];
	char         bridgeID[Settings::kMaxBridgeID + 1];
	uint32_t     deadline;
	uint32_t     shownAt;     // millis() when the code appeared; keys are ignored for kPairingKeyGuard
	int          holdKey;     // the key being held to confirm, or -1
	uint32_t     holdSince;
} pairing = {};

static bool pairingShown() {
	return pairing.stage == PairingStage::Comparing || pairing.stage == PairingStage::Confirmed;
}

static bool             pendingVerify  = false;   // this image is new and hasn't authenticated yet
static bool             restartPending = false;   // a firmware update is installed
static uint32_t         restartAt      = 0;

static volatile bool    wifiJoined     = false;   // set on the Wi-Fi event task

// A paired device that connects must authenticate within kAuthTimeout.
static uint32_t         connectedAt    = 0;

// The name in the last hello, which the bridge shows; see checkRenamed().
static char             helloName[Settings::kMaxName + 1] = {};

static void refreshScreen( bool redraw = false );
static void dropBridge( bool retrySoon );

static uint32_t keyBit( uint8_t key ) {
	return 1u << key;
}

static uint32_t allKeys( uint8_t count ) {
	return count >= 32 ? 0xFFFFFFFFu : ( 1u << count ) - 1;
}

static StreamDeck::Transform effectiveTransform() {
	StreamDeck::Transform transform = deckInfo.transform;
	StreamDeck::transformFromName( settings.orientation(), transform );   // leaves it alone for "auto"
	return transform;
}

static int randomBytes( void *, unsigned char *out, size_t length ) {
	esp_fill_random( out, length );
	return 0;
}

// MARK: - Sending to the Mac

// Unauthenticated messages (hello, auth, pairing) go out as bare JSON.
static void sendPlain( cJSON *json, bool isHello = false ) {
	char *text = cJSON_PrintUnformatted( json );
	if( text ) {
		size_t length = strlen( text );
		// Without the hello's hash the handshake can't succeed; the bridge's auth then fails.
		if( !isHello || session.recordHello( text, length ) )
			bridge.sendText( text, length );
		statusLed.activity();
		cJSON_free( text );
	}
	cJSON_Delete( json );
}

// Everything else needs the session, and goes out with its MAC in front. Before the
// handshake it's dropped.
static void sendJSON( cJSON *json ) {
	char *text = session.authenticated() ? cJSON_PrintUnformatted( json ) : nullptr;
	cJSON_Delete( json );
	if( !text )
		return;

	constexpr size_t kHexMAC = Crypto::kMACSize * 2;
	size_t length = strlen( text );
	char  *frame  = (char *)malloc( kHexMAC + length + 1 );
	if( frame && session.sealText( text, length, frame ) ) {
		memcpy( frame + kHexMAC, text, length + 1 );
	} else {
		free( frame );
		frame = nullptr;
	}
	cJSON_free( text );

	// A frame that didn't go out would throw the counters off; start over instead.
	statusLed.activity();
	if( !frame || !bridge.sendText( frame, kHexMAC + length ) ) {
		ESP_LOGW( TAG, "Sending failed; closing the connection" );
		dropBridge( false );
	}
	free( frame );
}

static cJSON *deckJSON() {
	cJSON *object = cJSON_CreateObject();
	cJSON_AddBoolToObject( object, "connected", deckConnected );
	if( deckConnected ) {
		cJSON_AddStringToObject( object, "model", deckInfo.model );
		cJSON_AddNumberToObject( object, "pid", deckInfo.pid );
		cJSON_AddStringToObject( object, "serial", deckInfo.serial );
		cJSON_AddStringToObject( object, "firmware", deckInfo.firmware );
		cJSON_AddNumberToObject( object, "rows", deckInfo.rows );
		cJSON_AddNumberToObject( object, "cols", deckInfo.cols );
		cJSON_AddNumberToObject( object, "keySize", deckInfo.keySize );
		cJSON_AddStringToObject( object, "format", StreamDeck::formatName( deckInfo.format ) );
		cJSON_AddStringToObject( object, "transform", StreamDeck::transformName( effectiveTransform() ) );
	}
	return object;
}

static cJSON *settingsJSON() {
	cJSON *object = cJSON_CreateObject();
	cJSON_AddStringToObject( object, "orientation", settings.orientation() );
	cJSON_AddNumberToObject( object, "sleepTimeout", settings.sleepTimeout() );
	cJSON_AddNumberToObject( object, "brightness", cache.brightness() );
	cJSON_AddStringToObject( object, "ip", WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString().c_str() : "" );
	return object;
}

static cJSON *statusJSON() {
	cJSON *object = cJSON_CreateObject();
	cJSON_AddBoolToObject( object, "asleep", asleep );
	cJSON_AddBoolToObject( object, "setupMode", portal.active() );
	cJSON_AddBoolToObject( object, "devOTA", settings.hasOTAPassword() );
	cJSON_AddStringToObject( object, "storage", SecureNVS::stateName() );

	// The network it's set up for, only inside the session: an unpaired device sends its
	// hello to whichever bridge it finds. So the first hello goes without it, and a status
	// follows the handshake.
	if( session.authenticated() ) {
		char   ssid[33];
		cJSON *wifi = cJSON_AddObjectToObject( object, "wifi" );
		cJSON_AddStringToObject( wifi, "ssid", Text::displayable( settings.ssid(), ssid, sizeof( ssid ) ) );
		cJSON_AddBoolToObject( wifi, "connected", settings.hasCredentials() && WiFi.status() == WL_CONNECTED && WiFi.SSID() == settings.ssid() );
	}
	return object;
}

// Unauthenticated right after connecting; inside the session (same nonce, with a MAC) when
// resent after setup mode.
static void sendHello() {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "hello" );
	cJSON_AddNumberToObject( json, "protocol", kProtocolVersion );
	cJSON_AddStringToObject( json, "id", settings.id() );
	cJSON_AddStringToObject( json, "name", settings.name() );
	cJSON_AddStringToObject( json, "firmware", firmwareVersion() );
	cJSON_AddStringToObject( json, "elfSHA256", firmwareBuild() );
	cJSON_AddStringToObject( json, "nonce", session.deviceNonceHex() );
	cJSON_AddStringToObject( json, "pairedBridge", settings.isPaired() ? settings.pairedBridge() : "" );

	cJSON *cached = cJSON_AddArrayToObject( json, "cached" );
	char   hex[kHashSize * 2 + 1];
	for( const Hash &hash : cache.hashes() ) {
		hashToHex( hash, hex );
		cJSON_AddItemToArray( cached, cJSON_CreateString( hex ) );
	}

	cJSON_AddItemToObject( json, "deck", deckJSON() );
	cJSON_AddItemToObject( json, "settings", settingsJSON() );
	cJSON_AddItemToObject( json, "status", statusJSON() );
	strlcpy( helloName, settings.name(), sizeof( helloName ) );
	if( session.authenticated() )
		sendJSON( json );
	else
		sendPlain( json, true );
}

static void sendDeck() {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "deck" );
	cJSON_AddItemToObject( json, "deck", deckJSON() );
	sendJSON( json );
}

// reason: what changed it ("timer", "key", "bridge", "chord", "setupPage", "exitKey",
// "improv", "pairing", "boot", "timeout", "session", "deck"), for the Mac's log.
static void sendStatus( const char *reason ) {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "status" );
	cJSON_AddItemToObject( json, "status", statusJSON() );
	cJSON_AddStringToObject( json, "reason", reason );
	sendJSON( json );
}

// Whatever was plugged into the USB port, for the Mac's log: a Stream Deck that never shows
// up is otherwise indistinguishable from nothing plugged in.
static void sendUsbDevice( const StreamDeck::UsbDevice &device ) {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "usbDevice" );
	if( device.vid != 0 ) {
		cJSON_AddNumberToObject( json, "vid", device.vid );
		cJSON_AddNumberToObject( json, "pid", device.pid );
		cJSON_AddNumberToObject( json, "class", device.deviceClass );
	}
	sendJSON( json );
}

static void sendKey( const char *type, uint8_t key ) {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", type );
	cJSON_AddNumberToObject( json, "key", key );
	sendJSON( json );
}

// A key now shows a cached image (uploaded, or already there): the Mac's progress display.
static void sendShown( uint8_t key, const Hash &hash ) {
	char hex[kHashSize * 2 + 1];
	hashToHex( hash, hex );
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "shown" );
	cJSON_AddNumberToObject( json, "key", key );
	cJSON_AddStringToObject( json, "hash", hex );
	sendJSON( json );
}

static void sendNeed( const char *hex ) {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "need" );
	cJSON_AddStringToObject( json, "hash", hex );
	sendJSON( json );
}

static void addHex( cJSON *json, const char *field, const uint8_t *data, size_t length ) {
	char hex[Crypto::kKeySize * 2 + 1];
	Crypto::toHex( data, length, hex );
	cJSON_AddStringToObject( json, field, hex );
}

static void sendHexField( const char *type, const char *field, const uint8_t *data, size_t length ) {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", type );
	addHex( json, field, data, length );
	sendPlain( json );
}

static void sendFirmwareStatus( const FirmwareUpdate::Status &status ) {
	using State = FirmwareUpdate::Status::State;
	if( status.state == State::None )
		return;

	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "firmwareStatus" );
	switch( status.state ) {
		case State::Ready:
			cJSON_AddStringToObject( json, "state", "ready" );
			break;
		case State::Progress:
			cJSON_AddStringToObject( json, "state", "progress" );
			cJSON_AddNumberToObject( json, "received", status.received );
			break;
		case State::Installed:
			cJSON_AddStringToObject( json, "state", "installed" );
			break;
		default:
			cJSON_AddStringToObject( json, "state", "error" );
			cJSON_AddStringToObject( json, "message", status.message );
			break;
	}
	sendJSON( json );
}

// Ends every press the Mac has seen, before key events stop being forwarded (sleep, setup
// mode, unplug). Keys still held are ignored until they're all released.
static void releaseForwardedKeys() {
	for( uint8_t key = 0; key < kMaxKeys; key++ ) {
		if( keysForwarded & keyBit( key ) )
			sendKey( "keyUp", key );
	}
	keysForwarded = 0;
	swallowKeys   = keysDown != 0;
}

// MARK: - Brightness and sleep

static void applyBrightness() {
	if( !deckConnected )
		return;

	uint8_t level = cache.brightness();
	if( screen != Screen::Normal && screen != Screen::Connecting )
		level = std::max( level, kSetupBrightness );   // our own screens must be readable
	else if( asleep )
		level = 0;
	deck.setBrightness( level );
}

static void goToSleep( const char *reason ) {
	if( asleep || ( screen != Screen::Normal && screen != Screen::Connecting ) )
		return;

	ESP_LOGI( TAG, "Sleeping (%s)", reason );
	releaseForwardedKeys();
	asleep = true;
	refreshScreen();   // leaves the connecting screen; nothing shows while asleep
	applyBrightness();
	sendStatus( reason );
}

static void wake( const char *reason ) {
	if( !asleep )
		return;

	ESP_LOGI( TAG, "Waking (%s)", reason );
	asleep       = false;
	lastActivity = millis();
	refreshScreen();
	applyBrightness();
	sendStatus( reason );
}

static void checkSleepTimer() {
	uint32_t timeout = settings.sleepTimeout();
	if( asleep || ( screen != Screen::Normal && screen != Screen::Connecting ) || timeout == 0 )
		return;
	if( (uint64_t)( millis() - lastActivity ) >= (uint64_t)timeout * 1000 )
		goToSleep( "timer" );
}

// MARK: - Screens

// Renders every key in `only` (all by default) with draw( key ), which paints keyImage,
// and uploads it.
template <typename Draw>
static void drawKeys( Draw draw, uint32_t only = 0xFFFFFFFF ) {
	if( !deckConnected || deckInfo.format == StreamDeck::Format::None )
		return;
	if( !keyImage.begin( deckInfo.keySize ) ) {
		ESP_LOGE( TAG, "Out of memory for key images" );
		return;
	}

	StreamDeck::Transform transform = effectiveTransform();
	for( uint8_t key = 0; key < deckInfo.keyCount(); key++ ) {
		if( !( only & keyBit( key ) ) )
			continue;
		draw( key );
		size_t         length = 0;
		const uint8_t *image  = keyImage.encode( deckInfo.format, transform, length );
		if( image )
			uploader.show( key, makeImage( image, length ), nullptr );
	}
}

static void drawLine( const char *line, uint32_t background = 0x000000, KeyImage::TextStyle style = KeyImage::TextStyle::Label ) {
	keyImage.drawText( &line, 1, background, style );
}

// Our layouts need a top and a bottom row of at least three keys.
static bool deckHasLayout() {
	return deckConnected && deckInfo.format != StreamDeck::Format::None && deckInfo.rows >= 2 && deckInfo.cols >= 3;
}

static int setupExitKey() {
	if( !setupExitShown || !deckHasLayout() )
		return -1;
	return ( deckInfo.rows - 1 ) * deckInfo.cols + deckInfo.cols / 2;
}

// Backslash-escapes the characters the WIFI: QR format reserves.
static void appendEscaped( String &out, const char *text ) {
	for( ; *text; text++ ) {
		if( strchr( "\\;,\":", *text ) )
			out += '\\';
		out += *text;
	}
}

static void showSetupKeys() {
	setupExitShown = portal.canExit();
	if( !deckHasLayout() ) {
		if( deckConnected )
			ESP_LOGI( TAG, "%s can't show the setup display", deckInfo.model );
		return;
	}

	String wifi = "WIFI:T:WPA;S:";
	appendEscaped( wifi, portal.apSSID() );
	wifi += ";P:";
	appendEscaped( wifi, portal.apPassword() );
	wifi += ";;";

	static const char *const kJoinLines[]  = { "1. Scan", "to join", "Wi-Fi" };
	static const char *const kSetupLines[] = { "2. Scan", "to open", "setup" };
	static const char *const kExitLines[]  = { "Exit", "setup" };

	// The network's name on the top-middle key, for joining it from the phone's Wi-Fi
	// settings when a QR-code join doesn't stick: "ESPDeck-" / "67E8" fit a key; the
	// whole name doesn't.
	String      ssid  = portal.apSSID();
	int         split = ssid.lastIndexOf( '-' );
	String      head  = split > 0 ? ssid.substring( 0, split + 1 ) : ssid;
	String      tail  = split > 0 ? ssid.substring( split + 1 ) : String();
	const char *networkLines[] = { "Wi-Fi:", head.c_str(), tail.c_str() };
	size_t      networkCount   = tail.isEmpty() ? 2 : 3;

	uint8_t cols    = deckInfo.cols;
	int     exitKey = setupExitKey();
	drawKeys( [&]( uint8_t key ) {
		if( key == 0 )
			keyImage.drawQR( wifi.c_str() );
		else if( key == cols )
			keyImage.drawText( kJoinLines, 3 );
		else if( key == cols - 1 )
			keyImage.drawQR( "http://192.168.4.1/" );
		else if( key == 2 * cols - 1 )
			keyImage.drawText( kSetupLines, 3 );
		else if( key == exitKey )
			keyImage.drawText( kExitLines, 2 );
		else if( key == cols / 2 )
			keyImage.drawText( networkLines, networkCount );
		else
			keyImage.fill( 0, 0, 0 );
	} );
}

// Top row: "Pair?" and the code in two halves; bottom row: Cancel at the left, "Hold to
// Confirm" at the right ("Waiting for Mac" once confirmed). Decks without the layout show
// nothing; holding any key confirms, and the status LED blinks magenta.
static uint8_t pairingFirstKey() {
	return ( deckInfo.cols - 3 ) / 2;
}

static uint8_t cancelKey() {
	return ( deckInfo.rows - 1 ) * deckInfo.cols;
}

static uint8_t confirmKey() {
	return cancelKey() + deckInfo.cols - 1;
}

static void showPairingKeys() {
	if( !deckHasLayout() )
		return;

	char first[4], last[4];
	memcpy( first, pairing.code, 3 );
	memcpy( last, pairing.code + 3, 3 );
	first[3] = last[3] = '\0';

	static const char *const kHold[]    = { "Hold to", "Confirm" };
	static const char *const kWaiting[] = { "Waiting", "for Mac" };
	bool    confirmed = pairing.stage == PairingStage::Confirmed;
	uint8_t start     = pairingFirstKey();
	drawKeys( [&]( uint8_t key ) {
		if( key == start )
			drawLine( "Pair?" );
		else if( key == start + 1 )
			drawLine( first, 0x000000, KeyImage::TextStyle::Big );
		else if( key == start + 2 )
			drawLine( last, 0x000000, KeyImage::TextStyle::Big );
		else if( key == cancelKey() )
			drawLine( "Cancel", 0xA01020 );
		else if( key == confirmKey() )
			keyImage.drawText( confirmed ? kWaiting : kHold, 2, confirmed ? 0x0A3D1E : 0x14803C );
		else
			keyImage.fill( 0, 0, 0 );
	} );
}

// Set up, but not paired with a bridge yet.
static void showNotPairedKeys() {
	if( !deckHasLayout() )
		return;

	uint8_t start = pairingFirstKey();
	drawKeys( [&]( uint8_t key ) {
		if( key == start )
			drawLine( "Pair in" );
		else if( key == start + 1 )
			drawLine( "ESPDeck" );
		else if( key == start + 2 )
			drawLine( "Bridge" );
		else
			keyImage.fill( 0, 0, 0 );
	} );
}

static void showUpdatingKeys() {
	static const char *const kLines[] = { "Updating", "firmware" };
	uint8_t center = deckInfo.cols / 2;
	drawKeys( [&]( uint8_t key ) {
		if( key == center )
			keyImage.drawText( kLines, 2 );
		else
			keyImage.fill( 0, 0, 0 );
	} );
}

// "Connecting / to Wi-Fi" (or "to Mac" once Wi-Fi is up) on the top-centre key, and blue
// dots filling and emptying the row below; every other key black, so no key looks usable.
static int connectingTextKey() {
	return deckInfo.cols / 2;
}

static void showConnectingText() {
	static const char *const kWiFi[] = { "Connecting", "to Wi-Fi" };
	static const char *const kMac[]  = { "Connecting", "to Mac" };
	connectingWiFi = WiFi.status() == WL_CONNECTED;
	drawKeys( [&]( uint8_t ) {
		keyImage.drawText( connectingWiFi ? kMac : kWiFi, 2 );
	}, keyBit( connectingTextKey() ) );
}

static ImagePtr renderDot( bool dot ) {
	if( !keyImage.begin( deckInfo.keySize ) )
		return nullptr;
	if( dot )
		keyImage.drawDot( kConnectingDotColor, 0.4f );
	else
		keyImage.fill( 0, 0, 0 );
	size_t         length = 0;
	const uint8_t *image  = keyImage.encode( deckInfo.format, effectiveTransform(), length );
	return image ? makeImage( image, length ) : nullptr;
}

static void showConnectingKeys() {
	if( !deckConnected || deckInfo.format == StreamDeck::Format::None )
		return;

	bool dotRow = deckInfo.rows >= 2;
	dotImage    = dotRow ? renderDot( true ) : nullptr;
	blackImage  = renderDot( false );
	dotStep     = 0;
	dotMovedAt  = millis();

	uint32_t others = allKeys( deckInfo.keyCount() ) & ~keyBit( connectingTextKey() );
	for( uint8_t key = 0; key < deckInfo.keyCount(); key++ ) {
		if( !( others & keyBit( key ) ) )
			continue;
		bool dot = dotRow && key == deckInfo.cols;   // step 0: only the first dot is lit
		uploader.show( key, dot ? dotImage : blackImage, nullptr );
	}
	showConnectingText();
}

// One step of the chaser on row 1: dots light up left to right until the row is full, then
// go out left to right until it's empty (●○○ ●●○ ●●● ○●● ○○● ○○○ for three columns). Each
// step changes one key; the uploader keeps only the newest image per key, so a slow deck
// can't fall behind.
static void stepConnectingScreen() {
	if( screen != Screen::Connecting || !deckConnected )
		return;
	if( ( WiFi.status() == WL_CONNECTED ) != connectingWiFi )
		showConnectingText();
	if( !dotImage || !blackImage || millis() - dotMovedAt < kConnectingDotStep )
		return;

	dotMovedAt = millis();
	uint8_t cols = deckInfo.cols;
	dotStep = ( dotStep + 1 ) % ( 2 * cols );
	bool    on     = dotStep < cols;
	uint8_t column = on ? dotStep : dotStep - cols;
	uploader.show( cols + column, on ? dotImage : blackImage, nullptr );
}

// While the corner keys are held: the seconds left on the bottom key of the middle
// column, "Entering / Setup In" on the key above it, every other key black.
static int countdownKey() {
	return ( deckInfo.rows - 1 ) * deckInfo.cols + deckInfo.cols / 2;
}

static uint8_t countdownSeconds() {
	uint32_t held = millis() - chordSince;
	return held >= kSetupChordTime ? 0 : (uint8_t)( ( kSetupChordTime - held + 999 ) / 1000 );
}

static void showCountdownKeys( bool digitOnly ) {
	if( !deckHasLayout() )
		return;

	static const char *const kLabel[] = { "Entering", "Setup In" };
	char digit[4];
	countdownShown = countdownSeconds();
	snprintf( digit, sizeof( digit ), "%u", countdownShown );
	const char *line = digit;

	int number = countdownKey();
	drawKeys( [&]( uint8_t key ) {
		if( key == number )
			keyImage.drawText( &line, 1, 0x000000, KeyImage::TextStyle::Big );
		else if( key == number - deckInfo.cols )
			keyImage.drawText( kLabel, 2 );
		else
			keyImage.fill( 0, 0, 0 );
	}, digitOnly ? keyBit( number ) : 0xFFFFFFFF );
}

static Screen desiredScreen() {
	if( portal.active() )
		return Screen::Setup;
	if( pairingShown() )
		return Screen::Pairing;
	if( firmware.active() || restartPending || DevOTA::active() )
		return Screen::Updating;
	if( chordHeld && millis() - chordSince >= kSetupCountdown && deckHasLayout() )
		return Screen::SetupCountdown;
	// Also while no bridge is found: pairing is still what it needs.
	if( !session.authenticated() && !settings.isPaired() && settings.hasCredentials() )
		return Screen::NotPaired;
	if( settings.isPaired() && settings.hasCredentials() && !session.authenticated() && !asleep
	    && ( !hadSession || millis() - sessionLostAt >= kConnectingGrace ) )
		return Screen::Connecting;
	return Screen::Normal;
}

// Switches the deck to the screen the current state calls for; redraw repaints it even if
// it hasn't changed (a new deck, a new transform, a new pairing code).
static void refreshScreen( bool redraw ) {
	Screen wanted = desiredScreen();
	if( wanted == screen && !redraw )
		return;

	static const char *const kNames[] = { "normal", "setup", "pairing", "not paired", "connecting", "updating", "setup countdown" };
	if( wanted != screen )
		ESP_LOGI( TAG, "Screen: %s", kNames[(int)wanted] );

	Screen previous = screen;
	screen = wanted;
	switch( wanted ) {
		case Screen::Setup:     showSetupKeys();     break;
		case Screen::Pairing:   showPairingKeys();   break;
		case Screen::NotPaired: showNotPairedKeys(); break;
		case Screen::Connecting: showConnectingKeys(); break;
		case Screen::Updating:  showUpdatingKeys();  break;
		case Screen::SetupCountdown: showCountdownKeys( false ); break;
		case Screen::Normal:
			if( previous != Screen::Normal ) {
				keysToUpload = allKeys( kMaxKeys );
				keysToBlank  = allKeys( kMaxKeys );
			}
			break;
	}
	applyBrightness();
}

// The app icon and "ESPDeck" on the Neo's info bar or the +'s touch strip, instead of
// whatever the deck showed at power-up. Drawn once per connection; brightness and sleep
// apply to it too.
static void showDeckScreen() {
	if( deckInfo.screenWidth == 0 || !screenImage.begin( deckInfo.screenWidth, deckInfo.screenHeight ) )
		return;
	bool large = deckInfo.screenHeight >= kAppIconLargeSize + 10;
	screenImage.drawIconAndText( large ? kAppIconLarge : kAppIconSmall, large ? kAppIconLargeSize : kAppIconSmallSize, "ESPDeck" );
	size_t         length = 0;
	const uint8_t *image  = screenImage.encode( StreamDeck::Format::JPEG, deckInfo.screenTransform, length );
	if( image )
		deck.setScreenImage( image, length );
}

// MARK: - Pairing

static void endPairing() {
	memset( &pairing, 0, sizeof( pairing ) );
	pairing.stage   = PairingStage::None;
	pairing.holdKey = -1;
	swallowKeys     = keysDown != 0;
	refreshScreen();
}

// reason: "deck" (Cancel pressed), "timeout", "setupMode", or why a pairRequest was refused:
// "paired", "busy", "failed". The bridge explains it to the user.
static void cancelPairing( bool notifyBridge, const char *reason ) {
	ESP_LOGI( TAG, "Pairing cancelled (%s)", reason );
	if( notifyBridge ) {
		cJSON *json = cJSON_CreateObject();
		cJSON_AddStringToObject( json, "type", "pairCancel" );
		cJSON_AddStringToObject( json, "reason", reason );
		sendPlain( json );
	}
	endPairing();
}

// Pairing step 2. Only an unpaired device pairs: moving a paired one to another Mac starts
// on the device (Unpair on its setup page) or on its own Mac (Forget Device).
static void startPairing( cJSON *json ) {
	const char *bridgeID   = cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "bridgeID" ) );
	const char *bridgeName = cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "bridgeName" ) );
	const char *peerHex    = cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "publicKey" ) );
	uint8_t     peer[Crypto::kKeySize];
	if( !bridgeID || !bridgeID[0] || strlen( bridgeID ) > Settings::kMaxBridgeID || !Crypto::fromHex( peerHex, peer, sizeof( peer ) ) ) {
		ESP_LOGW( TAG, "Bad pairRequest" );
		cancelPairing( true, "failed" );
		return;
	}
	const char *refusal = nullptr;
	if( settings.isPaired() )
		refusal = "paired";
	else if( portal.active() )
		refusal = "setupMode";
	else if( firmware.active() || restartPending || DevOTA::active() )
		refusal = "busy";
	if( refusal ) {
		ESP_LOGI( TAG, "Refusing a pairRequest (%s)", refusal );
		cancelPairing( true, refusal );
		return;
	}

	// A repeated request starts over with fresh keys and nonces.
	endPairing();
	uint8_t privateKey[Crypto::kKeySize], commitment[Crypto::kKeySize];
	memcpy( pairing.macPublic, peer, sizeof( peer ) );
	randomBytes( nullptr, pairing.deviceNonce, sizeof( pairing.deviceNonce ) );
	bool ok = Crypto::makeKeyPair( privateKey, pairing.devicePublic, randomBytes, nullptr )
	          && Crypto::sharedSecret( privateKey, peer, pairing.shared, randomBytes, nullptr )
	          && Crypto::pairCommitment( pairing.deviceNonce, pairing.devicePublic, pairing.macPublic, commitment );
	memset( privateKey, 0, sizeof( privateKey ) );
	if( !ok ) {
		ESP_LOGW( TAG, "Key agreement failed" );
		cancelPairing( true, "failed" );
		return;
	}

	strlcpy( pairing.bridgeID, bridgeID, sizeof( pairing.bridgeID ) );
	pairing.stage    = PairingStage::Committed;
	pairing.deadline = millis() + kPairingTimeout;

	cJSON *reply = cJSON_CreateObject();
	cJSON_AddStringToObject( reply, "type", "pairResponse" );
	addHex( reply, "publicKey", pairing.devicePublic, sizeof( pairing.devicePublic ) );
	addHex( reply, "commitment", commitment, sizeof( commitment ) );
	sendPlain( reply );

	char name[40], id[48];
	ESP_LOGI( TAG, "Pairing requested by %s (%s)", Text::printable( bridgeName, name, sizeof( name ) ), Text::printable( bridgeID, id, sizeof( id ) ) );
}

// Pairing step 4: the Mac's nonce. The device reveals its own, and both show the code.
static void handlePairNonce( cJSON *json ) {
	if( pairing.stage != PairingStage::Committed
	    || !Crypto::fromHex( cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "nonce" ) ), pairing.macNonce, sizeof( pairing.macNonce ) )
	    || !Crypto::pairingCode( pairing.macPublic, pairing.devicePublic, pairing.macNonce, pairing.deviceNonce, pairing.code ) ) {
		ESP_LOGW( TAG, "Unexpected pairNonce" );
		cancelPairing( true, "failed" );
		return;
	}

	sendHexField( "pairReveal", "nonce", pairing.deviceNonce, sizeof( pairing.deviceNonce ) );
	pairing.stage   = PairingStage::Comparing;
	pairing.shownAt = millis();
	pairing.holdKey = -1;
	ESP_LOGI( TAG, "Pairing code %s", pairing.code );

	wake( "pairing" );
	refreshScreen( true );
}

// Held long enough: derive K and tell the bridge. K is stored once the bridge's auth proves
// it has K too (handleAuth), which it only sends after the user confirmed on the Mac.
static void confirmPairing() {
	uint8_t proof[Crypto::kKeySize];
	bool    ok = Crypto::pairingKey( pairing.shared, pairing.macPublic, pairing.devicePublic, pairing.macNonce, pairing.deviceNonce,
	                                 pairing.bridgeID, settings.id(), pairing.key )
	             && Crypto::pairConfirmProof( pairing.key, proof );
	memset( pairing.shared, 0, sizeof( pairing.shared ) );
	if( !ok ) {
		cancelPairing( true, "failed" );
		return;
	}

	ESP_LOGI( TAG, "Pairing confirmed on the deck; waiting for the Mac" );
	sendHexField( "pairConfirm", "proof", proof, sizeof( proof ) );
	pairing.stage = PairingStage::Confirmed;
	refreshScreen( true );
}

// Keys are ignored for kPairingKeyGuard after the code appears, so a press that was already
// on its way doesn't count. Confirm has to be held for kConfirmHold (any key on decks
// without a display); Cancel works on a press.
static void handlePairingKey( uint8_t key ) {
	if( millis() - pairing.shownAt < kPairingKeyGuard )
		return;
	if( deckHasLayout() && key == cancelKey() ) {
		cancelPairing( true, "deck" );
	} else if( pairing.stage == PairingStage::Comparing && ( !deckHasLayout() || key == confirmKey() ) ) {
		pairing.holdKey   = key;
		pairing.holdSince = millis();
	}
}

static void checkPairingHold() {
	if( pairing.stage != PairingStage::Comparing || pairing.holdKey < 0 )
		return;
	if( !( keysDown & keyBit( (uint8_t)pairing.holdKey ) ) ) {
		pairing.holdKey = -1;   // let go too soon
	} else if( millis() - pairing.holdSince >= kConfirmHold ) {
		pairing.holdKey = -1;
		confirmPairing();
	}
}

// MARK: - Connection and authentication

static void onBridgeDown() {
	if( session.authenticated() )
		sessionLostAt = millis();   // the connecting screen follows after kConnectingGrace
	firmware.abort();
	if( pairing.stage != PairingStage::None )
		endPairing();
	keysForwarded = 0;
	swallowKeys   = keysDown != 0;
	session.reset();
	refreshScreen();
}

static void dropBridge( bool retrySoon ) {
	bridge.disconnect( retrySoon );
	onBridgeDown();
}

// Handshake step 3, with the stored K, or during pairing with the new K once it's been
// confirmed on the deck (which the bridge's proof then shows it has too).
static void handleAuth( cJSON *json ) {
	bool           pairingAuth = pairing.stage == PairingStage::Confirmed;
	const uint8_t *key         = pairingAuth ? pairing.key : settings.pairingKey();
	uint8_t        nonce[Crypto::kNonceSize], proof[Crypto::kKeySize], deviceProof[Crypto::kKeySize];
	bool           wellFormed  = Crypto::fromHex( cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "nonce" ) ), nonce, sizeof( nonce ) )
	                             && Crypto::fromHex( cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "proof" ) ), proof, sizeof( proof ) );
	bool           expected    = pairingAuth || ( settings.isPaired() && pairing.stage == PairingStage::None );
	if( !wellFormed || !expected || !session.authenticate( key, nonce, proof, deviceProof ) ) {
		ESP_LOGW( TAG, "Bridge authentication failed; closing the connection" );
		if( settings.isPaired() )
			bridge.avoidCurrent();
		dropBridge( false );
		return;
	}

	// The device's own auth is the last unauthenticated frame.
	char hex[Crypto::kKeySize * 2 + 1];
	Crypto::toHex( deviceProof, sizeof( deviceProof ), hex );
	cJSON *reply = cJSON_CreateObject();
	cJSON_AddStringToObject( reply, "type", "auth" );
	cJSON_AddStringToObject( reply, "proof", hex );
	sendPlain( reply );

	if( pairingAuth ) {
		settings.setPairing( pairing.key, pairing.bridgeID );
		endPairing();
	}
	char id[48];
	ESP_LOGI( TAG, "%s %s", pairingAuth ? "Paired and authenticated with" : "Authenticated with",
			  Text::printable( settings.pairedBridge(), id, sizeof( id ) ) );
	bridge.markAuthenticated();
	hadSession = true;

	if( pendingVerify ) {
		FirmwareUpdate::markValid();
		pendingVerify = false;
	}
	keysForwarded = 0;
	swallowKeys   = keysDown != 0;
	refreshScreen();

	// What the unauthenticated hello left out (the Wi-Fi network).
	sendStatus( "session" );

	// Plugged in before the Mac connected (at boot, say) but never recognized as a deck.
	StreamDeck::UsbDevice usb = deck.lastUsbDevice();
	if( usb.seen && !deckConnected )
		sendUsbDevice( usb );
}

// Renamed since the last hello (over Improv, or on the setup page) while connected: inside a
// session a fresh hello resyncs the bridge. Before one, the bridge lists the device under the
// name its hello had, so reconnect and send a new one; a pairing in progress finishes first
// (once it succeeds, the session's hello carries the new name).
static void checkRenamed() {
	if( !bridge.isConnected() || strcmp( settings.name(), helloName ) == 0 )
		return;
	if( session.authenticated() ) {
		sendHello();
	} else if( pairing.stage == PairingStage::None ) {
		ESP_LOGI( TAG, "Renamed before authenticating; reconnecting with a new hello" );
		dropBridge( true );
	}
}

// MARK: - Setup mode

static void enterSetupMode( const char *reason ) {
	if( portal.active() )
		return;

	if( firmware.active() ) {
		firmware.abort();
		FirmwareUpdate::Status status;
		status.state   = FirmwareUpdate::Status::State::Error;
		status.message = "Setup mode started.";
		sendFirmwareStatus( status );
	}
	if( pairing.stage != PairingStage::None )
		cancelPairing( true, "setupMode" );

	releaseForwardedKeys();
	asleep    = false;
	chordHeld = false;
	portal.start();
	ESP_LOGI( TAG, "Setup mode on (%s)", reason );
	refreshScreen();
	sendStatus( reason );
}

static void leaveSetupMode( const char *reason ) {
	if( !portal.active() )
		return;

	portal.stop();
	ESP_LOGI( TAG, "Setup mode off (%s)", reason );
	swallowKeys  = keysDown != 0;
	lastActivity = millis();
	refreshScreen();
	sendStatus( reason );

	// The setup page may have renamed the device. Inside a session a fresh hello resyncs the
	// Mac; before one, reconnecting starts over with a new hello.
	if( session.authenticated() )
		sendHello();
	else if( bridge.isConnected() )
		dropBridge( true );
}

// MARK: - Factory reset

// Erases everything the device has learned (Wi-Fi, name, pairing, settings, a choice of
// Standard storage, and the image cache) and restarts. It comes back in setup mode, as new.
// The firmware itself stays, and so does an eFuse key (NVS starts over encrypted).
static void factoryReset( const char *reason ) {
	ESP_LOGW( TAG, "Factory reset (%s)", reason );
	disableLoopWDT();   // erasing the image cache takes longer than the watchdog allows

	uint8_t center = deckInfo.cols / 2;
	drawKeys( [&]( uint8_t key ) {
		if( key == center )
			drawLine( "Resetting" );
		else
			keyImage.fill( 0, 0, 0 );
	} );
	uploader.waitIdle( 3000 );   // "Resetting" is on the deck before anything is erased

	portal.stop();
	if( bridge.isConnected() )
		dropBridge( false );
	WiFi.disconnect( true, true );   // also forgets the station config the Wi-Fi driver keeps

	// NVS first: the pairing, Wi-Fi and name must go even if the image cache can't.
	esp_err_t err = nvs_flash_erase();
	if( err != ESP_OK )
		ESP_LOGE( TAG, "Erasing NVS failed: %s", esp_err_to_name( err ) );

	// The cache's writer must have stopped before its filesystem goes away underneath it.
	if( cache.stop() ) {
		esp_vfs_littlefs_unregister( "littlefs" );
		const esp_partition_t *partition = esp_partition_find_first( ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, "littlefs" );
		if( partition )
			esp_partition_erase_range( partition, 0, partition->size );   // remounted and formatted at boot
	} else {
		ESP_LOGE( TAG, "The image cache didn't stop; leaving it" );
	}

	delay( 200 );
	esp_restart();
}

// MARK: - Storage encryption

// state: "encrypting" (the device restarts once it's done) or "error" (nothing changed).
static void sendStorageStatus( const char *state, const char *message ) {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "storageStatus" );
	cJSON_AddStringToObject( json, "state", state );
	if( message )
		cJSON_AddStringToObject( json, "message", message );
	sendJSON( json );
}

// The bridge's encryptStorage, after the user confirmed it there: burns the eFuse key, moves
// NVS over to encryption (SecureNVS::encrypt()), and restarts. Only between other work, so
// nothing else writes NVS meanwhile.
static void encryptStorage() {
	const char *refusal = nullptr;
	if( SecureNVS::state() == SecureNVS::State::Encrypted )
		refusal = "Storage is already encrypted.";
	else if( SecureNVS::state() == SecureNVS::State::Unsupported )
		refusal = "This chip has no free eFuse key block.";
	else if( portal.active() )
		refusal = "Leave setup mode first.";
	else if( firmware.active() || restartPending || DevOTA::active() )
		refusal = "A firmware update is running.";
	if( refusal ) {
		ESP_LOGW( TAG, "Not encrypting storage: %s", refusal );
		sendStorageStatus( "error", refusal );
		return;
	}

	ESP_LOGW( TAG, "Encrypting storage (requested by the bridge)" );
	sendStorageStatus( "encrypting", nullptr );
	disableLoopWDT();   // the move and the waits add up to more than the watchdog allows

	uint8_t center = deckInfo.cols / 2;
	drawKeys( [&]( uint8_t key ) {
		static const char *const kLines[] = { "Encrypting", "storage" };
		if( key == center )
			keyImage.drawText( kLines, 2 );
		else
			keyImage.fill( 0, 0, 0 );
	} );
	uploader.waitIdle( 3000 );
	cache.persistNow();   // the image cache is on LittleFS, not NVS; nothing of it is lost

	const char        *error   = nullptr;
	SecureNVS::Outcome outcome = SecureNVS::encrypt( error );
	if( outcome == SecureNVS::Outcome::Refused ) {
		ESP_LOGE( TAG, "Not encrypting storage: %s", error );
		sendStorageStatus( "error", error );
		enableLoopWDT();
		keysToUpload = allKeys( kMaxKeys );   // the key images again, instead of "Encrypting"
		keysToBlank  = allKeys( kMaxKeys );
		refreshScreen( true );
		return;
	}
	if( outcome == SecureNVS::Outcome::Failed )
		ESP_LOGE( TAG, "%s Restarting.", error );
	else
		ESP_LOGI( TAG, "Storage encrypted; restarting" );
	if( bridge.isConnected() )
		dropBridge( false );
	delay( 200 );
	esp_restart();
}

// Top-left and bottom-right held together for kSetupChordTime.
static void checkSetupChord() {
	uint8_t count = deckInfo.keyCount();
	if( portal.active() || !deckConnected || count < 2 ) {
		chordHeld = false;
		return;
	}

	uint32_t chord = keyBit( 0 ) | keyBit( count - 1 );
	if( ( keysDown & chord ) != chord ) {
		// Letting go of either key cancels, and the keys go back to normal.
		chordHeld = false;
		if( screen == Screen::SetupCountdown )
			refreshScreen();
	} else if( !chordHeld ) {
		chordHeld  = true;
		chordSince = millis();
	} else if( millis() - chordSince >= kSetupChordTime ) {
		ESP_LOGI( TAG, "Setup chord held" );
		enterSetupMode( "chord" );
	} else if( screen != Screen::SetupCountdown ) {
		refreshScreen();   // shows the countdown once kSetupCountdown has passed
	} else if( countdownSeconds() != countdownShown ) {
		showCountdownKeys( true );
	}
}

// MARK: - Messages from the Mac

static void handleCommand( const char *type, cJSON *json ) {
	if( strcmp( type, "show" ) == 0 ) {
		cJSON      *key = cJSON_GetObjectItemCaseSensitive( json, "key" );
		const char *hex = cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "hash" ) );
		Hash        hash;
		if( cJSON_IsNumber( key ) && key->valueint >= 0 && key->valueint < kMaxKeys && hashFromHex( hex, hash ) ) {
			ImageCache::Lookup lookup = cache.assign( (uint8_t)key->valueint, hash );
			ESP_LOGI( TAG, "Show key %d: %02x%02x… %s", key->valueint, hash[0], hash[1],
					  lookup == ImageCache::Lookup::Ready ? "in PSRAM" : lookup == ImageCache::Lookup::Loading ? "loading from flash" : "missing" );
			if( lookup == ImageCache::Lookup::Ready )
				keysToUpload |= keyBit( key->valueint );
			else if( lookup == ImageCache::Lookup::Missing )
				sendNeed( hex );   // shown as soon as the image arrives
			// Loading: cache.takeReady() reports the key once it's in PSRAM
		} else {
			ESP_LOGW( TAG, "Bad show message" );
		}

	} else if( strcmp( type, "brightness" ) == 0 ) {
		cJSON *value = cJSON_GetObjectItemCaseSensitive( json, "value" );
		if( cJSON_IsNumber( value ) ) {
			cache.setBrightness( (uint8_t)std::min( std::max( value->valueint, 0 ), 100 ) );
			applyBrightness();
		}

	} else if( strcmp( type, "devOTA" ) == 0 ) {
		// Uploads from PlatformIO: the password's SHA-256, sealed for this frame, or nothing
		// (or an empty passwordHash, as older bridges send) to turn them off. A hash in the
		// clear isn't accepted: it works as the password.
		const char *sealedHex = cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "sealedHash" ) );
		const char *plain     = cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "passwordHash" ) );
		bool        ok;
		if( sealedHex && sealedHex[0] ) {
			uint8_t sealed[Crypto::kSealedHash], hash[32];
			char    hex[65];
			ok = Crypto::fromHex( sealedHex, sealed, sizeof( sealed ) ) && session.openDevOTA( sealed, hash );
			if( ok ) {
				Crypto::toHex( hash, sizeof( hash ), hex );
				ok = settings.setOTAPasswordHash( hex );
			}
			memset( hash, 0, sizeof( hash ) );
			memset( hex, 0, sizeof( hex ) );
		} else {
			ok = !plain || !plain[0];
			if( ok )
				settings.setOTAPasswordHash( nullptr );
		}
		if( ok )
			ESP_LOGI( TAG, "Uploads from PlatformIO %s", settings.hasOTAPassword() ? "allowed" : "off" );
		else
			ESP_LOGW( TAG, "Bad devOTA message" );
		DevOTA::setPasswordHash( settings.otaPasswordHash() );
		sendStatus( "bridge" );

	} else if( strcmp( type, "setName" ) == 0 ) {
		if( settings.setName( cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "name" ) ) ) )
			strlcpy( helloName, settings.name(), sizeof( helloName ) );   // the bridge knows it
		else
			ESP_LOGW( TAG, "Bad setName message" );

	} else if( strcmp( type, "orientation" ) == 0 ) {
		const char           *value = cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "value" ) );
		StreamDeck::Transform transform;
		if( value && ( strcmp( value, "auto" ) == 0 || StreamDeck::transformFromName( value, transform ) ) ) {
			settings.setOrientation( value );
			if( screen != Screen::Normal )
				refreshScreen( true );
		} else {
			ESP_LOGW( TAG, "Bad orientation message" );
		}
		sendDeck();   // the Mac re-renders for the transform in effect

	} else if( strcmp( type, "sleepTimeout" ) == 0 ) {
		cJSON *seconds = cJSON_GetObjectItemCaseSensitive( json, "seconds" );
		if( cJSON_IsNumber( seconds ) && seconds->valuedouble >= 0 )
			settings.setSleepTimeout( (uint32_t)std::min( seconds->valuedouble, 30.0 * 24 * 3600 ) );

	} else if( strcmp( type, "sleep" ) == 0 ) {
		goToSleep( "bridge" );

	} else if( strcmp( type, "wake" ) == 0 ) {
		if( asleep ) {
			wake( "bridge" );
			swallowKeys = keysDown != 0;   // keys held while asleep stay unforwarded
		}

	} else if( strcmp( type, "setupMode" ) == 0 ) {
		if( cJSON_IsTrue( cJSON_GetObjectItemCaseSensitive( json, "enabled" ) ) )
			enterSetupMode( "bridge" );
		else
			leaveSetupMode( "bridge" );

	} else if( strcmp( type, "factoryReset" ) == 0 ) {
		factoryReset( "requested by the bridge" );

	} else if( strcmp( type, "encryptStorage" ) == 0 ) {
		encryptStorage();

	} else if( strcmp( type, "unpair" ) == 0 ) {
		ESP_LOGI( TAG, "Unpaired by the bridge" );
		settings.clearPairing();
		dropBridge( true );

	} else if( strcmp( type, "firmwareBegin" ) == 0 ) {
		cJSON                 *size = cJSON_GetObjectItemCaseSensitive( json, "size" );
		FirmwareUpdate::Status status;
		status.state = FirmwareUpdate::Status::State::Error;
		if( portal.active() )
			status.message = "Setup mode is on.";
		else if( restartPending )
			status.message = "An update is installed; the device is restarting.";
		else if( DevOTA::active() )
			status.message = "An upload from PlatformIO is running.";
		else if( !cJSON_IsNumber( size ) || size->valuedouble <= 0 )
			status.message = "Bad size.";
		else
			status = firmware.begin( cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "version" ) ), (size_t)size->valuedouble,
			                         cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "sha256" ) ),
			                         cJSON_IsTrue( cJSON_GetObjectItemCaseSensitive( json, "allowDowngrade" ) ) );
		sendFirmwareStatus( status );
		refreshScreen();

	} else if( strcmp( type, "firmwareEnd" ) == 0 ) {
		FirmwareUpdate::Status status = firmware.finish();
		if( status.state == FirmwareUpdate::Status::State::Installed ) {
			restartPending = true;
			restartAt      = millis() + kRestartDelay;
		}
		sendFirmwareStatus( status );
		refreshScreen();

	} else {
		char safe[32];
		ESP_LOGW( TAG, "Unknown message type %s", Text::printable( type, safe, sizeof( safe ) ) );
	}
}

// Before the handshake only auth and pairing messages count.
static void handleUnauthenticated( const char *type, cJSON *json ) {
	if( strcmp( type, "auth" ) == 0 ) {
		handleAuth( json );
	} else if( strcmp( type, "pairRequest" ) == 0 ) {
		startPairing( json );
	} else if( strcmp( type, "pairNonce" ) == 0 ) {
		handlePairNonce( json );
	} else if( strcmp( type, "pairCancel" ) == 0 ) {
		if( pairing.stage != PairingStage::None )
			cancelPairing( false, "bridge" );
	} else {
		char safe[32];
		ESP_LOGW( TAG, "Ignoring %s before authentication", Text::printable( type, safe, sizeof( safe ) ) );
	}
}

static void handleText( const char *frame, size_t length ) {
	const char *text = frame;
	if( session.authenticated() ) {
		if( !session.openText( frame, length, text ) ) {
			ESP_LOGW( TAG, "Bad MAC; closing the connection" );
			dropBridge( false );
			return;
		}
	} else if( length > kMaxPlainText ) {
		ESP_LOGW( TAG, "Ignoring a %u byte message before authentication", (unsigned)length );
		return;
	}

	// cJSON parses recursively on this task's stack; deep nesting would overflow it.
	size_t jsonLength = length - (size_t)( text - frame );
	if( !Text::jsonDepthWithin( text, jsonLength, kMaxJSONDepth ) ) {
		ESP_LOGW( TAG, "Message nested too deeply; ignored" );
		return;
	}
	cJSON *json = cJSON_ParseWithLength( text, jsonLength );
	if( !json ) {
		ESP_LOGW( TAG, "Unparseable message" );
		return;
	}
	const char *type = cJSON_GetStringValue( cJSON_GetObjectItemCaseSensitive( json, "type" ) );
	if( !type )
		type = "";

	if( session.authenticated() )
		handleCommand( type, json );
	else
		handleUnauthenticated( type, json );
	cJSON_Delete( json );
}

// "IMG1" + 16-byte hash + image file
static void handleImage( const uint8_t *data, size_t size ) {
	constexpr size_t kHeader = 4 + kHashSize;
	if( size <= kHeader || size - kHeader > kMaxImageSize ) {
		ESP_LOGW( TAG, "Bad image frame (%u bytes)", (unsigned)size );
		return;
	}

	Hash claimed;
	memcpy( claimed.data(), data + 4, kHashSize );
	const uint8_t *image  = data + kHeader;
	size_t         length = size - kHeader;

	int64_t received = esp_timer_get_time();
	Hash    actual;
	if( !hashOf( image, length, actual ) || actual != claimed ) {
		ESP_LOGW( TAG, "Image hash mismatch; dropped" );
		return;
	}
	int64_t verified = esp_timer_get_time();

	// Into PSRAM only; the cache's own task saves it to flash later if it stays on a key.
	if( cache.store( claimed, image, length ) ) {
		keysToUpload |= cache.takeReady();
		ESP_LOGI( TAG, "Image %02x%02x…: %u bytes, verified in %lld ms, cached in %lld ms", claimed[0], claimed[1], (unsigned)length,
				  ( verified - received ) / 1000, ( esp_timer_get_time() - verified ) / 1000 );
	}
}

static void handleBinary( const uint8_t *frame, size_t length ) {
	if( !session.authenticated() ) {
		ESP_LOGW( TAG, "Ignoring binary data before authentication" );
		return;
	}

	const uint8_t *payload = nullptr;
	size_t         size    = 0;
	if( !session.openBinary( frame, length, payload, size ) ) {
		ESP_LOGW( TAG, "Bad MAC; closing the connection" );
		dropBridge( false );
		return;
	}

	if( size >= 4 && memcmp( payload, "IMG1", 4 ) == 0 ) {
		handleImage( payload, size );
	} else if( size >= 4 && memcmp( payload, "FWU1", 4 ) == 0 ) {
		FirmwareUpdate::Status status = firmware.write( payload, size );
		sendFirmwareStatus( status );
		if( status.state == FirmwareUpdate::Status::State::Error )
			refreshScreen();
	} else {
		ESP_LOGW( TAG, "Unknown binary frame (%u bytes)", (unsigned)size );
	}
}

// MARK: - Deck

static void handleKeyDown( uint8_t key ) {
	keysDown     |= keyBit( key );
	lastActivity  = millis();

	switch( screen ) {
		case Screen::Setup:
			if( key == setupExitKey() )
				leaveSetupMode( "exitKey" );
			return;
		case Screen::Pairing:
			handlePairingKey( key );
			return;
		case Screen::NotPaired:
		case Screen::Connecting:
		case Screen::Updating:
		case Screen::SetupCountdown:
			return;
		case Screen::Normal:
			break;
	}

	if( asleep ) {
		wake( "key" );
		swallowKeys = true;   // this press only wakes the deck
		return;
	}
	if( swallowKeys || !session.authenticated() )
		return;

	ESP_LOGI( TAG, "Key %u down", key );
	keysForwarded |= keyBit( key );
	sendKey( "keyDown", key );
}

static void handleKeyUp( uint8_t key ) {
	keysDown     &= ~keyBit( key );
	lastActivity  = millis();

	if( keysForwarded & keyBit( key ) ) {
		keysForwarded &= ~keyBit( key );
		sendKey( "keyUp", key );
	}
	if( !keysDown )
		swallowKeys = false;
}

static void handleDeckEvent( const StreamDeck::Event &event ) {
	switch( event.type ) {
		case StreamDeck::EventType::Connected:
			deckInfo      = deck.info();
			deckConnected = true;
			keysDown      = 0;
			keysForwarded = 0;
			swallowKeys   = false;
			keysToBlank   = 0;   // a freshly plugged-in deck shows its own logo
			keysToUpload  = allKeys( deckInfo.keyCount() );
			uploader.reset();
			// The sleep timer runs with no deck attached too, so a deck plugged into an idle
			// board would otherwise stay dark. Plugging one in counts as activity.
			lastActivity  = millis();
			wake( "deck" );
			refreshScreen( true );   // also sets the brightness
			showDeckScreen();
			sendDeck();
			break;
		case StreamDeck::EventType::Disconnected:
			uploader.reset();
			keysDown = 0;
			releaseForwardedKeys();
			deckConnected = false;
			sendDeck();
			break;
		case StreamDeck::EventType::KeyDown:
			ESP_LOGI( TAG, "Deck key %u down (screen %d, asleep %d, swallowing %d, authenticated %d)",
					  event.key, (int)screen, asleep, swallowKeys, session.authenticated() );
			statusLed.keyPressed();
			handleKeyDown( event.key );
			break;
		case StreamDeck::EventType::KeyUp:
			ESP_LOGI( TAG, "Deck key %u up (forwarded %d)", event.key, ( keysForwarded & keyBit( event.key ) ) != 0 );
			handleKeyUp( event.key );
			break;
		case StreamDeck::EventType::UsbDevice:
			sendUsbDevice( deck.lastUsbDevice() );
			break;
	}
}

// Images cached for a different model (in the wrong format) aren't sent to the deck.
static bool matchesFormat( const uint8_t *image, size_t length ) {
	if( length < 2 )
		return false;
	switch( deckInfo.format ) {
		case StreamDeck::Format::BMP:  return image[0] == 'B' && image[1] == 'M';
		case StreamDeck::Format::JPEG: return image[0] == 0xFF && image[1] == 0xD8;
		default:                       return false;
	}
}

// Hands each key's image to the upload task, which skips any a key already shows.
static void uploadPendingKeys() {
	if( !deckConnected || screen != Screen::Normal || deckInfo.format == StreamDeck::Format::None )
		return;

	keysToUpload &= allKeys( deckInfo.keyCount() );   // keys this model doesn't have are never shown
	while( keysToUpload ) {
		uint8_t key   = __builtin_ctz( keysToUpload );
		bool    blank = keysToBlank & keyBit( key );
		keysToUpload &= ~keyBit( key );
		keysToBlank  &= ~keyBit( key );

		Hash     hash;
		ImagePtr image = cache.keyImage( key, &hash );
		if( image && matchesFormat( image->data(), image->size() ) ) {
			uploader.show( key, image, &hash );
		} else if( blank && keyImage.begin( deckInfo.keySize ) ) {
			size_t length = 0;
			keyImage.fill( 0, 0, 0 );
			const uint8_t *black = keyImage.encode( deckInfo.format, effectiveTransform(), length );
			if( black )
				uploader.show( key, makeImage( black, length ), nullptr );
		}
	}
}

// MARK: - Timers

static void checkTimers() {
	uint32_t now = millis();

	if( pairing.stage != PairingStage::None && (int32_t)( now - pairing.deadline ) >= 0 )
		cancelPairing( true, "timeout" );

	// A paired device gives a bridge kAuthTimeout to authenticate. One that doesn't (a
	// stand-in advertising our bridge's ID, say) is dropped and its address avoided for a
	// while, so the device gets back to looking for the real one.
	if( bridge.isConnected() && !session.authenticated() && settings.isPaired() && now - connectedAt >= kAuthTimeout ) {
		ESP_LOGW( TAG, "The bridge didn't authenticate within %u s; closing the connection", (unsigned)( kAuthTimeout / 1000 ) );
		bridge.avoidCurrent();
		dropBridge( false );
	}

	if( restartPending && (int32_t)( now - restartAt ) >= 0 ) {
		ESP_LOGI( TAG, "Restarting into the new firmware" );
		disableLoopWDT();            // the waits below can add up to more than its timeout
		uploader.waitIdle( 2000 );   // "Updating" reaches the deck first
		cache.persistNow();
		esp_restart();
	}

	// A new image that never reached its bridge restarts, and the bootloader rolls it back.
	if( pendingVerify && now >= kRollbackDeadline ) {
		ESP_LOGE( TAG, "New firmware didn't authenticate within %u minutes; rolling back", (unsigned)( kRollbackDeadline / 60000 ) );
		disableLoopWDT();
		cache.persistNow();
		esp_restart();
	}
}

// MARK: - USB port

// A computer on the native USB port sends start-of-frame packets every millisecond, which
// the USB-Serial-JTAG peripheral notices. With the OTG adapter and a Stream Deck there's no
// host upstream and so no SOFs. A computer that was just plugged in needs a moment to
// enumerate the port, hence the wait.
static bool detectComputer() {
	constexpr uint32_t kSettle  = 20;     // ms; the SOF monitor starts out assuming "connected"
	constexpr uint32_t kTimeout = 1500;

	uint32_t start = millis();
	delay( kSettle );
	while( !usb_serial_jtag_is_connected() && millis() - start < kTimeout )
		delay( 10 );

	bool     connected = usb_serial_jtag_is_connected();
	unsigned elapsed   = (unsigned)( millis() - start );
	if( connected )
		ESP_LOGI( TAG, "USB port: computer (start-of-frame packets after %u ms); staying a serial port, no Stream Deck", elapsed );
	else
		ESP_LOGI( TAG, "USB port: no computer after %u ms; starting the USB host for a Stream Deck", elapsed );
	return connected;
}

// MARK: - Arduino

void setup() {
	ESP_LOGI( TAG, "ESPDeck %s", firmwareVersion() );
	// The QR library logs each payload at INFO, which would print the access point's password.
	esp_log_level_set( "QRCODE", ESP_LOG_WARN );

	pendingVerify = FirmwareUpdate::pendingVerify();
	if( pendingVerify )
		ESP_LOGI( TAG, "New firmware; waiting for an authenticated connection to keep it" );

	statusLed.begin( kStatusLedPin );
	// initArduino() set NVS up through SecureNVS (nvs_flash_init() is wrapped); without that,
	// an encrypted device's settings would have been erased.
	if( !SecureNVS::ready() )
		ESP_LOGE( TAG, "NVS isn't set up (storage %s)", SecureNVS::stateName() );
	settings.begin();

	// "espdeck-eeff": unique per device, for DHCP and mDNS.
	static char hostname[16];
	snprintf( hostname, sizeof( hostname ), "espdeck-%s", settings.idSuffix() );
	for( char *c = hostname; *c; c++ )
		*c = (char)tolower( *c );

	if( !cache.begin() )
		ESP_LOGE( TAG, "Image cache unavailable" );
	// The USB host stack takes the port over from USB-Serial-JTAG, so only with no computer.
	computerOnUSB = detectComputer();
	improv.begin( computerOnUSB );
	if( !computerOnUSB ) {
		if( deck.begin() )
			uploader.begin( deck );
		else
			ESP_LOGE( TAG, "USB host unavailable" );
	}
	bridge.begin( hostname );
	DevOTA::begin( hostname, [] { refreshScreen( true ); }, [] { cache.persistNow(); } );
	DevOTA::setPasswordHash( settings.otaPasswordHash() );
	portal.begin();
	session.reset();

	WiFi.onEvent( []( arduino_event_id_t, arduino_event_info_t ) { wifiJoined = true; }, ARDUINO_EVENT_WIFI_STA_GOT_IP );
	WiFi.persistent( false );   // credentials live in Settings
	WiFi.mode( WIFI_STA );
	// Mains powered: no modem sleep. With it, the radio only wakes for beacons, so data from
	// the Mac (19 KB images) trickles in and key presses reach it late.
	WiFi.setSleep( false );
	WiFi.setHostname( hostname );
	WiFi.setAutoReconnect( true );

	lastActivity = millis();
	if( settings.hasCredentials() ) {
		char name[40], ssid[40];
		ESP_LOGI( TAG, "%s joining %s", Text::printable( settings.name(), name, sizeof( name ) ), Text::printable( settings.ssid(), ssid, sizeof( ssid ) ) );
		WiFi.begin( settings.ssid(), settings.password() );
	} else {
		ESP_LOGI( TAG, "No Wi-Fi credentials" );
		enterSetupMode( "boot" );
	}

	// A loop pass that takes longer than CONFIG_ESP_TASK_WDT_TIMEOUT_S restarts the device.
	// Nothing in it legitimately does: image uploads take ~320 ms, flash writes happen on
	// the cache's own task, an upload from PlatformIO feeds the watchdog as it goes, and the
	// long waits before a restart or a factory reset turn it off first.
	enableLoopWDT();
}

void loop() {
	statusLed.update( pairing.stage == PairingStage::Confirmed ? StatusLed::Mode::PairingConfirmed
					  : pairingShown()                         ? StatusLed::Mode::Pairing
					  : portal.active()                        ? StatusLed::Mode::Setup
					  : WiFi.status() == WL_CONNECTED          ? StatusLed::Mode::Connected
					  :                                          StatusLed::Mode::Searching,
					  keysDown != 0, asleep );

	if( wifiJoined ) {
		wifiJoined = false;
		settings.markCredentialsWork();
		// With uploads from PlatformIO on, a new image is kept once it's on Wi-Fi, where the
		// next upload comes from, rather than waiting for a bridge that may not be part of
		// the test.
		if( pendingVerify && settings.hasOTAPassword() ) {
			FirmwareUpdate::markValid();
			pendingVerify = false;
		}
	}
	// Pairing again or unpairing (here or on the setup page) turns uploads off.
	DevOTA::setPasswordHash( settings.otaPasswordHash() );
	DevOTA::loop( firmware.active() || restartPending );

	portal.loop();
	if( portal.takeExitRequest() )
		leaveSetupMode( "setupPage" );
	if( portal.takeIdleTimeout() )
		leaveSetupMode( "timeout" );

	// Wi-Fi from ESP Web Tools; like the setup page's, a network that works ends setup mode.
	improv.loop();
	if( improv.takeProvisioned() )
		leaveSetupMode( "improv" );
	if( portal.takeResetRequest() )
		factoryReset( "requested on the setup page" );

	// Encrypting storage for a new device's first network fell back to plain storage after
	// burning the key (SecureNVS::encryptForSetup()); the next start encrypts it, so restart
	// once setup is over.
	if( SecureNVS::restartWanted() && !portal.active() && !firmware.active() && !restartPending && !DevOTA::active() ) {
		ESP_LOGW( TAG, "Restarting to finish encrypting storage" );
		disableLoopWDT();
		if( bridge.isConnected() )
			dropBridge( false );
		delay( 200 );
		esp_restart();
	}
	if( screen == Screen::Setup && portal.canExit() != setupExitShown )
		refreshScreen( true );   // add or remove the Exit key

	// Unpairing on the setup page ends the session too.
	if( session.authenticated() && !settings.isPaired() )
		dropBridge( true );
	bridge.setPreferredBridge( settings.pairedBridge() );
	bridge.loop();

	// Key presses first, and again between messages from the Mac, so a burst of images
	// (each a flash write) doesn't hold them up.
	StreamDeck::Event event;
	while( deck.nextEvent( event ) )
		handleDeckEvent( event );

	BridgeClient::Message message;
	while( bridge.nextMessage( message ) ) {
		statusLed.activity();
		switch( message.kind ) {
			case BridgeClient::Message::Kind::Connected:
				session.reset();
				connectedAt = millis();
				sendHello();
				refreshScreen();
				break;
			case BridgeClient::Message::Kind::Disconnected:
				onBridgeDown();   // the deck keeps showing its last images
				break;
			case BridgeClient::Message::Kind::Text:
				handleText( (const char *)message.data, message.size );
				break;
			case BridgeClient::Message::Kind::Binary:
				handleBinary( message.data, message.size );
				break;
		}
		BridgeClient::release( message );

		while( deck.nextEvent( event ) )
			handleDeckEvent( event );
	}

	checkRenamed();
	checkSetupChord();
	checkPairingHold();
	checkSleepTimer();
	checkTimers();
	refreshScreen();
	stepConnectingScreen();

	// Images that reached PSRAM (from the Mac or from flash), images the Mac must resend, and
	// uploads that finished.
	keysToUpload |= cache.takeReady();
	for( const Hash &hash : cache.takeMissing() ) {
		char hex[kHashSize * 2 + 1];
		hashToHex( hash, hex );
		sendNeed( hex );
	}
	uploadPendingKeys();
	KeyUploader::Shown shown;
	while( uploader.nextShown( shown ) )
		sendShown( shown.key, shown.hash );

	delay( portal.active() ? 2 : 5 );
}
