//
//  DeckController+Clipboard.swift
//  ESPDeck Bridge
//
//  Copying and pasting single keys, or one press of a key (its tap, double tap or hold), on
//  the same device or between devices. The
//  clipboard carries the whole assignment with its dropped images embedded, so a paste
//  works even after the source key's image files are gone, plus a PNG of the key for
//  pasting into other apps.
//

import UIKit
import UniformTypeIdentifiers

/// What the clipboard holds for a copied key.
private struct KeyClipboard: Codable {
	var assignment : KeyAssignment
	/// Dropped image files the assignment refers to, by their file name.
	var images     : [String: Data]
	/// The menus the key opens, with their keys; nil from a version before menus.
	var menus      : [DeckMenu]?
}

/// What the clipboard holds for one copied press of a key (its tap, double tap or hold).
private struct PressClipboard: Codable {
	/// What the press does, as an assignment; a tap's has the key's look too.
	var assignment : KeyAssignment
	/// Copied from a tap, so the label, background and icons are part of it.
	var hasLook    : Bool
	/// Dropped image files the assignment and its menu refer to, by their file name.
	var images     : [String: Data]
	/// The menu the press opens, if it opens one.
	var menus      : [DeckMenu]
}

extension UTType {
	/// A copied key, on the clipboard (KeyClipboard's JSON).
	nonisolated static let deckKeyAssignment = UTType( exportedAs: "com.tmproductions.espdeck.key-assignment" )
	/// One copied press of a key, on the clipboard (PressClipboard's JSON).
	nonisolated static let deckKeyPress = UTType( exportedAs: "com.tmproductions.espdeck.key-press" )
}

extension DeckController {
	/// The Log page's selected entries, oldest first, while that page is showing.
	var selectedLogEntries: [TrafficEntry] {
		guard window.isShowing, window.page == .log, !window.logSelection.isEmpty,
			  let device = window.selection.flatMap( device ) else { return [] }
		return device.log.filter { window.logSelection.contains( $0.id ) }
	}

	/// Puts log entries on the clipboard as text.
	func copyLogEntries( _ entries: some Sequence<TrafficEntry> ) {
		UIPasteboard.general.string = TrafficEntry.plainText( entries )
	}

	/// Puts a key on the clipboard: its assignment with its images and the menus it opens, and
	/// a PNG of how it looks.
	func copyKey( device id: String, key: Int ) {
		let assignment = assignment( id, key: key )
		guard !assignment.isMenuClose else { return }   // not a key of its own

		let menus = menus( opened: assignment, device: id )
		guard let data = try? JSONEncoder().encode( KeyClipboard( assignment: assignment, images: images( of: [ assignment ] + menus.flatMap( \.keys ) ), menus: menus ) ) else { return }

		var item: [String: Any] = [ UTType.deckKeyAssignment.identifier: data ]
		if let device = device( id ), key < device.keys.count, let png = device.keys[key]?.preview.pngData() {
			item[UTType.png.identifier] = png
		}
		UIPasteboard.general.setItems( [ item ] )
		refreshClipboard()
	}

	/// Replaces a key with the copied one. Its images are imported afresh and its menus are
	/// copied, so the two keys don't share files or menus.
	func pasteKey( device id: String, key: Int ) {
		guard let data = UIPasteboard.general.data( forPasteboardType: UTType.deckKeyAssignment.identifier ),
			  let clipboard = try? JSONDecoder().decode( KeyClipboard.self, from: data ) else {
			lastError = BridgeProblem( "Nothing to Paste", "There's no copied key to paste." )
			return
		}

		// Under the key's own run of edits, so the update below doesn't add a second step.
		recordUndo( device: id, "Paste Key", coalesce: Self.keyTag( device: id, key: key ) )
		var assignment = clipboard.assignment
		assignment.slider = nil   // half of a pair pastes as an ordinary key
		adopt( &assignment, images: clipboard.images, menus: clipboard.menus ?? [], device: id )
		update( device: id, key: key ) { $0 = assignment }
		config.removeUnusedIcons()
	}

	// MARK: - One press

	/// What a press of a key does, as an assignment on its own: the tap with the key's look
	/// (its label, background and icons, which are the tap's), a double tap or hold without.
	/// Nil when the press does nothing (and, for a tap, shows nothing), and for Level keys,
	/// whose presses come as a pair.
	func pressContents( device id: String, key: Int, _ kind: PressKind ) -> KeyAssignment? {
		let assignment = assignment( id, key: key )
		guard !assignment.isMenuClose, assignment.slider == nil else { return nil }
		guard kind == .tap else { return assignment.press( kind )?.assignment }
		var tap       = assignment
		tap.doubleTap = nil
		tap.hold      = nil
		return tap.isEmpty ? nil : tap
	}

	/// Puts one press of a key on the clipboard, with its images and the menu it opens.
	func copyPress( device id: String, key: Int, _ kind: PressKind ) {
		guard let press = pressContents( device: id, key: key, kind ) else { return }
		let menus = menus( opened: press, device: id )
		let copy  = PressClipboard( assignment: press, hasLook: kind == .tap, images: images( of: [ press ] + menus.flatMap( \.keys ) ), menus: menus )
		guard let data = try? JSONEncoder().encode( copy ) else { return }
		UIPasteboard.general.setItems( [ [ UTType.deckKeyPress.identifier: data ] ] )
		refreshClipboard()
	}

	/// Makes a press of a key do what the copied press does, leaving the key's other presses
	/// alone. The look comes along only from a tap onto a tap: a double tap or hold has none,
	/// and pasting onto one mustn't change how the key looks.
	func pastePress( device id: String, key: Int, _ kind: PressKind ) {
		guard let data = UIPasteboard.general.data( forPasteboardType: UTType.deckKeyPress.identifier ),
			  let clipboard = try? JSONDecoder().decode( PressClipboard.self, from: data ) else {
			lastError = BridgeProblem( "Nothing to Paste", "There's no copied action to paste." )
			return
		}
		let before = assignment( id, key: key )
		guard !before.isMenuClose, before.slider == nil else { return }
		if clipboard.assignment.kind == .menu && openMenu( device: id ) != nil {
			lastError = BridgeProblem( "Action Not Pasted", "The copied action opens a menu, and a menu's keys can't open another menu." )
			return
		}

		recordUndo( device: id, "Paste Action", coalesce: Self.keyTag( device: id, key: key ) )
		var pasted = clipboard.assignment
		adopt( &pasted, images: clipboard.images, menus: clipboard.menus, device: id )
		update( device: id, key: key ) { assignment in
			switch kind {
				case .tap:
					var tap       = pasted
					tap.doubleTap = assignment.doubleTap
					tap.hold      = assignment.hold
					if !clipboard.hasLook {
						tap.label           = assignment.label
						tap.showLabel       = assignment.showLabel
						tap.backgroundColor = assignment.backgroundColor
						tap.icons           = assignment.icons
						tap.singleIcon      = assignment.singleIcon
					}
					assignment = tap
				case .doubleTap:
					assignment.doubleTap = PressAction( pasted )
				case .hold:
					assignment.hold = PressAction( pasted )
			}
		}
		config.removeUnusedIcons()
	}

	// MARK: - What travels with a key

	/// The menus an assignment's presses open, as they are now.
	private func menus( opened assignment: KeyAssignment, device id: String ) -> [DeckMenu] {
		let all = settings( id )?.menus ?? []
		return assignment.menuIDs.compactMap { id in all.first { $0.id == id } }
	}

	/// The dropped image files `keys` refer to, by their file name.
	private func images( of keys: [KeyAssignment] ) -> [String: Data] {
		var images: [String: Data] = [:]
		for name in keys.flatMap( \.icons.values ) where !name.hasPrefix( KeyAssignment.symbolPrefix ) && images[name] == nil {
			images[name] = config.icon( named: name )?.pngData()
		}
		return images
	}

	/// Makes a pasted assignment this device's own: its images imported afresh, and each menu
	/// it opens added to the device as a copy with its own ID (so the pasted key and the one
	/// it was copied from don't edit each other's menu). Pasted into a menu, its menu presses
	/// are dropped, since a menu's keys don't open menus.
	private func adopt( _ assignment: inout KeyAssignment, images: [String: Data], menus: [DeckMenu], device id: String ) {
		guard let index = config.settings.deviceIndex( id ) else { return }
		// One imported file per copied image, however many keys show it.
		var imported: [String: String] = [:]
		func adoptIcons( _ key: inout KeyAssignment ) {
			for ( state, name ) in key.icons where !name.hasPrefix( KeyAssignment.symbolPrefix ) {
				if imported[name] == nil { imported[name] = images[name].flatMap { config.importIcon( $0 ) } }
				key.icons[state] = imported[name]
			}
		}
		adoptIcons( &assignment )

		let intoMenu = config.settings.devices[index].openMenu != nil
		func adoptMenu( _ id: UUID? ) -> UUID? {
			guard !intoMenu else { return nil }
			var menu = menus.first { $0.id == id } ?? DeckMenu()   // an empty one, from an older copy
			menu.id  = UUID()
			for key in menu.keys.indices {
				adoptIcons( &menu.keys[key] )
				// No menus inside menus, whatever was copied.
				if menu.keys[key].kind == .menu { menu.keys[key].bind( to: nil ) }
				if menu.keys[key].doubleTap?.kind == .menu { menu.keys[key].doubleTap = nil }
				if menu.keys[key].hold?.kind == .menu { menu.keys[key].hold = nil }
			}
			config.settings.devices[index].menus.append( menu )
			return menu.id
		}
		if assignment.kind == .menu {
			if let menu = adoptMenu( assignment.menuID ) { assignment.menuID = menu } else { assignment.bind( to: nil ) }
		}
		if assignment.doubleTap?.kind == .menu {
			if let menu = adoptMenu( assignment.doubleTap?.menuID ) { assignment.doubleTap?.menuID = menu } else { assignment.doubleTap = nil }
		}
		if assignment.hold?.kind == .menu {
			if let menu = adoptMenu( assignment.hold?.menuID ) { assignment.hold?.menuID = menu } else { assignment.hold = nil }
		}
	}

	/// Keeps `clipboardHasKey` and `clipboardHasPress` current; call when the pasteboard may have changed.
	func refreshClipboard() {
		clipboardHasKey   = UIPasteboard.general.contains( pasteboardTypes: [ UTType.deckKeyAssignment.identifier ] )
		clipboardHasPress = UIPasteboard.general.contains( pasteboardTypes: [ UTType.deckKeyPress.identifier ] )
	}
}
