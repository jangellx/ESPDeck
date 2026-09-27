//
//  DeckMenuBarProtocols.swift
//  ESPDeck Bridge
//
//  Compiled into both the Catalyst app and the AppKit menu bar bundle. The explicit
//  Objective-C names make both copies resolve to the same runtime protocols, so the
//  app can cast the bundle's principal class to DeckMenuBarPlugin.
//

import Foundation

/// Implemented by the Catalyst app; called by the menu bar bundle.
@objc( DeckMenuBarHost )
public protocol DeckMenuBarHost: NSObjectProtocol {
	/// The user picked "Configure…" from the menu.
	func menuBarOpenConfiguration()
}

/// Implemented by the menu bar bundle's principal class.
@objc( DeckMenuBarPlugin )
public protocol DeckMenuBarPlugin: NSObjectProtocol {
	/// Creates the status item. Called once, after the app finishes launching.
	func install( host: DeckMenuBarHost )

	/// Replaces the informational lines at the top of the menu and the icon's connected state.
	/// `levels` has one entry per line: 0 waiting (yellow), 1 OK (green check), 2 problem (red).
	func update( statusLines: [String], levels: [Int], connected: Bool )

	/// Brings the app to the front; Catalyst can't do this for an LSUIElement app on its own.
	func activateApp()

	/// Activates the app and orders its visible windows, except any titled `excluding`
	/// (the splash screen), in front of other apps' windows.
	func bringWindowsToFront( excluding title: String )

	/// Closes every window with this title. Catalyst doesn't reliably close a scene's
	/// window when its session is destroyed during launch.
	func closeWindows( titled title: String )

	// MARK: Shortcuts
	//
	// All asynchronous: they run the `shortcuts` command-line tool (or osascript, for icons)
	// in the background and call back on the main thread, so a slow Shortcuts never stalls
	// the app (and with it the WebSocket heartbeat).

	/// The user's shortcuts as [id, name, folder] triples (folder "" when not in one), or an
	/// error message.
	func loadShortcuts( completion: @escaping ( [[String]], String? ) -> Void )

	/// The shortcut's icon as a PNG no larger than `size` pixels square, or nil.
	func loadShortcutIcon( id: String, size: Int, completion: @escaping ( Data? ) -> Void )

	/// Runs a shortcut, with `input` as its text input if given. The completion gets nil and
	/// the shortcut's output as text ("" for none) when it finished, or an error message.
	func startShortcut( id: String, input: String?, completion: @escaping ( _ error: String?, _ output: String ) -> Void )

	// MARK: Updates

	/// Installs a downloaded app update (a zip holding the .app): checks that it's signed
	/// by the same team with the same bundle ID, replaces this app, and relaunches.
	/// Returns an error message; on success the app quits instead of returning.
	func installAppUpdate( archivePath: String ) -> String?
}
