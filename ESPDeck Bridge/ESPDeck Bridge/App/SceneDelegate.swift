//
//  SceneDelegate.swift
//  ESPDeck Bridge
//

import SwiftUI

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
	static let splashTitle = "ESPDeck Bridge Starting"
	static let windowTitle = "ESPDeck Bridge"

	private static let splashDuration: Duration = .seconds( 2 )

	var window: UIWindow?

	private static var isMenuBarApp: Bool {
		#if targetEnvironment( macCatalyst )
		true
		#else
		false
		#endif
	}

	func scene( _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions ) {
		guard let windowScene = scene as? UIWindowScene else { return }
		let app = AppDelegate.shared

		let window = UIWindow( windowScene: windowScene )
		// On iPad every window is the configuration window: iPadOS disconnects and
		// reconnects scenes on its own, and the app has no menu bar to reopen one from.
		// With no decks set up yet (first launch, say), the launch window is the configuration
		// window rather than a splash: there's nothing to do but set one up.
		let noDecks = app.controller.config.settings.devices.allSatisfy( \.isDemo )
		if app.consumeConfigurationRequest() || !Self.isMenuBarApp || noDecks {
			windowScene.title = Self.windowTitle
			windowScene.sizeRestrictions?.minimumSize = CGSize( width: 1040, height: 640 )
			window.rootViewController = ConfigurationHostingController( controller: app.controller )
		} else {
			// UIKit opens a window at launch whether we want one or not. Use it as a splash
			// screen, then close it; the app lives in the menu bar.
			let size = CGSize( width: 420, height: 280 )
			windowScene.title = Self.splashTitle
			windowScene.sizeRestrictions?.minimumSize = size
			windowScene.sizeRestrictions?.maximumSize = size
			#if targetEnvironment( macCatalyst )
			windowScene.titlebar?.titleVisibility = .hidden
			#endif
			window.rootViewController = UIHostingController( rootView: SplashView() )
			app.splashSessions.insert( session.persistentIdentifier )

			Task {
				try? await Task.sleep( for: Self.splashDuration )
				app.closeSplash( session )
			}
		}
		window.makeKeyAndVisible()
		self.window = window

		// The NSWindow behind the scene appears a moment later; bring it forward then.
		if windowScene.title == Self.windowTitle {
			app.bringConfigurationToFront()
		}
	}

	func sceneDidDisconnect( _ scene: UIScene ) {
		AppDelegate.shared.splashSessions.remove( scene.session.persistentIdentifier )
	}
}
