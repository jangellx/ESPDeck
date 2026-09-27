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
	let isCurrent     : Bool
	let onDrop        : ( Data ) -> Void
	let onPickSymbol  : ( String ) -> Void
	let onRemove      : () -> Void

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
					SymbolPicker( current: customSymbol ) { name in
						onPickSymbol( name )
						showingSymbols = false
					}
				}
				.dropDestination( for: DroppedImage.self ) { items, _ in
					guard let item = items.first else { return false }
					onDrop( item.data )
					return true
				} isTargeted: { isTargeted = $0 }
				.contextMenu {
					Button( "Choose Symbol…" ) { showingSymbols = true }
					if hasCustomIcon {
						Button( "Remove Icon", role: .destructive, action: onRemove )
					}
				}

			HStack( spacing: 4 ) {
				if isCurrent {
					Circle().fill( Color.accentColor ).frame( width: 6, height: 6 )
				}
				Text( title )
					.font( .caption )
					.foregroundStyle( isCurrent ? .primary : .secondary )
			}
		}
		.help( "Click to choose an SF Symbol, or drag an image here" )
	}
}
