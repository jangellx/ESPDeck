//
//  DeckController+Menus.swift
//  ESPDeck Bridge
//
//  Menus: keys that take the place of the page while they're open (DeckMenu). A Menu key
//  opens one from the deck; Edit Menu opens it from the Keys page, which then edits the
//  menu's keys as it edits a page's. Either way the deck and the Keys page show the same
//  thing (DeviceSettings.surface).
//

import Foundation

extension DeckController {
	/// The menu the deck shows over its page, if one is open.
	func openMenu( device id: String ) -> DeckMenu? {
		settings( id )?.shownMenu
	}

	/// What the deck shows: a menu, or its current page.
	func surface( device id: String ) -> KeySurface? {
		settings( id )?.surface
	}

	/// Shows a page or a menu on the deck (and in the Keys page).
	func show( device id: String, _ surface: KeySurface ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		var changed     = config.settings.devices[index]
		changed.surface = surface
		guard changed.surface != config.settings.devices[index].surface else { return }
		stopSliders( device: id )
		// What each key shows now, which may still be the page before (changing twice quickly).
		device( id )?.pageChange = ( Date(), device( id )?.displayedPreviews ?? [] )
		config.settings.devices[index] = changed
		clearFailures( device: id )   // they were about the other page's keys
		window.selectedKey = min( window.selectedKey, max( layout( id ).keyCount - 1, 0 ) )
		assignmentsChanged( device: id )
	}

	/// Opens a menu over the page. `key` is the key that opened it, which the Keys page
	/// selects again when the menu closes.
	func showMenu( device id: String, _ menu: UUID, from key: Int? = nil ) {
		let wasOpen = openMenu( device: id ) != nil
		show( device: id, .menu( menu ) )
		guard openMenu( device: id )?.id == menu else { return }
		if !wasOpen {
			device( id )?.menuOpenerKey   = key
			device( id )?.menuOpenerPress = nil
			window.menuInspectorTab     = .key
		}
		// Not left on the Close key, which has nothing to edit.
		if window.selection == id, isMenuClose( device: id, key: window.selectedKey ), layout( id ).keyCount > 1 {
			window.selectedKey = window.selectedKey == 0 ? 1 : window.selectedKey - 1
		}
	}

	/// Make Menu and Edit Menu: opens the menu from the inspector, to set up its keys. The
	/// inspector shows the keys' taps, whichever press opens the menu, until the menu closes.
	func editMenu( device id: String, _ menu: UUID, from key: Int ) {
		let wasOpen = openMenu( device: id ) != nil
		let press   = window.pressKind
		showMenu( device: id, menu, from: key )
		guard !wasOpen, openMenu( device: id )?.id == menu else { return }
		device( id )?.menuOpenerPress = press
		window.pressKind              = .tap
	}

	/// Goes back to the page under the open menu.
	func closeMenu( device id: String ) {
		guard let settings = settings( id ), settings.openMenu != nil else { return }
		show( device: id, .page( settings.currentPage ) )
		if let key = device( id )?.menuOpenerKey, window.selection == id, key < layout( id ).keyCount {
			window.selectedKey = key
			// Back on the press that opens the menu.
			if let press = device( id )?.menuOpenerPress { window.pressKind = press }
		}
		device( id )?.menuOpenerKey   = nil
		device( id )?.menuOpenerPress = nil
	}

	/// The open menu's Close key, which can't be edited, moved or cleared.
	func isMenuClose( device id: String, key: Int ) -> Bool {
		assignment( id, key: key ).isMenuClose
	}

	/// What a menu is called: the label of the key that opens it.
	func menuName( device id: String, _ menu: UUID ) -> String {
		guard let opener = settings( id )?.opener( of: menu ) else { return "Menu" }
		return opener.label.isEmpty ? defaultName( for: opener ) ?? "Menu" : opener.label
	}

	/// Changes a menu's own settings (whether it dismisses on action, its Close key's icon),
	/// as an undo step.
	func updateMenu( device id: String, _ menu: UUID, _ change: ( inout DeckMenu ) -> Void ) {
		guard let index = config.settings.deviceIndex( id ),
			  let place = config.settings.devices[index].menus.firstIndex( where: { $0.id == menu } ) else { return }
		var changed = config.settings.devices[index].menus[place]
		change( &changed )
		guard changed != config.settings.devices[index].menus[place] else { return }
		recordUndo( device: id, "Edit Menu" )
		if config.settings.devices[index].openMenu == menu { stopSliders( device: id ) }   // the Close key may land on one
		config.settings.devices[index].menus[place] = changed
		assignmentsChanged( device: id )
	}

	/// Moves a menu's Close key to its other corner, as an undo step; the key that was there
	/// moves to the corner it left.
	func setMenuCloseStyle( device id: String, _ menu: UUID, _ style: MenuCloseStyle ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		var changed = config.settings.devices[index]
		changed.setCloseStyle( style, menu: menu )
		guard changed != config.settings.devices[index] else { return }
		recordUndo( device: id, "Edit Menu" )
		if changed.openMenu == menu { stopSliders( device: id ) }
		config.settings.devices[index] = changed
		assignmentsChanged( device: id )
	}

	/// A Menu key's press, or the Close key's.
	func performMenu( _ assignment: KeyAssignment, device id: String, key: Int? ) {
		if assignment.action == .closeMenu {
			closeMenu( device: id )
		} else if let menu = assignment.menuID {
			showMenu( device: id, menu, from: key )
		}
	}

	/// Whether pressing a key for `action` closes the open menu afterward: a menu that
	/// dismisses on action, and a key that did something. Page commands leave the menu themselves, and
	/// Level keys (which step while held) keep it open.
	func closesMenu( after action: KeyAssignment?, device id: String ) -> Bool {
		guard openMenu( device: id )?.closesOnAction == true, let action, let kind = action.kind else { return false }
		return kind != .menu && kind != .page && action.action != .none && action.slider == nil
	}

	/// Records what an On/Off shortcut's key shows, on the surface it was pressed on: a menu
	/// that closes on action is gone by the time its shortcut finishes.
	func setShortcutState( _ state: KeyState, shortcut: String, device id: String, key: Int, on surface: KeySurface? ) {
		func change( _ assignment: inout KeyAssignment ) {
			// Unless the key was reassigned while the shortcut ran.
			if assignment.isToggleShortcut && assignment.shortcutID == shortcut { assignment.shortcutState = state }
		}
		guard let surface, let index = config.settings.deviceIndex( id ), config.settings.devices[index].surface != surface else {
			update( device: id, key: key, change )
			return
		}
		_ = config.settings.devices[index].update( key: key, on: surface, change )
	}
}
