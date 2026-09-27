//
//  DeckGridView.swift
//  ESPDeck Bridge
//
//  A simulated Stream Deck, laid out like the device's own model, showing the same
//  images as the physical deck.
//

import SwiftUI

struct DeckGridView: View {
	let controller         : DeckController
	let deviceID           : String
	@Binding var selection : Int

	/// The simulated deck fits this width; larger decks get smaller keys.
	private static let maxWidth: CGFloat = 520

	var body: some View {
		let layout  = controller.layout( deviceID )
		let spacing = layout.cols > 5 ? 10.0 : 14.0
		let size    = min( 96, ( Self.maxWidth - 44 - spacing * CGFloat( layout.cols - 1 ) ) / CGFloat( layout.cols ) )

		Grid( horizontalSpacing: spacing, verticalSpacing: spacing ) {
			ForEach( 0..<layout.rows, id: \.self ) { row in
				GridRow {
					ForEach( 0..<layout.cols, id: \.self ) { column in
						DeckKeyView( controller: controller, deviceID: deviceID, index: row * layout.cols + column, size: size, selection: $selection )
					}
				}
			}
		}
		.padding( 22 )
		.background( RoundedRectangle( cornerRadius: 26, style: .continuous ).fill( Color( white: 0.13 ) ) )
		.overlay( RoundedRectangle( cornerRadius: 26, style: .continuous ).strokeBorder( Color( white: 0.25 ), lineWidth: 1 ) )
	}
}

private struct DeckKeyView: View {
	let controller         : DeckController
	let deviceID           : String
	let index              : Int
	let size               : CGFloat
	@Binding var selection : Int
	@State private var isTargeted = false

	var body: some View {
		let device   = controller.device( deviceID )
		let selected = selection == index
		let pressed  = device?.pressed.contains( index ) ?? false
		let preview  = device.flatMap { index < $0.keys.count ? $0.keys[index]?.preview : nil }
		let radius   = size * 0.125

		Group {
			if let preview {
				Image( uiImage: preview )
					.resizable()
					.interpolation( .high )
			} else {
				Color.black
			}
		}
		.frame( width: size, height: size )
		.clipShape( RoundedRectangle( cornerRadius: radius, style: .continuous ) )
		.overlay {
			// Held on the physical deck: flash it here too.
			RoundedRectangle( cornerRadius: radius, style: .continuous )
				.fill( Color.white.opacity( pressed ? 0.45 : 0 ) )
		}
		.overlay {
			RoundedRectangle( cornerRadius: radius, style: .continuous )
				.strokeBorder( pressed ? Color.white : isTargeted ? Color.accentColor : selected ? Color.accentColor.opacity( 0.9 ) : Color( white: 0.3 ),
							   lineWidth: pressed || isTargeted || selected ? 3 : 1 )
		}
		.scaleEffect( pressed ? 0.94 : 1 )
		.animation( .easeOut( duration: 0.08 ), value: pressed )
		.contentShape( Rectangle() )
		.onTapGesture {
			// Leave any text field, so Cmd-C / Cmd-V go to the key instead of the text.
			ConfigurationHostingController.takeKeyboardFocus()
			selection = index
		}
		.contextMenu {
			Button( "Copy Key", systemImage: "doc.on.doc" ) { controller.copyKey( device: deviceID, key: index ) }
			Button( "Paste Key", systemImage: "doc.on.clipboard" ) {
				selection = index
				controller.pasteKey( device: deviceID, key: index )
			}
			.disabled( !controller.clipboardHasKey )
			Divider()
			Button( "Clear Key", systemImage: "trash", role: .destructive ) { controller.clear( device: deviceID, key: index ) }
		}
		.draggable( KeyDrag( index: index ) ) {
			if let preview {
				Image( uiImage: preview )
					.resizable()
					.frame( width: size, height: size )
					.clipShape( RoundedRectangle( cornerRadius: radius, style: .continuous ) )
			}
		}
		.dropDestination( for: DeckDrop.self ) { items, _ in
			switch items.first {
				case .key( let source ):
					guard source != index else { return false }
					controller.swapKeys( device: deviceID, source, index )
					selection = index   // the selection follows the dragged key
				case .image( let data ):
					selection = index
					controller.setIcon( data: data, device: deviceID, key: index, state: .standard )
				case nil:
					return false
			}
			return true
		} isTargeted: { isTargeted = $0 }
		.accessibilityLabel( "Key \(index + 1)" )
		.accessibilityAddTraits( selected ? [ .isButton, .isSelected ] : .isButton )
	}
}
