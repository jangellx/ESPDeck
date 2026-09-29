//
//  WindowState.swift
//  ESPDeck Bridge
//
//  What the configuration window shows: the sidebar selection, a device's page, and the
//  selected key. It lives on the controller so the app's menus (AppCommands) and the
//  menu bar menu can read and change it, and the views follow.
//

import CoreGraphics
import Foundation
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

	/// The Keys page's deck preview: its key size, or 0 to size it to fit (kept between
	/// launches), and the size that fits as last laid out, which zooming starts from.
	var deckKeySize = UserDefaults.standard.double( forKey: "keysKeySize" ) {
		didSet { UserDefaults.standard.set( deckKeySize, forKey: "keysKeySize" ) }
	}
	var deckFitKeySize: CGFloat = 96

	/// The preview's key size now, fitted or chosen.
	var deckEffectiveKeySize: CGFloat {
		deckKeySize > 0 ? CGFloat( deckKeySize ) : deckFitKeySize
	}

	/// Zooms the preview to a key size, from the smallest to full size (never beyond).
	func zoomDeck( to size: CGFloat, range: ClosedRange<CGFloat> ) {
		deckKeySize = Double( min( max( size, range.lowerBound ), range.upperBound ).rounded() )
	}

	/// Getting Started's sheet, and how the dev kit is being set up (nil until chosen: USB
	/// where it's available). Here so USB Setup and the menus can open a sheet.
	var guideSheet  = GuideSheet.parts
	var guidePath   : GuidePath?

	// Asked for by the menus, shown by the views (the same dialogs as their buttons).
	var confirmingClearKey  = false
	var confirmingForget    = false
	/// The inspector's press tab (Tap, Double Tap, Hold); kept from key to key, to set up the
	/// same press on several keys.
	var pressKind           = PressKind.tap
	/// The key picker's tab last chosen: a blank key's picker opens on it.
	var lastKeyTargetMode   = TargetMode.accessory
	/// Key ▸ Assign Accessory/Scene/Shortcut: the mode the key's picker switches to.
	var requestedTargetMode : TargetMode?
	/// File ▸ Reset Bridge…, asking first.
	var confirmingResetBridge = false
	/// Export Bridge or Import Bridge, from the File menu or the About page.
	var bridgeTransfer      : BridgeTransferSheet?

	/// Set while the configuration window is on screen.
	var isShowing   = false
}
