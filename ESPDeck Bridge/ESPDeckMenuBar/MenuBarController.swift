//
//  MenuBarController.swift
//  ESPDeckMenuBar
//
//  AppKit side of ESPDeck Bridge. Catalyst has no NSStatusItem, so the app loads this
//  bundle at runtime and talks to it through DeckMenuBarPlugin / DeckMenuBarHost.
//

import AppKit
import ObjectiveC
import Security
import ServiceManagement

@objc( MenuBarController )
final class MenuBarController: NSObject, DeckMenuBarPlugin, NSMenuDelegate {
	private var statusItem : NSStatusItem?
	private weak var host  : DeckMenuBarHost?
	private let menu       = NSMenu()
	private var statusLines: [String] = [ "Starting…" ]
	private var statusLevels: [Int]   = [ 0 ]
	private var connected  = false

	func install( host: DeckMenuBarHost ) {
		self.host = host
		keepRunningWithoutWindows()

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

	func activateApp() {
		NSApp.activate()
	}

	func bringWindowsToFront( excluding title: String ) {
		NSApp.activate()
		// Not by title: the configuration window's title follows the selected device.
		for window in NSApp.windows where window.isVisible && window.canBecomeKey && window.title != title {
			// An agent app's activation request can be declined, so also order the window
			// forward directly.
			window.makeKeyAndOrderFront( nil )
			window.orderFrontRegardless()
		}
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

		let login = NSMenuItem( title: "Launch at Login", action: #selector( toggleLaunchAtLogin ), keyEquivalent: "" )
		login.target = self
		login.state  = launchAtLoginState
		menu.addItem( login )

		menu.addItem( .separator() )

		let quit = NSMenuItem( title: "Quit ESPDeck Bridge", action: #selector( quit ), keyEquivalent: "q" )
		quit.target = self
		menu.addItem( quit )
	}

	/// Matches the configuration window: yellow circle while waiting, white check on
	/// green when found, white exclamation mark on red for a problem.
	private static func statusImage( level: Int ) -> NSImage? {
		let ( name, colors ): ( String, [NSColor] ) = switch level {
			case 1:  ( "checkmark.circle.fill", [ .white, .systemGreen ] )
			case 2:  ( "exclamationmark.circle.fill", [ .white, .systemRed ] )
			default: ( "circle.fill", [ .systemYellow ] )
		}
		let configuration = NSImage.SymbolConfiguration( paletteColors: colors ).applying( .init( pointSize: 12, weight: .regular ) )
		return NSImage( systemSymbolName: name, accessibilityDescription: nil )?.withSymbolConfiguration( configuration )
	}

	@objc private func openConfiguration() {
		activateApp()
		host?.menuBarOpenConfiguration()
	}

	// MARK: - Shortcuts

	nonisolated private static let shortcutsTool = "/usr/bin/shortcuts"

	// Each runs its tool in a detached task and calls back on the main thread.

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

	func startShortcut( id: String, completion: @escaping ( String? ) -> Void ) {
		Task {
			let message = await Task.detached( priority: .userInitiated ) { () -> String? in
				let result = Self.capture( Self.shortcutsTool, [ "run", id ] )
				return result.status == 0 ? nil : ( result.error.isEmpty ? "The shortcut failed." : result.error )
			}.value
			completion( message )
		}
	}

	nonisolated private static func readShortcuts() -> ( [[String]], String? ) {
		let all = capture( shortcutsTool, [ "list", "--show-identifiers" ] )
		guard all.status == 0 else {
			return ( [], all.error.isEmpty ? "The shortcuts tool failed." : all.error )
		}

		// "Name (UUID)" per line; folders come from listing each one.
		var folderByID: [String: String] = [:]
		let folders = capture( shortcutsTool, [ "list", "--folders" ] ).output.split( separator: "\n" ).map( String.init )
		for folder in folders where !folder.isEmpty {
			for entry in parseShortcuts( capture( shortcutsTool, [ "list", "--folder-name", folder, "--show-identifiers" ] ).output ) {
				folderByID[entry.id] = folder
			}
		}
		return ( parseShortcuts( all.output ).map { [ $0.id, $0.name, folderByID[$0.id] ?? "" ] }, nil )
	}

	/// Shortcuts Events hands the icon over as a TIFF; osascript writes it to a file.
	nonisolated private static func readShortcutIcon( id: String, size: Int ) -> Data? {
		let file = FileManager.default.temporaryDirectory.appendingPathComponent( "espdeck-icon-\(UUID().uuidString).tiff" )
		defer { try? FileManager.default.removeItem( at: file ) }
		let script = [
			"tell application \"Shortcuts Events\" to set theIcon to icon of shortcut id \(quoted( id ))",
			"set f to open for access POSIX file \(quoted( file.path )) with write permission",
			"set eof f to 0",
			"write theIcon to f",
			"close access f",
		]
		let result = capture( "/usr/bin/osascript", script.flatMap { [ "-e", $0 ] } )
		guard result.status == 0, let image = NSImage( contentsOf: file ) else {
			if !result.error.isEmpty { print( "[MenuBar] Shortcut icon: \(result.error)" ) }
			return nil
		}
		return png( image, size: size )
	}

	nonisolated private static func parseShortcuts( _ output: String ) -> [( id: String, name: String )] {
		output.split( separator: "\n" ).compactMap { line in
			guard line.hasSuffix( ")" ), let open = line.range( of: " (", options: .backwards ) else { return nil }
			let id = line[open.upperBound..<line.index( before: line.endIndex )]
			return ( String( id ), String( line[..<open.lowerBound] ) )
		}
	}

	/// Runs a tool and collects its output; call off the main thread.
	nonisolated private static func capture( _ tool: String, _ arguments: [String] ) -> ( status: Int32, output: String, error: String ) {
		let process = Process()
		let output  = Pipe()
		let error   = Pipe()
		process.executableURL  = URL( fileURLWithPath: tool )
		process.arguments      = arguments
		process.standardOutput = output
		process.standardError  = error
		do {
			try process.run()
		} catch {
			return ( -1, "", error.localizedDescription )
		}
		let out = output.fileHandleForReading.readDataToEndOfFile()
		let err = error.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return ( process.terminationStatus,
				 String( decoding: out, as: UTF8.self ),
				 String( decoding: err, as: UTF8.self ).trimmingCharacters( in: .whitespacesAndNewlines ) )
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

	// MARK: - App updates

	func installAppUpdate( archivePath: String ) -> String? {
		let files   = FileManager.default
		let staging = files.temporaryDirectory.appending( path: "ESPDeck Update \(UUID().uuidString)", directoryHint: .isDirectory )
		defer { try? files.removeItem( at: staging ) }

		// ditto keeps the bundle's signature, symlinks and extended attributes intact.
		guard run( "/usr/bin/ditto", [ "-x", "-k", archivePath, staging.path( percentEncoded: false ) ] ) == 0,
			  let app = ( try? files.contentsOfDirectory( at: staging, includingPropertiesForKeys: nil ) )?.first( where: { $0.pathExtension == "app" } ) else {
			return "The update couldn't be unpacked."
		}

		if let problem = verifySignature( of: app ) {
			return problem
		}

		let current = Bundle.main.bundleURL
		do {
			_ = try files.replaceItemAt( current, withItemAt: app )
		} catch {
			return "The update couldn't replace \(current.lastPathComponent): \(error.localizedDescription). Download it from the release page instead."
		}

		// Relaunch from a detached shell once this process has quit.
		let path = current.path( percentEncoded: false )
		let relaunch = Process()
		relaunch.executableURL = URL( fileURLWithPath: "/bin/sh" )
		relaunch.arguments     = [ "-c", "while kill -0 $1 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path, "\(ProcessInfo.processInfo.processIdentifier)" ]
		try? relaunch.run()
		NSApp.terminate( nil )
		return nil
	}

	/// The update must be validly signed by the same team, with the same bundle ID.
	private func verifySignature( of app: URL ) -> String? {
		guard let teamID = currentTeamID() else {
			return "This copy of ESPDeck Bridge isn't signed with a Developer ID, so it can't verify updates."
		}
		let bundleID = Bundle.main.bundleIdentifier ?? ""
		let text     = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""

		var code: SecStaticCode?
		var requirement: SecRequirement?
		guard SecStaticCodeCreateWithPath( app as CFURL, [], &code ) == errSecSuccess, let code,
			  SecRequirementCreateWithString( text as CFString, [], &requirement ) == errSecSuccess, let requirement else {
			return "The update's signature couldn't be read."
		}
		let flags = SecCSFlags( rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate )
		guard SecStaticCodeCheckValidity( code, flags, requirement ) == errSecSuccess else {
			return "The update isn't signed by the same developer as this app, so it wasn't installed."
		}
		return nil
	}

	private func currentTeamID() -> String? {
		var code: SecCode?
		var staticCode: SecStaticCode?
		var info: CFDictionary?
		guard SecCodeCopySelf( [], &code ) == errSecSuccess, let code,
			  SecCodeCopyStaticCode( code, [], &staticCode ) == errSecSuccess, let staticCode,
			  SecCodeCopySigningInformation( staticCode, SecCSFlags( rawValue: kSecCSSigningInformation ), &info ) == errSecSuccess,
			  let dictionary = info as? [String: Any] else { return nil }
		return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
	}

	private func run( _ tool: String, _ arguments: [String] ) -> Int32 {
		let process = Process()
		process.executableURL = URL( fileURLWithPath: tool )
		process.arguments     = arguments
		do {
			try process.run()
			process.waitUntilExit()
			return process.terminationStatus
		} catch {
			return -1
		}
	}

	// MARK: - Launch at Login

	/// Registered through SMAppService.mainApp, which is the Catalyst app hosting this bundle.
	private var launchAtLoginState: NSControl.StateValue {
		switch SMAppService.mainApp.status {
			case .enabled:          .on
			case .requiresApproval: .mixed
			default:                .off
		}
	}

	func menuNeedsUpdate( _ menu: NSMenu ) {
		// The user can change this in System Settings while the app runs.
		menu.items.first { $0.action == #selector( toggleLaunchAtLogin ) }?.state = launchAtLoginState
	}

	@objc private func toggleLaunchAtLogin() {
		let service = SMAppService.mainApp
		do {
			if service.status == .enabled {
				try service.unregister()
			} else {
				try service.register()
			}
		} catch {
			print( "[MenuBar] Launch at Login change failed: \(error)" )
		}

		if service.status == .requiresApproval {
			SMAppService.openSystemSettingsLoginItems()
		}
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
