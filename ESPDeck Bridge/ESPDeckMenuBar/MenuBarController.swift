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

/// The bundle's principal class: the menu bar item and its menu, and the AppKit services
/// the Catalyst app reaches through DeckMenuBarPlugin.
@objc( MenuBarController )
final class MenuBarController: NSObject, DeckMenuBarPlugin {
	private var statusItem   : NSStatusItem?
	private weak var host    : DeckMenuBarHost?
	/// The menu, as a panel of our own (MenuPanel.swift says why), and what it lists.
	private var panel        : MenuPanel?
	/// When the panel last closed: a click on the icon that closed it shouldn't reopen it.
	private var panelClosedAt = Date.distantPast
	/// The app in front when the panel opened, to hand activation back to after a row that
	/// opens no window (clicking the panel activated this app).
	private var appBeforePanel: NSRunningApplication?
	private var statusLines  : [String] = [ "Starting…" ]
	private var statusLevels : [Int]    = [ 0 ]
	private var connected    = false
	private var decks        : [( id: String, title: String, level: Int )] = []

	// USB setup; see MenuBarController+USB.swift.
	var portWatcher   : SerialPortWatcher?
	var installTask   : Task<Void, Never>?
	var improvSession : ImprovSession?
	var improvReader  : Task<String?, Never>?
	var improvTask    : Task<Void, Never>?

	/// Shortcuts running or waiting to run, by ID.
	private var runningShortcuts: Set<String> = []

	/// Keeps the app running without windows, starts DockPresence and adds the status item.
	func install( host: DeckMenuBarHost ) {
		self.host = host
		keepRunningWithoutWindows()
		DockPresence.start()

		let item = NSStatusBar.system.statusItem( withLength: NSStatusItem.squareLength )
		item.button?.target = self
		item.button?.action = #selector( togglePanel( _: ) )
		item.button?.sendAction( on: [ .leftMouseDown, .rightMouseDown ] )
		statusItem = item
		rebuild()

		// Colors dragged onto the app's windows; see ColorDropView. A window gets its view when
		// it becomes key, which the configuration window does as it opens. Not panels: this
		// bundle's menu, and the Colors panel itself.
		NotificationCenter.default.addObserver( forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main ) { [weak self] note in
			guard let window = note.object as? NSWindow, !( window is NSPanel ) else { return }
			MainActor.assumeIsolated {
				ColorDropView.install( in: window, host: self?.host )
				// The configuration window keeps its size and place between launches: AppKit
				// restores the frame saved under this name, and saves it again as it changes.
				if window.title == DeckConfigurationWindow.title, window.frameAutosaveName.isEmpty {
					window.setFrameUsingName( DeckConfigurationWindow.frameName )
					window.setFrameAutosaveName( DeckConfigurationWindow.frameName )
				}
			}
		}
	}

	/// New status lines and connected state; rebuilds the menu and icon.
	func update( statusLines: [String], levels: [Int], connected: Bool ) {
		self.statusLines  = statusLines
		self.statusLevels = levels
		self.connected    = connected
		rebuild()
	}

	/// New deck list; updates the panel.
	func updateDecks( ids: [String], titles: [String], levels: [Int] ) {
		decks = zip( ids, zip( titles, levels ) ).map { ( $0, $1.0, $1.1 ) }
		rebuild()
	}

	/// A row of the menu panel (or a notification) is opening a window: the app is active,
	/// and the window is made key when it appears.
	func activateApp() {
		DockPresence.windowWillOpen()
		DockPresence.activate()
	}

	/// Activates the app and orders its windows, except those titled `title`, to the front.
	func bringWindowsToFront( excluding title: String ) {
		DockPresence.update()   // a window that just opened makes the app regular first
		DockPresence.activate()
		// Not by title: the configuration window's title follows the selected device.
		for window in NSApp.windows where window.isVisible && window.canBecomeKey && window.title != title {
			window.makeKeyAndOrderFront( nil )
		}
	}

	/// The column-resize pointer, or the arrow again.
	func setResizeCursor( _ active: Bool ) {
		if !active {
			NSCursor.arrow.set()
		} else if #available( macOS 15, * ) {
			NSCursor.columnResize.set()
		} else {
			NSCursor.resizeLeftRight.set()
		}
	}

	/// The same for a divider between panes one above the other.
	func setRowResizeCursor( _ active: Bool ) {
		if !active {
			NSCursor.arrow.set()
		} else if #available( macOS 15, * ) {
			NSCursor.rowResize.set()
		} else {
			NSCursor.resizeUpDown.set()
		}
	}

	/// Closes every window titled `title`.
	func closeWindows( titled title: String ) {
		for window in NSApp.windows where window.title == title {
			window.close()
		}
	}

	/// Redraws the status icon, and the panel's rows if it's open.
	private func rebuild() {
		statusItem?.button?.image = Self.statusIcon( connected: connected )
		if panel?.isVisible == true {
			panel?.setEntries( entries )
		}
	}

	/// The panel's rows, as the menu had them: decks (each opening its Keys page), the status
	/// lines (opening the window, where the same status is), the commands, Quit.
	private var entries: [MenuPanelEntry] {
		var entries: [MenuPanelEntry] = [ .header( "Decks" ) ]
		if decks.isEmpty {
			entries.append( .row( icon: nil, title: "None yet", action: nil ) )
		}
		for deck in decks {
			// The app sends "Name: state" or "Name (demo)": the state goes on a second line.
			let parts = deck.title.components( separatedBy: ": " )
			let name  = parts.count > 1 ? parts.dropLast().joined( separator: ": " ) : deck.title
			let state = parts.count > 1 ? parts.last.map { $0.prefix( 1 ).uppercased() + $0.dropFirst() } : nil
			let id    = deck.id
			entries.append( .row( icon: Self.deckImage( level: deck.level ), title: name, detail: state ) { [weak self] in self?.showDeck( id: id ) } )
		}
		entries.append( .separator )
		for ( index, line ) in statusLines.enumerated() {
			let level = index < statusLevels.count ? statusLevels[index] : 0
			entries.append( .row( icon: Self.statusImage( level: level ), title: line ) { [weak self] in self?.openConfiguration() } )
		}
		entries.append( .separator )
		entries.append( .row( icon: Self.symbol( "gearshape" ), title: "Configure…" ) { [weak self] in self?.openConfiguration() } )
		entries.append( .row( icon: Self.symbol( "cable.connector" ), title: "Set Up a Device over USB…" ) { [weak self] in self?.openUSBSetup() } )
		let loginOn = SMAppService.mainApp.status == .enabled
		entries.append( .row( icon: loginOn ? Self.symbol( "checkmark" ) : nil, title: "Launch at Login" ) { [weak self] in self?.toggleLaunchAtLogin() } )
		entries.append( .separator )
		entries.append( .row( icon: Self.symbol( "power" ), title: "Quit ESPDeck Bridge" ) { [weak self] in self?.quit() } )
		return entries
	}

	/// The icon's click: opens the panel under it, or closes it if it's open.
	@objc private func togglePanel( _ sender: NSStatusBarButton ) {
		if panel?.isVisible == true {
			panel?.close()
			return
		}
		// The same click took the keyboard from the panel and closed it: leave it closed.
		guard Date().timeIntervalSince( panelClosedAt ) > 0.25 else { return }
		let panel = self.panel ?? makePanel()
		self.panel = panel
		let front = NSWorkspace.shared.frontmostApplication
		appBeforePanel = front == NSRunningApplication.current ? nil : front
		panel.setEntries( entries )
		sender.highlight( true )
		panel.show( below: sender )
	}

	/// Builds the panel, un-highlighting the icon when it closes.
	private func makePanel() -> MenuPanel {
		let panel = MenuPanel()
		panel.onClose = { [weak self] in
			self?.panelClosedAt = Date()
			self?.statusItem?.button?.highlight( false )
		}
		return panel
	}

	/// The app icon's design as a menu bar template: a Stream Deck Mini's 3 × 2 keys with the
	/// bottom-middle one lit. The lit key is filled while a deck is connected and outlined
	/// otherwise. A template, so the menu bar tints it for light, dark and selected states.
	private static func statusIcon( connected: Bool ) -> NSImage {
		let image = NSImage( size: NSSize( width: 18, height: 18 ), flipped: true ) { rect in
			let key: CGFloat = 4.6, gap: CGFloat = 1.6, line: CGFloat = 1.2
			let width  = key * 3 + gap * 2
			let height = key * 2 + gap
			let origin = CGPoint( x: rect.midX - width / 2, y: rect.midY - height / 2 )
			NSColor.black.set()
			for row in 0..<2 {
				for col in 0..<3 {
					let frame = NSRect( x: origin.x + CGFloat( col ) * ( key + gap ), y: origin.y + CGFloat( row ) * ( key + gap ), width: key, height: key )
					if row == 1 && col == 1 && connected {
						NSBezierPath( roundedRect: frame, xRadius: 1.2, yRadius: 1.2 ).fill()
					} else {
						let outline = NSBezierPath( roundedRect: frame.insetBy( dx: line / 2, dy: line / 2 ), xRadius: 0.9, yRadius: 0.9 )
						outline.lineWidth = line
						outline.stroke()
					}
				}
			}
			return true
		}
		image.isTemplate = true
		image.accessibilityDescription = connected ? "ESPDeck Bridge, connected" : "ESPDeck Bridge, no deck connected"
		return image
	}

	/// A menu-sized SF Symbol, in a color or (without one) as a template like the menu's text.
	private static func symbol( _ name: String, color: NSColor? = nil ) -> NSImage? {
		var configuration = NSImage.SymbolConfiguration( pointSize: 13, weight: .regular )
		if let color {
			configuration = configuration.applying( .init( paletteColors: [ color ] ) )
		}
		return NSImage( systemSymbolName: name, accessibilityDescription: nil )?.withSymbolConfiguration( configuration )
	}

	/// A deck: the status lines' icons (green check connected, green dot asleep, yellow dot
	/// connecting, red exclamation mark a problem, dashed circle a demo), or the sidebar's
	/// shield for a new device waiting to be paired.
	private static func deckImage( level: Int ) -> NSImage? {
		level == 4 ? symbol( "lock.shield", color: .controlAccentColor ) : statusImage( level: level )
	}

	/// A status line's icon, matching the configuration window: yellow circle while waiting,
	/// white check on green when found, green dot while asleep, white exclamation mark on red
	/// for a problem, dashed circle for a demo deck.
	private static func statusImage( level: Int ) -> NSImage? {
		let ( name, colors ): ( String, [NSColor] ) = switch level {
			case 1:  ( "checkmark.circle.fill", [ .white, .systemGreen ] )
			case 2:  ( "exclamationmark.circle.fill", [ .white, .systemRed ] )
			case 3:  ( "circle.dashed", [ .secondaryLabelColor ] )
			case 5:  ( "circle.fill", [ .systemGreen ] )   // asleep: fine, just dark
			default: ( "circle.fill", [ .systemYellow ] )
		}
		let configuration = NSImage.SymbolConfiguration( paletteColors: colors ).applying( .init( pointSize: 12, weight: .regular ) )
		return NSImage( systemSymbolName: name, accessibilityDescription: nil )?.withSymbolConfiguration( configuration )
	}

	/// "Configure…" and the status lines: the configuration window.
	private func openConfiguration() {
		activateApp()
		host?.menuBarOpenConfiguration()
	}

	/// A deck: the configuration window on that deck's Keys page.
	private func showDeck( id: String ) {
		activateApp()
		host?.menuBarShowDevice( id: id )
	}

	/// "Set Up a Device over USB…": the configuration window's USB Setup page.
	private func openUSBSetup() {
		activateApp()
		host?.menuBarOpenUSBSetup()
	}

	// MARK: - Shortcuts
	//
	// Through Shortcuts Events' Apple Events, in-process (ShortcutsEvents): nothing to
	// launch, so it works in the App Sandbox (with the scripting-targets entitlement for
	// com.apple.shortcuts.run). Callbacks come on the main thread.

	/// The user's shortcuts as [id, name, folder], or an error message.
	func loadShortcuts( completion: @escaping ( [[String]], String? ) -> Void ) {
		Task {
			switch await ShortcutsEvents.shortcuts() {
				case .success( let list ):   completion( list, nil )
				case .failure( let error ):  completion( [], error.message )
			}
		}
	}

	/// A shortcut's icon as a PNG, or nil (logged) when it can't be had.
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

	/// Whether startShortcut started this shortcut and it hasn't finished.
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

	/// startShortcut's error for a shortcut already running.
	private static let shortcutBusy = "That shortcut is still running from an earlier press."

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

	/// The panel's Launch at Login row. The click activated this app; give the app that was
	/// in front its activation back, since no window opens.
	private func toggleLaunchAtLogin() {
		setLaunchAtLogin( SMAppService.mainApp.status != .enabled )
		guard let app = appBeforePanel, !DockPresence.hasOpenWindow else { return }
		appBeforePanel = nil
		NSApp.yieldActivation( to: app )
		app.activate( from: .current, options: [] )
	}

	/// Registers or unregisters the app as a login item, opening System Settings if macOS
	/// wants approval, and tells the host.
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

	/// The panel's Quit row.
	private func quit() {
		confirmQuit()
	}

	/// Decks can't do anything while the bridge isn't running, so quitting asks first. With a
	/// window open, closing it is offered too, since that's often what was meant.
	func confirmQuit() {
		let windowOpen = DockPresence.hasOpenWindow
		let alert = NSAlert()
		alert.icon = DockPresence.appIcon
		alert.messageText     = "Quit ESPDeck Bridge?"
		alert.informativeText = "While ESPDeck Bridge isn't running, your Stream Decks can't control anything and show Connecting."
		alert.addButton( withTitle: "Quit" )
		if windowOpen {
			alert.addButton( withTitle: "Close Config Window" )
		}
		alert.addButton( withTitle: "Cancel" ).keyEquivalent = "\u{1b}"

		DockPresence.activate()
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
