//
//  PressAction.swift
//  ESPDeck Bridge
//
//  What a key's double tap or hold does, as a Home app stateless button does for its double
//  and long presses: the same kinds of target and action as the key's tap, without the key's
//  look (icon, label, background), which belongs to the tap. The device judges which kind of
//  press it was (keyModes).
//

import Foundation

enum PressKind: String, CaseIterable, Identifiable {
	case tap       = "Tap"
	case doubleTap = "Double Tap"
	case hold      = "Hold"

	var id: String { rawValue }
}

struct PressAction: Codable, Equatable {
	var kind            : KeyKind
	var accessoryID     : UUID?
	var serviceID       : UUID?
	var actionSetID     : UUID?
	var shortcutID      : String?
	var shortcutName    : String?
	var shortcutToggles : Bool?
	var action          = KeyAction.none
	var pageNumber      : Int?
	var others          : [KeyMember]?

	/// nil for an assignment that does nothing.
	init?( _ assignment: KeyAssignment ) {
		guard let kind = assignment.kind else { return nil }
		self.kind       = kind
		accessoryID     = assignment.accessoryID
		serviceID       = assignment.serviceID
		actionSetID     = assignment.actionSetID
		shortcutID      = assignment.shortcutID
		shortcutName    = assignment.shortcutName
		shortcutToggles = assignment.shortcutToggles
		action          = assignment.action
		pageNumber      = assignment.pageNumber
		others          = assignment.others
	}

	/// As a key assignment, for the picker and for performing it.
	var assignment: KeyAssignment {
		var assignment             = KeyAssignment()
		assignment.kind            = kind
		assignment.accessoryID     = accessoryID
		assignment.serviceID       = serviceID
		assignment.actionSetID     = actionSetID
		assignment.shortcutID      = shortcutID
		assignment.shortcutName    = shortcutName
		assignment.shortcutToggles = shortcutToggles
		assignment.action          = action
		assignment.pageNumber      = pageNumber
		assignment.others          = others
		return assignment
	}

	/// Field by field, like KeyAssignment; only the kind is needed.
	init( from decoder: Decoder ) throws {
		let container   = try decoder.container( keyedBy: CodingKeys.self )
		kind            = try container.decode( KeyKind.self, forKey: .kind )
		accessoryID     = container.lenient( UUID.self, forKey: .accessoryID )
		serviceID       = container.lenient( UUID.self, forKey: .serviceID )
		actionSetID     = container.lenient( UUID.self, forKey: .actionSetID )
		shortcutID      = container.lenient( String.self, forKey: .shortcutID )
		shortcutName    = container.lenient( String.self, forKey: .shortcutName )
		shortcutToggles = container.lenient( Bool.self, forKey: .shortcutToggles )
		action          = container.lenient( KeyAction.self, forKey: .action ) ?? .none
		pageNumber      = container.lenient( Int.self, forKey: .pageNumber )
		others          = container.lenientArray( of: KeyMember.self, forKey: .others )
	}
}
