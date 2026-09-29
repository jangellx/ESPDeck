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

	var isToggleShortcut: Bool { kind == .shortcut && shortcutToggles == true }

	/// States that can have their own icon, besides `standard`.
	var states: [KeyState] { isToggleShortcut ? [ .on, .off ] : kind?.states ?? [] }

	var actions: [KeyAction] { isToggleShortcut ? [ .toggle, .turnOn, .turnOff, .none ] : kind?.actions ?? [] }

	/// The level a slider key adjusts.
	var sliderRef: CharacteristicRef? {
		guard let slider, let accessoryID else { return nil }
		return CharacteristicRef( accessoryID: accessoryID, serviceID: serviceID, characteristicType: slider.level.characteristicType )
	}

	/// The key accessory, then the others.
	var members: [KeyMember] {
		guard let kind, let accessoryID else { return [] }
		return [ KeyMember( kind: kind, accessoryID: accessoryID, serviceID: serviceID ) ] + ( others ?? [] )
	}

	var characteristicRef: CharacteristicRef? {
		guard let kind, let accessoryID, let type = kind.displayCharacteristicType else { return nil }
		return CharacteristicRef( accessoryID: accessoryID, serviceID: serviceID, characteristicType: type )
	}

	/// Secondary characteristic that flags a problem, e.g. a garage door obstruction.
	var alertRef: CharacteristicRef? {
		guard let kind, let accessoryID, let type = kind.alertCharacteristicType else { return nil }
		return CharacteristicRef( accessoryID: accessoryID, serviceID: serviceID, characteristicType: type )
	}

	static let symbolPrefix = "sf:"

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
