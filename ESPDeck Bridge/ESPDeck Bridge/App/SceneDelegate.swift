//
//  SceneDelegate.swift
//  ESPDeck Bridge
//

import SwiftUI

/// Makes each window either the configuration window or the launch splash.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
	static let splashTitle = "ESPDeck Bridge Starting"
	static let windowTitle = "ESPDeck Bridge"

	private static let splashDuration: Duration = .seconds( 2 )
	private static let splashSize        = CGSize( width: 420, height: 280 )
	private static let windowMinimumSize = CGSize( width: 1040, height: 640 )
	/// How tall the configuration window opens, where the screen has room: Getting Started's
	/// first sheet fits without scrolling.
	private static let windowOpeningHeight: CGFloat = 1135
	/// Left free above and below it for the menu bar, its title bar and the Dock.
	private static let screenMargin: CGFloat = 140

	var window: UIWindow?

	/// Sets up the new window as the configuration window or the splash.
	func scene( _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions ) {
		guard let windowScene = scene as? UIWindowScene else { return }
		let app = AppDelegate.shared

		let window = UIWindow( windowScene: windowScene )
		// With no decks set up yet (first launch, say), the launch window is the configuration
		// window rather than a splash: there's nothing to do but set one up.
		let noDecks = app.controller.config.settings.devices.allSatisfy( \.isDemo )
		if app.consumeConfigurationRequest() || noDecks {
			windowScene.title = Self.windowTitle
			// A window opens at its minimum size, so the height it should open at is the minimum
			// (and the maximum) until it's on screen; then it can be resized freely again.
			let height = max( Self.windowMinimumSize.height, min( Self.windowOpeningHeight, windowScene.screen.bounds.height - Self.screenMargin ) )
			windowScene.sizeRestrictions?.minimumSize = CGSize( width: Self.windowMinimumSize.width, height: height )
			windowScene.sizeRestrictions?.maximumSize = CGSize( width: CGFloat.greatestFiniteMagnitude, height: height )
			Task {
				try? await Task.sleep( for: .milliseconds( 600 ) )
				windowScene.sizeRestrictions?.minimumSize = Self.windowMinimumSize
				windowScene.sizeRestrictions?.maximumSize = CGSize( width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude )
			}
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
		if windowScene.title == Self.windowTitle {
			app.bringConfigurationToFront()
		}
	}

	/// Forgets a closed splash window.
	func sceneDidDisconnect( _ scene: UIScene ) {
		AppDelegate.shared.splashSessions.remove( scene.session.persistentIdentifier )
	}
}
