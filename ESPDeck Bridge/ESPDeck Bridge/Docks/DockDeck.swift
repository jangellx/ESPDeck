//
//  DockDeck.swift
//  ESPDeck Bridge
//
//  A Network Dock dressed as an ESPDeck device. The rest of the app speaks PROTOCOL.md to
//  its decks, and an ESP32 does a good deal itself: it caches key images, judges what kind
//  of press each one was, runs the sleep timer and keeps the deck's settings. A dock only
//  passes the Stream Deck's USB reports along, so this does the ESP32's part on the Mac:
//  it takes the messages the Mac sends a device (HostMessage, and images by hash) and
//  answers with the ones a device sends (hello, deck, status, need, shown, and the key
//  events), as JSON, the way the firmware would (main.cpp). DeckServer passes them on as if
//  they had come over a device's connection.
//
//  Each time the dock connects is one session, as each connection of an ESP32 is; between
//  them it tries again on its own, a little less often each time.
//

import Foundation
import Network

/// One dock the user added; see the file comment.
final class DockDeck {
	/// What the Mac keeps for the deck, which an ESP32 would keep itself.
	struct Settings: Equatable {
		var name         : String
		var brightness   : Int
		var orientation  : String
		var sleepTimeout : Int
	}

	/// A session started: the device's hello, and the JSON it stands for (for the Log tab).
	var onConnect    : ( ( DeviceHello, Data ) -> Void )?
	/// A message, as a device would send it.
	var onMessage    : ( ( Data ) -> Void )?
	/// The session ended.
	var onDisconnect : ( () -> Void )?
	/// Something happened that the Log tab should say, in plain words.
	var onEvent      : ( ( String ) -> Void )?

	/// "dock-" and the dock's serial number: DeviceSettings.id.
	let id          : String
	/// Its Bonjour service, which is how it's found again.
	let serviceName : String
	private(set) var settings: Settings

	/// Images kept by hash, as an ESP32 caches them; `need` asks for one it doesn't have.
	private static let cacheLimit = 256
	private static let retryDelays: [Duration] = [ .seconds( 2 ), .seconds( 5 ), .seconds( 10 ), .seconds( 30 ) ]

	private var link         : DockLink?
	private var retryTask    : Task<Void, Never>?
	private var failures     = 0
	private var stopped      = true
	/// A session is under way: the Mac has had this device's hello.
	private(set) var inSession = false
	private var firmware     : String?
	/// The dock's address on the network, for the Device page.
	private(set) var address : String?
	private var capabilities : DockCapabilities?
	private var model        : DockModel?
	private var deckReady    = false
	private var keyStates    : [Bool] = []
	private var presses      = DockPresses()
	private var pressTimer   : Task<Void, Never>?
	private var asleep       = false
	private var lastActivity = ProcessInfo.processInfo.systemUptime
	private var sleepTimer   : Task<Void, Never>?
	private var images       : [String: Data] = [:]
	private var imageOrder   : [String] = []
	/// What each key should show, by hash, and what it does show.
	private var wanted       : [Int: String] = [:]
	private var showing      : [Int: String] = [:]

	init( id: String, serviceName: String, settings: Settings ) {
		self.id          = id
		self.serviceName = serviceName
		self.settings    = settings
	}

	/// Its device ID: "dock-" and the serial number, lowercased, letters and digits only.
	static func deviceID( serial: String ) -> String {
		"dock-" + serial.lowercased().filter { $0.isLetter || $0.isNumber }
	}

	/// The dock's Bonjour service.
	static func endpoint( serviceName: String ) -> NWEndpoint {
		.service( name: serviceName, type: DockBrowser.serviceType, domain: "local.", interface: nil )
	}

	// MARK: - Connecting

	/// Connects, and keeps trying until stopped.
	func start() {
		guard stopped else { return }
		stopped  = false
		failures = 0
		connect()
	}

	/// Disconnects for good (the dock was forgotten, or docks were turned off).
	func stop() {
		stopped = true
		retryTask?.cancel()
		link?.stop()
		link = nil
		endSession()
	}

	/// Ends the session and connects again after a moment, as an ESP32 whose connection the
	/// Mac closed would.
	func disconnect() {
		guard let link else { return }
		link.onClosed = nil
		link.stop()
		linkClosed( "closed by ESPDeck Bridge" )
	}

	/// Tries again now, rather than after the wait.
	func retryNow() {
		guard !stopped, link == nil else { return }
		retryTask?.cancel()
		connect()
	}

	private func connect() {
		let link = DockLink( endpoint: Self.endpoint( serviceName: serviceName ) )
		self.link = link
		link.onIdentity = { [weak self] identity in self?.identified( identity ) }
		link.onCapabilities = { [weak self] value in self?.capabilitiesChanged( value ) }
		link.onDeckReady = { [weak self] in self?.deckBecameReady() }
		link.onDeckLost = { [weak self] in self?.deckLost() }
		link.onKeys = { [weak self] states in self?.keysChanged( states ) }
		link.onClosed = { [weak self] reason in self?.linkClosed( reason ) }
		link.start()
	}

	private func identified( _ identity: DockLink.Identity ) {
		guard Self.deviceID( serial: identity.serial ) == id else {
			// Another dock has taken this one's name on the network.
			link?.stop()
			linkClosed( "a different dock answered (serial number \(identity.serial))" )
			return
		}
		firmware = identity.firmware
		failures = 0
	}

	private func linkClosed( _ reason: String ) {
		link = nil
		if inSession { onEvent?( "Lost the connection to the Network Dock: \(reason)" ) }
		endSession()
		guard !stopped else { return }
		let delay = Self.retryDelays[min( failures, Self.retryDelays.count - 1 )]
		failures += 1
		retryTask = Task { [weak self] in
			try? await Task.sleep( for: delay )
			guard !Task.isCancelled, let self, !stopped else { return }
			connect()
		}
	}

	/// Starts a session once the dock has said what's plugged into it, as an ESP32's hello
	/// says what's plugged into it.
	private func beginSession() {
		guard !inSession else { return }
		inSession = true
		asleep    = false
		showing   = [:]
		wanted    = [:]
		presses   = DockPresses()
		lastActivity = ProcessInfo.processInfo.systemUptime
		let hello = DeviceHello( protocolVersion: DeckServer.protocolVersion, nonce: nil, pairedBridge: "", id: id, name: settings.name,
								 firmware: firmware ?? "?", elfSHA256: nil, cached: Array( images.keys ), deck: deckInfo,
								 settings: reportedSettings, status: status )
		onConnect?( hello, json( HelloJSON( id: id, name: settings.name, firmware: firmware ?? "?", cached: Array( images.keys ),
											deck: deckInfo, settings: reportedSettings, status: status ) ) )
		scheduleSleep()
	}

	private func endSession() {
		pressTimer?.cancel()
		sleepTimer?.cancel()
		deckReady    = false
		keyStates    = []
		capabilities = nil
		model        = nil
		guard inSession else { return }
		inSession = false
		onDisconnect?()
	}

	// MARK: - The Stream Deck

	private func capabilitiesChanged( _ value: DockCapabilities ) {
		let before = deckInfo
		capabilities = value
		model = value.connected ? DockModel.model( productID: value.productID ) : nil
		if value.connected && model == nil {
			onEvent?( "The Network Dock has a \(value.model.isEmpty ? "Stream Deck" : value.model) (product ID \(String( format: "0x%04X", value.productID ))), which ESPDeck Bridge can't drive through a dock yet." )
		}
		if !inSession {
			address = link?.address
			beginSession()
		} else if deckInfo != before {
			send( Message( type: "deck", deck: deckInfo ) )
		}
	}

	private func deckBecameReady() {
		deckReady = true
		keyStates = []
		applyBrightness()
		// A deck just plugged in counts as activity, as on an ESP32.
		lastActivity = ProcessInfo.processInfo.systemUptime
		if asleep { wake( reason: "deck" ) }
		showing = [:]
		for key in wanted.keys.sorted() { showWanted( key ) }
	}

	private func deckLost() {
		deckReady = false
		keyStates = []
		forward( presses.releaseForwarded() )
		presses.reset()
	}

	/// The deck as an ESP32 reports it: its layout, from the model table.
	private var deckInfo: DeckInfo {
		guard let capabilities, capabilities.connected, let model else { return .disconnected }
		let transform = KeyTransform( rawValue: settings.orientation ) ?? model.transform
		return DeckInfo( connected: true, model: model.name, pid: Int( model.productID ), serial: capabilities.serial, firmware: nil,
						 rows: model.rows, cols: model.cols, keySize: model.keySize, format: model.format, transform: transform )
	}

	private var reportedSettings: DeviceReportedSettings {
		DeviceReportedSettings( orientation: settings.orientation, sleepTimeout: settings.sleepTimeout, brightness: settings.brightness, ip: address )
	}

	private var status: DeviceStatus {
		var status = DeviceStatus()
		status.asleep  = asleep
		status.presses = true
		return status
	}

	// MARK: - From the Mac

	/// A message the Mac sends a device.
	func receive( _ message: HostMessage ) {
		switch message {
			case .show( let key, let hash ):
				wanted[key] = hash
				if images[hash] == nil {
					send( Message( type: "need", hash: hash ) )
				} else {
					showWanted( key )
				}
			case .brightness( let value ):
				settings.brightness = min( max( value, 0 ), 100 )
				applyBrightness()
			case .setName( let name ):
				settings.name = name
			case .orientation( let value ):
				settings.orientation = value
				send( Message( type: "deck", deck: deckInfo ) )   // the Mac renders for it again
			case .sleepTimeout( let seconds ):
				settings.sleepTimeout = max( seconds, 0 )
				scheduleSleep()
			case .sleep:
				goToSleep( reason: "bridge" )
			case .wake:
				if asleep {
					wake( reason: "bridge" )
					presses.swallowHeldKeys()   // keys held while asleep stay unforwarded
				}
			case .keyModes( let keys, let doubleTap, let hold, let delay, let interval, let window, let holdTime ):
				presses.setModes( repeat: keys, doubleTap: doubleTap, hold: hold, delay: delay, interval: interval, doubleTapWindow: window, holdTime: holdTime )
				schedulePresses()
			case .repeatKeys( let keys, let delay, let interval ):
				presses.setModes( repeat: keys, doubleTap: [], hold: [], delay: delay, interval: interval, doubleTapWindow: 300, holdTime: 500 )
				schedulePresses()
			case .setupMode, .setHostname, .unpair, .factoryReset, .encryptStorage, .devOTA, .firmwareBegin, .firmwareEnd,
				 .auth, .pairRequest, .pairNonce, .pairCancel, .noKey:
				break   // nothing a dock has
		}
	}

	/// An image the Mac sends, by hash (an ESP32's IMG1 frame).
	func receiveImage( _ image: Data, hash: String ) {
		if images[hash] == nil { imageOrder.append( hash ) }
		images[hash] = image
		let shown = Set( wanted.values )
		while imageOrder.count > Self.cacheLimit, let index = imageOrder.firstIndex( where: { !shown.contains( $0 ) } ) {
			images[imageOrder.remove( at: index )] = nil
		}
	}

	/// Sends a key the image it should show, and says so once the deck has it.
	private func showWanted( _ key: Int ) {
		guard let hash = wanted[key], let image = images[hash] else { return }
		guard deckReady, let model, key < model.rows * model.cols, model.format == .jpeg, image.starts( with: [ 0xFF, 0xD8 ] ) else { return }
		guard showing[key] != hash else {
			send( Message( type: "shown", key: key, hash: hash ) )
			return
		}
		link?.sendImage( image, key: key ) { [weak self] in
			guard let self, wanted[key] == hash, deckReady else { return }
			showing[key] = hash
			send( Message( type: "shown", key: key, hash: hash ) )
		}
	}

	// MARK: - Keys

	/// The deck's key states: keys that went down or up since the last ones.
	private func keysChanged( _ states: [Bool] ) {
		let now = ProcessInfo.processInfo.systemUptime
		let before = keyStates.count == states.count ? keyStates : Array( repeating: false, count: states.count )
		keyStates = states
		for key in states.indices where states[key] != before[key] {
			lastActivity = now
			if states[key] {
				if asleep {
					wake( reason: "key" )
					presses.swallowPress()   // this press only wakes the deck
				}
				forward( presses.keyDown( key, at: now ) )
			} else {
				forward( presses.keyUp( key, at: now ) )
			}
		}
		schedulePresses()
		scheduleSleep()
	}

	/// Sends key events to the Mac, as an ESP32 does.
	private func forward( _ events: [DockPresses.Event] ) {
		for event in events {
			switch event {
				case .keyDown( let key ):   send( Message( type: "keyDown", key: key ) )
				case .keyUp( let key ):     send( Message( type: "keyUp", key: key ) )
				case .tap( let key ):       send( Message( type: "keyTap", key: key ) )
				case .doubleTap( let key ): send( Message( type: "keyDoubleTap", key: key ) )
				case .hold( let key ):      send( Message( type: "keyHold", key: key ) )
				case .repeated( let key ):  send( Message( type: "keyRepeat", key: key ) )
			}
		}
	}

	/// Wakes for the next repeat, hold or tap that's due.
	private func schedulePresses() {
		pressTimer?.cancel()
		guard let due = presses.nextDeadline else { return }
		let wait = max( due - ProcessInfo.processInfo.systemUptime, 0 )
		pressTimer = Task { [weak self] in
			try? await Task.sleep( for: .seconds( wait ) )
			guard !Task.isCancelled, let self else { return }
			forward( presses.tick( at: ProcessInfo.processInfo.systemUptime ) )
			schedulePresses()
		}
	}

	// MARK: - Sleep and brightness

	/// The backlight: the brightness setting, or off while asleep.
	private func applyBrightness() {
		link?.setBrightness( asleep ? 0 : settings.brightness )
	}

	private func goToSleep( reason: String ) {
		guard !asleep, inSession else { return }
		forward( presses.releaseForwarded() )
		asleep = true
		applyBrightness()
		send( Message( type: "status", status: status, reason: reason ) )
	}

	private func wake( reason: String ) {
		guard asleep else { return }
		asleep       = false
		lastActivity = ProcessInfo.processInfo.systemUptime
		applyBrightness()
		send( Message( type: "status", status: status, reason: reason ) )
		scheduleSleep()
	}

	/// Sleeps once no key has been touched for the sleep timeout.
	private func scheduleSleep() {
		sleepTimer?.cancel()
		guard inSession, !asleep, settings.sleepTimeout > 0 else { return }
		let wait = max( lastActivity + TimeInterval( settings.sleepTimeout ) - ProcessInfo.processInfo.systemUptime, 0 )
		sleepTimer = Task { [weak self] in
			try? await Task.sleep( for: .seconds( wait ) )
			guard !Task.isCancelled, let self else { return }
			goToSleep( reason: "timer" )
		}
	}

	// MARK: - To the Mac

	/// A message as the firmware sends it; nil fields are left out.
	private struct Message: Encodable {
		var type   : String
		var key    : Int?
		var hash   : String?
		var deck   : DeckInfo?
		var status : DeviceStatus?
		var reason : String?
	}

	/// The hello, as JSON for the Log tab (DeviceHello itself isn't encodable).
	private struct HelloJSON: Encodable {
		var type     = "hello"
		var `protocol` = DeckServer.protocolVersion
		var id       : String
		var name     : String
		var firmware : String
		var cached   : [String]
		var deck     : DeckInfo
		var settings : DeviceReportedSettings
		var status   : DeviceStatus
	}

	private func send( _ message: Message ) {
		guard inSession else { return }
		onMessage?( json( message ) )
	}

	private func json( _ value: some Encodable ) -> Data {
		( try? JSONEncoder().encode( value ) ) ?? Data()
	}
}
