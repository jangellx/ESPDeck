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

/// The app's hub: owns the settings, HomeKit and the server, and ties them to the devices.
@Observable
final class DeckController {
	let config = ConfigStore()
	let home   = HomeObserver()
	let server = DeckServer()
	@ObservationIgnored private(set) lazy var updates  = UpdateManager( controller: self )
	@ObservationIgnored private(set) lazy var usbSetup = USBSetup( controller: self )

	/// One per configured device, in the same order as `config.settings.devices`.
	private(set) var devices   : [DeckDevice] = []
	var lastError              : BridgeProblem? {
		didSet { if let lastError, lastError != oldValue { onProblem?( lastError ) } }
	}
	/// A new problem, for a notification when the window isn't in front.
	@ObservationIgnored var onProblem: ( ( BridgeProblem ) -> Void )?

	/// The key selected in the configuration window, which Copy and Paste act on.
	var focusedKey       : ( device: String, key: Int )?
	/// A copied key is on the clipboard; see DeckController+Clipboard.
	var clipboardHasKey  = false
	/// The configuration window's selection and page, shared with the menus.
	let window           = WindowState()

	/// Called whenever the menu bar summary may have changed.
	@ObservationIgnored var onStatusChange: ( ( _ items: [StatusItem], _ connected: Bool ) -> Void )?
	/// Called whenever the menu bar's deck list may have changed.
	@ObservationIgnored var onDecksChange : ( ( _ decks: [DeckMenuEntry] ) -> Void )?

	/// This Mac's password for uploads from PlatformIO, once there is one (DevOTAPassword).
	private(set) var developerPassword: String?

	/// Encrypting a device's storage: under way, or why it failed. See DeckController+Storage.
	var storageEncryption    : [String: StorageEncryption] = [:]
	/// The connection encryptStorage went to, and the wait for the device to come back.
	@ObservationIgnored var storageEncryptionRequests: [String: ( client: ClientID, timeout: Task<Void, Never> )] = [:]

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
	/// Keys ("device/key") whose HomeKit write or scene hasn't finished yet.
	@ObservationIgnored private var keysInFlight: Set<String> = []
	/// The Keys page's deck preview: where each key is in the window, for shift-click.
	@ObservationIgnored var previewKeyFrames: [Int: CGRect] = [:]
	@ObservationIgnored var previewDevice: String?
	/// A drag that would split a Level pair, for the Keys page to ask about.
	var pendingLevelMove: PendingLevelMove?
	/// Slider keys being held ("device/key"): their repeat.
	@ObservationIgnored var sliderRepeats: [String: Task<Void, Never>] = [:]
	/// The configuration window's, for Edit ▸ Undo; see DeckController+Undo.
	@ObservationIgnored weak var undoManager: UndoManager?
	@ObservationIgnored var undoCoalescing : String?
	@ObservationIgnored var undoCoalescedAt = Date.distantPast
	private static let shortcutIconSize = 160

	/// Connected devices that haven't authenticated, for the sidebar's New Devices.
	var newDevices                                : [NewDevice] = []
	@ObservationIgnored var handshakes            : [ClientID: Handshake] = [:]
	@ObservationIgnored var clientDevices         : [ClientID: String] = [:]
	/// This Mac's host name, for the deck while pairing; see bridgeName.
	@ObservationIgnored var hostName              : String?
	/// Nothing goes to the devices until HomeKit has names and values (or pushHoldLimit
	/// passes), so launch doesn't send each key twice: once half-rendered, once for real.
	@ObservationIgnored private var holdingPushes = true
	/// Last state seen by each sleep trigger, to act only on changes.
	@ObservationIgnored private var triggerStates : [UUID: KeyState] = [:]
	/// Rendered images kept per device for answering `need`, beyond those the keys show.
	private static let recentLimit     = 96
	/// The longest pushes wait for HomeKit at launch (holdingPushes).
	private static let pushHoldLimit   : Duration = .seconds( 10 )
	/// How long edits from the configuration UI settle before the images go out (deferPush).
	private static let pushDelay       : Duration = .milliseconds( 400 )
	/// The progress bar gives up after this long without a `shown`.
	private static let progressTimeout : TimeInterval = 30

	/// "device/key": how per-key state (repeats, commands in flight, runs of undo) is keyed.
	static func keyTag( device id: String, key: Int ) -> String {
		"\(id)/\(key)"
	}

	/// Wires up HomeKit, the server and the menu bar, and starts everything running.
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
		if usesShortcuts {
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
			try? await Task.sleep( for: Self.pushHoldLimit )
			self?.releasePushes()
		}

		refreshClipboard()
		NotificationCenter.default.addObserver( forName: UIPasteboard.changedNotification, object: nil, queue: .main ) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshClipboard() }
		}
	}

	/// A key, or a sleep or wake command, runs a shortcut.
	private var usesShortcuts: Bool {
		config.settings.devices.contains { settings in
			( settings.allKeys + [ settings.onSleep, settings.onWake ] ).contains { $0.kind == .shortcut }
		}
	}

	/// Closes every connection and stops watching HomeKit, before the app quits.
	func stop() async {
		server.stop()
		await home.stopWatching()
	}

	// MARK: - Lookup

	/// A configured device's live state.
	func device( _ id: String ) -> DeckDevice? {
		devices.first { $0.id == id }
	}

	/// A configured device's settings.
	func settings( _ id: String ) -> DeviceSettings? {
		config.settings.devices.first { $0.id == id }
	}

	/// The layout to render for: what the deck reports now, else what it last reported.
	func layout( _ id: String ) -> DeckLayout {
		device( id )?.deck.layout ?? settings( id )?.layout ?? .mini
	}

	/// A key of the page the device shows; an empty one if there's no such key.
	func assignment( _ id: String, key: Int ) -> KeyAssignment {
		settings( id )?.key( key ) ?? KeyAssignment()
	}

	// MARK: - Key configuration

	/// Edits a key of the page the device shows, as one undo step with the edits to the same
	/// key around it. Its Level partner follows.
	func update( device id: String, key: Int, _ change: ( inout KeyAssignment ) -> Void ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		guard key < config.settings.devices[index].keys.count else { return }   // not on this deck
		let before = config.settings.devices[index].keys[key]
		var after  = before
		change( &after )
		guard after != before else { return }
		recordUndo( device: id, "Edit Key", coalesce: Self.keyTag( device: id, key: key ) )
		config.settings.devices[index].keys[key] = after
		if before.slider != nil || after.slider != nil {
			syncSliderPartner( device: index, key: key, before: before )
		}
		assignmentsChanged( device: id, deferPush: true )
	}

	/// Imports a dropped image as a state's icon.
	func setIcon( data: Data, device id: String, key: Int, state: KeyState ) {
		guard let name = config.importIcon( data ) else {
			lastError = BridgeProblem( "Image Not Added", "That image couldn't be read." )
			return
		}
		recordUndo( device: id, "Change Icon" )
		config.setIcon( name, device: id, key: key, state: state )
		render( device: id, key: key )
	}

	/// Sets an SF Symbol as a state's icon. Also gives the opposite state (On/Off, Open/Closed,
	/// Locked/Unlocked) the matching symbol, unless it has an icon of its own that wasn't
	/// matched this way.
	func setSymbol( _ name: String, device id: String, key: Int, state: KeyState ) {
		recordUndo( device: id, "Change Icon" )
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

	/// Takes a state's own icon away, so it falls back to Default's (or the built-in one).
	func removeIcon( device id: String, key: Int, state: KeyState ) {
		recordUndo( device: id, "Remove Icon" )
		config.setIcon( nil, device: id, key: key, state: state )
		render( device: id, key: key )
	}

	/// Exchanges two keys' assignments, icons and appearance.
	func swapKeys( device id: String, _ first: Int, _ second: Int ) {
		guard first != second, let index = config.settings.deviceIndex( id ),
			  max( first, second ) < config.settings.devices[index].keys.count else { return }
		recordUndo( device: id, "Move Key" )
		config.settings.devices[index].keys.swapAt( first, second )
		Self.remapSliders( &config.settings.devices[index].keys ) { $0 == first ? second : $0 == second ? first : $0 }
		assignmentsChanged( device: id )
	}

	/// Empties a key. A Level pair's other key is cleared too, unless `keepingPartner`: then it
	/// stays as an ordinary key for the same accessory.
	func clear( device id: String, key: Int, keepingPartner: Bool = false ) {
		guard let index = config.settings.deviceIndex( id ), key < config.settings.devices[index].keys.count else { return }
		recordUndo( device: id, "Clear Key" )
		let keys = config.settings.devices[index].keys
		if let partner = keys[key].slider?.partner, Self.isPartner( partner, of: key, in: keys ) {
			if keepingPartner {
				config.settings.devices[index].keys[partner].slider = nil
			} else {
				config.settings.devices[index].keys[partner] = KeyAssignment()
			}
		}
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
	//
	// Settings mirrored in DeviceSettings change there at once; then the command goes out.

	/// Renames the device; blank names are ignored.
	func rename( device id: String, to name: String ) {
		let trimmed = name.trimmingCharacters( in: .whitespacesAndNewlines )
		guard !trimmed.isEmpty else { return }
		updateMirror( id ) { $0.name = trimmed }
		send( .setName( trimmed ), to: id )
	}

	/// The display's brightness, in percent.
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

	/// Seconds without a key press before the deck sleeps; 0 for never.
	func setSleepTimeout( device id: String, seconds: Int ) {
		updateMirror( id ) { $0.sleepTimeout = seconds }
		send( .sleepTimeout( seconds ), to: id )
	}

	/// Its name on the network, or nil for the original; the device restarts to use it.
	func setHostname( device id: String, _ hostname: String? ) {
		send( .setHostname( hostname ?? "" ), to: id )
	}

	/// Puts the deck to sleep now.
	func sleep( device id: String ) {
		send( .sleep, to: id )
	}

	/// Wakes the deck now.
	func wake( device id: String ) {
		send( .wake, to: id )
	}

	/// Enters or leaves setup mode, where the keys show the setup page's QR codes.
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
			lastError = BridgeProblem( "Uploads Not Allowed", "Uploads through PlatformIO need firmware 4.0.0 or later on the deck." )
			return
		}
		server.sendDevOTA( passwordHash: enabled ? Self.devOTAHash( developerPasswordCreatingIfNeeded() ) : nil, to: client )
	}

	/// The password's SHA-256, as devOTA carries it.
	private static func devOTAHash( _ password: String ) -> Data? {
		Data( hex: DevOTAPassword.hash( password ) )
	}

	/// This Mac's developer password, made and stored in the Keychain the first time.
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

		/// The outcome in a sentence or two, for an alert.
		var summary: String {
			let count = updated.count == 1 ? "1 device updated" : "\(updated.count) devices updated"
			var text  = updated.isEmpty && offline.isEmpty && turnedOff.isEmpty ? "No device allows uploads right now." : "\(count)."
			if !offline.isEmpty {
				let names = ListFormatter.localizedString( byJoining: offline )
				text = "\(count); \(names) \(offline.count == 1 ? "is" : "are") offline and will keep using the old password."
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

	/// Where every key's label goes; drawn here, so it works for demo and offline decks too.
	func setLabelPosition( device id: String, _ position: LabelPosition ) {
		updateMirror( id ) { $0.labelPosition = position }
		renderAll( device: id )
	}

	/// Changes a demo deck's model. Keys past the new size are kept, just not shown.
	func setDemoLayout( device id: String, _ layout: DeckLayout ) {
		guard settings( id )?.isDemo == true else { return }
		updateMirror( id ) { $0.layout = layout }
		renderAll( device: id )
	}

	/// Renames a demo deck, which has no device to tell; blank names are ignored.
	func renameDemo( device id: String, to name: String ) {
		let trimmed = name.trimmingCharacters( in: .whitespacesAndNewlines )
		guard !trimmed.isEmpty, settings( id )?.isDemo == true else { return }
		updateMirror( id ) { $0.name = trimmed }
	}

	/// Replaces a device's keys with another's, matching keys by row and column so a
	/// layout carries across deck sizes. Keys that don't fit are left out.
	/// With `page`, only that page of the source replaces the page the destination shows (the
	/// source can be the same device); without, every page is copied.
	func copyKeys( from source: String, to destination: String, page: Int? = nil ) {
		guard let from = settings( source ), let index = config.settings.deviceIndex( destination ) else { return }
		// Keys are kept by row and column (DeviceSettings.gridColumns), so pages copy as they
		// are: each deck shows the part that fits, and nothing is lost for a bigger one.
		if let page {
			guard page < from.pages.count else { return }
			recordUndo( device: destination, "Copy Page" )
			let current = config.settings.devices[index].currentPage
			config.settings.devices[index].pages[current] = from.pages[page]
		} else {
			recordUndo( device: destination, "Copy Keys" )
			config.settings.devices[index].copyPages( from: from )
		}
		stopSliders( device: destination )
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
		storageEncryption[id] = nil
		config.settings.devices.removeAll { $0.id == id }
		devices.removeAll { $0.id == id }
		config.removeUnusedIcons()
		assignmentsChanged()
	}

	/// After the settings and Keychain were replaced with another bridge (see
	/// DeckController+Transfer): forgets every connection and what it knew about the old
	/// bridge, and starts again as the new one, without relaunching.
	func restartAsReplacedBridge() {
		server.stop()   // drops every client; clientDisconnected tidies up after each
		for request in storageEncryptionRequests.values {
			request.timeout.cancel()
		}
		for handshake in handshakes.values {
			handshake.pairing?.timeout?.cancel()
		}
		for device in devices {
			device.pushTask?.cancel()
			device.clearPending()
		}
		storageEncryptionRequests = [:]
		storageEncryption         = [:]
		handshakes                = [:]
		clientDevices             = [:]
		newDevices                = []
		triggerStates             = [:]
		focusedKey                = nil

		devices           = config.settings.devices.map { DeckDevice( id: $0.id ) }
		developerPassword = DevOTAPassword.stored()
		window.selection  = devices.first?.id
		if usesShortcuts {
			reloadShortcuts()
		}
		assignmentsChanged()
		server.start( bridgeID: config.settings.bridgeID )
	}

	/// Changes a device's settings without re-rendering or undo: what the device reported, or
	/// a setting it keeps itself.
	private func updateMirror( _ id: String, _ change: ( inout DeviceSettings ) -> Void ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		change( &config.settings.devices[index] )
	}

	/// Sends a message to a device, if it's connected.
	func send( _ message: HostMessage, to id: String ) {
		guard let client = device( id )?.client else { return }
		server.send( message, to: client )
	}

	// MARK: - Watching HomeKit

	/// After keys or triggers changed: watches what they now name, and re-renders the device
	/// (or every device). `deferPush` batches edits from the configuration UI (e.g. dragging
	/// the color picker) so the ESP32 only receives the final image.
	func assignmentsChanged( device id: String? = nil, deferPush: Bool = false ) {
		var refs = Set<CharacteristicRef>()
		for settings in config.settings.devices {
			for key in settings.allKeys {
				if let ref = key.characteristicRef { refs.insert( ref ) }
				if let ref = key.alertRef { refs.insert( ref ) }
				if let ref = key.sliderRef { refs.insert( ref ) }
			}
			for trigger in settings.sleepTriggers {
				if let ref = trigger.source.characteristicRef { refs.insert( ref ) }
			}
		}
		home.watch( refs )

		if let id {
			renderAll( device: id, deferPush: deferPush )
			sendRepeatKeys( device: id )
		} else {
			renderEverything()
			for device in devices { sendRepeatKeys( device: device.id ) }
		}
	}

	/// A watched value (or its reachability) changed: re-renders the keys showing it, and runs
	/// sleep triggers.
	private func valueChanged( _ ref: CharacteristicRef ) {
		for settings in config.settings.devices {
			for ( index, key ) in settings.keys.enumerated() where key.characteristicRef == ref || key.alertRef == ref || key.sliderRef == ref {
				render( device: settings.id, key: index )
			}
		}
		evaluateTriggers( for: ref )
	}

	/// Sleeps or wakes decks whose triggers watch `ref`, when its state changed to theirs.
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
				logEvent( "Trigger: \(name) became \(current.title) → \(effect.title.lowercased()) the deck", device: settings.id )
				send( effect == .sleep ? .sleep : .wake, to: settings.id )
			}
		}
	}

	// MARK: - Rendering

	/// The state a key shows now, from HomeKit (or, for an On/Off shortcut, what it last did).
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
		let assignment  = assignment( id, key: key )
		var face        = KeyFace()
		face.labelOnTop = settings( id )?.labelPosition == .top
		face.background = assignment.backgroundColor.flatMap( Color.init( hex: ) )
		guard let kind = assignment.kind else {
			// Not bound to anything, but it can still carry an icon and a label.
			face.label = assignment.showLabel && !assignment.label.isEmpty ? assignment.label : nil
			applyCustomIcon( assignment.iconName( for: .standard ), to: &face )
			return face
		}

		let state = override ?? state( device: id, key: key )
		// The key accessory's (the first one chosen) look, as near as HomeKit lets us to Home's.
		face.symbol     = home.symbol( for: kind, accessoryID: assignment.accessoryID, serviceID: assignment.serviceID, state: state )
		face.tint       = kind.tint( for: state )
		face.doorArrow  = kind.doorArrow( for: state )
		face.shortcutID = assignment.shortcutID
		if kind == .page {
			face.symbol = pageSymbol( for: assignment )
			if assignment.action == .pageNumber {
				face.pageNumber = currentPage( device: id ) + 1
			}
		}
		if let slider = assignment.slider {
			// Up or down (right or left, side by side), whatever the kind's own symbol is.
			let horizontal = isHorizontalPair( device: id, key, slider.partner )
			face.symbol    = slider.style.symbol( raises: slider.raises, horizontal: horizontal )
			face.doorArrow = nil
			// One above the other: the labels on the edges that face each other.
			if !horizontal && slider.labelsFacing {
				face.labelOnTop = slider.partner < key
			}
		}
		applyCustomIcon( iconName( for: state, of: assignment ), to: &face )

		if assignment.showLabel {
			var label = assignment.label.isEmpty ? defaultName( for: assignment ) : assignment.label
			// A pair reads like a control: the name on the upper (or left) key, the level
			// ("60%") on the other.
			if let slider = assignment.slider, assignment.label.isEmpty, slider.partner < key {
				label = sliderLabel( for: assignment ) ?? label
			}
			if kind == .temperature, let ref = assignment.characteristicRef, let celsius = home.values[ref] as? NSNumber {
				let reading = Measurement( value: celsius.doubleValue, unit: UnitTemperature.celsius )
				label = reading.formatted( .measurement( width: .narrow, numberFormatStyle: .number.precision( .fractionLength( 0...1 ) ) ) )
			}
			face.label = label
		}

		if override == nil, let ref = assignment.characteristicRef {
			face.unreachable = !home.isReachable( ref )
		}
		face.failed = override == nil && device( id )?.failedKeys.contains( key ) == true
		return face
	}

	/// Re-renders every key of every device.
	func renderEverything() {
		for device in devices {
			renderAll( device: device.id )
		}
	}

	/// Re-renders every key of a device, sizing its key list to its layout first.
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

	/// Renders one key's image and sends it to the deck, now or after `pushDelay`.
	func render( device id: String, key: Int, deferPush: Bool = false ) {
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

	/// Sends every key once edits have paused for `pushDelay`.
	private func schedulePush( _ device: DeckDevice ) {
		device.pushTask?.cancel()
		device.pushTask = Task { [weak self, weak device] in
			try? await Task.sleep( for: Self.pushDelay )
			guard !Task.isCancelled, let self, let device else { return }
			for key in device.keys.indices {
				push( device, key: key )
			}
		}
	}

	/// Keeps a rendered image for answering `need`, up to `recentLimit` besides those shown.
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

	/// HomeKit is ready (or the wait is over): renders everything and sends it to the decks.
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

	/// Makes the ESP32 show `keys[key]`, sending the image first if it lacks it. Only when it
	/// shows something else, unless `force`.
	private func push( _ device: DeckDevice, key: Int, force: Bool = false ) {
		guard !holdingPushes else { return }
		guard let client = device.client, key < device.keys.count, let rendered = device.keys[key] else { return }
		guard layout( device.id ).format != .none else { return }
		guard force || device.shown[key] != rendered.hash else { return }

		if !device.knownHashes.contains( rendered.hash ) {
			server.sendImage( hash: rendered.hash, image: rendered.data, keys: [ key ], to: client )
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
			try? await Task.sleep( for: .seconds( Self.progressTimeout ) )
			// A second's slack for the timer.
			guard !Task.isCancelled, let device, Date().timeIntervalSince( device.lastProgress ) >= Self.progressTimeout - 1 else { return }
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

	/// A message from a device: the handshake's until the connection authenticates.
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
			case .hello, .auth, .pairResponse, .pairReveal, .pairConfirm, .pairCancel, .usbDevice:
				break

			case .firmwareStatus( let status ):
				firmwareStatus( status, device: device, client: client )

			case .storageStatus( let status ):
				storageStatus( status, device: device )

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
				if let value = status.hostname {
					updateMirror( id ) { $0.hostname = value == $0.defaultHostname ? nil : value }
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
					server.sendImage( hash: hash, image: data, keys: keys, to: client )
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
				if !device.pressed.isEmpty {
					device.chord = true
					stopSliders( device: id )
				}
				device.pressed.insert( key )
				device.suppressedPresses.remove( key )   // a fresh press
				// Slider keys act on press, and repeat while held.
				if !device.chord && assignment( id, key: key ).slider != nil {
					startSlider( device: id, key: key, repeatHere: !repeatsOnDevice( device ) )
				}

			case .keyPress( let key, let kind ):
				// A hold arrives while the key is down: ignored if another key is down too.
				if device.suppressedPresses.remove( key ) != nil || ( kind == .hold && device.chord ) { break }
				performPress( device: id, key: key, kind: kind )

			case .keyRepeat( let key ):
				// The device repeats a held Level key itself (firmware 4.1.0 and later).
				if device.pressed.contains( key ) && !device.chord && assignment( id, key: key ).slider != nil {
					stepSlider( device: id, key: key )
				}

			case .keyUp( let key ):
				// Act on release, and only for a lone press: holding two keys (the setup
				// chord) shouldn't open the garage.
				let wasPressed = device.pressed.remove( key ) != nil
				if assignment( id, key: key ).slider != nil {
					stopSlider( device: id, key: key )
				} else if device.status.presses == true {
					// The device reports what kind of press it was (keyPress); not if it was
					// part of a two-key hold.
					if !wasPressed || device.chord { device.suppressedPresses.insert( key ) }
				} else if wasPressed && !device.chord {
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
			if let value = hello.status.hostname       { settings.hostname = value == settings.defaultHostname ? nil : value }
			settings.lastSeen = Date()
		}

		guard let device = device( hello.id ) else { return }
		for entry in handshakeTraffic {
			device.record( entry )
		}
		let endpoint           = server.endpoint( of: client )
		device.client          = client
		device.lastAddress     = endpoint
		device.protocolVersion = hello.protocolVersion
		device.firmware        = hello.firmware
		device.firmwareBuild   = hello.elfSHA256
		device.ip              = hello.settings.ip ?? endpoint
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
		sendRepeatKeys( device: hello.id )
		firmwareReconnected( device )
		applyPendingRestore( device: hello.id )
		storageReconnected( device )
		updates.deviceConnected()
	}

	/// A connection closed: ends its handshake, or takes its device offline.
	private func clientDisconnected( _ client: ClientID ) {
		handshakeEnded( client )
		guard let id = clientDevices.removeValue( forKey: client ), let device = device( id ), device.client == client else { return }
		stopSliders( device: id )
		firmwareDisconnected( device )
		device.disconnected()
	}

	// MARK: - Actions

	/// A tap, double tap or hold, as the device judged it. Level keys act on keyDown and
	/// keyRepeat; their double tap can go all the way.
	func performPress( device id: String, key: Int, kind: PressKind ) {
		let assignment = assignment( id, key: key )
		if let slider = assignment.slider {
			if kind == .doubleTap && slider.doubleTapToEnd, let level = home.adjust( assignment, toEnd: true ) {
				logEvent( "Key \(key + 1) double-tapped: \(slider.level.title) \(Self.levelText( level ))", device: id )
			}
			return
		}
		switch kind {
			case .tap:
				press( device: id, key: key )
			case .doubleTap, .hold:
				if let action = assignment.press( kind ) {
					perform( action.assignment, context: "Key \(key + 1) \(kind == .hold ? "held" : "double-tapped")", device: id )
				}
		}
	}

	/// Performs a key's action; also used by the configuration UI's Test button.
	func press( device id: String, key: Int ) {
		perform( assignment( id, key: key ), context: "Key \(key + 1)", device: id, key: key )
	}

	/// Runs an assignment's action: a HomeKit write, a scene, or a shortcut.
	/// `device` is whose log records it; `key`, when it's a key press, lets an On/Off
	/// shortcut record its new state.
	func perform( _ assignment: KeyAssignment, context: String, device id: String? = nil, key: Int? = nil ) {
		// A slider key's Test Action: one step.
		if let id, let key, assignment.slider != nil {
			stepSlider( device: id, key: key )
			if let ref = assignment.sliderRef, let level = home.level( ref ) {
				logEvent( "\(context): \(assignment.slider?.level.title ?? "Level") \(Self.levelText( level ))", device: id )
			}
			return
		}
		guard let kind = assignment.kind, assignment.action != .none else { return }

		if kind == .page {
			if let id { performPage( assignment, device: id ) }
			return
		}
		if kind == .shortcut {
			runShortcut( assignment, context: context, device: id, key: key )
			return
		}

		// A key pressed again before HomeKit has finished its last command is ignored, like a
		// shortcut that's still running: the second press would otherwise decide Toggle from
		// the state before the first one landed. This lasts until HomeKit accepts the command
		// (a fraction of a second), not while a garage door moves.
		let inFlight = id.flatMap { id in key.map { Self.keyTag( device: id, key: $0 ) } }
		if let inFlight {
			guard !keysInFlight.contains( inFlight ) else {
				logEvent( "\(context): ignored; its last command hasn't finished", device: id )
				return
			}
			keysInFlight.insert( inFlight )
		}

		Task {
			defer { if let inFlight { keysInFlight.remove( inFlight ) } }
			do {
				let summary = try await home.perform( assignment )
				lastError = nil
				logEvent( "\(context): \(summary)", device: id )
			} catch {
				print( "[DeckController] \(context) failed: \(error)" )
				lastError = BridgeProblem( "HomeKit Error", "\(context): \(error.localizedDescription)" )
				if let id, let key { flagFailure( device: id, key: key ) }
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
				for page in config.settings.devices[index].pages.indices {
					for key in config.settings.devices[index].pages[page].indices {
						refresh( &config.settings.devices[index].pages[page][key] )
					}
				}
				refresh( &config.settings.devices[index].onSleep )
				refresh( &config.settings.devices[index].onWake )
			}
			renderEverything()
		}
	}

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
			lastError = BridgeProblem( "Shortcuts Unavailable", "Shortcuts can only run on the Mac." )
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
				// Shortcuts' own wording doesn't say where to look.
				let hint = message.localizedCaseInsensitiveContains( "required app is missing" )
					? " One of its actions needs an app that isn't installed on this Mac."
					: ""
				lastError = BridgeProblem( "Shortcut Error", "\(context): \(message)\(hint)",
											link: assignment.shortcutName.flatMap { BridgeProblem.openShortcut( named: $0 ) } )
				if let device, let key { flagFailure( device: device, key: key ) }
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

	/// The state an On/Off shortcut's output names, if it names one.
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
		if assignment.icons[state.rawValue] == nil, let symbol = assignment.symbol( for: .standard ) {
			return KeyAssignment.symbolPrefix + SymbolCounterpart.variant( of: symbol, for: state )
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

	/// A line of status for the menu bar and the sidebar, with its indicator.
	struct StatusItem: Hashable {
		/// The indicator; the raw values go to the menu bar plugin.
		enum Level: Int {
			case waiting = 0
			case ok      = 1
			case problem = 2
			case demo    = 3
			/// Connected but asleep: fine, just not showing anything. (4 is the menu's new device.)
			case asleep  = 5
		}

		let text  : String
		let level : Level
	}

	/// A known device that's connected but can't be authenticated (this Mac lost its key, or
	/// it's paired elsewhere): shown on its own row, not again under New Devices.
	func stuckConnection( for id: String ) -> NewDevice? {
		newDevices.first { $0.hello.id == id && !$0.reason.canPair && $0.reason != .oldFirmware }
	}

	/// New Devices, without known devices that are only stuck (stuckConnection).
	var listedNewDevices: [NewDevice] {
		let known = Set( devices.map( \.id ) )
		return newDevices.filter { !known.contains( $0.hello.id ) || stuckConnection( for: $0.hello.id )?.client != $0.client }
	}

	/// One device's state in a few words, with its indicator.
	func status( device: DeckDevice ) -> StatusItem {
		let settings = settings( device.id )
		let name     = settings?.name ?? device.id
		if settings?.isDemo == true { return StatusItem( text: "\(name): demo deck", level: .demo ) }
		if !device.isOnline, let stuck = stuckConnection( for: device.id ) {
			return StatusItem( text: "\(name): \(stuck.reason.status)", level: .problem )
		}
		guard device.isOnline else { return StatusItem( text: "\(name): offline", level: .waiting ) }
		if device.status.setupMode { return StatusItem( text: "\(name): setup mode", level: .waiting ) }
		if !device.deck.connected  { return StatusItem( text: "\(name): no Stream Deck", level: .waiting ) }
		if device.status.asleep    { return StatusItem( text: "\(name): asleep", level: .asleep ) }
		return StatusItem( text: "\(name): connected", level: .ok )
	}

	/// For a device that isn't working normally: what's wrong and how to fix it.
	func statusExplanation( device: DeckDevice ) -> String? {
		if settings( device.id )?.isDemo == true { return nil }
		if !device.isOnline, let stuck = stuckConnection( for: device.id ) {
			var text = "The deck is on the network and connected to this Mac, but can't be used. " + stuck.reason.explanation
			if let steps = stuck.reason.steps { text += "\n\n" + steps }
			// A Keychain that failed to answer (rather than having no key) may yet recover.
			if stuck.reason == .keyMissing && !PairingKeyStore.isMissing( device.id ) {
				text += "\n\nIf the Keychain was unavailable, the deck will connect by itself within a minute."
			}
			return text
		}
		guard device.isOnline else {
			return "ESPDeck Bridge can't reach this deck. Check that it has power and is on the same Wi-Fi network as this Mac.\n\nAfter a restart or a firmware update, it will take a few seconds to come back online.\n\nIf its Wi-Fi network has changed, set it up again by either plugging it into this Mac and using [USB Setup](espdeck:usb-setup), or holding its top-left and bottom-right keys for 5 seconds to show the setup QR codes."
		}
		if device.status.setupMode {
			return "The deck is in setup mode.\n\nScan the left key's QR code to join its own Wi-Fi network, then scan its right code to open the setup page.\n\nOnce setup is finished, press the Exit key or choose Exit Setup Mode on the Device page."
		}
		if !device.deck.connected {
			return "The deck is online, but no Stream Deck is connected to it.\n\nCheck the Stream Deck's USB cable and the OTG adapter, and make sure that the power supply is at least 2 A. The Log page shows what the device saw when a Stream Deck was plugged into it."
		}
		return nil
	}

	/// The server's problem, or while there are only demo decks, that it's waiting for one.
	var serverStatus: StatusItem? {
		switch server.listenerState {
			case .listening:          config.settings.devices.allSatisfy( \.isDemo ) ? StatusItem( text: "Waiting for an ESP32-S3…", level: .waiting ) : nil
			case .stopped:            StatusItem( text: "Server stopped", level: .problem )
			case .failed( let text ): StatusItem( text: "Server failed: \(text)", level: .problem )
		}
	}

	/// Whether HomeKit is available: connected, denied, without a home, or not answered yet.
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
		[ serverStatus ].compactMap { $0 } + [ homeStatus ] + updates.statusItems
	}

	/// One deck in the menu bar's deck list.
	struct DeckMenuEntry: Equatable {
		var id    : String
		var title : String
		var level : StatusItem.Level
		/// Under New Devices: not paired with this Mac yet.
		var isNew = false

		/// For the menu bar plugin: StatusItem.Level's values, and 4 for a new device.
		var menuLevel: Int { isNew ? 4 : level.rawValue }
	}

	/// Real decks in sidebar order, then new devices, then demo decks.
	var deckMenuEntries: [DeckMenuEntry] {
		let entries = devices.map { device in
			let status = status( device: device )
			let name   = settings( device.id )?.name ?? device.id
			let state  = status.text.components( separatedBy: ": " ).last ?? ""
			return DeckMenuEntry( id: device.id, title: status.level == .demo ? "\(name) (demo)" : "\(name): \(state)", level: status.level )
		}
		let new = listedNewDevices.map { device in
			DeckMenuEntry( id: SidebarItem.newDevice( device.client ), title: "\(device.hello.name): \(device.reason.status)",
						   level: device.reason.canPair ? .waiting : .problem, isNew: true )
		}
		return entries.filter { $0.level != .demo } + new + entries.filter { $0.level == .demo }
	}

	// MARK: - Launch at Login

	/// The login item's state; the raw values are the AppKit bundle's.
	enum LaunchAtLogin: Int {
		case off           = 0
		case on            = 1
		case needsApproval = 2
	}

	/// Re-reads it; the user can also change it in System Settings.
	func refreshLaunchAtLogin() {
		launchAtLogin = macBridge.flatMap { LaunchAtLogin( rawValue: $0.launchAtLoginStatus() ) } ?? .off
	}

	/// Turns Launch at Login on or off, through the AppKit bundle.
	func setLaunchAtLogin( _ enabled: Bool ) {
		macBridge?.setLaunchAtLogin( enabled )
		refreshLaunchAtLogin()
	}

	/// Pushes the menu bar summary now and again whenever anything it reads changes, so
	/// the menu always matches the configuration window.
	private func observeStatus() {
		let ( items, connected, decks ) = withObservationTracking {
			( statusItems, devices.contains { $0.isOnline && $0.deck.connected }, deckMenuEntries )
		} onChange: { [weak self] in
			Task { @MainActor in self?.observeStatus() }
		}
		onStatusChange?( items, connected )
		onDecksChange?( decks )
	}
}
