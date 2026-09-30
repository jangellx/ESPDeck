//
//  KeyAssignment.swift
//  ESPDeck Bridge
//

import Foundation

/// What one physical key is bound to and how it looks.
struct KeyAssignment: Codable, Equatable {
	/// nil means the key is unassigned.
	var kind        : KeyKind?
	/// `HMAccessory.uniqueIdentifier`; stable within a Home.
	var accessoryID : UUID?
	/// `HMService.uniqueIdentifier`, for accessories with several services of the same kind.
	var serviceID   : UUID?
	/// `HMActionSet.uniqueIdentifier`, for scenes.
	var actionSetID : UUID?
	/// Shortcuts' own identifier, for shortcuts.
	var shortcutID  : String?
	/// Last known name of the shortcut, for the label and when Shortcuts can't be reached.
	var shortcutName: String?
	/// Shortcuts only: true makes an On/Off key that passes "on" or "off" to the shortcut as
	/// its input. nil (or false) runs it once per press.
	var shortcutToggles : Bool?
	/// On/Off shortcuts: the state the key last switched to, or that the shortcut reported.
	var shortcutState   : KeyState?
	var action      = KeyAction.none
	/// Overrides the accessory/scene name. Empty uses the name.
	var label       = ""
	var showLabel   = true
	/// More accessories the key controls along with its own ("the key accessory", above),
	/// which alone decides the key's state. nil or empty for a single accessory.
	var others      : [KeyMember]?
	/// Icons keyed by `KeyState.rawValue`: an image file name, or an SF Symbol
	/// name prefixed with `KeyAssignment.symbolPrefix`.
	var icons       : [String: String] = [:]
	/// "#RRGGBB" base of the key's background gradient; nil is plain black.
	var backgroundColor : String?
	/// One of a pair of keys stepping a level up and down, instead of the key's action.
	var slider          : SliderKey?
	/// Go to Page: the page, from 1.
	var pageNumber      : Int?
	/// Scenes the key runs besides its accessories, or besides `actionSetID` on a scenes-only
	/// key; nil for none.
	var scenes          : [UUID]?
	/// When a key with accessories runs its scenes; nil is every press.
	var sceneTiming     : SceneTiming?

	/// Every scene the key runs, in order.
	var allScenes: [UUID] {
		( kind == .scene ? [ actionSetID ].compactMap { $0 } : [] ) + ( scenes ?? [] )
	}

	/// What a double tap and a hold do, besides the tap (this assignment); nil for nothing.
	var doubleTap       : PressAction?
	var hold            : PressAction?

	/// What a kind of press does: the tap is this assignment itself.
	func press( _ kind: PressKind ) -> PressAction? {
		switch kind {
			case .tap:       PressAction( self )
			case .doubleTap: doubleTap
			case .hold:      hold
		}
	}

	/// An On/Off shortcut rather than a One-Shot one.
	var isToggleShortcut: Bool { kind == .shortcut && shortcutToggles == true }

	/// Nothing on it at all.
	var isEmpty: Bool { self == KeyAssignment() }

	/// States that can have their own icon, besides `standard`.
	var states: [KeyState] { isToggleShortcut ? [ .on, .off ] : kind?.states ?? [] }

	/// The actions a press can perform, for the picker.
	var actions: [KeyAction] { isToggleShortcut ? [ .toggle, .turnOn, .turnOff, .none ] : kind?.actions ?? [] }

	/// The level a slider key adjusts.
	var sliderRef: CharacteristicRef? {
		ref( slider?.level.characteristicType )
	}

	/// The key accessory, then the others.
	var members: [KeyMember] {
		guard let kind, let accessoryID else { return [] }
		return [ KeyMember( kind: kind, accessoryID: accessoryID, serviceID: serviceID ) ] + ( others ?? [] )
	}

	/// The characteristic the key shows, of the key accessory.
	var characteristicRef: CharacteristicRef? {
		ref( kind?.displayCharacteristicType )
	}

	/// Secondary characteristic that flags a problem, e.g. a garage door obstruction.
	var alertRef: CharacteristicRef? {
		ref( kind?.alertCharacteristicType )
	}

	/// A characteristic of the key accessory's service; nil without an accessory or a type.
	private func ref( _ type: String? ) -> CharacteristicRef? {
		guard let accessoryID, let type else { return nil }
		return CharacteristicRef( accessoryID: accessoryID, serviceID: serviceID, characteristicType: type )
	}

	/// Marks an icon that's an SF Symbol's name rather than an image file's.
	static let symbolPrefix = "sf:"

	/// A state's icon, or Default's.
	func iconName( for state: KeyState ) -> String? {
		icons[state.rawValue] ?? icons[KeyState.standard.rawValue]
	}

	/// The SF Symbol chosen for exactly this state, if any.
	func symbol( for state: KeyState ) -> String? {
		guard let icon = icons[state.rawValue], icon.hasPrefix( Self.symbolPrefix ) else { return nil }
		return String( icon.dropFirst( Self.symbolPrefix.count ) )
	}
}

extension KeyAssignment {
	/// Field by field: what can't be read (a kind or action this version doesn't know) is
	/// left at its default, so the rest of the key survives.
	init( from decoder: Decoder ) throws {
		let container   = try decoder.container( keyedBy: CodingKeys.self )
		kind            = container.lenient( KeyKind.self, forKey: .kind )
		accessoryID     = container.lenient( UUID.self, forKey: .accessoryID )
		serviceID       = container.lenient( UUID.self, forKey: .serviceID )
		actionSetID     = container.lenient( UUID.self, forKey: .actionSetID )
		shortcutID      = container.lenient( String.self, forKey: .shortcutID )
		shortcutName    = container.lenient( String.self, forKey: .shortcutName )
		shortcutToggles = container.lenient( Bool.self, forKey: .shortcutToggles )
		shortcutState   = container.lenient( KeyState.self, forKey: .shortcutState )
		action          = container.lenient( KeyAction.self, forKey: .action ) ?? .none
		label           = container.lenient( String.self, forKey: .label ) ?? ""
		showLabel       = container.lenient( Bool.self, forKey: .showLabel ) ?? true
		others          = container.lenientArray( of: KeyMember.self, forKey: .others )
		icons           = container.lenient( [String: String].self, forKey: .icons ) ?? [:]
		backgroundColor = container.lenient( String.self, forKey: .backgroundColor )
		slider          = container.lenient( SliderKey.self, forKey: .slider )
		pageNumber      = container.lenient( Int.self, forKey: .pageNumber )
		scenes          = container.lenientArray( of: UUID.self, forKey: .scenes )
		sceneTiming     = container.lenient( SceneTiming.self, forKey: .sceneTiming )
		doubleTap       = container.lenient( PressAction.self, forKey: .doubleTap )
		hold            = container.lenient( PressAction.self, forKey: .hold )
	}
}

/// When a key's scenes run, if it has accessories too: every press, or only a press that
/// turns the accessories on, or off.
enum SceneTiming: String, Codable, CaseIterable, Identifiable {
	case everyPress
	case turningOn
	case turningOff

	var id: String { rawValue }

	var title: String {
		switch self {
			case .everyPress: "Every Press"
			case .turningOn:  "When Turning On"
			case .turningOff: "When Turning Off"
		}
	}

	/// Whether the scenes run with a press that turns the accessories on (or off).
	func runs( activating: Bool ) -> Bool {
		switch self {
			case .everyPress: true
			case .turningOn:  activating
			case .turningOff: !activating
		}
	}
}

extension KeyAssignment {
	/// What the Accessories & Scenes sheet chose. The key accessory stays first if it's still
	/// chosen; with no accessories, the first scene heads a scenes-only key.
	mutating func setHomeTargets( accessories: [KeyMember], scenes chosen: [UUID] ) {
		var accessories = accessories
		if let current = members.first, let index = accessories.firstIndex( of: current ), index > 0 {
			accessories.insert( accessories.remove( at: index ), at: 0 )
		}
		let oldKind = kind
		shortcutID      = nil
		shortcutName    = nil
		shortcutToggles = nil
		shortcutState   = nil
		pageNumber      = nil
		if let first = accessories.first {
			kind        = first.kind
			accessoryID = first.accessoryID
			serviceID   = first.serviceID
			others      = accessories.count > 1 ? Array( accessories.dropFirst() ) : nil
			actionSetID = nil
			scenes      = chosen.isEmpty ? nil : chosen
		} else if let first = chosen.first {
			kind        = .scene
			accessoryID = nil
			serviceID   = nil
			others      = nil
			actionSetID = first
			scenes      = chosen.count > 1 ? Array( chosen.dropFirst() ) : nil
		} else {
			kind        = nil
			accessoryID = nil
			serviceID   = nil
			others      = nil
			actionSetID = nil
			scenes      = nil
		}
		if kind != .power && kind != .fan { slider = nil }
		if kind != oldKind || !actions.contains( action ) {
			action = kind == nil ? .none : actions.first ?? .none
		}
	}
}

/// Identifies a characteristic across launches.
struct CharacteristicRef: Hashable {
	var accessoryID        : UUID
	var serviceID          : UUID?
	var characteristicType : String
}

/// One accessory (a service of it) a key controls.
struct KeyMember: Codable, Equatable, Hashable {
	var kind        : KeyKind
	var accessoryID : UUID
	var serviceID   : UUID?
}
