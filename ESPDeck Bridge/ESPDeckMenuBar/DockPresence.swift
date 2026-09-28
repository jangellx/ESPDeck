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
		observers = names.map { name in
			NotificationCenter.default.addObserver( forName: name, object: nil, queue: .main ) { _ in
				// After the change settles: a closing window is still listed as visible here.
				DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
			}
		}
		update()
	}

	/// Regular while a window is open (minimized counts), an accessory otherwise.
	static func update() {
		let open = NSApp.windows.contains { window in
			( window.isVisible || window.isMiniaturized ) && window.canBecomeMain && !( window is NSPanel ) && window.title != splashTitle
		}
		let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
		if NSApp.activationPolicy() != policy {
			NSApp.setActivationPolicy( policy )
		}
	}
}
