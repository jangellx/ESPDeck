//
//  DockPresence.swift
//  ESPDeckMenuBar
//
//  Shows the app in the Dock (and the app switcher) while one of its windows is open, and
//  hides it again when the last one closes. The app is a menu bar app (LSUIElement), but
//  macOS treats an accessory app's windows as second-class: activation requests can be
//  declined and the first click on a window can be swallowed. A regular app avoids that.
//

import AppKit

@MainActor
enum DockPresence {
	/// SceneDelegate.splashTitle: the launch splash doesn't count as an open window.
	private static let splashTitle = "ESPDeck Bridge Starting"

	private static var observers: [NSObjectProtocol] = []
	/// Until then, stay regular without a window: one has been asked for and is on its way.
	private static var expectingWindowUntil = Date.distantPast

	static func start() {
		guard observers.isEmpty else { return }
		let names: [Notification.Name] = [
			NSWindow.didBecomeKeyNotification,
			NSWindow.didBecomeMainNotification,
			NSWindow.didChangeOcclusionStateNotification,
			NSWindow.didMiniaturizeNotification,
			NSWindow.didDeminiaturizeNotification,
			NSWindow.willCloseNotification,
		]
		// Switched to regular at run time, an LSUIElement app can show the generic icon in the
		// Dock; give it the bundle's icon explicitly.
		NSApp.applicationIconImage = NSWorkspace.shared.icon( forFile: Bundle.main.bundlePath )

		observers = names.map { name in
			NotificationCenter.default.addObserver( forName: name, object: nil, queue: .main ) { _ in
				// After the change settles: a closing window is still listed as visible here.
				DispatchQueue.main.async {
					MainActor.assumeIsolated {
						update()
						focusExpectedWindow()
					}
				}
			}
		}
		update()
	}

	/// The windows that count: visible or minimized, and not the splash, panels or menus.
	private static var openWindows: [NSWindow] {
		NSApp.windows.filter { window in
			( window.isVisible || window.isMiniaturized ) && window.canBecomeMain && !( window is NSPanel ) && window.title != splashTitle
		}
	}

	static var hasOpenWindow: Bool { !openWindows.isEmpty }

	/// A window is about to open. Stay an accessory until it's on screen: WindowServer denies
	/// activation to a regular app that has no windows ("presents 0 windows… Denying the
	/// request"), and that would be the one request that carries the click's permission.
	static func windowWillOpen() {
		expectingWindowUntil = Date( timeIntervalSinceNow: 5 )
	}

	/// UIKit builds the window asynchronously, sometimes well after the click that asked for
	/// it, and orders it in without making it key. So when the expected window shows up, make
	/// it key and activate for it, once.
	private static func focusExpectedWindow() {
		guard Date() < expectingWindowUntil, let window = openWindows.first( where: \.isVisible ) else { return }
		expectingWindowUntil = .distantPast
		update()   // regular now that a window is on screen
		NSApp.activate()
		NSApp.activate( ignoringOtherApps: true )
		window.makeKeyAndOrderFront( nil )
	}

	static func closeWindows() {
		expectingWindowUntil = .distantPast
		for window in openWindows {
			window.performClose( nil )
		}
	}

	/// Regular while a window is open (minimized counts), an accessory otherwise.
	static func update() {
		let policy: NSApplication.ActivationPolicy = hasOpenWindow ? .regular : .accessory
		if NSApp.activationPolicy() != policy {
			NSApp.setActivationPolicy( policy )
		}
	}
}
