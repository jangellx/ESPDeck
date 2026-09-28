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

	func activateApp() {
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
	// Through Shortcuts Events' Apple Events, in-process: nothing to launch, so it works in
	// the App Sandbox (with the scripting-targets entitlement for com.apple.shortcuts.run).
	// Each script runs in a detached task, one at a time, and calls back on the main thread.

	func loadShortcuts( completion: @escaping ( [[String]], String? ) -> Void ) {
		Task {
			let ( list, message ) = await Task.detached( priority: .userInitiated ) { Self.readShortcuts() }.value
			completion( list, message )
		}
	}

	func loadShortcutIcon( id: String, size: Int, completion: @escaping ( Data? ) -> Void ) {
		Task {
			let png = await Task.detached( priority: .userInitiated ) { Self.readShortcutIcon( id: id, size: size ) }.value
			completion( png )
		}
	}

	func startShortcut( id: String, input: String?, completion: @escaping ( String?, String ) -> Void ) {
		Task {
			let ( message, output ) = await Task.detached( priority: .userInitiated ) { Self.runShortcut( id: id, input: input ) }.value
			completion( message, output )
		}
	}

	/// The shortcut's output as text: a list's items on separate lines, nothing for none.
	nonisolated private static func runShortcut( id: String, input: String? ) -> ( String?, String ) {
		let with = input.map { " with input \(quoted( $0 ))" } ?? ""
		// A shortcut can take a while; AppleScript's default is 2 minutes.
		let script = """
			with timeout of 3600 seconds
				tell application "Shortcuts Events" to run shortcut id \(quoted( id ))\(with)
			end timeout
			"""
		switch execute( script ) {
			case .success( let result ): return ( nil, text( result ).trimmingCharacters( in: .whitespacesAndNewlines ) )
			case .failure( let error ):  return ( error.message, "" )
		}
	}

	/// [id, name, folder] for each shortcut, folder "" when it isn't in one.
	nonisolated private static func readShortcuts() -> ( [[String]], String? ) {
		let script = """
			tell application "Shortcuts Events"
				set folderList to {}
				repeat with theFolder in folders
					set end of folderList to {name of theFolder, id of every shortcut of theFolder}
				end repeat
				return {id of every shortcut, name of every shortcut, folderList}
			end tell
			"""
		let result: NSAppleEventDescriptor
		switch execute( script ) {
			case .success( let value ): result = value
			case .failure( let error ): return ( [], error.message )
		}
		guard result.numberOfItems == 3 else { return ( [], "Shortcuts Events answered in an unexpected way." ) }

		var folderByID: [String: String] = [:]
		for folder in items( result.atIndex( 3 ) ) where folder.numberOfItems == 2 {
			let name = folder.atIndex( 1 )?.stringValue ?? ""
			for id in items( folder.atIndex( 2 ) ).compactMap( \.stringValue ) {
				folderByID[id] = name
			}
		}
		let ids   = items( result.atIndex( 1 ) ).map { $0.stringValue ?? "" }
		let names = items( result.atIndex( 2 ) ).map { $0.stringValue ?? "" }
		return ( zip( ids, names ).map { [ $0, $1, folderByID[$0] ?? "" ] }, nil )
	}

	/// The icon property is TIFF data.
	nonisolated private static func readShortcutIcon( id: String, size: Int ) -> Data? {
		switch execute( "tell application \"Shortcuts Events\" to return icon of shortcut id \(quoted( id ))" ) {
			case .success( let result ):
				guard let image = NSImage( data: result.data ) else { return nil }
				return png( image, size: size )
			case .failure( let error ):
				print( "[MenuBar] Shortcut icon: \(error.message)" )
				return nil
		}
	}

	private struct ScriptError: Error {
		let message: String
	}

	/// NSAppleScript isn't safe to use from several threads at once.
	nonisolated private static let scriptLock = NSLock()

	nonisolated private static func execute( _ source: String ) -> Result<NSAppleEventDescriptor, ScriptError> {
		scriptLock.lock()
		defer { scriptLock.unlock() }
		guard let script = NSAppleScript( source: source ) else { return .failure( ScriptError( message: "The script couldn't be built." ) ) }
		var info: NSDictionary?
		let result = script.executeAndReturnError( &info )
		guard let info else { return .success( result ) }

		let number = info[NSAppleScript.errorNumber] as? Int ?? 0
		if number == -1743 {
			return .failure( ScriptError( message: "ESPDeck Bridge isn't allowed to use Shortcuts. Turn it on in System Settings → Privacy & Security → Automation." ) )
		}
		return .failure( ScriptError( message: info[NSAppleScript.errorMessage] as? String ?? "Shortcuts Events reported error \(number)." ) )
	}

	nonisolated private static func items( _ list: NSAppleEventDescriptor? ) -> [NSAppleEventDescriptor] {
		guard let list, list.numberOfItems > 0 else { return [] }
		return ( 1...list.numberOfItems ).compactMap { list.atIndex( $0 ) }
	}

	/// Text, a list of texts (one per line), or nothing.
	nonisolated private static func text( _ result: NSAppleEventDescriptor ) -> String {
		if result.descriptorType == typeAEList {
			return items( result ).map( text ).joined( separator: "\n" )
		}
		return result.stringValue ?? ""
	}

	nonisolated private static func png( _ image: NSImage, size: Int ) -> Data? {
		guard let bitmap = NSBitmapImageRep( bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
											 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0 ) else { return nil }
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext( bitmapImageRep: bitmap )
		NSGraphicsContext.current?.imageInterpolation = .high
		image.draw( in: NSRect( x: 0, y: 0, width: size, height: size ) )
		NSGraphicsContext.restoreGraphicsState()
		return bitmap.representation( using: .png, properties: [:] )
	}

	nonisolated private static func quoted( _ text: String ) -> String {
		"\"" + text.replacingOccurrences( of: "\\", with: "\\\\" ).replacingOccurrences( of: "\"", with: "\\\"" ) + "\""
	}

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
		NSApp.terminate( nil )
	}

	/// Catalyst quits when its last window closes. A menu bar app has to outlive its
	/// configuration window, so answer NO on the app delegate's behalf.
	private func keepRunningWithoutWindows() {
		guard let delegate = NSApp.delegate else { return }

		let selector = #selector( NSApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed( _: ) )
		let block: @convention( block ) ( AnyObject, NSApplication ) -> Bool = { _, _ in false }
		class_replaceMethod( type( of: delegate ), selector, imp_implementationWithBlock( block ), "c@:@" )
	}
}
