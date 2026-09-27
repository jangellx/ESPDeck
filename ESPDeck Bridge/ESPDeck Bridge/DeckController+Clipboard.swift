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
	nonisolated static let deckKeyAssignment = UTType( exportedAs: "com.tmproductions.espdeck.key-assignment" )
}

extension DeckController {
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
			lastError = "There's no copied key to paste."
			return
		}

		var assignment = clipboard.assignment
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
