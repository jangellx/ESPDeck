// Arduino headers must precede anything that pulls in lwIP, or INADDR_NONE collides.
#include <Arduino.h>
#include <DNSServer.h>
#include <WebServer.h>
#include <WiFi.h>

#include "SetupPortal.h"

#include <algorithm>
#include <cstring>

#include "cJSON.h"
#include "esp_log.h"

#include "Config.h"

static const char *TAG = "Setup";

namespace {
	const IPAddress kAddress( 192, 168, 4, 1 );
	const IPAddress kNetmask( 255, 255, 255, 0 );
	constexpr const char *kPortalURL      = "http://192.168.4.1/";
	constexpr uint32_t    kConnectTimeout = 30000;   // ms before the page reports a failure

	DNSServer dnsServer;
	WebServer webServer( 80 );

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
let st={},nets=[],keepFor=null,nameEdited=false;
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
 $('fw').textContent='Firmware '+st.firmware;
 if(keepFor!==(st.configured?st.ssid:null))fillNets();
}
async function poll(){try{st=await(await fetch('/status')).json();render()}catch(e){}setTimeout(poll,1500)}
$('net').onchange=update;
$('name').oninput=()=>nameEdited=true;
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
  const r=await(await fetch('/save',{method:'POST',body:new URLSearchParams({name,ssid,password:pass})})).json();
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

	void addString( cJSON *object, const char *key, const char *value ) {
		cJSON_AddStringToObject( object, key, value ? value : "" );
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
	if( !WiFi.softAP( apSSID_, settings_.apPassword() ) )
		ESP_LOGE( TAG, "Starting the access point failed" );
#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL( 5, 4, 2 )
	// DHCP option 114 (RFC 8910) points newer phones straight at the page.
	WiFi.AP.enableDhcpCaptivePortal();
#endif

	dnsServer.start( 53, "*", kAddress );

	if( !routesAdded_ ) {
		webServer.on( "/", HTTP_GET, [this]() { handleRoot(); } );
		webServer.on( "/scan", HTTP_GET, [this]() { handleScan(); } );
		webServer.on( "/status", HTTP_GET, [this]() { handleStatus(); } );
		webServer.on( "/save", HTTP_POST, [this]() { handleSave(); } );
		webServer.on( "/exit", HTTP_POST, [this]() { handleExit(); } );
		webServer.on( "/unpair", HTTP_POST, [this]() { handleUnpair(); } );
		webServer.on( "/reset", HTTP_POST, [this]() { handleReset(); } );
		webServer.onNotFound( [this]() { handleNotFound(); } );
		routesAdded_ = true;
	}
	webServer.begin();

	active_        = true;
	exitRequested_ = false;
	connecting_    = false;
	joined_        = false;
	timedOut_      = false;
	startScan();
	ESP_LOGI( TAG, "Setup mode: join %s and open %s", apSSID_, kPortalURL );
}

void SetupPortal::stop() {
	if( !active_ )
		return;

	webServer.stop();
	dnsServer.stop();
	WiFi.scanDelete();
	WiFi.softAPdisconnect( false );
	WiFi.mode( WIFI_STA );
	WiFi.setSleep( false );
	networks_.clear();
	scanning_ = false;
	active_   = false;
	ESP_LOGI( TAG, "Left setup mode" );
}

bool SetupPortal::takeExitRequest() {
	bool requested = exitRequested_;
	exitRequested_ = false;
	return requested;
}

// MARK: - Loop

void SetupPortal::loop() {
	if( !active_ )
		return;

	dnsServer.processNextRequest();
	webServer.handleClient();
	collectScan();
	trackConnection();
}

void SetupPortal::beginConnecting() {
	WiFi.disconnect( false, false );
	lastReason_   = 0;
	gotIP_        = false;
	connecting_   = true;
	joined_       = false;
	timedOut_     = false;
	connectStart_ = millis();
	WiFi.begin( settings_.ssid(), settings_.password() );
	ESP_LOGI( TAG, "Joining %s", settings_.ssid() );
}

void SetupPortal::trackConnection() {
	uint32_t now = millis();
	if( connecting_ ) {
		if( gotIP_ ) {
			connecting_ = false;
			joined_     = true;
			joinedAt_   = now;
			ESP_LOGI( TAG, "Joined %s as %s", settings_.ssid(), WiFi.localIP().toString().c_str() );
		} else if( now - connectStart_ >= kConnectTimeout ) {
			timedOut_ = true;
		}
	}
	if( joined_ && now - joinedAt_ >= kSetupExitDelay ) {
		joined_        = false;
		exitRequested_ = true;
	}
}

const char *SetupPortal::errorText() const {
	if( WiFi.status() == WL_CONNECTED && !connecting_ )
		return "";

	switch( lastReason_ ) {
		case 0:
		case WIFI_REASON_ASSOC_LEAVE:   // our own disconnect before joining another network
			return timedOut_ ? "Couldn't connect. Check the network name and password." : "";
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

void SetupPortal::startScan() {
	if( scanning_ )
		return;
	WiFi.scanDelete();
	scanning_ = WiFi.scanNetworks( true ) == WIFI_SCAN_RUNNING;
}

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

void SetupPortal::sendJSON( int code, const char *json ) {
	webServer.sendHeader( "Cache-Control", "no-store" );
	webServer.send( code, "application/json", json );
}

void SetupPortal::handleRoot() {
	webServer.sendHeader( "Cache-Control", "no-store" );
	webServer.send( 200, "text/html; charset=utf-8", kPage );
}

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
	char *text = cJSON_PrintUnformatted( json );
	sendJSON( 200, text ? text : "{}" );
	cJSON_free( text );
	cJSON_Delete( json );
}

void SetupPortal::handleStatus() {
	bool connected = WiFi.status() == WL_CONNECTED && !connecting_;

	cJSON *json = cJSON_CreateObject();
	cJSON_AddBoolToObject( json, "configured", settings_.hasCredentials() );
	cJSON_AddBoolToObject( json, "connecting", connecting_ );
	cJSON_AddBoolToObject( json, "connected", connected );
	addString( json, "ssid", settings_.ssid() );
	addString( json, "ip", connected ? WiFi.localIP().toString().c_str() : "" );
	addString( json, "name", settings_.name() );
	addString( json, "error", errorText() );
	cJSON_AddBoolToObject( json, "canExit", canExit() );
	cJSON_AddBoolToObject( json, "leaving", joined_ || exitRequested_ );
	cJSON_AddBoolToObject( json, "paired", settings_.isPaired() );
	addString( json, "bridge", settings_.pairedBridge() );
	addString( json, "firmware", firmwareVersion() );
	char *text = cJSON_PrintUnformatted( json );
	sendJSON( 200, text ? text : "{}" );
	cJSON_free( text );
	cJSON_Delete( json );
}

void SetupPortal::handleSave() {
	String name     = webServer.arg( "name" );
	String ssid     = webServer.arg( "ssid" );
	String password = webServer.arg( "password" );
	name.trim();

	const char *error = nullptr;
	if( name.isEmpty() || name.length() > Settings::kMaxName )
		error = "Names have 1 to 32 characters.";
	else if( ssid.length() > 32 )
		error = "Network names have at most 32 characters.";
	else if( !ssid.isEmpty() && !password.isEmpty() && ( password.length() < 8 || password.length() > 63 ) )
		error = "Wi-Fi passwords have 8 to 63 characters.";
	if( error ) {
		cJSON *json = cJSON_CreateObject();
		cJSON_AddBoolToObject( json, "ok", false );
		addString( json, "error", error );
		char *text = cJSON_PrintUnformatted( json );
		sendJSON( 400, text ? text : "{}" );
		cJSON_free( text );
		cJSON_Delete( json );
		return;
	}

	settings_.setName( name.c_str() );
	if( !ssid.isEmpty() ) {
		settings_.setCredentials( ssid.c_str(), password.c_str() );
		beginConnecting();
	}
	sendJSON( 200, "{\"ok\":true}" );
}

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
	bool requested  = resetRequested_;
	resetRequested_ = false;
	return requested;
}

// Captive-network probes (/hotspot-detect.html, /generate_204, /ncsi.txt, …) get a redirect
// instead of the answer they expect, which makes phones open the page.
void SetupPortal::handleNotFound() {
	webServer.sendHeader( "Location", kPortalURL, true );
	webServer.sendHeader( "Cache-Control", "no-store" );
	webServer.send( 302, "text/plain", "" );
}
