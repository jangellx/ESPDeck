//
//  DeckMenu.swift
//  ESPDeck Bridge
//
//  A menu: a set of keys that takes the place of the page while it's open, like a folder in
//  Elgato's software. A key opens it with its tap, double tap or hold (KeyKind.menu), and
//  names it by ID; the device keeps the menus (DeviceSettings.menus). It closes after one
//  of its keys is pressed, or with its own Close key.
//

import Foundation

/// How a menu goes away again.
enum MenuDismissal: String, Codable, CaseIterable, Identifiable {
	/// Pressing any of its keys runs the key and closes the menu.
	case onAction
	/// It stays until its Close key is pressed; that key takes a corner of the menu.
	case manual

	var id: String { rawValue }

	var title: String {
		switch self {
			case .onAction: "On Action"
			case .manual:   "Manually"
		}
	}
}

/// The Close key of a menu that's closed manually: where it is and what it shows.
enum MenuCloseStyle: String, Codable, CaseIterable, Identifiable {
	/// A "go back" key at the top left.
	case back
	/// A "close" key at the top right.
	case close

	var id: String { rawValue }

	var title: String {
		switch self {
			case .back:  "Back, Top Left"
			case .close: "Close, Top Right"
		}
	}

	/// The SF Symbols offered for the key, the default first.
	var symbols: [String] {
		switch self {
			case .back:
				[ "chevron.left", "chevron.left.circle", "chevron.left.circle.fill", "chevron.left.2",
				  "chevron.left.to.line", "arrow.left", "arrow.left.circle.fill", "arrow.uturn.left",
				  "arrowshape.turn.up.backward.fill", "arrowshape.left.fill" ]
			case .close:
				[ "xmark", "xmark.circle", "xmark.circle.fill", "xmark.square", "xmark.square.fill",
				  "xmark.app.fill", "xmark.octagon.fill", "multiply" ]
		}
	}

	/// The key's place on a deck with `layout`, as the deck numbers its keys.
	func key( in layout: DeckLayout ) -> Int {
		self == .back ? 0 : max( layout.cols - 1, 0 )
	}
}

/// One menu of a device.
struct DeckMenu: Codable, Equatable, Identifiable {
	/// What the keys that open it name (KeyAssignment.menuID).
	var id          = UUID()
	/// Its keys, on the same grid as a page's (DeviceSettings.pages).
	var keys        : [KeyAssignment] = []
	var dismissal   = MenuDismissal.onAction
	var closeStyle  = MenuCloseStyle.back
	/// The Close key's SF Symbol; nil (or one the style doesn't offer) is the style's first.
	var closeSymbol : String?

	init( id: UUID = UUID() ) {
		self.id = id
	}

	/// What the Close key shows.
	var symbol: String {
		closeSymbol.flatMap { closeStyle.symbols.contains( $0 ) ? $0 : nil } ?? closeStyle.symbols[0]
	}

	/// Where the Close key is on a deck with `layout`; nil for a menu that closes on its own.
	func closeKey( in layout: DeckLayout ) -> Int? {
		dismissal == .manual ? closeStyle.key( in: layout ) : nil
	}

	/// The key standing in the Close key's place: not stored, and not editable.
	static let closeAssignment: KeyAssignment = {
		var key       = KeyAssignment()
		key.kind      = .menu
		key.action    = .closeMenu
		key.showLabel = false
		return key
	}()

	private enum CodingKeys: String, CodingKey {
		case id, keys, dismissal, closeStyle, closeSymbol
	}

	/// Field by field; only the ID is needed.
	init( from decoder: Decoder ) throws {
		let container = try decoder.container( keyedBy: CodingKeys.self )
		id            = try container.decode( UUID.self, forKey: .id )
		keys          = container.lenientArray( of: KeyAssignment.self, forKey: .keys, placeholder: KeyAssignment() ) ?? []
		dismissal     = container.lenient( MenuDismissal.self, forKey: .dismissal ) ?? .onAction
		closeStyle    = container.lenient( MenuCloseStyle.self, forKey: .closeStyle ) ?? .back
		closeSymbol   = container.lenient( String.self, forKey: .closeSymbol )
	}

	func encode( to encoder: Encoder ) throws {
		var container = encoder.container( keyedBy: CodingKeys.self )
		try container.encode( id, forKey: .id )
		var keys = keys
		while let last = keys.last, last.isEmpty { keys.removeLast() }
		try container.encode( keys, forKey: .keys )
		try container.encode( dismissal, forKey: .dismissal )
		try container.encode( closeStyle, forKey: .closeStyle )
		try container.encodeIfPresent( closeSymbol, forKey: .closeSymbol )
	}
}

/// What a deck is showing: one of its pages, or a menu over it.
enum KeySurface: Equatable {
	case page( Int )
	case menu( UUID )
}
