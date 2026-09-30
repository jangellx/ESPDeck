// Arduino headers must precede anything that pulls in lwIP, or INADDR_NONE collides.
#include <Arduino.h>
#include <AsyncUDP.h>
#include <WebServer.h>
#include <WiFi.h>

#include "SetupPortal.h"

#include <algorithm>
#include <cstring>

#include "cJSON.h"
#include "esp_log.h"
#include "esp_random.h"

#include "Config.h"
#include "SecureNVS.h"
#include "Text.h"

static const char *TAG = "Setup";

namespace {
	const IPAddress kAddress( 192, 168, 4, 1 );
	const IPAddress kNetmask( 255, 255, 255, 0 );
	constexpr const char *kPortalHost     = "192.168.4.1";      // the Host the page's requests name,
	constexpr const char *kPortalHostPort = "192.168.4.1:80";   // with or without the port
	constexpr const char *kPortalURL      = "http://192.168.4.1/";
	constexpr const char *kPortalOrigin   = "http://192.168.4.1";
	constexpr uint16_t    kDNSPort        = 53;
	constexpr uint8_t     kAPChannel      = 1;
	constexpr int         kAPMaxStations  = 4;
	constexpr size_t      kSafeSSID       = 40;        // buffer for an SSID made printable
	constexpr uint32_t    kConnectTimeout = 30000;     // ms before the page reports a failure
	constexpr uint32_t    kIdleTimeout    = 900000;    // ms without a phone on the access point
	constexpr uint32_t    kStationCheck   = 1000;      // ms between looks for phones

	// No 0/O, 1/l/i, in case the password is read off a phone and typed. 12 characters
	// (59 bits) still fit the smallest keys' QR code (version 3).
	constexpr const char *kPasswordAlphabet = "abcdefghjkmnpqrstuvwxyz23456789";
	constexpr size_t      kPasswordLength   = 12;

	WebServer webServer( 80 );
	AsyncUDP  dnsSocket;

	// Whether address is on the access point's subnet.
	bool onAccessPoint( const IPAddress &address ) {
		return ( (uint32_t)address & (uint32_t)kNetmask ) == ( (uint32_t)kAddress & (uint32_t)kNetmask );
	}

	// The captive-portal DNS server: every name is 192.168.4.1, for queries that arrive on the
	// access point only. Runs on AsyncUDP's task.
	void answerDNS( AsyncUDPPacket &packet ) {
		constexpr size_t kHeader    = 12;
		constexpr size_t kMaxLength = 512;   // DNS over UDP
		const uint8_t   *query      = packet.data();
		size_t           length     = packet.length();
		if( packet.interface() != TCPIP_ADAPTER_IF_AP || length < kHeader + 5 || length > kMaxLength )
			return;
		// A standard query (QR 0, opcode 0) with exactly one question.
		if( ( query[2] & 0xF8 ) != 0 || query[4] != 0 || query[5] != 1 )
			return;

		size_t end = kHeader;
		while( end < length && query[end] != 0 ) {
			if( query[end] & 0xC0 )
				return;   // no compression pointers in a question
			end += query[end] + 1;
		}
		if( end + 5 > length )
			return;
		size_t   questionEnd = end + 5;   // the name's terminator, type and class
		uint16_t type        = (uint16_t)( query[end + 1] << 8 | query[end + 2] );
		bool     answer      = type == 1 || type == 255;   // A or ANY; others get no records

		uint8_t header[kHeader] = {};
		memcpy( header, query, 2 );                            // ID
		header[2] = (uint8_t)( 0x84 | ( query[2] & 0x01 ) );   // response, authoritative, RD copied
		header[5] = 1;                                         // one question
		header[7] = answer ? 1 : 0;                            // and its answer, if any
		// The answer: the question's name (a pointer to it), A, IN, TTL 60 s, 192.168.4.1.
		static const uint8_t kRecord[] = { 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 168, 4, 1 };

		AsyncUDPMessage reply( questionEnd + sizeof( kRecord ) );
		reply.write( header, sizeof( header ) );
		reply.write( query + kHeader, questionEnd - kHeader );
		if( answer )
			reply.write( kRecord, sizeof( kRecord ) );
		packet.send( reply );
	}

	// The whole setup page: no external resources, since the phone has no internet here.
	const char kPage[] = R"HTML(<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>ESPDeck Setup</title>
<style>
:root{--bg:#f2f2f7;--card:#fff;--text:#1c1c1e;--muted:#6e6e73;--line:#d8d8dd;--field:#f5f5f8;--accent:#0a7cff;--ok:#2fb350;--busy:#ff9f0a;--bad:#ff3b30}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f5f5f7;--muted:#98989f;--line:#3a3a3c;--field:#2c2c2e;--accent:#3d9bff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-text-size-adjust:100%}
main{max-width:460px;margin:0 auto;padding:28px 16px 48px}
h1{font-size:28px;letter-spacing:-.02em;margin:0}
.sub{color:var(--muted);margin:2px 0 20px}
.card{background:var(--card);border-radius:16px;padding:18px;margin-bottom:16px;box-shadow:0 1px 2px rgba(0,0,0,.06)}
.status{display:flex;gap:12px}
.dot{width:12px;height:12px;border-radius:50%;margin-top:6px;flex:none;background:var(--muted)}
.dot.ok{background:var(--ok)}.dot.bad{background:var(--bad)}
.dot.busy{background:var(--busy);animation:pulse .9s ease-in-out infinite alternate}
@keyframes pulse{to{opacity:.3}}
.title{font-weight:600}
label{display:block;font-size:13px;font-weight:600;color:var(--muted);margin:16px 0 6px}
form>label:first-child{margin-top:0}
input,select{width:100%;min-width:0;font:inherit;color:inherit;background:var(--field);border:1px solid var(--line);border-radius:10px;padding:11px 12px;-webkit-appearance:none;appearance:none}
select{background-image:linear-gradient(45deg,transparent 50%,var(--muted) 50%),linear-gradient(135deg,var(--muted) 50%,transparent 50%);background-position:calc(100% - 18px) 50%,calc(100% - 13px) 50%;background-size:5px 5px;background-repeat:no-repeat;padding-right:32px}
input:focus,select:focus{outline:2px solid var(--accent);outline-offset:-1px}
.row{display:flex;gap:8px}.row>:first-child{flex:1}
button{font:inherit;font-weight:600;border:0;border-radius:12px;padding:13px 16px;width:100%;cursor:pointer}
.primary{background:var(--accent);color:#fff;margin-top:20px}
.secondary{background:var(--field);color:var(--accent);border:1px solid var(--line)}
.small{width:auto;padding:0 14px;font-size:15px;white-space:nowrap}
button:disabled{opacity:.5;cursor:default}
.hint{font-size:14px;color:var(--muted);margin:4px 0 0}
.error{color:var(--bad);margin-top:12px}
.check{display:flex;align-items:center;gap:10px;font-size:16px;font-weight:400;color:var(--text);margin:18px 0 0}
.check input{width:20px;height:20px;margin:0;padding:0;flex:none;-webkit-appearance:checkbox;appearance:auto;accent-color:var(--accent)}
.hidden{display:none}
</style></head><body><main>
<h1>ESPDeck Setup</h1>
<p class="sub" id="devname">&nbsp;</p>
<div class="card status"><div class="dot" id="dot"></div><div><div class="title" id="stext">Checking&hellip;</div><div class="hint" id="sdetail"></div></div></div>
<form class="card" id="form" autocomplete="off">
<label for="name">Device name</label>
<input id="name" maxlength="32" required>
<label for="net">Wi-Fi network</label>
<div class="row"><select id="net"></select><button type="button" class="secondary small" id="rescan">Rescan</button></div>
<div id="manualbox" class="hidden"><label for="ssid">Network name</label><input id="ssid" maxlength="32" autocapitalize="none" autocorrect="off" spellcheck="false"></div>
<div id="passbox"><label for="pass">Password</label>
<div class="row"><input id="pass" type="password" maxlength="63" autocapitalize="none" autocorrect="off" spellcheck="false"><button type="button" class="secondary small" id="show">Show</button></div></div>
<div id="encbox" class="hidden"><label class="check" for="enc"><input id="enc" type="checkbox" checked>Encrypt stored secrets (recommended)</label>
<p class="hint">Burns a one-time key into this chip, so encryption stays on for good. The Wi-Fi network, name and pairing can still be changed.</p></div>
<p class="hint error hidden" id="formerr"></p>
<button class="primary" id="save" type="submit">Save &amp; Connect</button>
</form>
<div class="card"><div class="title">Mac</div><p class="hint" id="pairtext">&nbsp;</p><button class="secondary hidden" id="unpair" type="button" style="margin-top:12px">Unpair</button></div>
<div class="card"><div class="title">Factory Reset</div><p class="hint">Erases this ESPDeck's Wi-Fi settings, name, pairing, and stored key images, then restarts it as new.</p><button class="secondary" id="reset" type="button" style="margin-top:12px">Factory Reset…</button></div>
<div class="card hidden" id="exitcard"><button class="secondary" id="exit" type="button">Exit Setup</button><p class="hint">Keeps the current settings and returns the deck to normal use.</p></div>
<p class="hint" id="fw" style="text-align:center"></p>
</main>
<script>
const $=id=>document.getElementById(id),KEEP='\u0001keep',OTHER='\u0001other',sleep=ms=>new Promise(r=>setTimeout(r,ms));
let st={},nets=[],keepFor=null,nameEdited=false,encEdited=false,saveError='';
function bars(r){const n=r>-60?4:r>-70?3:r>-80?2:1;return '▂▄▆█'.slice(0,n)+'▁'.repeat(4-n)}
function opt(v,t){const o=document.createElement('option');o.value=v;o.textContent=t;$('net').appendChild(o)}
function fillNets(){
 const sel=$('net'),prev=sel.value;sel.innerHTML='';keepFor=st.configured?st.ssid:null;
 if(keepFor!==null)opt(KEEP,'Keep '+keepFor);
 nets.forEach(n=>opt(n.ssid,bars(n.rssi)+'  '+n.ssid+(n.secure?'':'  (open)')));
 opt(OTHER,'Other network…');
 if([...sel.options].some(o=>o.value===prev))sel.value=prev;
 update();
}
function update(){
 const v=$('net').value,n=nets.find(n=>n.ssid===v);
 $('manualbox').classList.toggle('hidden',v!==OTHER);
 $('passbox').classList.toggle('hidden',v===KEEP||(n&&!n.secure));
}
function err(t){$('formerr').textContent=t||'';$('formerr').classList.toggle('hidden',!t)}
async function scan(refresh){
 $('rescan').disabled=true;
 try{for(let i=0;i<30;i++){
  const r=await(await fetch('/scan'+(refresh&&!i?'?refresh=1':''))).json();
  nets=r.networks||[];fillNets();if(!r.scanning)break;await sleep(1000);
 }}catch(e){}
 $('rescan').disabled=false;
}
function render(){
 $('devname').textContent=st.name;
 if(!nameEdited&&document.activeElement!==$('name'))$('name').value=st.name;
 let c='',t,d='';
 if(st.leaving){c='ok';t='Connected to '+st.ssid;d='ESPDeck is at '+st.ip+' and is leaving setup mode. You can close this page.'}
 else if(st.connected){c='ok';t='Connected to '+st.ssid;d='IP address '+st.ip}
 else if(st.connecting){c=st.error?'bad':'busy';t='Connecting to '+st.ssid+'…';d=st.error||''}
 else if(st.configured){c=st.error?'bad':'busy';t='Not connected to '+st.ssid;d=st.error||'Still trying…'}
 else{t='Not set up yet';d='Choose a Wi-Fi network below.'}
 $('dot').className='dot '+c;$('stext').textContent=t;$('sdetail').textContent=d;
 $('exitcard').classList.toggle('hidden',!st.canExit||st.leaving);
 $('pairtext').textContent=st.paired?'Paired with ESPDeck Bridge '+st.bridge+'.':'Not paired. Pair it from ESPDeck Bridge on your Mac.';
 $('unpair').classList.toggle('hidden',!st.paired);
 $('encbox').classList.toggle('hidden',!st.encryptOffered);
 if(!encEdited)$('enc').checked=!st.standardStorage;
 $('fw').textContent='Firmware '+st.firmware+(st.storage==='encrypted'?' · stored secrets encrypted':'');
 if(st.saveError!==saveError){saveError=st.saveError;err(saveError)}
 if(keepFor!==(st.configured?st.ssid:null))fillNets();
}
async function poll(){try{st=await(await fetch('/status')).json();render()}catch(e){}setTimeout(poll,1500)}
$('net').onchange=update;
$('name').oninput=()=>nameEdited=true;
$('enc').onchange=()=>encEdited=true;
$('rescan').onclick=()=>scan(true);
$('show').onclick=()=>{const p=$('pass'),s=p.type==='password';p.type=s?'text':'password';$('show').textContent=s?'Hide':'Show'};
$('form').onsubmit=async e=>{
 e.preventDefault();err('');
 const v=$('net').value,ssid=v===KEEP?'':v===OTHER?$('ssid').value:v,pass=$('passbox').classList.contains('hidden')?'':$('pass').value,name=$('name').value.trim();
 if(!name)return err('Enter a device name.');
 if(v===OTHER&&!ssid)return err('Enter the network name.');
 if(pass&&pass.length<8)return err('Wi-Fi passwords have at least 8 characters.');
 $('save').disabled=true;
 try{
  const f={name,ssid,password:pass};if(st.encryptOffered)f.encrypt=$('enc').checked?'1':'0';
  const r=await(await fetch('/save',{method:'POST',body:new URLSearchParams(f)})).json();
  if(r.ok){nameEdited=false;$('pass').value='';if(ssid)$('net').value=KEEP}else err(r.error||'Couldn’t save.');
 }catch(e){err('Couldn’t reach ESPDeck.')}
 $('save').disabled=false;
};
$('exit').onclick=async()=>{
 $('exit').disabled=true;
 try{const r=await(await fetch('/exit',{method:'POST'})).json();
  if(r.ok){$('stext').textContent='Leaving setup mode';$('sdetail').textContent='You can close this page.';$('exitcard').classList.add('hidden');return}
 }catch(e){}
 $('exit').disabled=false;
};
$('unpair').onclick=async()=>{
 if(!confirm('Unpair from this Mac? ESPDeck Bridge will have to pair with it again.'))return;
 $('unpair').disabled=true;
 try{await fetch('/unpair',{method:'POST'})}catch(e){}
 $('unpair').disabled=false;
};
$('reset').onclick=async()=>{
 if(!confirm('Factory reset this ESPDeck? It forgets its Wi-Fi network, name, and pairing, and restarts in setup mode. Its setup Wi-Fi gets a new password: scan the QR code on the deck to reconnect.'))return;
 $('reset').disabled=true;
 try{await fetch('/reset',{method:'POST'})}catch(e){}
 $('stext').textContent='Resetting';$('sdetail').textContent='ESPDeck is restarting. Scan the QR code on the deck to set it up again.';
};
poll();scan(false);
</script></body></html>
)HTML";

	// Adds a string member, "" for null.
	void addString( cJSON *object, const char *key, const char *value ) {
		cJSON_AddStringToObject( object, key, value ? value : "" );
	}

	// Answers with JSON that mustn't be cached.
	void sendJSON( int code, const char *json ) {
		webServer.sendHeader( "Cache-Control", "no-store" );
		webServer.send( code, "application/json", json );
	}

	// The same for a cJSON object, which it deletes.
	void sendJSON( int code, cJSON *json ) {
		char *text = cJSON_PrintUnformatted( json );
		sendJSON( code, text ? text : "{}" );
		cJSON_free( text );
		cJSON_Delete( json );
	}

	// An empty 403.
	void refuse() {
		webServer.send( 403, "text/plain", "" );
	}

	// Sends the phone to the setup page.
	void redirectToPortal() {
		webServer.sendHeader( "Location", kPortalURL, true );
		webServer.sendHeader( "Cache-Control", "no-store" );
		webServer.send( 302, "text/plain", "" );
	}

	// Whether the request came in on the access point from a phone on it.
	bool fromAccessPoint() {
		NetworkClient &client = webServer.client();
		return client.localIP() == kAddress && onAccessPoint( client.remoteIP() );
	}

	// Returns flag and clears it.
	bool take( bool &flag ) {
		bool value = flag;
		flag       = false;
		return value;
	}
}

void SetupPortal::begin() {
	snprintf( apSSID_, sizeof( apSSID_ ), "ESPDeck-%s", settings_.idSuffix() );

	WiFi.onEvent( [this]( arduino_event_id_t, arduino_event_info_t info ) {
		lastReason_ = info.wifi_sta_disconnected.reason;
	}, ARDUINO_EVENT_WIFI_STA_DISCONNECTED );
	WiFi.onEvent( [this]( arduino_event_id_t, arduino_event_info_t ) {
		lastReason_ = 0;
		gotIP_      = true;
	}, ARDUINO_EVENT_WIFI_STA_GOT_IP );
}

// MARK: - Start and stop

void SetupPortal::start() {
	if( active_ )
		return;

	// AP+STA keeps the station connected (or trying) alongside the access point.
	WiFi.mode( WIFI_AP_STA );
	WiFi.setSleep( false );
	WiFi.softAPConfig( kAddress, kAddress, kNetmask );
	makePassword();   // after WiFi.mode(): with the radio on, esp_random() is truly random
	if( !WiFi.softAP( apSSID_, apPassword_, kAPChannel, 0, kAPMaxStations, false, WIFI_AUTH_WPA2_WPA3_PSK ) )
		ESP_LOGE( TAG, "Starting the access point failed" );
#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL( 5, 4, 2 )
	// DHCP option 114 (RFC 8910) points newer phones straight at the page.
	WiFi.AP.enableDhcpCaptivePortal();
#endif

	dnsSocket.onPacket( answerDNS );
	if( !dnsSocket.listen( kDNSPort ) )
		ESP_LOGE( TAG, "Starting the DNS server failed" );

	if( !routesAdded_ ) {
		static const char *kHeaders[] = { "Origin" };
		webServer.collectHeaders( kHeaders, 1 );
		webServer.on( "/", HTTP_GET, [this]() { if( allowRequest( false ) ) handleRoot(); } );
		webServer.on( "/scan", HTTP_GET, [this]() { if( allowRequest( false ) ) handleScan(); } );
		webServer.on( "/status", HTTP_GET, [this]() { if( allowRequest( false ) ) handleStatus(); } );
		webServer.on( "/save", HTTP_POST, [this]() { if( allowRequest( true ) ) handleSave(); } );
		webServer.on( "/exit", HTTP_POST, [this]() { if( allowRequest( true ) ) handleExit(); } );
		webServer.on( "/unpair", HTTP_POST, [this]() { if( allowRequest( true ) ) handleUnpair(); } );
		webServer.on( "/reset", HTTP_POST, [this]() { if( allowRequest( true ) ) handleReset(); } );
		webServer.onNotFound( [this]() { handleNotFound(); } );
		routesAdded_ = true;
	}
	webServer.begin();

	active_        = true;
	exitRequested_ = false;
	idleTimedOut_  = false;
	lastActivity_  = millis();
	connecting_    = false;
	joined_        = false;
	timedOut_      = false;
	saveError_[0]  = '\0';
	startScan();
	ESP_LOGI( TAG, "Setup mode: join %s and open %s", apSSID_, kPortalURL );
}

void SetupPortal::stop() {
	if( !active_ )
		return;

	webServer.stop();
	dnsSocket.close();
	WiFi.scanDelete();
	WiFi.softAPdisconnect( false );
	WiFi.mode( WIFI_STA );
	WiFi.setSleep( false );
	networks_.clear();
	scanning_ = false;
	active_   = false;
	memset( apPassword_, 0, sizeof( apPassword_ ) );
	memset( pendingPassword_, 0, sizeof( pendingPassword_ ) );
	if( connecting_ ) {
		connecting_ = false;
		restoreNetwork();
	}
	ESP_LOGI( TAG, "Left setup mode" );
}

// Rejection sampling keeps every character equally likely.
void SetupPortal::makePassword() {
	size_t alphabet = strlen( kPasswordAlphabet );
	size_t limit    = 256 - 256 % alphabet;
	for( size_t i = 0; i < kPasswordLength; ) {
		uint8_t random;
		esp_fill_random( &random, 1 );
		if( random < limit )
			apPassword_[i++] = kPasswordAlphabet[random % alphabet];
	}
	apPassword_[kPasswordLength] = '\0';
}

bool SetupPortal::takeIdleTimeout() {
	return take( idleTimedOut_ );
}

bool SetupPortal::takeExitRequest() {
	return take( exitRequested_ );
}

// MARK: - Loop

void SetupPortal::loop() {
	if( !active_ )
		return;

	webServer.handleClient();
	collectScan();
	trackConnection();

	uint32_t now = millis();
	if( now - lastStationCheck_ >= kStationCheck ) {
		lastStationCheck_ = now;
		if( WiFi.softAPgetStationNum() > 0 || connecting_ || joined_ )
			lastActivity_ = now;
		else if( now - lastActivity_ >= kIdleTimeout && canExit() && !idleTimedOut_ && !exitRequested_ ) {
			ESP_LOGI( TAG, "No phone on the access point for %u minutes", (unsigned)( kIdleTimeout / 60000 ) );
			idleTimedOut_ = true;
		}
	}
}

// Tries pendingSSID_; trackConnection() follows it.
void SetupPortal::beginConnecting() {
	WiFi.disconnect( false, false );
	lastReason_   = 0;
	gotIP_        = false;
	connecting_   = true;
	joined_       = false;
	timedOut_     = false;
	saveError_[0] = '\0';
	connectStart_ = millis();
	WiFi.begin( pendingSSID_, pendingPassword_ );
	char ssid[kSafeSSID];
	ESP_LOGI( TAG, "Joining %s", Text::printable( pendingSSID_, ssid, sizeof( ssid ) ) );
}

// Back to the saved network, if there is one, after a failed attempt.
void SetupPortal::restoreNetwork() {
	if( settings_.hasCredentials() )
		WiFi.begin( settings_.ssid(), settings_.password() );
	else
		WiFi.disconnect( false, false );
}

// Saves the pending network once it has an address, or goes back after kConnectTimeout; and
// asks to leave setup mode kSetupExitDelay after joining.
void SetupPortal::trackConnection() {
	uint32_t now = millis();
	if( connecting_ ) {
		char ssid[kSafeSSID];
		Text::printable( pendingSSID_, ssid, sizeof( ssid ) );
		if( gotIP_ ) {
			connecting_ = false;
			joined_     = true;
			joinedAt_   = now;
			settings_.setCredentials( pendingSSID_, pendingPassword_ );
			settings_.markCredentialsWork();
			memset( pendingPassword_, 0, sizeof( pendingPassword_ ) );
			ESP_LOGI( TAG, "Joined %s as %s (storage %s)", ssid, WiFi.localIP().toString().c_str(), SecureNVS::stateName() );
		} else if( now - connectStart_ >= kConnectTimeout ) {
			timedOut_   = true;
			connecting_ = false;
			snprintf( saveError_, sizeof( saveError_ ), "Couldn't join that network: %s The previous settings are kept.", errorText() );
			memset( pendingPassword_, 0, sizeof( pendingPassword_ ) );
			ESP_LOGW( TAG, "Couldn't join %s; back to the saved network", ssid );
			restoreNetwork();
		}
	}
	if( joined_ && now - joinedAt_ >= kSetupExitDelay ) {
		joined_        = false;
		exitRequested_ = true;
	}
}

// Why the station isn't connected, for the page ("" if it is, or there's nothing to say).
const char *SetupPortal::errorText() const {
	if( WiFi.status() == WL_CONNECTED && !connecting_ && !timedOut_ )
		return "";

	switch( lastReason_ ) {
		case 0:
		case WIFI_REASON_ASSOC_LEAVE:   // our own disconnect before joining another network
			return timedOut_ ? "Check the network name and password." : "";
		case WIFI_REASON_AUTH_FAIL:
		case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
		case WIFI_REASON_HANDSHAKE_TIMEOUT:
		case WIFI_REASON_MIC_FAILURE:
			return "Wrong password.";
		case WIFI_REASON_NO_AP_FOUND:
		case WIFI_REASON_NO_AP_FOUND_W_COMPATIBLE_SECURITY:
		case WIFI_REASON_NO_AP_FOUND_IN_AUTHMODE_THRESHOLD:
		case WIFI_REASON_NO_AP_FOUND_IN_RSSI_THRESHOLD:
			return "Network not found. ESPDeck only sees 2.4 GHz networks.";
		default:
			return "Couldn't connect to the network.";
	}
}

// MARK: - Scanning

// Starts a scan in the background, unless one is running.
void SetupPortal::startScan() {
	if( scanning_ )
		return;
	WiFi.scanDelete();
	scanning_ = WiFi.scanNetworks( true ) == WIFI_SCAN_RUNNING;
}

// Picks up a finished scan's results.
void SetupPortal::collectScan() {
	if( !scanning_ )
		return;

	int16_t count = WiFi.scanComplete();
	if( count == WIFI_SCAN_RUNNING )
		return;
	scanning_ = false;
	if( count < 0 )
		return;

	// One entry per name, strongest access point first.
	networks_.clear();
	for( int16_t i = 0; i < count; i++ ) {
		String ssid = WiFi.SSID( i );
		if( ssid.isEmpty() )
			continue;
		int32_t rssi   = WiFi.RSSI( i );
		bool    secure = WiFi.encryptionType( i ) != WIFI_AUTH_OPEN;
		auto    found  = std::find_if( networks_.begin(), networks_.end(), [&]( const Network &n ) { return ssid.equals( n.ssid ); } );
		if( found != networks_.end() ) {
			if( rssi > found->rssi ) {
				found->rssi   = rssi;
				found->secure = secure;
			}
			continue;
		}
		Network network = {};
		strlcpy( network.ssid, ssid.c_str(), sizeof( network.ssid ) );
		network.rssi   = rssi;
		network.secure = secure;
		networks_.push_back( network );
	}
	std::sort( networks_.begin(), networks_.end(), []( const Network &a, const Network &b ) { return a.rssi > b.rssi; } );
	WiFi.scanDelete();
}

// MARK: - HTTP

// Requests from the home network, from pages that reached 192.168.4.1 by another name, and
// POSTs from other origins get an error. Answers them itself when it returns false.
bool SetupPortal::allowRequest( bool post ) {
	if( !fromAccessPoint() ) {
		refuse();
		return false;
	}
	lastActivity_ = millis();

	String host = webServer.hostHeader();
	if( host != kPortalHost && host != kPortalHostPort ) {
		if( post )
			refuse();
		else
			redirectToPortal();
		return false;
	}
	if( post && webServer.hasHeader( "Origin" ) && webServer.header( "Origin" ) != kPortalOrigin ) {
		refuse();
		return false;
	}
	return true;
}

// The page itself.
void SetupPortal::handleRoot() {
	webServer.sendHeader( "Cache-Control", "no-store" );
	webServer.send( 200, "text/html; charset=utf-8", kPage );
}

// The networks found, strongest first; `refresh` starts a new scan.
void SetupPortal::handleScan() {
	if( webServer.hasArg( "refresh" ) )
		startScan();

	cJSON *json = cJSON_CreateObject();
	cJSON_AddBoolToObject( json, "scanning", scanning_ );
	cJSON *list = cJSON_AddArrayToObject( json, "networks" );
	for( const Network &network : networks_ ) {
		cJSON *item = cJSON_CreateObject();
		addString( item, "ssid", network.ssid );
		cJSON_AddNumberToObject( item, "rssi", network.rssi );
		cJSON_AddBoolToObject( item, "secure", network.secure );
		cJSON_AddItemToArray( list, item );
	}
	sendJSON( 200, json );
}

// Everything the page shows, polled.
void SetupPortal::handleStatus() {
	bool connected = WiFi.status() == WL_CONNECTED && !connecting_;

	cJSON *json = cJSON_CreateObject();
	cJSON_AddBoolToObject( json, "configured", settings_.hasCredentials() );
	cJSON_AddBoolToObject( json, "connecting", connecting_ );
	cJSON_AddBoolToObject( json, "connected", connected );
	addString( json, "ssid", connecting_ ? pendingSSID_ : settings_.ssid() );
	addString( json, "saveError", saveError_ );
	addString( json, "ip", connected ? WiFi.localIP().toString().c_str() : "" );
	addString( json, "name", settings_.name() );
	addString( json, "error", errorText() );
	cJSON_AddBoolToObject( json, "canExit", canExit() );
	cJSON_AddBoolToObject( json, "leaving", joined_ || exitRequested_ );
	cJSON_AddBoolToObject( json, "paired", settings_.isPaired() );
	addString( json, "bridge", settings_.pairedBridge() );
	addString( json, "firmware", firmwareVersion() );
	addString( json, "storage", SecureNVS::stateName() );
	// A new device with plain storage: saving its first network encrypts storage, unless the
	// page's checkbox (Settings::standardStorage()) says Standard.
	cJSON_AddBoolToObject( json, "encryptOffered", settings_.isNew() && SecureNVS::state() == SecureNVS::State::Plain );
	cJSON_AddBoolToObject( json, "standardStorage", settings_.standardStorage() );
	sendJSON( 200, json );
}

// Save & Connect: the name now, the network once it has been joined.
void SetupPortal::handleSave() {
	String name     = webServer.arg( "name" );
	String ssid     = webServer.arg( "ssid" );
	String password = webServer.arg( "password" );
	name.trim();

	const char *error = nullptr;
	if( name.isEmpty() )
		error = "Enter a device name.";
	else if( !Text::isValidName( name.c_str(), Settings::kMaxName ) )
		error = "That name is too long, or has characters that aren't allowed.";
	else if( ssid.length() > 32 )
		error = "Network names have at most 32 characters.";
	else if( !ssid.isEmpty() && !password.isEmpty() && ( password.length() < 8 || password.length() > 63 ) )
		error = "Wi-Fi passwords have 8 to 63 characters.";
	if( error ) {
		cJSON *json = cJSON_CreateObject();
		cJSON_AddBoolToObject( json, "ok", false );
		addString( json, "error", error );
		sendJSON( 400, json );
		return;
	}

	settings_.setName( name.c_str() );
	// The checkbox, on a new device: applies when the network is saved, once it works.
	if( webServer.hasArg( "encrypt" ) && settings_.isNew() && SecureNVS::state() == SecureNVS::State::Plain )
		settings_.setStandardStorage( webServer.arg( "encrypt" ) != "1" );
	if( !ssid.isEmpty() ) {
		strlcpy( pendingSSID_, ssid.c_str(), sizeof( pendingSSID_ ) );
		strlcpy( pendingPassword_, password.c_str(), sizeof( pendingPassword_ ) );
		beginConnecting();
	}
	sendJSON( 200, "{\"ok\":true}" );
}

// Exit Setup, allowed once there's a network that works.
void SetupPortal::handleExit() {
	if( !canExit() ) {
		sendJSON( 409, "{\"ok\":false,\"error\":\"Set up Wi-Fi first.\"}" );
		return;
	}
	exitRequested_ = true;
	sendJSON( 200, "{\"ok\":true}" );
}

// main notices the pairing is gone and drops an authenticated connection.
void SetupPortal::handleUnpair() {
	settings_.clearPairing();
	ESP_LOGI( TAG, "Unpaired from the setup page" );
	sendJSON( 200, "{\"ok\":true}" );
}

// main performs the reset from its loop, after this response has gone out.
void SetupPortal::handleReset() {
	resetRequested_ = true;
	sendJSON( 200, "{\"ok\":true}" );
}

bool SetupPortal::takeResetRequest() {
	return take( resetRequested_ );
}

// Captive-network probes (/hotspot-detect.html, /generate_204, /ncsi.txt, …) get a redirect
// instead of the answer they expect, which makes phones open the page.
void SetupPortal::handleNotFound() {
	if( !fromAccessPoint() ) {
		refuse();
		return;
	}
	lastActivity_ = millis();
	redirectToPortal();
}
