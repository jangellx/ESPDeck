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
final class MenuBarController: NSObject, DeckMenuBarPlugin, NSMenuDelegate {
	private var statusItem   : NSStatusItem?
	private weak var host    : DeckMenuBarHost?
	private let menu         = NSMenu()
	private var statusLines  : [String] = [ "Starting…" ]
	private var statusLevels : [Int]    = [ 0 ]
	private var connected    = false
	private var decks        : [( id: String, title: String, level: Int )] = []

	/// The app that was frontmost when the menu opened, and whether a menu item then opened
	/// a window; see menuWillOpen(_:).
	private var appBeforeMenu   : NSRunningApplication?
	private var menuOpensWindow = false

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
		menu.delegate = self
		item.menu = menu
		statusItem = item
		rebuild()
	}

	/// New status lines and connected state; rebuilds the menu and icon.
	func update( statusLines: [String], levels: [Int], connected: Bool ) {
		self.statusLines  = statusLines
		self.statusLevels = levels
		self.connected    = connected
		rebuild()
	}

	/// New deck list; rebuilds the menu.
	func updateDecks( ids: [String], titles: [String], levels: [Int] ) {
		decks = zip( ids, zip( titles, levels ) ).map { ( $0, $1.0, $1.1 ) }
		rebuild()
	}

	/// Called while handling the click that opens the window, and still an accessory, which
	/// WindowServer lets activate; DockPresence goes regular once the window is on screen.
	func activateApp() {
		menuOpensWindow = true
		DockPresence.windowWillOpen()
		Self.forceActivate()
	}

	/// Activates the app and orders its windows, except those titled `title`, to the front.
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
		DockPresence.forceActivate()
		DockPresence.logState( "activate requested" )
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

	/// Closes every window titled `title`.
	func closeWindows( titled title: String ) {
		for window in NSApp.windows where window.title == title {
			window.close()
		}
	}

	/// Redraws the status icon and rebuilds the whole menu from the current state.
	private func rebuild() {
		statusItem?.button?.image = Self.statusIcon( connected: connected )

		menu.removeAllItems()

		// The decks, each opening its Keys page. (HomeKit's state is with the status lines;
		// there can be several Homes, so no one Home heads the list.)
		menu.addItem( .sectionHeader( title: "Decks" ) )
		if decks.isEmpty {
			let none = NSMenuItem( title: "None yet", action: nil, keyEquivalent: "" )
			none.isEnabled = false
			menu.addItem( none )
		}
		for deck in decks {
			// The app sends "Name: state" or "Name (demo)": the state goes on a second line.
			let parts = deck.title.components( separatedBy: ": " )
			let name  = parts.count > 1 ? parts.dropLast().joined( separator: ": " ) : deck.title
			let state = parts.count > 1 ? parts.last.map { $0.prefix( 1 ).uppercased() + $0.dropFirst() } : nil
			let item  = actionItem( deck.title, #selector( showDeck( _: ) ) )
			item.representedObject = deck.id
			item.attributedTitle   = Self.title( name, icon: Self.deckImage( level: deck.level ), detail: state )
			menu.addItem( item )
		}
		menu.addItem( .separator() )

		for ( index, line ) in statusLines.enumerated() {
			// Enabled, so it isn't drawn dimmed (macOS 27 dims a disabled item whatever its
			// colors); choosing it opens the configuration window, where the same status is.
			let item = actionItem( line, #selector( openConfiguration ) )
			item.attributedTitle = Self.title( line, icon: Self.statusImage( level: index < statusLevels.count ? statusLevels[index] : 0 ) )
			menu.addItem( item )
		}
		menu.addItem( .separator() )

		menu.addItem( actionItem( "Configure…", #selector( openConfiguration ), key: ",", symbol: "gearshape" ) )
		menu.addItem( actionItem( "Set Up a Device over USB…", #selector( openUSBSetup ), symbol: "cable.connector" ) )
		let login = actionItem( "Launch at Login", #selector( toggleLaunchAtLogin ) )
		login.state = launchAtLoginMenuState
		menu.addItem( login )

		menu.addItem( .separator() )

		menu.addItem( actionItem( "Quit ESPDeck Bridge", #selector( quit ), key: "q", symbol: "power" ) )
	}

	/// A menu item that sends `action` to this controller, with an SF Symbol if named.
	private func actionItem( _ title: String, _ action: Selector, key: String = "", symbol name: String? = nil ) -> NSMenuItem {
		let item = NSMenuItem( title: title, action: action, keyEquivalent: key )
		item.target = self
		if let name {
			item.image = Self.symbol( name )
		}
		return item
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

	/// A title with its icon in front, and optionally a smaller second line (like a
	/// subtitle, which would start under the icon) lined up with the text. macOS 27 gives a
	/// menu item's own image no room unless the item also shows a state (a checkmark), but an
	/// attachment in the title gets its space. The icon sits in a fixed-width box so the
	/// titles line up.
	private static func title( _ text: String, icon: NSImage?, detail: String? = nil ) -> NSAttributedString {
		let font  = NSFont.menuFont( ofSize: 0 )
		let title = NSMutableAttributedString()
		var indent: CGFloat = 0
		if let icon {
			let side: CGFloat = 16
			let box = NSImage( size: NSSize( width: side, height: side ), flipped: false ) { rect in
				let size = icon.size
				icon.draw( in: NSRect( x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height ) )
				return true
			}
			let attachment = NSTextAttachment()
			attachment.image  = box
			attachment.bounds = NSRect( x: 0, y: ( font.capHeight - side ) / 2, width: side, height: side )
			title.append( NSAttributedString( attachment: attachment ) )
			title.append( NSAttributedString( string: " " ) )
			indent = side + NSAttributedString( string: " ", attributes: [ .font: font ] ).size().width
		}
		title.append( NSAttributedString( string: text ) )
		title.addAttribute( .font, value: font, range: NSRange( location: 0, length: title.length ) )

		if let detail {
			let paragraph = NSMutableParagraphStyle()
			paragraph.headIndent          = indent   // the second line starts where the text does
			paragraph.firstLineHeadIndent = 0
			title.append( NSAttributedString( string: "\n" + detail, attributes: [
				.font:            NSFont.menuFont( ofSize: NSFont.smallSystemFontSize ),
				.foregroundColor: NSColor.secondaryLabelColor,
			] ) )
			title.addAttribute( .paragraphStyle, value: paragraph, range: NSRange( location: 0, length: title.length ) )
		}
		return title
	}

	/// A menu-sized SF Symbol, in a color or (without one) as a template like the menu's text.
	private static func symbol( _ name: String, color: NSColor? = nil ) -> NSImage? {
		var configuration = NSImage.SymbolConfiguration( pointSize: 13, weight: .regular )
		if let color {
			configuration = configuration.applying( .init( paletteColors: [ color ] ) )
		}
		return NSImage( systemSymbolName: name, accessibilityDescription: nil )?.withSymbolConfiguration( configuration )
	}

	/// A deck: the status lines' icons (green check connected, yellow dot connecting or
	/// asleep, red exclamation mark a problem, dashed circle a demo), or the sidebar's
	/// shield for a new device waiting to be paired.
	private static func deckImage( level: Int ) -> NSImage? {
		level == 4 ? symbol( "lock.shield", color: .controlAccentColor ) : statusImage( level: level )
	}

	/// A status line's icon, matching the configuration window: yellow circle while waiting,
	/// white check on green when found, white exclamation mark on red for a problem, dashed
	/// circle for a demo deck.
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

	/// "Configure…" and the status lines: the configuration window.
	@objc private func openConfiguration() {
		activateApp()
		host?.menuBarOpenConfiguration()
	}

	/// A deck: the configuration window on that deck's Keys page.
	@objc private func showDeck( _ sender: NSMenuItem ) {
		guard let id = sender.representedObject as? String else { return }
		activateApp()
		host?.menuBarShowDevice( id: id )
	}

	/// "Set Up a Device over USB…": the configuration window's USB Setup page.
	@objc private func openUSBSetup() {
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

	/// launchAtLoginStatus() as the menu item's checkmark, a dash while awaiting approval.
	private var launchAtLoginMenuState: NSControl.StateValue {
		switch launchAtLoginStatus() {
			case 1:  .on
			case 2:  .mixed
			default: .off
		}
	}

	/// Activates the app while the click that opened the menu is the latest input. macOS 27
	/// runs the menu outside the app, so choosing an item delivers no event of its own, and an
	/// activation asked for then carries the opening click's time; WindowServer refuses it as
	/// expired ("earlier than the time of the last activation"). If no item opens a window,
	/// menuDidClose(_:) hands activation back.
	func menuWillOpen( _ menu: NSMenu ) {
		menuOpensWindow = false
		let front = NSWorkspace.shared.frontmostApplication
		appBeforeMenu = front == NSRunningApplication.current ? nil : front
		NSApp.activate()
		DockPresence.logState( "menu opened" )
	}

	/// Gives activation back to the app that was in front, unless an item opened a window.
	func menuDidClose( _ menu: NSMenu ) {
		// The chosen item's action runs after this.
		DispatchQueue.main.async { [self] in
			guard !menuOpensWindow, let app = appBeforeMenu else { return }
			appBeforeMenu = nil
			NSApp.yieldActivation( to: app )
			app.activate( from: .current, options: [] )
			DockPresence.logState( "menu closed; gave activation back to \(app.localizedName ?? "?")" )
		}
	}

	/// Refreshes Launch at Login's checkmark.
	func menuNeedsUpdate( _ menu: NSMenu ) {
		// The user can change this in System Settings while the app runs.
		menu.items.first { $0.action == #selector( toggleLaunchAtLogin ) }?.state = launchAtLoginMenuState
	}

	/// The Launch at Login menu item.
	@objc private func toggleLaunchAtLogin() {
		setLaunchAtLogin( SMAppService.mainApp.status != .enabled )
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

	/// The Quit menu item.
	@objc private func quit() {
		menuOpensWindow = true   // the alert
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
