//
//  IconWell.swift
//  ESPDeck Bridge
//
//  One state's icon: a preview of the key in that state that accepts dropped images,
//  and opens an SF Symbol picker when clicked.
//

import SwiftUI
import UniformTypeIdentifiers

/// One state's icon well: its title under a preview that takes drops and opens the symbol
/// picker.
struct IconWell: View {
	let title         : String
	let face          : KeyFace
	let icon          : UIImage?
	/// The state has its own image or symbol (rather than Default's or the built-in one).
	let hasCustomIcon : Bool
	/// The state's own symbol, if it has one; highlighted in the picker.
	let customSymbol  : String?
	let onDrop        : ( DroppedImage ) -> Void
	let onPickSymbol  : ( String ) -> Void
	let onRemove      : () -> Void
	/// Offered first in the symbol picker.
	var suggested     : [String] = []

	private var removeTitle: String { "Remove \(title) Icon" }

	@State private var isTargeted     = false
	@State private var showingSymbols = false
	/// The file picker from the context menu's Choose Image… (the symbol picker has its own).
	@State private var choosingImage  = false

	private static let size: CGFloat = 64

	var body: some View {
		VStack( spacing: 6 ) {
			// A button, so VoiceOver and the keyboard can reach it as one.
			Button {
				showingSymbols = true
			} label: {
				KeyFaceView( face: face, icon: icon )
					.scaleEffect( Self.size / CGFloat( deckKeyPixels ) )
					.frame( width: Self.size, height: Self.size )
					.clipShape( RoundedRectangle( cornerRadius: 10 ) )
					.keyOutline( cornerRadius: 10, isTargeted ? Color.accentColor : Color( white: 0.35 ),
								 lineWidth: isTargeted ? 3 : 1, dash: hasCustomIcon ? [] : [ 4 ] )
					.contentShape( Rectangle() )
			}
			.buttonStyle( .plain )
			.accessibilityLabel( "\(title) icon" )
			.popover( isPresented: $showingSymbols ) {
				SymbolPicker( current: customSymbol, removeTitle: removeTitle, canRemove: hasCustomIcon, onPick: { name in
					onPickSymbol( name )
					showingSymbols = false
				}, onPickImage: { image in
					onDrop( image )
					showingSymbols = false
				}, onRemove: {
					onRemove()
					showingSymbols = false
				}, suggested: suggested )
			}
			.dropDestination( for: DroppedImage.self ) { items, _ in
				guard let item = items.first else { return false }
				onDrop( item )
				return true
			} isTargeted: { isTargeted = $0 }
			.contextMenu {
				// Named for the state, and always listed but disabled when the state has no icon of
				// its own, so it can't appear to remove the Default icon a state is only borrowing.
				Button( "Choose Symbol…" ) { showingSymbols = true }
				Button( "Choose Image…" ) { choosingImage = true }
				Button( removeTitle, role: .destructive, action: onRemove )
					.disabled( !hasCustomIcon )
			}

			Text( title )
				.secondaryCaption()
		}
		.fileImporter( isPresented: $choosingImage, allowedContentTypes: [ .image ] ) { result in
			if case .success( let url ) = result { onDrop( .chosen( url ) ) }
		}
		.help( "Click to choose an SF Symbol, or drag an image here" )
	}
}
