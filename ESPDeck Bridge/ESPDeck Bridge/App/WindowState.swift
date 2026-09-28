//
//  WindowState.swift
//  ESPDeck Bridge
//
//  What the configuration window shows: the sidebar selection, a device's page, and the
//  selected key. It lives on the controller so the app's menus (AppCommands) and the
//  menu bar menu can read and change it, and the views follow.
//

import Observation

@Observable
final class WindowState {
	enum Page: String, CaseIterable, Identifiable {
		case keys   = "Keys"
		case device = "Device"
		case log    = "Log"

		var id: String { rawValue }
	}

	/// A device ID or one of SidebarItem's values.
	var selection   : String? {
		didSet {
			if selection != oldValue { selectedKey = 0 }
		}
	}
	var page        = Page.keys
	var selectedKey = 0

	// Asked for by the menus, shown by the views (the same dialogs as their buttons).
	var confirmingClearKey  = false
	var confirmingForget    = false
	/// Key ▸ Assign Accessory/Scene/Shortcut: the mode the key's picker switches to.
	var requestedTargetMode : TargetMode?

	/// Set while the configuration window is on screen.
	var isShowing   = false
}
