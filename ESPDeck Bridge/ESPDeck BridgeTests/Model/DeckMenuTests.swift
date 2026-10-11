//
//  DeckMenuTests.swift
//  ESPDeck BridgeTests
//
//  A menu's keys live beside the pages and are reached through the same `keys` as a page's.
//  A mistake here loses keys quietly: an edit landing on the page under the menu, the Close
//  key overwriting the key stored in its corner, a key hidden under
//  the Close key when that key moves, or a menu dropped while a key still opens it.
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
		let empty = settings.keys.dropFirst().allSatisfy( \.isEmpty )   // after the Close key
		#expect( empty )

		settings.keys[2] = labeled( "Lamp" )
		#expect( settings.keys[2].label == "Lamp" )
		settings.surface = .page( 0 )
		#expect( settings.keys == page )
	}

	/// The Close key stands in its corner, and writes to it (or of it, dragged elsewhere)
	/// change nothing.
	@Test func closeKeyIsNotStored() {
		var ( settings, menu ) = deckWithMenu()
		settings.surface = .menu( menu )
		#expect( settings.keys[0].isMenuClose )

		settings.keys[0] = labeled( "Overwritten" )
		settings.keys[1] = labeled( "Lamp" )
		settings.keys.swapAt( 0, 1 )
		#expect( settings.keys[0].isMenuClose )
		#expect( settings.keys[1].label == "Lamp" )
		#expect( settings.menus[0].keys.count { !$0.isEmpty } == 1 )
	}

	/// Moving the Close key to the other corner moves the key that was there to the corner
	/// it left, rather than hiding it.
	@Test func movingTheCloseKeyKeepsTheKeyInItsWay() {
		var ( settings, menu ) = deckWithMenu()
		settings.surface = .menu( menu )
		settings.keys[2] = labeled( "Corner" )   // top right of a Mini

		settings.setCloseStyle( .close, menu: menu )
		#expect( settings.keys[2].isMenuClose )
		#expect( settings.keys[0].label == "Corner" )
	}

	/// A menu saved before every menu had a Close key: it still dismisses as it did, and a
	/// key in what is now the Close key's corner moves to a free key.
	@Test func olderMenusKeepTheirCornerKey() throws {
		let menu = UUID()
		let json = """
			{ "id": "aa:bb", "name": "Desk", "gridColumns": 8,
			  "pages": [ [ { "kind": "menu", "action": "openMenu", "menuID": "\(menu.uuidString)" } ] ],
			  "menus": [ { "id": "\(menu.uuidString)", "dismissal": "manual", "keys": [ { "label": "Corner" }, {}, { "label": "Lamp" } ] } ] }
			"""
		var settings = try JSONDecoder().decode( DeviceSettings.self, from: Data( json.utf8 ) )
		#expect( settings.menus[0].closesOnAction == false )

		settings.reconcileMenus()
		settings.surface = .menu( menu )
		#expect( settings.keys[0].isMenuClose )
		#expect( settings.keys[1].label == "Corner" )
		#expect( settings.keys[2].label == "Lamp" )
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
