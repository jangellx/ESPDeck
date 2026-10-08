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

	/// The user picked "Set Up a Device over USB…": the configuration window's USB Setup page.
	func menuBarOpenUSBSetup()

	/// The user picked a deck: the configuration window with that deck's Keys page.
	func menuBarShowDevice( id: String )

	/// Launch at Login changed from the menu; the app's own controls follow.
	func menuBarLaunchAtLoginChanged()
}

/// Implemented by the menu bar bundle's principal class.
@objc( DeckMenuBarPlugin )
public protocol DeckMenuBarPlugin: NSObjectProtocol {
	/// Creates the status item. Called once, after the app finishes launching.
	func install( host: DeckMenuBarHost )

	/// The column-resize pointer (over the Keys page's divider), or the arrow again. SwiftUI's
	/// pointer styles aren't available to Catalyst.
	func setResizeCursor( _ active: Bool )

	/// Replaces the informational lines at the top of the menu and the icon's connected state.
	/// `levels` has one entry per line: 0 waiting (yellow), 1 OK (green check), 2 problem (red).
	func update( statusLines: [String], levels: [Int], connected: Bool )

	/// The decks at the top of the menu. `levels` as in update(statusLines:); 3 is a demo
	/// deck, 4 a new device waiting to be paired.
	func updateDecks( ids: [String], titles: [String], levels: [Int] )

	/// Launch at Login (SMAppService.mainApp, which Catalyst can't reach): 0 off, 1 on,
	/// 2 waiting for approval in System Settings.
	func launchAtLoginStatus() -> Int
	/// Turns it on or off, opening System Settings if macOS wants approval.
	func setLaunchAtLogin( _ enabled: Bool )

	/// A color dragged from the Colors panel or a color well, as sRGB red, green and blue
	/// (0 … 1): from `archived`, the drag's com.apple.cocoa.pasteboard.color data (an archived
	/// NSColor, which Catalyst can't read), or from the drag pasteboard when that's nil. nil if
	/// there's no color in it.
	func draggedColor( archived: Data? ) -> [Double]?

	/// The configuration window is about to open: activates the app, and makes the window key
	/// when it appears (Catalyst doesn't for an LSUIElement app).
	func activateApp()

	/// Asks whether to quit (or, with a window open, whether to close it instead), then does it.
	func confirmQuit()

	/// Activates the app and orders its visible windows, except any titled `excluding`
	/// (the splash screen), in front of other apps' windows.
	func bringWindowsToFront( excluding title: String )

	/// Closes every window with this title. Catalyst doesn't reliably close a scene's
	/// window when its session is destroyed during launch.
	func closeWindows( titled title: String )

	// MARK: Shortcuts
	//
	// All asynchronous: they send Apple Events to Shortcuts Events on queues of their own
	// and call back on the main thread, so a slow Shortcuts never stalls the app (and with
	// it the WebSocket heartbeat). Lookups don't wait for running shortcuts; shortcuts run
	// one at a time.

	/// The user's shortcuts as [id, name, folder] triples (folder "" when not in one), or an
	/// error message.
	func loadShortcuts( completion: @escaping ( [[String]], String? ) -> Void )

	/// The shortcut's icon as a PNG no larger than `size` pixels square, or nil.
	func loadShortcutIcon( id: String, size: Int, completion: @escaping ( Data? ) -> Void )

	/// Runs a shortcut, with `input` as its text input if given. The completion gets nil and
	/// the shortcut's output as text ("" for none) when it finished, or an error message.
	/// While the same shortcut is still running or waiting to run, it isn't started again:
	/// the completion gets an error at once.
	func startShortcut( id: String, input: String?, completion: @escaping ( _ error: String?, _ output: String ) -> Void )

	/// The shortcut was started and hasn't finished, so a key press for it can be ignored.
	func isShortcutRunning( id: String ) -> Bool

	// MARK: USB setup
	//
	// For setting up a board plugged into the Mac: its serial ports, installing firmware
	// through the ESP32-S3's ROM bootloader, and Improv Wi-Fi. The serial work runs in the
	// background; callbacks come on the main thread.

	/// Calls `changed` with every serial port now, and again whenever one comes or goes.
	/// Each is [path, product, vendor, vendor ID, product ID, USB location, serial number],
	/// with "" for what isn't known.
	func watchSerialPorts( changed: @escaping ( [[String]] ) -> Void )
	func stopWatchingSerialPorts()

	/// Writes `images[i]` at flash offset `offsets[i]` on the ESP32-S3 at `port` (erasing
	/// only what they cover), checks them, and restarts the board. First, in the
	/// bootloader, it refuses a board with less flash than `minimumFlashSize` bytes or
	/// without the PSRAM ESPDeck needs; `identified` gets what it found, like "ESP32-S3,
	/// 16 MB flash, 8 MB PSRAM". `progress` gets a stage and the fraction done.
	/// `completion` gets an error message or nil, and the port the board is on now:
	/// restarting into its bootloader can give it a new one.
	func installFirmware( port: String, offsets: [Int], images: [Data], minimumFlashSize: Int, identified: @escaping ( String ) -> Void,
						  progress: @escaping ( String, Double ) -> Void, completion: @escaping ( _ error: String?, _ port: String ) -> Void )
	func cancelFirmwareInstall()

	/// Opens `port` for Improv Wi-Fi. `received` gets each packet: its type, then the
	/// state or error code, or for an RPC result the command and its strings. `log` gets
	/// the device's log lines. `stopped` gets an error message, or nil after stopImprov().
	func startImprov( port: String, received: @escaping ( _ type: Int, _ value: Int, _ strings: [String] ) -> Void,
					  log: @escaping ( String ) -> Void, stopped: @escaping ( String? ) -> Void )
	/// Sends an RPC command with its data; returns an error message.
	func sendImprov( command: Int, data: Data ) -> String?
	func stopImprov()
}
