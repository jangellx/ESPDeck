//
//  DeckDrop.swift
//  ESPDeck Bridge
//
//  Things that can be dropped on a key in the simulated deck: another key (to swap
//  assignments), a color (its background) or an image (to set its Default icon).
//

import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
	/// Declared in Info.plist under UTExportedTypeDeclarations.
	nonisolated static let deckKey = UTType( exportedAs: "com.tmproductions.espdeck.key" )
	/// What the Mac's Colors panel and color wells put on a drag: an archived NSColor. It's
	/// AppKit's type, which Catalyst doesn't turn into a color (a drop of `Color` is refused),
	/// so the menu bar bundle reads it (DeckMenuBarPlugin.draggedColor).
	nonisolated static let appKitColor = UTType( importedAs: "com.apple.cocoa.pasteboard.color" )
}

/// A key being dragged within the simulated deck.
struct KeyDrag: Codable, Transferable {
	let index: Int

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation( contentType: .deckKey )
	}
}

/// What was dropped on a key: another key, a color, or an image.
enum DeckDrop: Transferable {
	case key( Int )
	case color( Color )
	/// A color from the Mac's Colors panel or a color well: UTType.appKitColor's data.
	case appKitColor( Data )
	case image( DroppedImage )

	static var transferRepresentation: some TransferRepresentation {
		// Keys first, so a key dragged within the deck is never read as an image.
		ProxyRepresentation { ( drag: KeyDrag ) in DeckDrop.key( drag.index ) }
		// A color before images: a swatch dragged from the color panel or a color well.
		DataRepresentation( importedContentType: .appKitColor ) { data in DeckDrop.appKitColor( data ) }
		ProxyRepresentation { ( color: Color ) in DeckDrop.color( color ) }
		ProxyRepresentation { ( image: DroppedImage ) in DeckDrop.image( image ) }
	}
}
