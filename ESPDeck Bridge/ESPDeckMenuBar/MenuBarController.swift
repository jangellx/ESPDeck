//
//  MenuBarController.swift
//  ESPDeckMenuBar
//
//  AppKit side of ESPDeck Bridge. Catalyst has no NSStatusItem, so the app loads this
//  bundle at runtime and talks to it through DeckMenuBarPlugin / DeckMenuBarHost.
//

import AppKit
import ObjectiveC
import ServiceManagement

@objc( MenuBarController )
final class MenuBarController: NSObject, DeckMenuBarPlugin, NSMenuDelegate {
	private var statusItem : NSStatusItem?
	private weak var host  : DeckMenuBarHost?
	private let menu       = NSMenu()
	private var statusLines: [String] = [ "Starting…" ]
	private var statusLevels: [Int]   = [ 0 ]
	private var connected  = false
	private var deckHeading = "Waiting for HomeKit…"
	private var decks       : [( id: String, title: String, level: Int )] = []

	// USB setup; see MenuBarController+USB.swift.
	var portWatcher        : SerialPortWatcher?
	var installTask        : Task<Void, Never>?
	var improvSession      : ImprovSession?
	var improvReader       : Task<String?, Never>?
	var improvTask         : Task<Void, Never>?

	/// Shortcuts running or waiting to run, by ID.
	private var runningShortcuts: Set<String> = []

	func install( host: DeckMenuBarHost ) {
		self.host = host
		keepRunningWithoutWindows()
		DockPresence.start()

		let item = NSStatusBar.system.statusItem( withLength: NSStatusItem.squareLength )
		menu.delegate = self
		item.menu = menu
		statusItem = item
		rebuild()
	}

	func update( statusLines: [String], levels: [Int], connected: Bool ) {
		self.statusLines  = statusLines
		self.statusLevels = levels
		self.connected   = connected
		rebuild()
	}

	func updateDecks( heading: String, ids: [String], titles: [String], levels: [Int] ) {
		deckHeading = heading
		decks       = zip( ids, zip( titles, levels ) ).map { ( $0, $1.0, $1.1 ) }
		rebuild()
	}

	/// Called while handling the click that opens the window, and still an accessory, which
	/// WindowServer lets activate; DockPresence goes regular once the window is on screen.
	func activateApp() {
		DockPresence.windowWillOpen()
		Self.forceActivate()
	}

	func bringWindowsToFront( excluding title: String ) {
		Self.forceActivate()
		// Not by title: the configuration window's title follows the selected device.
		for window in NSApp.windows where window.isVisible && window.canBecomeKey && window.title != title {
			// An agent app's activation request can be declined, so also order the window
			// forward directly.
			window.makeKeyAndOrderFront( nil )
			window.orderFrontRegardless()
		}
	}

	/// Cooperative activation (`NSApp.activate()`) can be declined while another app is
	/// frontmost. The window then comes forward without the app becoming active, so the
	/// window isn't key and its first click is swallowed. The older call still activates an
	/// agent app outright; it's deprecated, but has no replacement that can't be declined.
	private static func forceActivate() {
		DockPresence.update()   // a window that just opened makes the app regular first
		NSApp.activate()
		NSApp.activate( ignoringOtherApps: true )
	}

	func closeWindows( titled title: String ) {
		for window in NSApp.windows where window.title == title {
			window.close()
		}
	}

	private func rebuild() {
		let symbol = connected ? "square.grid.3x2.fill" : "square.grid.3x2"
		let image  = NSImage( systemSymbolName: symbol, accessibilityDescription: "ESPDeck" )
		image?.isTemplate = true
		statusItem?.button?.image = image

		menu.removeAllItems()

		// The decks, each opening its Keys page.
		let heading = NSMenuItem( title: deckHeading, action: nil, keyEquivalent: "" )
		heading.isEnabled = false
		menu.addItem( heading )
		for deck in decks {
			let item = NSMenuItem( title: deck.title, action: #selector( showDeck( _: ) ), keyEquivalent: "" )
			item.target            = self
			item.representedObject = deck.id
			item.image             = Self.statusImage( level: deck.level )
			item.indentationLevel  = 1
			menu.addItem( item )
		}
		menu.addItem( .separator() )

		for ( index, line ) in statusLines.enumerated() {
			let item = NSMenuItem( title: line, action: nil, keyEquivalent: "" )
			item.isEnabled = false
			item.image     = Self.statusImage( level: index < statusLevels.count ? statusLevels[index] : 0 )
			menu.addItem( item )
		}
		menu.addItem( .separator() )

		let configure = NSMenuItem( title: "Configure…", action: #selector( openConfiguration ), keyEquivalent: "," )
		configure.target = self
		menu.addItem( configure )

		let usbSetup = NSMenuItem( title: "Set Up a Device over USB…", action: #selector( openUSBSetup ), keyEquivalent: "" )
		usbSetup.target = self
		menu.addItem( usbSetup )

		let login = NSMenuItem( title: "Launch at Login", action: #selector( toggleLaunchAtLogin ), keyEquivalent: "" )
		login.target = self
		login.state  = launchAtLoginMenuState
		menu.addItem( login )

		menu.addItem( .separator() )

		let quit = NSMenuItem( title: "Quit ESPDeck Bridge", action: #selector( quit ), keyEquivalent: "q" )
		quit.target = self
		menu.addItem( quit )
	}

	/// Matches the configuration window: yellow circle while waiting, white check on
	/// green when found, white exclamation mark on red for a problem, dashed circle for a
	/// demo deck.
	private static func statusImage( level: Int ) -> NSImage? {
		let ( name, colors ): ( String, [NSColor] ) = switch level {
			case 1:  ( "checkmark.circle.fill", [ .white, .systemGreen ] )
			case 2:  ( "exclamationmark.circle.fill", [ .white, .systemRed ] )
			case 3:  ( "circle.dashed", [ .secondaryLabelColor ] )
			default: ( "circle.fill", [ .systemYellow ] )
		}
		let configuration = NSImage.SymbolConfiguration( paletteColors: colors ).applying( .init( pointSize: 12, weight: .regular ) )
		return NSImage( systemSymbolName: name, accessibilityDescription: nil )?.withSymbolConfiguration( configuration )
	}

	@objc private func openConfiguration() {
		activateApp()
		host?.menuBarOpenConfiguration()
	}

	@objc private func showDeck( _ sender: NSMenuItem ) {
		guard let id = sender.representedObject as? String else { return }
		activateApp()
		host?.menuBarShowDevice( id: id )
	}

	@objc private func openUSBSetup() {
		activateApp()
		host?.menuBarOpenUSBSetup()
	}

	// MARK: - Shortcuts
	//
	// Through Shortcuts Events' Apple Events, in-process (ShortcutsEvents): nothing to
	// launch, so it works in the App Sandbox (with the scripting-targets entitlement for
	// com.apple.shortcuts.run). Callbacks come on the main thread.

	func loadShortcuts( completion: @escaping ( [[String]], String? ) -> Void ) {
		Task {
			switch await ShortcutsEvents.shortcuts() {
				case .success( let list ):   completion( list, nil )
				case .failure( let error ):  completion( [], error.message )
			}
		}
	}

	func loadShortcutIcon( id: String, size: Int, completion: @escaping ( Data? ) -> Void ) {
		Task {
			switch await ShortcutsEvents.icon( id: id, size: size ) {
				case .success( let png ):
					completion( png )
				case .failure( let error ):
					print( "[MenuBar] Shortcut icon: \(error.message)" )
					completion( nil )
			}
		}
	}

	func isShortcutRunning( id: String ) -> Bool {
		runningShortcuts.contains( id )
	}

	/// A shortcut still running (or waiting for another to finish) isn't started again: a
	/// deck key pressed repeatedly would otherwise queue up a run for every press.
	func startShortcut( id: String, input: String?, completion: @escaping ( String?, String ) -> Void ) {
		guard !runningShortcuts.contains( id ) else {
			completion( Self.shortcutBusy, "" )
			return
		}
		runningShortcuts.insert( id )
		Task {
			let result = await ShortcutsEvents.run( id: id, input: input )
			runningShortcuts.remove( id )
			switch result {
				case .success( let output ): completion( nil, output )
				case .failure( let error ):  completion( error.message, "" )
			}
		}
	}

	static let shortcutBusy = "That shortcut is still running from an earlier press."

	// MARK: - Launch at Login

	/// Registered through SMAppService.mainApp, which is the Catalyst app hosting this
	/// bundle. 0 off, 1 on, 2 waiting for approval in System Settings.
	func launchAtLoginStatus() -> Int {
		switch SMAppService.mainApp.status {
			case .enabled:          1
			case .requiresApproval: 2
			default:                0
		}
	}

	private var launchAtLoginMenuState: NSControl.StateValue {
		switch launchAtLoginStatus() {
			case 1:  .on
			case 2:  .mixed
			default: .off
		}
	}

	func menuNeedsUpdate( _ menu: NSMenu ) {
		// The user can change this in System Settings while the app runs.
		menu.items.first { $0.action == #selector( toggleLaunchAtLogin ) }?.state = launchAtLoginMenuState
	}

	@objc private func toggleLaunchAtLogin() {
		setLaunchAtLogin( SMAppService.mainApp.status != .enabled )
	}

	func setLaunchAtLogin( _ enabled: Bool ) {
		let service = SMAppService.mainApp
		do {
			if enabled {
				try service.register()
			} else {
				try service.unregister()
			}
		} catch {
			print( "[MenuBar] Launch at Login change failed: \(error)" )
		}

		if service.status == .requiresApproval {
			SMAppService.openSystemSettingsLoginItems()
		}
		host?.menuBarLaunchAtLoginChanged()
	}

	@objc private func quit() {
		confirmQuit()
	}

	/// Decks can't do anything while the bridge isn't running, so quitting asks first. With a
	/// window open, closing it is offered too, since that's often what was meant.
	func confirmQuit() {
		let windowOpen = DockPresence.hasOpenWindow
		let alert = NSAlert()
		alert.messageText     = "Quit ESPDeck Bridge?"
		alert.informativeText = "While ESPDeck Bridge isn't running, your Stream Decks can't control anything and show Connecting."
		alert.addButton( withTitle: "Quit" )
		if windowOpen {
			alert.addButton( withTitle: "Close Config Window" )
		}
		alert.addButton( withTitle: "Cancel" ).keyEquivalent = "\u{1b}"

		Self.forceActivate()
		switch alert.runModal() {
			case .alertFirstButtonReturn:
				NSApp.terminate( nil )
			case .alertSecondButtonReturn where windowOpen:
				DockPresence.closeWindows()
			default:
				break
		}
	}

	/// Catalyst quits when its last window closes. A menu bar app has to outlive its
	/// configuration window, so answer NO on the app delegate's behalf.
	private func keepRunningWithoutWindows() {
		guard let delegate = NSApp.delegate else {
			print( "[MenuBar] There's no application delegate, so closing the last window will quit." )
			return
		}

		let selector = #selector( NSApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed( _: ) )
		let block: @convention( block ) ( AnyObject, NSApplication ) -> Bool = { _, _ in false }
		// The protocol's own type encoding, since BOOL is "B" on Apple silicon and "c" on Intel.
		let described = objc_getProtocol( "NSApplicationDelegate" ).map { protocol_getMethodDescription( $0, selector, false, true ).types }
		let types     = described.flatMap { $0.map { String( cString: $0 ) } } ?? Self.boolMethodTypes
		class_replaceMethod( type( of: delegate ), selector, imp_implementationWithBlock( block ), types )
		if !delegate.responds( to: selector ) {
			print( "[MenuBar] Couldn't keep running without windows; closing the last window will quit." )
		}
	}

	/// A method returning BOOL and taking one object.
	private static var boolMethodTypes: String {
		#if arch( arm64 )
		"B@:@"
		#else
		"c@:@"
		#endif
	}
}
