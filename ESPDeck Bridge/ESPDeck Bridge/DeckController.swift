//
//  DeckController.swift
//  ESPDeck Bridge
//
//  Decides what every device's keys show, renders them, keeps each ESP32 in sync,
//  performs actions for key presses, and runs sleep/wake rules.
//

import HomeKit
import Observation
import SwiftUI

@Observable
final class DeckController {
	let config = ConfigStore()
	let home   = HomeObserver()
	let server = DeckServer()
	@ObservationIgnored private(set) lazy var updates  = UpdateManager( controller: self )
	@ObservationIgnored private(set) lazy var usbSetup = USBSetup( controller: self )

	/// One per configured device, in the same order as `config.settings.devices`.
	private(set) var devices   : [DeckDevice] = []
	var lastError              : String?

	/// The key selected in the configuration window, which Copy and Paste act on.
	var focusedKey       : ( device: String, key: Int )?
	/// A copied key is on the clipboard; see DeckController+Clipboard.
	var clipboardHasKey  = false
	/// The configuration window's selection and page, shared with the menus.
	let window           = WindowState()

	/// Called whenever the menu bar summary may have changed.
	@ObservationIgnored var onStatusChange: ( ( _ items: [StatusItem], _ connected: Bool ) -> Void )?
	/// Called whenever the menu bar's deck list may have changed.
	@ObservationIgnored var onDecksChange : ( ( _ heading: String, _ decks: [DeckMenuEntry] ) -> Void )?

	/// This Mac's password for uploads from PlatformIO, once there is one (DevOTAPassword).
	private(set) var developerPassword: String?

	/// Launch at Login, as the AppKit bundle reports it.
	private(set) var launchAtLogin = LaunchAtLogin.off

	/// The AppKit bundle, which runs shortcuts. nil outside Mac Catalyst.
	@ObservationIgnored var macBridge: DeckMenuBarPlugin?

	/// The user's shortcuts, loaded on demand by `reloadShortcuts()`.
	private(set) var shortcuts       : [HomeTarget] = []
	private(set) var shortcutsLoaded = false
	private(set) var shortcutError   : String?
	@ObservationIgnored private var shortcutIcons: [String: UIImage] = [:]
	@ObservationIgnored private var shortcutIconRequests: Set<String> = []
	@ObservationIgnored private var shortcutsLoading = false
	private static let shortcutIconSize = 160

	/// Connected devices that haven't authenticated, for the sidebar's New Devices.
	var newDevices                                : [NewDevice] = []
	@ObservationIgnored var handshakes            : [ClientID: Handshake] = [:]
	@ObservationIgnored var clientDevices         : [ClientID: String] = [:]
	/// This Mac's host name, for the deck while pairing; see bridgeName.
	@ObservationIgnored var hostName              : String?
	/// Nothing goes to the devices until HomeKit has names and values (or 10 s pass), so
	/// launch doesn't send each key twice: once half-rendered, once for real.
	@ObservationIgnored private var holdingPushes = true
	/// Last state seen by each sleep trigger, to act only on changes.
	@ObservationIgnored private var triggerStates : [UUID: KeyState] = [:]
	private static let recentLimit = 96

	func start() {
		home.onChange = { [weak self] ref in
			self?.valueChanged( ref )
		}
		home.onHomesChanged = { [weak self] in
			self?.renderEverything()
		}

		devices = config.settings.devices.map { DeckDevice( id: $0.id ) }

		server.onDisconnect = { [weak self] client in
			self?.clientDisconnected( client )
		}
		server.onTraffic = { [weak self] client, entry in
			self?.recordTraffic( entry, client: client )
		}
		server.onMessage = { [weak self] client, message, payload in
			self?.handle( message, from: client, payload: payload )
		}
		server.start( bridgeID: config.settings.bridgeID )
		Task.detached { [weak self] in
			let name = ProcessInfo.processInfo.hostName   // can wait on DNS
			await MainActor.run { self?.hostName = name }
		}

		// Refresh names and icons of shortcuts already in use. Doing this only when one
		// is used avoids an Automation prompt for people who never use shortcuts.
		if config.settings.devices.contains( where: { settings in
			( settings.keys + [ settings.onSleep, settings.onWake ] ).contains { $0.kind == .shortcut }
		} ) {
			reloadShortcuts()
		}

		assignmentsChanged()
		observeStatus()
		updates.start()
		usbSetup.start()
		developerPassword = DevOTAPassword.stored()

		home.onReady = { [weak self] in
			self?.releasePushes()
		}
		MainThreadWatchdog.start { [weak self] lag in
			MainActor.assumeIsolated { self?.reportStall( lag ) }
		}
		Task { [weak self] in
			try? await Task.sleep( for: .seconds( 10 ) )
			self?.releasePushes()
		}

		refreshClipboard()
		NotificationCenter.default.addObserver( forName: UIPasteboard.changedNotification, object: nil, queue: .main ) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshClipboard() }
		}
	}

	func stop() async {
		server.stop()
		await home.stopWatching()
	}

	// MARK: - Lookup

	func device( _ id: String ) -> DeckDevice? {
		devices.first { $0.id == id }
	}

	func settings( _ id: String ) -> DeviceSettings? {
		config.settings.devices.first { $0.id == id }
	}

	/// The layout to render for: what the deck reports now, else what it last reported.
	func layout( _ id: String ) -> DeckLayout {
		device( id )?.deck.layout ?? settings( id )?.layout ?? .mini
	}

	func assignment( _ id: String, key: Int ) -> KeyAssignment {
		settings( id )?.key( key ) ?? KeyAssignment()
	}

	// MARK: - Key configuration

	func update( device id: String, key: Int, _ change: ( inout KeyAssignment ) -> Void ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		config.settings.devices[index].ensureKey( key )
		change( &config.settings.devices[index].keys[key] )
		assignmentsChanged( device: id, deferPush: true )
	}

	func setIcon( data: Data, device id: String, key: Int, state: KeyState ) {
		guard let name = config.importIcon( data ) else {
			lastError = "That image couldn't be read."
			return
		}
		config.setIcon( name, device: id, key: key, state: state )
		render( device: id, key: key )
	}

	/// Also gives the opposite state (On/Off, Open/Closed, Locked/Unlocked) the matching symbol,
	/// unless it has an icon of its own that wasn't matched this way.
	func setSymbol( _ name: String, device id: String, key: Int, state: KeyState ) {
		let before = assignment( id, key: key )
		config.setIcon( KeyAssignment.symbolPrefix + name, device: id, key: key, state: state )

		if let opposite = state.opposite, before.states.contains( opposite ),
		   let match = SymbolCounterpart.symbol( pairing: name, for: opposite ) {
			let current      = before.icons[opposite.rawValue]
			let wasMatched   = before.symbol( for: state ).flatMap { SymbolCounterpart.symbol( pairing: $0, for: opposite ) }
			if current == nil || ( wasMatched != nil && before.symbol( for: opposite ) == wasMatched ) {
				config.setIcon( KeyAssignment.symbolPrefix + match, device: id, key: key, state: opposite )
			}
		}
		render( device: id, key: key )
	}

	func removeIcon( device id: String, key: Int, state: KeyState ) {
		config.setIcon( nil, device: id, key: key, state: state )
		render( device: id, key: key )
	}

	/// Exchanges two keys' assignments, icons and appearance.
	func swapKeys( device id: String, _ first: Int, _ second: Int ) {
		guard first != second, let index = config.settings.deviceIndex( id ) else { return }
		config.settings.devices[index].ensureKey( max( first, second ) )
		config.settings.devices[index].keys.swapAt( first, second )
		assignmentsChanged( device: id )
	}

	func clear( device id: String, key: Int ) {
		guard let index = config.settings.deviceIndex( id ), key < config.settings.devices[index].keys.count else { return }
		config.settings.devices[index].keys[key] = KeyAssignment()
		config.removeUnusedIcons()
		assignmentsChanged( device: id )
	}

	/// Mac-side device settings: sleep triggers and commands.
	func updateSettings( device id: String, _ change: ( inout DeviceSettings ) -> Void ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		change( &config.settings.devices[index] )
		assignmentsChanged( device: id )
	}

	// MARK: - Device settings (owned by the ESP32)

	func rename( device id: String, to name: String ) {
		let trimmed = name.trimmingCharacters( in: .whitespacesAndNewlines )
		guard !trimmed.isEmpty else { return }
		updateMirror( id ) { $0.name = trimmed }
		send( .setName( trimmed ), to: id )
	}

	func setBrightness( device id: String, _ value: Int ) {
		updateMirror( id ) { $0.brightness = value }
		send( .brightness( value ), to: id )
	}

	/// "auto" or a KeyTransform raw value. The ESP32 answers with a `deck` message
	/// carrying the new transform, and the keys re-render then.
	func setOrientation( device id: String, _ value: String ) {
		updateMirror( id ) { $0.orientation = value }
		send( .orientation( value ), to: id )
	}

	func setSleepTimeout( device id: String, seconds: Int ) {
		updateMirror( id ) { $0.sleepTimeout = seconds }
		send( .sleepTimeout( seconds ), to: id )
	}

	func sleep( device id: String ) {
		send( .sleep, to: id )
	}

	func wake( device id: String ) {
		send( .wake, to: id )
	}

	func setSetupMode( device id: String, _ enabled: Bool ) {
		send( .setupMode( enabled ), to: id )
	}

	/// Firmware 4.0.0 and later get the password's hash encrypted; earlier firmware can only be
	/// told to turn uploads off.
	static let devOTAProtocol = 4

	/// Allows uploads from PlatformIO with this Mac's developer password (made now if there
	/// isn't one), or turns them off. Devices only get the password's hash, encrypted.
	func setDevOTA( device id: String, enabled: Bool ) {
		guard let device = device( id ), let client = device.client else { return }
		guard !enabled || ( device.protocolVersion ?? 0 ) >= Self.devOTAProtocol else {
			lastError = "Uploads from PlatformIO need firmware 4.0.0 or later on the deck."
			return
		}
		server.sendDevOTA( passwordHash: enabled ? Self.devOTAHash( developerPasswordCreatingIfNeeded() ) : nil, to: client )
	}

	private static func devOTAHash( _ password: String ) -> Data? {
		Data( hex: DevOTAPassword.hash( password ) )
	}

	@discardableResult
	func developerPasswordCreatingIfNeeded() -> String {
		if let developerPassword { return developerPassword }
		let password: String
		if let stored = DevOTAPassword.stored() {
			password = stored
		} else {
			password = DevOTAPassword.generate()
			DevOTAPassword.store( password )
		}
		developerPassword = password
		return password
	}

	/// Which devices got a new developer password, which allow uploads but are offline and
	/// keep the old one, and which had uploads turned off because their firmware can't get the
	/// new one safely (before 4.0.0).
	struct DeveloperPasswordChange {
		var updated   : [String]
		var offline   : [String]
		var turnedOff : [String] = []

		var summary: String {
			let count = updated.count == 1 ? "1 device updated" : "\(updated.count) devices updated"
			var text  = updated.isEmpty && offline.isEmpty && turnedOff.isEmpty ? "No device allows uploads right now." : "\(count)."
			if !offline.isEmpty {
				let names = ListFormatter.localizedString( byJoining: offline )
				text = "\(count); \(names) \(offline.count == 1 ? "is" : "are") offline and still \(offline.count == 1 ? "uses" : "use") the old password."
			}
			if !turnedOff.isEmpty {
				let names = ListFormatter.localizedString( byJoining: turnedOff )
				text += " Uploads were turned off on \(names), which \(turnedOff.count == 1 ? "needs" : "need") firmware 4.0.0 or later for the new password."
			}
			return text
		}
	}

	/// Replaces this Mac's developer password with a new random one, or with `password`,
	/// and sends its hash to every connected device that allows uploads.
	@discardableResult
	func replaceDeveloperPassword( with password: String? = nil ) -> DeveloperPasswordChange {
		let new = password ?? DevOTAPassword.generate()
		DevOTAPassword.store( new )
		developerPassword = new

		var change = DeveloperPasswordChange( updated: [], offline: [] )
		for device in devices {
			guard let settings = settings( device.id ), !settings.isDemo else { continue }
			if let client = device.client, device.status.devOTA == true {
				if ( device.protocolVersion ?? 0 ) >= Self.devOTAProtocol {
					server.sendDevOTA( passwordHash: Self.devOTAHash( new ), to: client )
					change.updated.append( settings.name )
				} else {
					server.sendDevOTA( passwordHash: nil, to: client )
					change.turnedOff.append( settings.name )
				}
			} else if !device.isOnline, settings.devOTA {
				change.offline.append( settings.name )
			}
		}
		return change
	}

	// MARK: - Demo decks

	/// Adds a virtual deck of the given model and returns its ID.
	@discardableResult
	func addDemoDevice( layout: DeckLayout ) -> String {
		let id    = "demo-" + UUID().uuidString.lowercased()
		let count = config.settings.devices.filter( \.isDemo ).count
		var settings    = DeviceSettings( id: id, name: count == 0 ? "Demo \(layout.model)" : "Demo \(layout.model) \(count + 1)" )
		settings.isDemo = true
		settings.layout = layout
		config.settings.devices.append( settings )
		devices.append( DeckDevice( id: id ) )
		renderAll( device: id )
		return id
	}

	/// Changes a demo deck's model. Keys past the new size are kept, just not shown.
	func setLabelPosition( device id: String, _ position: LabelPosition ) {
		updateMirror( id ) { $0.labelPosition = position }
		renderAll( device: id )
	}

	func setDemoLayout( device id: String, _ layout: DeckLayout ) {
		guard settings( id )?.isDemo == true else { return }
		updateMirror( id ) { $0.layout = layout }
		renderAll( device: id )
	}

	func renameDemo( device id: String, to name: String ) {
		let trimmed = name.trimmingCharacters( in: .whitespacesAndNewlines )
		guard !trimmed.isEmpty, settings( id )?.isDemo == true else { return }
		updateMirror( id ) { $0.name = trimmed }
	}

	/// Replaces a device's keys with another's, matching keys by row and column so a
	/// layout carries across deck sizes. Keys that don't fit are left out.
	func copyKeys( from source: String, to destination: String ) {
		guard let from = settings( source ), let index = config.settings.deviceIndex( destination ) else { return }
		let sourceLayout = layout( source )
		let targetLayout = layout( destination )

		var keys = Array( repeating: KeyAssignment(), count: targetLayout.keyCount )
		for row in 0..<min( sourceLayout.rows, targetLayout.rows ) {
			for col in 0..<min( sourceLayout.cols, targetLayout.cols ) {
				keys[row * targetLayout.cols + col] = from.key( row * sourceLayout.cols + col )
			}
		}
		config.settings.devices[index].keys = keys
		config.removeUnusedIcons()
		assignmentsChanged( device: destination )
	}

	/// Erases the device (Wi-Fi, name, pairing, settings, image cache) and restarts it in
	/// setup mode. Its pairing key is useless afterwards, but its key layout is kept here,
	/// so it comes back once the device is set up and paired again.
	func factoryReset( device id: String ) {
		guard let client = device( id )?.client, server.isAuthenticated( client ) else { return }
		server.send( .factoryReset, to: client )
		PairingKeyStore.delete( id )
	}

	/// Removes a device's settings and unpairs it. If it's connected, it comes back as a
	/// new device waiting to be paired.
	func forget( device id: String ) {
		if let client = device( id )?.client {
			server.send( .unpair, to: client )
			server.drop( client )
		}
		PairingKeyStore.delete( id )
		config.settings.devices.removeAll { $0.id == id }
		devices.removeAll { $0.id == id }
		config.removeUnusedIcons()
		assignmentsChanged()
	}

	private func updateMirror( _ id: String, _ change: ( inout DeviceSettings ) -> Void ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		change( &config.settings.devices[index] )
	}

	private func send( _ message: HostMessage, to id: String ) {
		guard let client = device( id )?.client else { return }
		server.send( message, to: client )
	}

	// MARK: - Watching HomeKit

	/// `deferPush` batches edits from the configuration UI (e.g. dragging the color
	/// picker) so the ESP32 only receives the final image.
	private func assignmentsChanged( device id: String? = nil, deferPush: Bool = false ) {
		var refs = Set<CharacteristicRef>()
		for settings in config.settings.devices {
			for key in settings.keys {
				if let ref = key.characteristicRef { refs.insert( ref ) }
				if let ref = key.alertRef { refs.insert( ref ) }
			}
			for trigger in settings.sleepTriggers {
				if let ref = trigger.source.characteristicRef { refs.insert( ref ) }
			}
		}
		home.watch( refs )

		if let id {
			renderAll( device: id, deferPush: deferPush )
		} else {
			renderEverything()
		}
	}

	private func valueChanged( _ ref: CharacteristicRef ) {
		for settings in config.settings.devices {
			for ( index, key ) in settings.keys.enumerated() where key.characteristicRef == ref || key.alertRef == ref {
				render( device: settings.id, key: index )
			}
		}
		evaluateTriggers( for: ref )
	}

	private func evaluateTriggers( for ref: CharacteristicRef ) {
		for settings in config.settings.devices {
			for trigger in settings.sleepTriggers where trigger.source.characteristicRef == ref {
				guard let kind = trigger.source.kind else { continue }
				let current  = kind.state( for: home.values[ref] )
				let previous = triggerStates.updateValue( current, forKey: trigger.id )
				// The first reading is a baseline, not a change.
				guard let previous, previous != current else { continue }

				let effect: SleepEffect
				if current == trigger.state {
					effect = trigger.effect
				} else if trigger.reverse, current == trigger.state.opposite {
					effect = trigger.effect.opposite
				} else {
					continue
				}

				let name = home.name( for: trigger.source ) ?? "An accessory"
				print( "[DeckController] Trigger: \(settings.name) → \(effect.rawValue)" )
				logEvent( "Trigger: \(name) became \(current.title) → \(effect.title.lowercased()) the deck", device: settings.id )
				send( effect == .sleep ? .sleep : .wake, to: settings.id )
			}
		}
	}

	// MARK: - Rendering

	func state( device id: String, key: Int ) -> KeyState {
		let assignment = assignment( id, key: key )
		guard let kind = assignment.kind else { return .standard }
		if assignment.isToggleShortcut { return assignment.shortcutState ?? .off }
		guard let ref = assignment.characteristicRef else { return kind.state( for: nil ) }
		if let alert = assignment.alertRef, ( home.values[alert] as? NSNumber )?.boolValue == true {
			return .obstructed
		}
		return kind.state( for: home.values[ref] )
	}

	/// How a key looks now, or as it would look in `state` (for the Icons previews).
	func face( device id: String, key: Int, state override: KeyState? = nil ) -> KeyFace {
		let assignment = assignment( id, key: key )
		let labelOnTop = settings( id )?.labelPosition == .top
		guard let kind = assignment.kind else {
			// Not bound to anything, but it can still carry an icon and a label.
			var face = KeyFace()
			face.labelOnTop = labelOnTop
			face.background = assignment.backgroundColor.flatMap( Color.init( hex: ) )
			face.label      = assignment.showLabel && !assignment.label.isEmpty ? assignment.label : nil
			applyCustomIcon( assignment.iconName( for: .standard ), to: &face )
			return face
		}

		let state = override ?? state( device: id, key: key )
		var face  = KeyFace()
		face.labelOnTop = labelOnTop
		face.symbol     = kind.symbol( for: state )
		face.tint       = kind.tint( for: state )
		face.doorArrow  = kind.doorArrow( for: state )
		face.shortcutID = assignment.shortcutID
		face.background = assignment.backgroundColor.flatMap( Color.init( hex: ) )
		applyCustomIcon( iconName( for: state, of: assignment ), to: &face )

		if assignment.showLabel {
			var label = assignment.label.isEmpty ? defaultName( for: assignment ) : assignment.label
			if kind == .temperature, let ref = assignment.characteristicRef, let celsius = home.values[ref] as? NSNumber {
				let reading = Measurement( value: celsius.doubleValue, unit: UnitTemperature.celsius )
				label = reading.formatted( .measurement( width: .narrow, numberFormatStyle: .number.precision( .fractionLength( 0...1 ) ) ) )
			}
			face.label = label
		}

		if override == nil, let ref = assignment.characteristicRef {
			face.unreachable = !home.isReachable( ref )
		}
		return face
	}

	func renderEverything() {
		for device in devices {
			renderAll( device: device.id )
		}
	}

	private func renderAll( device id: String, deferPush: Bool = false ) {
		guard let device = device( id ) else { return }
		let count = layout( id ).keyCount
		if device.keys.count != count {
			device.keys = Array( repeating: nil, count: count )
		}
		for key in 0..<count {
			render( device: id, key: key, deferPush: deferPush )
		}
	}

	private func render( device id: String, key: Int, deferPush: Bool = false ) {
		guard let device = device( id ), key < device.keys.count else { return }
		let face = face( device: id, key: key )
		guard let rendered = KeyRenderer.render( face, icon: artwork( for: face ), layout: layout( id ) ) else {
			print( "[DeckController] Rendering key \(key) of \(id) failed" )
			return
		}

		remember( rendered, in: device )
		if device.keys[key]?.hash != rendered.hash {
			device.keys[key] = rendered
		}
		if deferPush {
			schedulePush( device )
		} else {
			push( device, key: key )
		}
	}

	private func schedulePush( _ device: DeckDevice ) {
		device.pushTask?.cancel()
		device.pushTask = Task { [weak self, weak device] in
			try? await Task.sleep( for: .milliseconds( 400 ) )
			guard !Task.isCancelled, let self, let device else { return }
			for key in device.keys.indices {
				push( device, key: key )
			}
		}
	}

	private func remember( _ rendered: RenderedKey, in device: DeckDevice ) {
		if device.recentImages[rendered.hash] == nil {
			device.recentOrder.append( rendered.hash )
		}
		device.recentImages[rendered.hash] = rendered.data

		// Drop the oldest images that no key is showing.
		let showing = Set( device.keys.compactMap { $0?.hash } + [ rendered.hash ] )
		while device.recentOrder.count > Self.recentLimit, let index = device.recentOrder.firstIndex( where: { !showing.contains( $0 ) } ) {
			device.recentImages[device.recentOrder.remove( at: index )] = nil
		}
	}

	// MARK: - ESP32

	/// Makes the ESP32 show `keys[key]`, sending the image first if it lacks it.
	private func releasePushes() {
		guard holdingPushes else { return }
		holdingPushes = false
		renderEverything()
		for device in devices where device.isOnline {
			for key in device.keys.indices {
				push( device, key: key )
			}
		}
	}

	private func push( _ device: DeckDevice, key: Int, force: Bool = false ) {
		guard !holdingPushes else { return }
		guard let client = device.client, key < device.keys.count, let rendered = device.keys[key] else { return }
		guard layout( device.id ).format != .none else { return }
		guard force || device.shown[key] != rendered.hash else { return }

		if !device.knownHashes.contains( rendered.hash ) {
			server.sendImage( hash: rendered.hash, image: rendered.data, to: client )
			device.knownHashes.insert( rendered.hash )
		}
		server.send( .show( key: key, hash: rendered.hash ), to: client )
		device.shown[key] = rendered.hash
		expectShown( device, key: key, hash: rendered.hash )
	}

	// MARK: - Progress and traffic

	/// Tracks a `show` until the deck confirms it, for the progress bar.
	private func expectShown( _ device: DeckDevice, key: Int, hash: String ) {
		if device.pendingShows.isEmpty { device.batchTotal = 0 }
		if device.pendingShows[key] == nil { device.batchTotal += 1 }
		device.pendingShows[key] = hash
		device.lastProgress      = Date()

		// Firmware that doesn't send `shown`, or a deck that's unplugged, would leave the bar
		// up forever; give up after a while without progress.
		device.pendingTimeout?.cancel()
		device.pendingTimeout = Task { [weak device] in
			try? await Task.sleep( for: .seconds( 30 ) )
			guard !Task.isCancelled, let device, Date().timeIntervalSince( device.lastProgress ) >= 29 else { return }
			device.clearPending()
		}
	}

	/// Into the device's Log tab once the connection has authenticated; until then only into
	/// its handshake, whose frames join the log if it does (anyone can claim a device's ID).
	private func recordTraffic( _ entry: TrafficEntry, client: ClientID ) {
		if let id = clientDevices[client], let device = device( id ) {
			device.record( entry )
		} else {
			recordHandshakeTraffic( entry, client: client )
		}
	}

	private func handle( _ message: DeviceMessage, from client: ClientID, payload: Data ) {
		guard server.isAuthenticated( client ) else {
			handleHandshake( message, from: client, payload: payload )
			return
		}
		if case .hello( let hello ) = message {
			// A resync inside the session, which can't change who the device is.
			guard hello.id == clientDevices[client] else {
				print( "[DeckController] A hello inside the session claimed another ID (\(hello.id)); closing" )
				server.drop( client )
				return
			}
			adoptDevice( hello, from: client )
			return
		}
		guard let id = clientDevices[client], let device = device( id ) else { return }

		switch message {
			case .hello, .auth, .pairResponse, .pairReveal, .pairConfirm, .pairCancel:
				break

			case .firmwareStatus( let status ):
				firmwareStatus( status, device: device, client: client )

			case .deck( let deck ):
				device.deck = deck
				if let layout = deck.layout {
					updateMirror( id ) { $0.layout = layout }
				}
				renderAll( device: id )

			case .status( let status ):
				let wasAsleep = device.status.asleep
				device.status = status
				if let value = status.devOTA {
					updateMirror( id ) { $0.devOTA = value }
				}
				if status.asleep || status.setupMode {
					device.pressed = []
					device.chord   = false
				}
				if status.asleep != wasAsleep, let settings = settings( id ) {
					let why = status.reason.map { " (\(DeviceStatus.describe( reason: $0 )))" } ?? ""
					logEvent( status.asleep ? "The deck went to sleep\(why)" : "The deck woke\(why)", device: id )
					perform( status.asleep ? settings.onSleep : settings.onWake, context: status.asleep ? "On sleep" : "On wake", device: id )
				}

			case .need( let hash ):
				print( "[DeckController] \(id) needs \(hash)" )
				device.knownHashes.remove( hash )
				let keys = device.shown.filter { $0.value == hash }.map( \.key )
				if let data = device.recentImages[hash] {
					server.sendImage( hash: hash, image: data, to: client )
					device.knownHashes.insert( hash )
					for key in keys {
						server.send( .show( key: key, hash: hash ), to: client )
					}
				} else {
					// Not something we rendered recently; resend whatever those keys should show now.
					for key in keys {
						push( device, key: key, force: true )
					}
				}

			case .shown( let key, let hash ):
				if device.pendingShows[key] == hash {
					device.pendingShows[key] = nil
					device.lastProgress      = Date()
					if device.pendingShows.isEmpty { device.clearPending() }
				}

			case .keyDown( let key ):
				device.lastKeyActivity = Date()
				if !device.pressed.isEmpty { device.chord = true }
				device.pressed.insert( key )

			case .keyUp( let key ):
				// Act on release, and only for a lone press: holding two keys (the setup
				// chord) shouldn't open the garage.
				let wasPressed = device.pressed.remove( key ) != nil
				if wasPressed && !device.chord {
					press( device: id, key: key )
				}
				if device.pressed.isEmpty { device.chord = false }
		}
	}

	/// A device that has authenticated: add it if it's new, and bring it up to date.
	/// `handshakeTraffic`: the connection's frames before it authenticated, for the log.
	func adoptDevice( _ hello: DeviceHello, from client: ClientID, handshakeTraffic: [TrafficEntry] = [] ) {
		print( "[DeckController] hello from \(hello.name) (\(hello.id)): firmware \(hello.firmware), \(hello.cached.count) cached images" )

		// A reconnecting device replaces its old connection.
		for ( other, id ) in clientDevices where id == hello.id && other != client {
			clientDevices[other] = nil
			server.drop( other )
		}
		clientDevices[client] = hello.id

		if config.settings.deviceIndex( hello.id ) == nil {
			var settings = DeviceSettings( id: hello.id, name: hello.name )
			// Keys configured in the single-deck version go to the first device.
			if let legacy = config.settings.legacyKeys {
				settings.keys = legacy
				config.settings.legacyKeys = nil
			}
			config.settings.devices.append( settings )
			devices.append( DeckDevice( id: hello.id ) )
		}

		updateMirror( hello.id ) { settings in
			settings.name = hello.name
			if let value = hello.settings.brightness   { settings.brightness = value }
			if let value = hello.settings.orientation  { settings.orientation = value }
			if let value = hello.settings.sleepTimeout { settings.sleepTimeout = value }
			if let value = hello.status.devOTA         { settings.devOTA = value }
			if let layout = hello.deck.layout          { settings.layout = layout }
		}

		guard let device = device( hello.id ) else { return }
		for entry in handshakeTraffic {
			device.record( entry )
		}
		device.client          = client
		device.endpoint        = server.endpoint( of: client )
		device.lastAddress     = device.endpoint
		device.protocolVersion = hello.protocolVersion
		device.firmware        = hello.firmware
		device.firmwareBuild   = hello.elfSHA256
		device.ip              = hello.settings.ip ?? device.endpoint
		device.deck            = hello.deck
		device.status          = hello.status
		device.pressed         = []
		device.chord           = false
		device.knownHashes     = Set( hello.cached )
		device.shown           = [:]
		device.clearPending()

		// `shown` was just reset, so rendering sends every key once (a second forced pass
		// used to send each `show` twice).
		renderAll( device: hello.id )
		firmwareReconnected( device )
		updates.deviceConnected( hello.id )
	}

	private func clientDisconnected( _ client: ClientID ) {
		handshakeEnded( client )
		guard let id = clientDevices.removeValue( forKey: client ), let device = device( id ), device.client == client else { return }
		firmwareDisconnected( device )
		device.disconnected()
	}

	// MARK: - Actions

	/// Performs a key's action; also used by the configuration UI's Test button.
	func press( device id: String, key: Int ) {
		perform( assignment( id, key: key ), context: "Key \(key + 1)", device: id, key: key )
	}

	/// Runs an assignment's action: a HomeKit write, a scene, or a shortcut.
	/// `device` is whose log records it; `key`, when it's a key press, lets an On/Off
	/// shortcut record its new state.
	func perform( _ assignment: KeyAssignment, context: String, device id: String? = nil, key: Int? = nil ) {
		guard let kind = assignment.kind, assignment.action != .none else { return }

		if kind == .shortcut {
			runShortcut( assignment, context: context, device: id, key: key )
			return
		}

		Task {
			do {
				let summary = try await home.perform( assignment )
				lastError = nil
				logEvent( "\(context): \(summary)", device: id )
			} catch {
				print( "[DeckController] \(context) failed: \(error)" )
				lastError = "\(context): \(error.localizedDescription)"
				logEvent( "\(context) failed: \(error.localizedDescription)", device: id )
			}
		}
	}

	/// The app didn't respond for a while: long enough, past 10 s, for the devices to give
	/// up on their heartbeat. Recorded in every connected device's log.
	private func reportStall( _ seconds: TimeInterval ) {
		let text = String( format: "ESPDeck Bridge was unresponsive for %.1f s", seconds )
		print( "[DeckController] \(text)" )
		for device in devices where device.isOnline {
			logEvent( text, device: device.id )
		}
	}

	/// Something the app did or noticed, rather than a message, in a device's Log tab.
	func logEvent( _ text: String, device id: String? ) {
		guard let id, let device = device( id ) else { return }
		device.record( TrafficEntry( direction: .event, summary: text, bytes: 0 ) )
	}

	// MARK: - Shortcuts

	/// Reads the shortcut list from Shortcuts Events. The first call shows the Automation
	/// permission prompt.
	func reloadShortcuts() {
		guard let macBridge else {
			shortcutError = "Shortcuts are only available on the Mac."
			return
		}
		guard !shortcutsLoading else { return }
		shortcutsLoading = true

		macBridge.loadShortcuts { [weak self] list, error in
			guard let self else { return }
			shortcutsLoading = false
			shortcutError    = error
			shortcutsLoaded  = true
			if error != nil && list.isEmpty && !shortcuts.isEmpty { return }   // keep the old list on a failure

			shortcuts = list.compactMap { entry in
				guard entry.count == 3 else { return nil }
				return HomeTarget( kind: .shortcut, accessoryID: nil, serviceID: nil, actionSetID: nil, shortcutID: entry[0],
								   name: entry[1], room: entry[2].isEmpty ? nil : entry[2] )
			}
			.sorted { ( $0.room ?? "~", $0.name ) < ( $1.room ?? "~", $1.name ) }

			// Follow renames.
			let names = Dictionary( shortcuts.compactMap { target in target.shortcutID.map { ( $0, target.name ) } }, uniquingKeysWith: { first, _ in first } )
			func refresh( _ assignment: inout KeyAssignment ) {
				if assignment.kind == .shortcut, let id = assignment.shortcutID, let name = names[id], name != assignment.shortcutName {
					assignment.shortcutName = name
				}
			}
			for index in config.settings.devices.indices {
				for key in config.settings.devices[index].keys.indices {
					refresh( &config.settings.devices[index].keys[key] )
				}
				refresh( &config.settings.devices[index].onSleep )
				refresh( &config.settings.devices[index].onWake )
			}
			renderEverything()
		}
	}


	/// The shortcut's own icon, from memory, then disk, then Shortcuts Events.
	/// The shortcut's own icon from memory or disk. If neither has it, it's fetched once in
	/// the background and the keys re-render when it arrives; a failed fetch isn't retried
	/// until the next launch (retrying on every render used to stall the app).
	func shortcutIcon( id: String ) -> UIImage? {
		if let cached = shortcutIcons[id] { return cached }
		if let stored = config.shortcutIcon( id: id ) {
			shortcutIcons[id] = stored
			return stored
		}
		guard let macBridge, !shortcutIconRequests.contains( id ) else { return nil }
		shortcutIconRequests.insert( id )
		macBridge.loadShortcutIcon( id: id, size: Self.shortcutIconSize ) { [weak self] png in
			guard let self, let png, let image = UIImage( data: png ) else { return }
			config.storeShortcutIcon( png, id: id )
			shortcutIcons[id] = image
			renderEverything()
		}
		return nil
	}


	/// A One-Shot shortcut just runs. An On/Off one gets "on" or "off" as its input, the state
	/// the key is switching to, and the key then shows the state the shortcut output
	/// ("on"/"off", "true"/"false", "yes"/"no", "1"/"0"), or failing that the one it asked for.
	private func runShortcut( _ assignment: KeyAssignment, context: String, device: String?, key: Int? ) {
		guard let id = assignment.shortcutID else { return }
		guard let macBridge else {
			lastError = "Shortcuts can only run on the Mac."
			return
		}

		var target: KeyState?
		if assignment.isToggleShortcut {
			switch assignment.action {
				case .turnOn:  target = .on
				case .turnOff: target = .off
				default:       target = assignment.shortcutState == .on ? .off : .on
			}
		}
		let input = target.map { $0 == .on ? "on" : "off" }

		let name = assignment.shortcutName ?? "shortcut"
		if macBridge.isShortcutRunning( id: id ) {
			logEvent( "\(context): shortcut \u{201C}\(name)\u{201D} is still running; press ignored", device: device )
			return
		}
		logEvent( "\(context): running shortcut \u{201C}\(name)\u{201D}" + ( input.map { " with input \u{201C}\($0)\u{201D}" } ?? "" ), device: device )
		macBridge.startShortcut( id: id, input: input ) { [weak self] message, output in
			guard let self else { return }
			if let message {
				lastError = "\(context): \(message)"
				logEvent( "\(context): shortcut \u{201C}\(name)\u{201D} failed: \(message)", device: device )
				return
			}
			guard let target, let device, let key else {
				logEvent( "\(context): shortcut \u{201C}\(name)\u{201D} finished", device: device )
				return
			}
			let state = Self.shortcutState( from: output ) ?? target
			update( device: device, key: key ) { assignment in
				// Unless the key was reassigned while the shortcut ran.
				if assignment.isToggleShortcut && assignment.shortcutID == id { assignment.shortcutState = state }
			}
			logEvent( "\(context): shortcut \u{201C}\(name)\u{201D} finished; the key shows \(state.title)", device: device )
		}
	}

	private static func shortcutState( from output: String ) -> KeyState? {
		switch output.trimmingCharacters( in: .whitespacesAndNewlines ).lowercased() {
			case "on", "true", "yes", "1":  .on
			case "off", "false", "no", "0": .off
			default:                        nil
		}
	}


	// MARK: - Faces

	/// A state's own icon, or else Default's. When Default is an SF Symbol, a state without its
	/// own icon uses the matching variant if there is one: lamp.ceiling gives lamp.ceiling.fill
	/// for On, door.garage.closed gives door.garage.open for Open. Off never gains a slash:
	/// Default is the plain symbol, so Off only unfills it (lightbulb.fill gives lightbulb).
	private func iconName( for state: KeyState, of assignment: KeyAssignment ) -> String? {
		if assignment.icons[state.rawValue] == nil, let symbol = assignment.symbol( for: .standard ),
		   let variant = SymbolCounterpart.symbol( pairing: symbol, for: state ),
		   symbol.contains( "slash" ) || !variant.contains( "slash" ) {
			return KeyAssignment.symbolPrefix + variant
		}
		return assignment.iconName( for: state )
	}

	/// A dropped image or chosen SF Symbol replaces the built-in artwork (and a
	/// shortcut's own icon). The garage arrow only fits the built-in open-door symbol.
	private func applyCustomIcon( _ icon: String?, to face: inout KeyFace ) {
		guard let icon else { return }
		if icon.hasPrefix( KeyAssignment.symbolPrefix ) {
			face.symbol = String( icon.dropFirst( KeyAssignment.symbolPrefix.count ) )
		} else {
			face.iconName = icon
		}
		face.shortcutID = nil
		if face.symbol != "door.garage.open" || face.iconName != nil {
			face.doorArrow = nil
		}
	}

	/// Name used when a key has no custom label.
	func defaultName( for assignment: KeyAssignment ) -> String? {
		assignment.kind == .shortcut ? assignment.shortcutName : home.name( for: assignment )
	}

	/// The dropped icon for a face, or a shortcut's own icon when it has none.
	func artwork( for face: KeyFace ) -> UIImage? {
		if let name = face.iconName, let icon = config.icon( named: name ) { return icon }
		return face.shortcutID.flatMap { shortcutIcon( id: $0 ) }
	}

	// MARK: - Status

	struct StatusItem: Hashable {
		enum Level: Int {
			case waiting = 0
			case ok      = 1
			case problem = 2
			case demo    = 3
		}

		let text  : String
		let level : Level
	}

	/// One device's state in a few words, with its indicator.
	func status( device: DeckDevice ) -> StatusItem {
		let name = settings( device.id )?.name ?? device.id
		if settings( device.id )?.isDemo == true { return StatusItem( text: "\(name): demo deck", level: .demo ) }
		guard device.isOnline else { return StatusItem( text: "\(name): offline", level: .waiting ) }
		if device.status.setupMode { return StatusItem( text: "\(name): setup mode", level: .waiting ) }
		if !device.deck.connected  { return StatusItem( text: "\(name): no Stream Deck", level: .waiting ) }
		if device.status.asleep    { return StatusItem( text: "\(name): asleep", level: .ok ) }
		return StatusItem( text: "\(name): connected", level: .ok )
	}

	var serverStatus: StatusItem? {
		switch server.listenerState {
			case .listening:          config.settings.devices.allSatisfy( \.isDemo ) ? StatusItem( text: "Waiting for an ESP32…", level: .waiting ) : nil
			case .stopped:            StatusItem( text: "Server stopped", level: .problem )
			case .failed( let text ): StatusItem( text: "Server failed: \(text)", level: .problem )
		}
	}

	var homeStatus: StatusItem {
		let authorization = home.authorization
		if !home.homes.isEmpty {
			return StatusItem( text: home.hasSeveralHomes ? "HomeKit: Connected (\(home.homes.count) Homes)" : "HomeKit: Connected", level: .ok )
		} else if authorization.contains( .determined ) && !authorization.contains( .authorized ) {
			return StatusItem( text: "HomeKit access denied", level: .problem )
		} else if authorization.contains( .authorized ) {
			return StatusItem( text: "No HomeKit home", level: .problem )
		}
		return StatusItem( text: "Waiting for HomeKit…", level: .waiting )
	}

	/// The menu bar's lines under its deck list (which shows each deck's own status).
	var statusItems: [StatusItem] {
		let pending = newDevices.map { StatusItem( text: "\($0.hello.name): waiting to be paired", level: .waiting ) }
		return [ serverStatus ].compactMap { $0 } + pending + [ homeStatus ] + updates.statusItems
	}

	struct DeckMenuEntry: Equatable {
		var id    : String
		var title : String
		var level : StatusItem.Level
	}

	/// The Home's name, "HomeKit" with several Homes, or HomeKit's state before it's ready.
	var deckMenuHeading: String {
		switch home.homes.count {
			case 0:  homeStatus.text
			case 1:  home.homes[0].name
			default: "HomeKit"
		}
	}

	/// Real decks in sidebar order, then demo decks.
	var deckMenuEntries: [DeckMenuEntry] {
		let entries = devices.map { device in
			let status = status( device: device )
			let name   = settings( device.id )?.name ?? device.id
			let state  = status.text.components( separatedBy: ": " ).last ?? ""
			return DeckMenuEntry( id: device.id, title: status.level == .demo ? "\(name) (demo)" : "\(name): \(state)", level: status.level )
		}
		return entries.filter { $0.level != .demo } + entries.filter { $0.level == .demo }
	}

	// MARK: - Launch at Login

	enum LaunchAtLogin: Int {
		case off           = 0
		case on            = 1
		case needsApproval = 2
	}

	/// Re-reads it; the user can also change it in System Settings.
	func refreshLaunchAtLogin() {
		launchAtLogin = macBridge.flatMap { LaunchAtLogin( rawValue: $0.launchAtLoginStatus() ) } ?? .off
	}

	func setLaunchAtLogin( _ enabled: Bool ) {
		macBridge?.setLaunchAtLogin( enabled )
		refreshLaunchAtLogin()
	}

	/// Pushes the menu bar summary now and again whenever anything it reads changes, so
	/// the menu always matches the configuration window.
	private func observeStatus() {
		let ( items, connected, heading, decks ) = withObservationTracking {
			( statusItems, devices.contains { $0.isOnline && $0.deck.connected }, deckMenuHeading, deckMenuEntries )
		} onChange: { [weak self] in
			Task { @MainActor in self?.observeStatus() }
		}
		onStatusChange?( items, connected )
		onDecksChange?( heading, decks )
	}
}
