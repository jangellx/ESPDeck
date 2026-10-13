//
//  SceneDelegate.swift
//  ESPDeck Bridge
//

import SwiftUI

/// Makes each window the configuration window, What's New, or the launch splash.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
	static let splashTitle = "ESPDeck Bridge Starting"
	static let windowTitle = DeckConfigurationWindow.title
	static let whatsNewTitle = DeckConfigurationWindow.whatsNewTitle

	private static let splashDuration: Duration = .seconds( 2 )
	private static let splashSize        = CGSize( width: 420, height: 280 )
	private static let windowMinimumSize = CGSize( width: 1040, height: 640 )
	private static let whatsNewSize      = CGSize( width: 760, height: 620 )
	var window: UIWindow?

	/// Sets up the new window as the configuration window or the splash.
	func scene( _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions ) {
		guard let windowScene = scene as? UIWindowScene else { return }
		let app = AppDelegate.shared

		let window = UIWindow( windowScene: windowScene )
		// With no decks set up yet (first launch, say), the launch window is the configuration
		// window rather than a splash: there's nothing to do but set one up.
		let noDecks = app.controller.config.settings.devices.allSatisfy( \.isDemo )
		let configuration = app.consumeConfigurationRequest() || noDecks
		if let whatsNew = app.consumeWhatsNewRequest( orPending: configuration ) {
			// Before the configuration window, which opens when this is dismissed.
			windowScene.title = Self.whatsNewTitle
			windowScene.sizeRestrictions?.minimumSize = Self.whatsNewSize
			windowScene.sizeRestrictions?.maximumSize = Self.whatsNewSize
			windowScene.titlebar?.titleVisibility = .hidden
			app.whatsNewSessions.insert( session.persistentIdentifier )
			window.rootViewController = UIHostingController( rootView: WhatsNewView( whatsNew: whatsNew ) { history in
				app.dismissWhatsNew( session, history: history )
			} )
		} else if configuration {
			windowScene.title = Self.windowTitle
			// The smallest it can be made; it opens there, and the menu bar bundle then gives it
			// the size and place it had last time, or its starting height the first time
			// (DeckConfigurationWindow). Pinning the minimum to the opening size for a moment,
			// as this did before, left the window unable to be made shorter again.
			windowScene.sizeRestrictions?.minimumSize = Self.windowMinimumSize
			window.rootViewController = ConfigurationHostingController( controller: app.controller )
		} else {
			// UIKit opens a window at launch whether we want one or not. Use it as a splash
			// screen, then close it; the app lives in the menu bar.
			windowScene.title = Self.splashTitle
			windowScene.sizeRestrictions?.minimumSize = Self.splashSize
			windowScene.sizeRestrictions?.maximumSize = Self.splashSize
			windowScene.titlebar?.titleVisibility = .hidden
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
		if windowScene.title == Self.windowTitle || windowScene.title == Self.whatsNewTitle {
			app.bringConfigurationToFront()
		}
	}

	/// Forgets a closed splash window; a closed What's New window opens the configuration window.
	func sceneDidDisconnect( _ scene: UIScene ) {
		AppDelegate.shared.whatsNewDisconnected( scene.session )
		AppDelegate.shared.splashSessions.remove( scene.session.persistentIdentifier )
	}
}
