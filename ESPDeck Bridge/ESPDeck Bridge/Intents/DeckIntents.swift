//
//  DeckIntents.swift
//  ESPDeck Bridge
//
//  Shortcuts actions for the decks themselves: go to a page, open or close a menu, sleep,
//  wake, and set the brightness. They run in the app (launching it in the background if it
//  isn't running) through the DeckController registered at launch (AppDelegate).
//
//  Their type names, DeckEntity's and MenuEntity's IDs (a deck's ID, a menu's UUID) and the
//  App Shortcut phrases are what saved shortcuts and Siri remember: don't rename them.
//

import AppIntents

// MARK: - Entities

/// A deck, as Shortcuts lists it; demo decks aren't offered.
struct DeckEntity: AppEntity {
	static let typeDisplayRepresentation: TypeDisplayRepresentation = "Deck"
	static let defaultQuery = DeckQuery()

	/// The deck's ID (DeviceSettings.id), which stays the same when it's renamed.
	let id: String
	@Property( title: "Name" ) var name: String

	var displayRepresentation: DisplayRepresentation { DisplayRepresentation( title: "\(name)" ) }

	init( id: String, name: String ) {
		self.id   = id
		self.name = name
	}
}

/// Every deck that isn't a demo: there are only ever a few.
struct DeckQuery: EnumerableEntityQuery {
	@Dependency private var controller: DeckController

	@MainActor func allEntities() async throws -> [DeckEntity] {
		controller.intentDecks()
	}

	@MainActor func entities( for identifiers: [String] ) async throws -> [DeckEntity] {
		controller.intentDecks().filter { identifiers.contains( $0.id ) }
	}
}

/// One of a deck's menus, named for the key that opens it.
struct MenuEntity: AppEntity {
	static let typeDisplayRepresentation: TypeDisplayRepresentation = "Menu"
	static let defaultQuery = MenuQuery()

	let id: UUID
	@Property( title: "Name" ) var name: String
	@Property( title: "Deck" ) var deckName: String
	/// The deck it belongs to.
	let deckID: String

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation( title: "\(name)", subtitle: "\(deckName)" )
	}

	init( id: UUID, name: String, deckID: String, deckName: String ) {
		self.id       = id
		self.deckID   = deckID
		self.name     = name   // the @Property wrappers last: setting one needs the rest set
		self.deckName = deckName
	}
}

/// Every menu of every deck that isn't a demo.
struct MenuQuery: EnumerableEntityQuery {
	@Dependency private var controller: DeckController

	@MainActor func allEntities() async throws -> [MenuEntity] {
		controller.intentMenus()
	}

	@MainActor func entities( for identifiers: [UUID] ) async throws -> [MenuEntity] {
		controller.intentMenus().filter { identifiers.contains( $0.id ) }
	}
}

// MARK: - Intents

/// Shows a page, as a Go to Page key does.
struct GoToPageIntent: AppIntent {
	static let title: LocalizedStringResource = "Go to Page"
	static let description = IntentDescription( "Shows one of a deck's pages, closing any menu that's open." )

	@Parameter( title: "Deck" ) var deck: DeckEntity
	@Parameter( title: "Page", default: 1, inclusiveRange: ( 1, 99 ) ) var page: Int

	static var parameterSummary: some ParameterSummary {
		Summary( "Show page \(\.$page) on \(\.$deck)" )
	}

	@Dependency private var controller: DeckController

	@MainActor func perform() async throws -> some IntentResult {
		try await controller.waitForDecks( [ deck ] )
		guard page <= controller.pageCount( device: deck.id ) else { throw DeckIntentError.noSuchPage( page, deck: deck.name ) }
		controller.showPage( device: deck.id, page - 1 )
		return .result()
	}
}

/// Opens a menu over the page, as its Menu key does.
struct OpenMenuIntent: AppIntent {
	static let title: LocalizedStringResource = "Open Menu"
	static let description = IntentDescription( "Opens one of a deck's menus, as the key that opens it would." )

	@Parameter( title: "Menu" ) var menu: MenuEntity

	static var parameterSummary: some ParameterSummary {
		Summary( "Open \(\.$menu)" )
	}

	@Dependency private var controller: DeckController

	@MainActor func perform() async throws -> some IntentResult {
		try await controller.waitForDecks( [ DeckEntity( id: menu.deckID, name: menu.deckName ) ] )
		guard controller.settings( menu.deckID )?.menus.contains( where: { $0.id == menu.id } ) == true else {
			throw DeckIntentError.menuGone( menu.name )
		}
		controller.showMenu( device: menu.deckID, menu.id )
		return .result()
	}
}

/// Closes the open menu, as its Close key does.
struct CloseMenuIntent: AppIntent {
	static let title: LocalizedStringResource = "Close Menu"
	static let description = IntentDescription( "Closes the menu open on a deck, going back to the page under it." )

	@Parameter( title: "Deck" ) var deck: DeckEntity

	static var parameterSummary: some ParameterSummary {
		Summary( "Close the menu on \(\.$deck)" )
	}

	@Dependency private var controller: DeckController

	@MainActor func perform() async throws -> some IntentResult {
		try await controller.waitForDecks( [ deck ] )
		controller.closeMenu( device: deck.id )
		return .result()
	}
}

/// Turns a deck's screen off, as Sleep Now does; any key press wakes it.
struct SleepDeckIntent: AppIntent {
	static let title: LocalizedStringResource = "Sleep Deck"
	static let description = IntentDescription( "Turns a deck's screen off. Pressing any of its keys wakes it." )

	@Parameter( title: "Deck", description: "Leave empty for every deck." ) var deck: DeckEntity?

	static var parameterSummary: some ParameterSummary {
		Summary( "Put \(\.$deck) to sleep" )
	}

	@Dependency private var controller: DeckController

	@MainActor func perform() async throws -> some IntentResult {
		for id in try await controller.waitForDecks( deck.map { [ $0 ] } ) {
			controller.sleep( device: id )
		}
		return .result()
	}
}

/// Turns a deck's screen back on, as Wake Now does.
struct WakeDeckIntent: AppIntent {
	static let title: LocalizedStringResource = "Wake Deck"
	static let description = IntentDescription( "Turns a sleeping deck's screen back on." )

	@Parameter( title: "Deck", description: "Leave empty for every deck." ) var deck: DeckEntity?

	static var parameterSummary: some ParameterSummary {
		Summary( "Wake \(\.$deck)" )
	}

	@Dependency private var controller: DeckController

	@MainActor func perform() async throws -> some IntentResult {
		for id in try await controller.waitForDecks( deck.map { [ $0 ] } ) {
			controller.wake( device: id )
		}
		return .result()
	}
}

/// Sets a deck's screen brightness, as the Device page's slider does.
struct SetDeckBrightnessIntent: AppIntent {
	static let title: LocalizedStringResource = "Set Deck Brightness"
	static let description = IntentDescription( "Sets how bright a deck's keys are, from 0 to 100 percent." )

	@Parameter( title: "Deck", description: "Leave empty for every deck." ) var deck: DeckEntity?
	@Parameter( title: "Brightness", default: 80, inclusiveRange: ( 0, 100 ) ) var brightness: Int

	static var parameterSummary: some ParameterSummary {
		Summary( "Set the brightness of \(\.$deck) to \(\.$brightness)%" )
	}

	@Dependency private var controller: DeckController

	@MainActor func perform() async throws -> some IntentResult {
		let value = min( max( brightness, 0 ), 100 )
		for id in try await controller.waitForDecks( deck.map { [ $0 ] } ) {
			controller.setBrightness( device: id, value )
		}
		return .result()
	}
}

// MARK: - App Shortcuts

/// Sleeping and waking every deck, ready-made in Shortcuts and by voice.
struct DeckShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut( intent: SleepDeckIntent(),
					 phrases: [ "Put my decks to sleep with \(.applicationName)", "Sleep my decks with \(.applicationName)" ],
					 shortTitle: "Sleep Decks",
					 systemImageName: "moon.fill" )
		AppShortcut( intent: WakeDeckIntent(),
					 phrases: [ "Wake my decks with \(.applicationName)" ],
					 shortTitle: "Wake Decks",
					 systemImageName: "sun.max.fill" )
	}
}

// MARK: - Errors

/// Why an action couldn't run, as Shortcuts shows it.
enum DeckIntentError: Error, CustomLocalizedStringResourceConvertible {
	case notConnected( String )
	case noneConnected
	case noSuchPage( Int, deck: String )
	case menuGone( String )

	var localizedStringResource: LocalizedStringResource {
		switch self {
			case .notConnected( let name ):        "\(name) isn't connected to ESPDeck Bridge."
			case .noneConnected:                   "No deck is connected to ESPDeck Bridge."
			case .noSuchPage( let page, let deck ): "\(deck) has no page \(page)."
			case .menuGone( let name ):            "The menu \(name) no longer exists."
		}
	}
}

// MARK: - The controller's side

extension DeckController {
	/// The decks Shortcuts offers: every one that isn't a demo.
	func intentDecks() -> [DeckEntity] {
		devices.compactMap { device in
			guard let settings = settings( device.id ), !settings.isDemo else { return nil }
			return DeckEntity( id: device.id, name: settings.name.isEmpty ? device.id : settings.name )
		}
	}

	/// Every menu of those decks.
	func intentMenus() -> [MenuEntity] {
		intentDecks().flatMap { deck in
			( settings( deck.id )?.menus ?? [] ).map { menu in
				MenuEntity( id: menu.id, name: menuName( device: deck.id, menu.id ), deckID: deck.id, deckName: deck.name )
			}
		}
	}

	/// Waits for `decks` (nil for every deck) to be connected, and returns the IDs of those to
	/// act on. An action that launched the app finds its decks still reconnecting, which takes
	/// a few seconds, so this waits up to 15 for them. A named deck that doesn't connect is an
	/// error; for every deck, it's enough that one has.
	@discardableResult
	func waitForDecks( _ decks: [DeckEntity]? ) async throws -> [String] {
		let wanted   = decks ?? intentDecks()
		guard !wanted.isEmpty else { throw DeckIntentError.noneConnected }
		let deadline = Date( timeIntervalSinceNow: 15 )
		while true {
			let online = wanted.filter { device( $0.id )?.isOnline == true }
			if online.count == wanted.count { return online.map( \.id ) }
			if Date() >= deadline {
				if decks == nil, !online.isEmpty { return online.map( \.id ) }
				if let missing = wanted.first( where: { device( $0.id )?.isOnline != true } ), decks != nil {
					throw DeckIntentError.notConnected( missing.name )
				}
				throw DeckIntentError.noneConnected
			}
			try await Task.sleep( for: .milliseconds( 250 ) )
		}
	}
}
