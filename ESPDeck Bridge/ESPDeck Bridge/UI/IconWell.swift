//
//  IconWell.swift
//  ESPDeck Bridge
//
//  One state's icon: a preview of the key in that state that accepts dropped images,
//  and opens an SF Symbol picker when clicked.
//

import SwiftUI

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

	private var removeTitle: String { "Remove \(title) Icon" }

	@State private var isTargeted     = false
	@State private var showingSymbols = false

	private static let size: CGFloat = 64

	var body: some View {
		VStack( spacing: 6 ) {
			KeyFaceView( face: face, icon: icon )
				.scaleEffect( Self.size / CGFloat( deckKeyPixels ) )
				.frame( width: Self.size, height: Self.size )
				.clipShape( RoundedRectangle( cornerRadius: 10, style: .continuous ) )
				.overlay {
					RoundedRectangle( cornerRadius: 10, style: .continuous )
						.strokeBorder( isTargeted ? Color.accentColor : Color( white: 0.35 ),
									   style: StrokeStyle( lineWidth: isTargeted ? 3 : 1, dash: hasCustomIcon ? [] : [ 4 ] ) )
				}
				.contentShape( Rectangle() )
				.onTapGesture { showingSymbols = true }
				.popover( isPresented: $showingSymbols ) {
					SymbolPicker( current: customSymbol, removeTitle: removeTitle, canRemove: hasCustomIcon ) { name in
						onPickSymbol( name )
						showingSymbols = false
					} onRemove: {
						onRemove()
						showingSymbols = false
					}
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
					Button( removeTitle, role: .destructive, action: onRemove )
						.disabled( !hasCustomIcon )
				}

			Text( title )
				.font( .caption )
				.foregroundStyle( .secondary )
		}
		.help( "Click to choose an SF Symbol, or drag an image here" )
	}
}
