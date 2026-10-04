//
//  DeckController+Clipboard.swift
//  ESPDeck Bridge
//
//  Copying and pasting single keys, on the same device or between devices. The
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
}

extension UTType {
	/// A copied key, on the clipboard (KeyClipboard's JSON).
	nonisolated static let deckKeyAssignment = UTType( exportedAs: "com.tmproductions.espdeck.key-assignment" )
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

	/// Puts a key on the clipboard: its assignment with its images, and a PNG of how it looks.
	func copyKey( device id: String, key: Int ) {
		let assignment = assignment( id, key: key )

		var images: [String: Data] = [:]
		for name in assignment.icons.values where !name.hasPrefix( KeyAssignment.symbolPrefix ) {
			images[name] = config.icon( named: name )?.pngData()
		}
		guard let data = try? JSONEncoder().encode( KeyClipboard( assignment: assignment, images: images ) ) else { return }

		var item: [String: Any] = [ UTType.deckKeyAssignment.identifier: data ]
		if let device = device( id ), key < device.keys.count, let png = device.keys[key]?.preview.pngData() {
			item[UTType.png.identifier] = png
		}
		UIPasteboard.general.setItems( [ item ] )
		refreshClipboard()
	}

	/// Replaces a key with the copied one. Its images are imported afresh, so the two
	/// keys don't share files.
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
		for ( state, name ) in assignment.icons where !name.hasPrefix( KeyAssignment.symbolPrefix ) {
			assignment.icons[state] = clipboard.images[name].flatMap { config.importIcon( $0 ) }
		}
		update( device: id, key: key ) { $0 = assignment }
		config.removeUnusedIcons()
	}

	/// Keeps `clipboardHasKey` current; call when the pasteboard may have changed.
	func refreshClipboard() {
		clipboardHasKey = UIPasteboard.general.contains( pasteboardTypes: [ UTType.deckKeyAssignment.identifier ] )
	}
}
