//
//  AppDelegate.swift
//  ESPDeck Bridge
//
//  Menu bar app: no Dock icon (LSUIElement), no window at launch (just a splash) unless no
//  decks are set up yet. The configuration window opens from the menu bar item.
//

import SwiftUI
import UIKit

/// Owns the controller and the menu bar plugin, and opens the configuration window.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate, DeckMenuBarHost {
	static var shared: AppDelegate { UIApplication.shared.delegate as! AppDelegate }

	let controller = DeckController()

	/// Launched by Xcode to run the unit tests inside it (it sets this for the test host).
	static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

	private(set) var menuBar             : DeckMenuBarPlugin?
	private var activity                 : NSObjectProtocol?
	private var configurationRequested   = false
	/// Launch windows showing the splash screen; never reused for configuration.
	var splashSessions                   : Set<String> = []
	/// The bundle's What's New, while the user hasn't seen it: shown before the configuration
	/// window the next time that's opened, and offered in the menu bar menu until then.
	private(set) var pendingWhatsNew     : WhatsNew?
	/// What the next window to open should show instead of the configuration window.
	private var whatsNewRequest          : WhatsNew?
	/// Windows showing What's New, and those of them already dismissed (on their way out).
	var whatsNewSessions                 : Set<String> = []
	private var whatsNewDismissed        : Set<String> = []
	/// A window of the app has come on screen since launch. HomeKit serves an app only once it
	/// has (see ensureForeground()).
	var sawForeground                    = false
	/// When ensureForeground() last opened a window, so a refusal doesn't open one after another.
	private var foregroundRequestedAt    = Date.distantPast
	/// The names the Device menu was built with.
	private var deviceMenuNames          : [String] = []

	/// Keeps AppKit's dictation and emoji items out of the Edit menu.
	func application( _ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
		// AppKit adds Start Dictation and Emoji & Symbols to the Edit menu unless these are set.
		UserDefaults.standard.set( true, forKey: "NSDisabledDictationMenuItem" )
		UserDefaults.standard.set( true, forKey: "NSDisabledCharacterPaletteMenuItem" )
		return true
	}

	/// Loads the menu bar plugin, connects it to the controller, and starts the bridge.
	func application( _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
		// Hosting the unit tests: no server, HomeKit or menu bar item, which would act on the
		// real decks and Home while the tests run.
		guard !Self.isHostingTests else { return true }

		#if DEBUG
		// For the documentation: print the guide's illustrations as PNGs and quit, before the
		// server, HomeKit or the menu bar item start (see GuideIllustrationExport).
		if UserDefaults.standard.bool( forKey: "ESPDeckExportIllustrations" ) {
			for picture in GuideIllustrationExport.pictures() {
				print( "ILLUSTRATION \(picture.name) \(picture.png.base64EncodedString())" )
			}
			fflush( stdout )
			exit( 0 )
		}
		#endif

		// App Nap would throttle HomeKit notifications and the server while no window is open.
		activity = ProcessInfo.processInfo.beginActivity( options: [ .userInitiatedAllowingIdleSystemSleep ], reason: "Bridging HomeKit to the Stream Deck" )

		menuBar = MenuBarLoader.load()
		menuBar?.install( host: self )
		controller.macBridge = menuBar
		controller.onStatusChange = { [weak self] items, connected in
			self?.menuBar?.update( statusLines: items.map( \.text ), levels: items.map { $0.level.rawValue }, connected: connected )
		}
		controller.onDecksChange = { [weak self] decks in
			guard let self else { return }
			menuBar?.updateDecks( ids: decks.map( \.id ), titles: decks.map( \.title ), levels: decks.map( \.menuLevel ) )
			// The Device menu lists the devices by name.
			let names = controller.devices.map { controller.settings( $0.id )?.name ?? $0.id }
			if names != deviceMenuNames {
				deviceMenuNames = names
				UIMenuSystem.main.setNeedsRebuild()
			}
		}
		controller.refreshLaunchAtLogin()
		setUpNotifications()
		// HomeKit refuses an app until it has shown a window. Opened by Launch at Login (or
		// `open -g`), the app may not have: then it shows its splash for a moment.
		controller.home.onBackgroundRefusal = { [weak self] in self?.ensureForeground( afterRefusal: true ) }
		Task { @MainActor [weak self] in
			try? await Task.sleep( for: .seconds( 4 ) )
			self?.ensureForeground( afterRefusal: false )
		}
		// What's New, unless it has been seen. A new installation has nothing to compare
		// with, so everything is new: it's taken as seen.
		if let whatsNew = WhatsNew.bundled, !whatsNew.isSeen {
			if controller.config.settings.devices.isEmpty {
				whatsNew.markSeen()
			} else {
				pendingWhatsNew = whatsNew
			}
		}
		menuBar?.setWhatsNewAvailable( pendingWhatsNew != nil )
		controller.start()

		return true
	}

	/// Stops the server and ends the App Nap exemption.
	func applicationWillTerminate( _ application: UIApplication ) {
		controller.server.stop()
		if let activity {
			ProcessInfo.processInfo.endActivity( activity )
		}
	}

	// MARK: - Scenes

	/// Every window is set up by SceneDelegate.
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

	/// What's New for the window that's opening, once: asked for (the menu, Help), or still
	/// unseen when the window would otherwise be the configuration window (`orPending`).
	func consumeWhatsNewRequest( orPending: Bool ) -> WhatsNew? {
		defer { whatsNewRequest = nil }
		if let whatsNewRequest { return whatsNewRequest }
		return orPending && openWhatsNewSession == nil ? pendingWhatsNew : nil
	}

	/// A What's New window that's open and hasn't been dismissed.
	private var openWhatsNewSession: UISceneSession? {
		UIApplication.shared.openSessions.first { whatsNewSessions.contains( $0.persistentIdentifier ) && !whatsNewDismissed.contains( $0.persistentIdentifier ) && $0.scene != nil }
	}

	/// Continue, Full Version History, or the window's own close button (`closing` false: it's
	/// going already). What's New counts as seen, and the configuration window opens; for the
	/// history, so does that page in the browser.
	func dismissWhatsNew( _ session: UISceneSession, history: Bool = false, closing: Bool = true ) {
		let id = session.persistentIdentifier
		guard whatsNewSessions.contains( id ), !whatsNewDismissed.contains( id ) else { return }
		whatsNewDismissed.insert( id )
		( pendingWhatsNew ?? WhatsNew.bundled )?.markSeen()
		pendingWhatsNew = nil
		menuBar?.setWhatsNewAvailable( false )

		// The configuration window first, while this one still keeps the app in front.
		menuBarOpenConfiguration()
		if closing {
			UIApplication.shared.requestSceneSessionDestruction( session, options: nil )
			menuBar?.closeWindows( titled: SceneDelegate.whatsNewTitle )
		}
		if history, let url = URL( string: "https://github.com/\(controller.updates.repository ?? "jangellx/ESPDeck")/blob/main/docs/version-history.md" ) {
			UIApplication.shared.open( url )
		}
	}

	/// A What's New window is gone: by its own close button, if it wasn't dismissed.
	func whatsNewDisconnected( _ session: UISceneSession ) {
		guard whatsNewSessions.contains( session.persistentIdentifier ) else { return }
		dismissWhatsNew( session, closing: false )
		whatsNewSessions.remove( session.persistentIdentifier )
		whatsNewDismissed.remove( session.persistentIdentifier )
	}

	/// Opens the splash window (which then stays, invisible: see closeSplash(_:)) if no window
	/// has come on screen since launch, or (`afterRefusal`) HomeKit has started refusing the app
	/// all the same: its invisible window was closed, say. Not more than once a minute.
	func ensureForeground( afterRefusal: Bool ) {
		guard afterRefusal || !sawForeground || splashSessions.isEmpty, Date().timeIntervalSince( foregroundRequestedAt ) > 60 else { return }
		foregroundRequestedAt = Date()
		print( "[AppDelegate] Showing the splash so HomeKit serves the app (\(afterRefusal ? "HomeKit refused it" : "no window yet"))" )
		UIApplication.shared.activateSceneSession( for: UISceneSessionActivationRequest( role: .windowApplication ) ) { error in
			print( "[AppDelegate] Opening the splash failed: \(error)" )
		}
	}

	/// Once the splash has shown, makes its window invisible rather than closing it. HomeKit
	/// serves the app only while macOS rates it as in the foreground, which a menu bar app with
	/// no window on screen isn't (HomeKit answers "Handler does not support background access").
	/// An invisible window that ignores the mouse keeps that rating, and with it the decks.
	func closeSplash( _ session: UISceneSession ) {
		guard splashSessions.contains( session.persistentIdentifier ) else { return }
		menuBar?.hideWindows( titled: SceneDelegate.splashTitle )
	}

	// MARK: - DeckMenuBarHost

	/// Now, and once more after the window has had time to appear (a new one's made key
	/// when it does, by the menu bar plugin).
	func bringConfigurationToFront() {
		Task { @MainActor in
			for delay in [ 0, 400 ] {
				try? await Task.sleep( for: .milliseconds( delay ) )
				menuBar?.bringWindowsToFront( excluding: SceneDelegate.splashTitle )
			}
		}
	}

	/// Selects a device from the menu bar menu, on its Keys page, and opens the window.
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

	/// The key of the deck preview at a point from the top left of the window's content,
	/// which is where SwiftUI's global frames are measured from too.
	private func previewKey( x: Double, y: Double ) -> ( device: String, key: Int )? {
		guard controller.window.isShowing, controller.window.page == .keys, let device = controller.previewDevice,
			  let key = controller.previewKeyFrames.first( where: { $0.value.contains( CGPoint( x: x, y: y ) ) } )?.key else { return nil }
		return ( device, key )
	}

	/// A color dragged over the window: the key under it is outlined, and can take it.
	func menuBarColorDragged( x: Double, y: Double ) -> Bool {
		let key = previewKey( x: x, y: y )?.key
		if controller.window.colorDropKey != key { controller.window.colorDropKey = key }
		return key != nil
	}

	func menuBarColorDragEnded() {
		controller.window.colorDropKey = nil
	}

	/// A color dropped on a key becomes its background. A Level key's partner takes it too
	/// (syncSliderPartner).
	func menuBarColorDropped( red: Double, green: Double, blue: Double, x: Double, y: Double ) -> Bool {
		controller.window.colorDropKey = nil
		guard let target = previewKey( x: x, y: y ) else { return false }
		// The selection stays where it is: a color can be dropped on key after key.
		controller.update( device: target.device, key: target.key ) {
			$0.backgroundColor = Color( .sRGB, red: red, green: green, blue: blue ).hex
		}
		return true
	}

	/// The What's New window (what's unseen, or the bundle's again), from the menu bar menu or
	/// Help. Dismissing it opens the configuration window.
	func menuBarShowWhatsNew() {
		guard let whatsNew = pendingWhatsNew ?? WhatsNew.bundled else { return menuBarOpenConfiguration() }
		menuBar?.activateApp()
		if let session = openWhatsNewSession {
			UIApplication.shared.activateSceneSession( for: UISceneSessionActivationRequest( session: session ) )
			bringConfigurationToFront()
			return
		}
		whatsNewRequest = whatsNew
		UIApplication.shared.activateSceneSession( for: UISceneSessionActivationRequest( role: .windowApplication ) ) { error in
			print( "[AppDelegate] Opening What's New failed: \(error)" )
		}
	}

	/// Opens the window on USB Setup.
	func menuBarOpenUSBSetup() {
		controller.window.selection = SidebarItem.usbSetup
		menuBarOpenConfiguration()
	}

	/// Brings the configuration window forward, or opens one: after What's New, the first time
	/// since there was something new (SceneDelegate shows that in the new window instead).
	func menuBarOpenConfiguration() {
		menuBar?.activateApp()

		// What's New is up: it comes first, and opens this window when it's dismissed.
		if let session = openWhatsNewSession {
			UIApplication.shared.activateSceneSession( for: UISceneSessionActivationRequest( session: session ) )
			bringConfigurationToFront()
			return
		}

		if let session = UIApplication.shared.openSessions.first( where: { $0.role == .windowApplication && $0.scene != nil && !splashSessions.contains( $0.persistentIdentifier ) && !whatsNewSessions.contains( $0.persistentIdentifier ) } ) {
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
