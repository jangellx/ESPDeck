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
				DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
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

	/// A window is about to open: become regular now, so activating for it works.
	static func windowWillOpen() {
		expectingWindowUntil = Date( timeIntervalSinceNow: 3 )
		update()
	}

	static func closeWindows() {
		expectingWindowUntil = .distantPast
		for window in openWindows {
			window.performClose( nil )
		}
	}

	/// Regular while a window is open (minimized counts) or about to open, an accessory otherwise.
	static func update() {
		let open = hasOpenWindow || Date() < expectingWindowUntil
		let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
		if NSApp.activationPolicy() != policy {
			NSApp.setActivationPolicy( policy )
		}
	}
}
