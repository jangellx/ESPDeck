//
//  AppDelegate.swift
//  ESPDeck Bridge
//
//  Menu bar app: no Dock icon (LSUIElement), no window at launch. The configuration
//  window opens from the menu bar item.
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, DeckMenuBarHost {
	static var shared: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

	let controller = DeckController()

	private(set) var menuBar             : DeckMenuBarPlugin?
	private var activity                 : NSObjectProtocol?
	private var configurationRequested   = false
	/// Launch windows showing the splash screen; never reused for configuration.
	var splashSessions                   : Set<String> = []
	/// The names the Device menu was built with.
	private var deviceMenuNames          : [String] = []

	func application( _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
		// App Nap would throttle HomeKit notifications and the server while no window is open.
		activity = ProcessInfo.processInfo.beginActivity( options: [ .userInitiatedAllowingIdleSystemSleep ], reason: "Bridging HomeKit to the Stream Deck" )

		menuBar = MenuBarLoader.load()
		menuBar?.install( host: self )
		controller.macBridge = menuBar
		controller.onStatusChange = { [weak self] items, connected in
			self?.menuBar?.update( statusLines: items.map( \.text ), levels: items.map { $0.level.rawValue }, connected: connected )
		}
		controller.onDecksChange = { [weak self] heading, decks in
			guard let self else { return }
			menuBar?.updateDecks( heading: heading, ids: decks.map( \.id ), titles: decks.map( \.title ), levels: decks.map( \.menuLevel ) )
			// The Device menu lists the devices by name.
			let names = controller.devices.map { controller.settings( $0.id )?.name ?? $0.id }
			if names != deviceMenuNames {
				deviceMenuNames = names
				UIMenuSystem.main.setNeedsRebuild()
			}
		}
		controller.refreshLaunchAtLogin()
		controller.start()

		return true
	}

	func applicationWillTerminate( _ application: UIApplication ) {
		controller.server.stop()
		if let activity {
			ProcessInfo.processInfo.endActivity( activity )
		}
	}

	// MARK: - Scenes

	func application( _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions ) -> UISceneConfiguration {
		let configuration = UISceneConfiguration( name: "Configuration", sessionRole: connectingSceneSession.role )
		configuration.delegateClass = SceneDelegate.self
		return configuration
	}

	/// True once per explicit request, so the window UIKit opens (or restores) at launch
	/// can be told apart from one the user asked for.
	func consumeConfigurationRequest() -> Bool {
		defer { configurationRequested = false }
		return configurationRequested
	}

	func closeSplash( _ session: UISceneSession ) {
		guard splashSessions.contains( session.persistentIdentifier ) else { return }
		UIApplication.shared.requestSceneSessionDestruction( session, options: nil )
		menuBar?.closeWindows( titled: SceneDelegate.splashTitle )
	}

	// MARK: - DeckMenuBarHost

	/// A few tries, since the window can appear a little after its scene connects.
	func bringConfigurationToFront() {
		Task { @MainActor in
			for delay in [ 0, 150, 400, 800 ] {
				try? await Task.sleep( for: .milliseconds( delay ) )
				menuBar?.bringWindowsToFront( excluding: SceneDelegate.splashTitle )
			}
		}
	}

	func menuBarShowDevice( id: String ) {
		controller.window.selection = id
		if !id.hasPrefix( SidebarItem.newPrefix ) {
			controller.window.page = .keys   // a new device has one page
		}
		menuBarOpenConfiguration()
	}

	func menuBarLaunchAtLoginChanged() {
		controller.refreshLaunchAtLogin()
	}

	func menuBarOpenUSBSetup() {
		controller.window.selection = SidebarItem.usbSetup
		menuBarOpenConfiguration()
	}

	func menuBarOpenConfiguration() {
		menuBar?.activateApp()

		if let session = UIApplication.shared.openSessions.first( where: { $0.role == .windowApplication && $0.scene != nil && !splashSessions.contains( $0.persistentIdentifier ) } ) {
			UIApplication.shared.activateSceneSession( for: UISceneSessionActivationRequest( session: session ) )
			bringConfigurationToFront()
		} else {
			configurationRequested = true
			UIApplication.shared.activateSceneSession( for: UISceneSessionActivationRequest( role: .windowApplication ) ) { error in
				print( "[AppDelegate] Opening the configuration window failed: \(error)" )
			}
		}
	}
}
