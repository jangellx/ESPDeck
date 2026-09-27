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

#include "BridgeClient.h"
#include "Config.h"
#include "Crypto.h"
#include "FirmwareUpdate.h"
#include "Hash.h"
#include "ImageCache.h"
#include "Improv.h"
#include "ImageData.h"
#include "KeyImage.h"
#include "KeyUploader.h"
#include "Session.h"
#include "Settings.h"
#include "SetupPortal.h"
#include "StatusLed.h"
#include "StreamDeck.h"

static const char *TAG = "ESPDeck";

static StreamDeck       deck;
static ImageCache       cache;
static BridgeClient     bridge;
static Settings         settings;
static SetupPortal      portal( settings );
static KeyImage         keyImage;
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

// A pairing waiting for Confirm on the deck.
static struct {
	bool     active;
	uint8_t  shared[Crypto::kKeySize];
	char     code[7];
	char     bridgeID[Settings::kMaxBridgeID + 1];
	uint32_t deadline;
} pairing = {};

static bool             pendingVerify  = false;   // this image is new and hasn't authenticated yet
static bool             restartPending = false;   // a firmware update is installed
static uint32_t         restartAt      = 0;

static volatile bool    wifiJoined     = false;   // set on the Wi-Fi event task

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
		if( isHello )
			session.recordHello( text, length );
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
	if( frame ) {
		session.sealText( text, length, frame );
		memcpy( frame + kHexMAC, text, length + 1 );
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
	if( session.authenticated() )
		sendJSON( json );
	else
		sendPlain( json, true );
}

static void sendType( const char *type, bool plain ) {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", type );
	if( plain )
		sendPlain( json );
	else
		sendJSON( json );
}

static void sendDeck() {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "deck" );
	cJSON_AddItemToObject( json, "deck", deckJSON() );
	sendJSON( json );
}

// reason: what changed it ("timer", "key", "bridge", "chord", "setupPage", "exitKey",
// "improv", "pairing", "boot"), for the Mac's log.
static void sendStatus( const char *reason ) {
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", "status" );
	cJSON_AddItemToObject( json, "status", statusJSON() );
	cJSON_AddStringToObject( json, "reason", reason );
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

static void sendHexField( const char *type, const char *field, const uint8_t *data, size_t length ) {
	char hex[Crypto::kKeySize * 2 + 1];
	Crypto::toHex( data, length, hex );
	cJSON *json = cJSON_CreateObject();
	cJSON_AddStringToObject( json, "type", type );
	cJSON_AddStringToObject( json, field, hex );
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
	appendEscaped( wifi, settings.apPassword() );
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

// Top row: "Pair?" and the code in two halves; bottom row: Cancel at the left, Confirm at
// the right. Decks without the layout show nothing, and any key confirms.
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

	uint8_t start = pairingFirstKey();
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
			drawLine( "Confirm", 0x14803C );
		else
			keyImage.fill( 0, 0, 0 );
	} );
}

// Connected to a bridge that doesn't know this device yet.
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
	if( pairing.active )
		return Screen::Pairing;
	if( firmware.active() || restartPending )
		return Screen::Updating;
	if( chordHeld && millis() - chordSince >= kSetupCountdown && deckHasLayout() )
		return Screen::SetupCountdown;
	if( bridge.isConnected() && !session.authenticated() && !settings.isPaired() )
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

// MARK: - Pairing

static void endPairing() {
	memset( pairing.shared, 0, sizeof( pairing.shared ) );
	pairing.active = false;
	swallowKeys    = keysDown != 0;
	refreshScreen();
}

static void cancelPairing( bool notifyBridge ) {
	ESP_LOGI( TAG, "Pairing cancelled" );
	if( notifyBridge )
		sendType( "pairCancel", true );
	endPairing();
}

static void startPairing( cJSON *json ) {
	const char *bridgeID   = cJSON_GetStringValue( cJSON_GetObjectItem( json, "bridgeID" ) );
	const char *bridgeName = cJSON_GetStringValue( cJSON_GetObjectItem( json, "bridgeName" ) );
	const char *peerHex    = cJSON_GetStringValue( cJSON_GetObjectItem( json, "publicKey" ) );
	uint8_t     peer[Crypto::kKeySize];
	if( !bridgeID || !bridgeID[0] || strlen( bridgeID ) > Settings::kMaxBridgeID || !Crypto::fromHex( peerHex, peer, sizeof( peer ) ) ) {
		ESP_LOGW( TAG, "Bad pairRequest" );
		return;
	}
	if( portal.active() ) {
		ESP_LOGI( TAG, "Not pairing during setup mode" );
		sendType( "pairCancel", true );
		return;
	}

	uint8_t privateKey[Crypto::kKeySize], publicKey[Crypto::kKeySize];
	bool    ok = Crypto::makeKeyPair( privateKey, publicKey, randomBytes, nullptr )
	             && Crypto::sharedSecret( privateKey, peer, pairing.shared, randomBytes, nullptr );
	memset( privateKey, 0, sizeof( privateKey ) );
	if( !ok ) {
		ESP_LOGW( TAG, "Key agreement failed" );
		sendType( "pairCancel", true );
		return;
	}

	Crypto::pairingCode( pairing.shared, pairing.code );
	strlcpy( pairing.bridgeID, bridgeID, sizeof( pairing.bridgeID ) );
	pairing.active   = true;
	pairing.deadline = millis() + kPairingTimeout;
	sendHexField( "pairResponse", "publicKey", publicKey, sizeof( publicKey ) );
	ESP_LOGI( TAG, "Pairing with %s (%s); code %s", bridgeName ? bridgeName : "?", bridgeID, pairing.code );

	wake( "pairing" );
	refreshScreen( true );   // a repeated request brings a new code
}

static void confirmPairing() {
	uint8_t key[Crypto::kKeySize], proof[Crypto::kKeySize];
	Crypto::pairingKey( pairing.shared, pairing.bridgeID, settings.id(), key );
	Crypto::pairConfirmProof( key, proof );
	settings.setPairing( key, pairing.bridgeID );
	memset( key, 0, sizeof( key ) );

	ESP_LOGI( TAG, "Paired with %s", pairing.bridgeID );
	sendHexField( "pairConfirm", "proof", proof, sizeof( proof ) );
	endPairing();   // the bridge continues with auth
}

static void handlePairingKey( uint8_t key ) {
	if( !deckHasLayout() )
		confirmPairing();
	else if( key == confirmKey() )
		confirmPairing();
	else if( key == cancelKey() )
		cancelPairing( true );
}

// MARK: - Connection and authentication

static void onBridgeDown() {
	if( session.authenticated() )
		sessionLostAt = millis();   // the connecting screen follows after kConnectingGrace
	firmware.abort();
	if( pairing.active )
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

// Handshake step 3.
static void handleAuth( cJSON *json ) {
	uint8_t nonce[Crypto::kNonceSize], proof[Crypto::kKeySize], deviceProof[Crypto::kKeySize];
	bool    wellFormed = Crypto::fromHex( cJSON_GetStringValue( cJSON_GetObjectItem( json, "nonce" ) ), nonce, sizeof( nonce ) )
	                     && Crypto::fromHex( cJSON_GetStringValue( cJSON_GetObjectItem( json, "proof" ) ), proof, sizeof( proof ) );
	if( !wellFormed || !settings.isPaired() || !session.authenticate( settings.pairingKey(), nonce, proof, deviceProof ) ) {
		ESP_LOGW( TAG, "Bridge authentication failed; closing the connection" );
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
	ESP_LOGI( TAG, "Authenticated with %s", settings.pairedBridge() );
	hadSession = true;

	if( pendingVerify ) {
		FirmwareUpdate::markValid();
		pendingVerify = false;
	}
	if( pairing.active )
		endPairing();
	keysForwarded = 0;
	swallowKeys   = keysDown != 0;
	refreshScreen();
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
	if( pairing.active )
		cancelPairing( true );

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

// Erases everything the device has learned (Wi-Fi, name, pairing, settings, the setup
// network's password, and the image cache) and restarts. It comes back in setup mode.
// The firmware itself stays.
static void factoryReset( const char *reason ) {
	ESP_LOGW( TAG, "Factory reset (%s)", reason );

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

	cache.stop();   // no writes into the filesystem while it's erased
	esp_vfs_littlefs_unregister( "littlefs" );
	const esp_partition_t *partition = esp_partition_find_first( ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, "littlefs" );
	if( partition )
		esp_partition_erase_range( partition, 0, partition->size );   // remounted and formatted at boot
	nvs_flash_erase();

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
		cJSON      *key = cJSON_GetObjectItem( json, "key" );
		const char *hex = cJSON_GetStringValue( cJSON_GetObjectItem( json, "hash" ) );
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
		cJSON *value = cJSON_GetObjectItem( json, "value" );
		if( cJSON_IsNumber( value ) ) {
			cache.setBrightness( (uint8_t)std::min( std::max( value->valueint, 0 ), 100 ) );
			applyBrightness();
		}

	} else if( strcmp( type, "setName" ) == 0 ) {
		if( !settings.setName( cJSON_GetStringValue( cJSON_GetObjectItem( json, "name" ) ) ) )
			ESP_LOGW( TAG, "Bad setName message" );

	} else if( strcmp( type, "orientation" ) == 0 ) {
		const char           *value = cJSON_GetStringValue( cJSON_GetObjectItem( json, "value" ) );
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
		cJSON *seconds = cJSON_GetObjectItem( json, "seconds" );
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
		if( cJSON_IsTrue( cJSON_GetObjectItem( json, "enabled" ) ) )
			enterSetupMode( "bridge" );
		else
			leaveSetupMode( "bridge" );

	} else if( strcmp( type, "factoryReset" ) == 0 ) {
		factoryReset( "requested by the bridge" );

	} else if( strcmp( type, "unpair" ) == 0 ) {
		ESP_LOGI( TAG, "Unpaired by the bridge" );
		settings.clearPairing();
		dropBridge( true );

	} else if( strcmp( type, "firmwareBegin" ) == 0 ) {
		cJSON                 *size = cJSON_GetObjectItem( json, "size" );
		FirmwareUpdate::Status status;
		status.state = FirmwareUpdate::Status::State::Error;
		if( portal.active() )
			status.message = "Setup mode is on.";
		else if( !cJSON_IsNumber( size ) || size->valuedouble <= 0 )
			status.message = "Bad size.";
		else
			status = firmware.begin( cJSON_GetStringValue( cJSON_GetObjectItem( json, "version" ) ), (size_t)size->valuedouble,
			                       cJSON_GetStringValue( cJSON_GetObjectItem( json, "sha256" ) ) );
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
		ESP_LOGW( TAG, "Unknown message type %s", type );
	}
}

// Before the handshake only auth and pairing messages count.
static void handleUnauthenticated( const char *type, cJSON *json ) {
	if( strcmp( type, "auth" ) == 0 )
		handleAuth( json );
	else if( strcmp( type, "pairRequest" ) == 0 )
		startPairing( json );
	else if( strcmp( type, "pairCancel" ) == 0 && pairing.active )
		cancelPairing( false );
	else
		ESP_LOGW( TAG, "Ignoring %s before authentication", type );
}

static void handleText( const char *frame, size_t length ) {
	const char *text = frame;
	if( session.authenticated() && !session.openText( frame, length, text ) ) {
		ESP_LOGW( TAG, "Bad MAC; closing the connection" );
		dropBridge( false );
		return;
	}

	cJSON *json = cJSON_Parse( text );
	if( !json ) {
		ESP_LOGW( TAG, "Unparseable message" );
		return;
	}
	const char *type = cJSON_GetStringValue( cJSON_GetObjectItem( json, "type" ) );
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
	if( hashOf( image, length ) != claimed ) {
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
			refreshScreen( true );   // also sets the brightness; stays dark if asleep
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

	if( pairing.active && (int32_t)( now - pairing.deadline ) >= 0 )
		cancelPairing( true );

	if( restartPending && (int32_t)( now - restartAt ) >= 0 ) {
		ESP_LOGI( TAG, "Restarting into the new firmware" );
		uploader.waitIdle( 2000 );   // "Updating" reaches the deck first
		cache.persistNow();
		esp_restart();
	}

	// A new image that never reached its bridge restarts, and the bootloader rolls it back.
	if( pendingVerify && now >= kRollbackDeadline ) {
		ESP_LOGE( TAG, "New firmware didn't authenticate within %u minutes; rolling back", (unsigned)( kRollbackDeadline / 60000 ) );
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
		ESP_LOGI( TAG, "%s joining %s", settings.name(), settings.ssid() );
		WiFi.begin( settings.ssid(), settings.password() );
	} else {
		ESP_LOGI( TAG, "No Wi-Fi credentials" );
		enterSetupMode( "boot" );
	}
}

void loop() {
	statusLed.update( portal.active()                 ? StatusLed::Mode::Setup
					  : WiFi.status() == WL_CONNECTED ? StatusLed::Mode::Connected
					  :                                 StatusLed::Mode::Searching,
					  keysDown != 0, asleep );

	if( wifiJoined ) {
		wifiJoined = false;
		settings.markCredentialsWork();
	}

	portal.loop();
	if( portal.takeExitRequest() )
		leaveSetupMode( "setupPage" );

	// Wi-Fi from ESP Web Tools; like the setup page's, a network that works ends setup mode.
	improv.loop();
	if( improv.takeProvisioned() )
		leaveSetupMode( "improv" );
	if( portal.takeResetRequest() )
		factoryReset( "requested on the setup page" );
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

	checkSetupChord();
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
