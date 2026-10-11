//
//  DeckMenuTests.swift
//  ESPDeck BridgeTests
//
//  A menu's keys live beside the pages and are reached through the same `keys` as a page's.
//  A mistake here loses keys quietly: an edit landing on the page under the menu, the Close
//  key overwriting the key stored in its corner, or a menu dropped while a key still opens it.
//

import Foundation
import Testing
@testable import ESPDeck_Bridge

/// Menus in a deck's settings.
struct DeckMenuTests {
	/// A Mini (2 rows of 3) whose first key opens a menu.
	private func deckWithMenu() -> ( settings: DeviceSettings, menu: UUID ) {
		var settings = DeviceSettings( id: "aa:bb", name: "Desk" )
		var opener   = KeyAssignment()
		opener.kind   = .menu
		opener.action = .openMenu
		opener.menuID = UUID()
		settings.keys[0] = opener
		settings.reconcileMenus()
		return ( settings, opener.menuID! )
	}

	private func labeled( _ label: String ) -> KeyAssignment {
		var key   = KeyAssignment()
		key.label = label
		return key
	}

	/// With a menu open, `keys` reads and writes the menu, and the page under it is untouched.
	@Test func editsGoToTheOpenMenu() {
		var ( settings, menu ) = deckWithMenu()
		let page = settings.keys
		settings.surface = .menu( menu )
		let empty = settings.keys.allSatisfy( \.isEmpty )
		#expect( empty )

		settings.keys[2] = labeled( "Lamp" )
		#expect( settings.keys[2].label == "Lamp" )
		settings.surface = .page( 0 )
		#expect( settings.keys == page )
	}

	/// The Close key stands in its corner without replacing the key stored there, and writes
	/// to it (or of it, dragged elsewhere) change nothing.
	@Test func closeKeyIsNotStored() {
		var ( settings, menu ) = deckWithMenu()
		settings.surface = .menu( menu )
		settings.keys[0] = labeled( "Corner" )
		settings.menus[0].dismissal = .manual

		#expect( settings.keys[0].isMenuClose )
		settings.keys[0] = labeled( "Overwritten" )
		settings.keys.swapAt( 0, 1 )
		#expect( settings.keys[0].isMenuClose )
		#expect( settings.keys[1].isEmpty )

		settings.menus[0].closeStyle = .close   // top right: key 2 of a Mini
		#expect( settings.keys[0].label == "Corner" )
		#expect( settings.keys[2].isMenuClose )
	}

	/// A menu lasts as long as a key opens it (by tap, double tap or hold), and what's saved
	/// reads back the same.
	@Test func menusFollowTheirKeys() throws {
		var ( settings, menu ) = deckWithMenu()
		settings.surface = .menu( menu )
		settings.keys[1] = labeled( "Fan" )
		settings.surface = .page( 0 )

		let decoded = try JSONDecoder().decode( DeviceSettings.self, from: JSONEncoder().encode( settings ) )
		#expect( decoded.menus == settings.menus )

		// Moved to the key's hold: still opened.
		var key   = settings.keys[0]
		key.hold  = PressAction( key )
		key.kind  = nil
		key.action = .none
		key.menuID = nil
		settings.keys[0] = key
		settings.reconcileMenus()
		#expect( settings.menus.map( \.id ) == [ menu ] )

		settings.keys[0] = KeyAssignment()
		settings.reconcileMenus()
		#expect( settings.menus.isEmpty )
	}
}
