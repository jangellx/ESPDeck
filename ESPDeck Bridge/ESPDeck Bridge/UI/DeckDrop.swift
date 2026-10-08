//
//  DeckDrop.swift
//  ESPDeck Bridge
//
//  Things that can be dropped on a key in the simulated deck: another key (to swap
//  assignments) or an image (to set its Default icon).
//

import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
	/// Declared in Info.plist under UTExportedTypeDeclarations.
	nonisolated static let deckKey = UTType( exportedAs: "com.tmproductions.espdeck.key" )
}

/// A key being dragged within the simulated deck.
struct KeyDrag: Codable, Transferable {
	let index: Int

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation( contentType: .deckKey )
	}
}

/// What was dropped on a key: another key, or an image.
enum DeckDrop: Transferable {
	case key( Int )
	case image( DroppedImage )

	static var transferRepresentation: some TransferRepresentation {
		// Keys first, so a key dragged within the deck is never read as an image.
		ProxyRepresentation { ( drag: KeyDrag ) in DeckDrop.key( drag.index ) }
		ProxyRepresentation { ( image: DroppedImage ) in DeckDrop.image( image ) }
	}
}
