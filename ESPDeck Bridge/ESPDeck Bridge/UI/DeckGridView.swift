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
	/// Each key's side; see fittingKeySize(for:in:).
	let keySize            : CGFloat
	@Binding var selection : Int

	/// Keys at full size, and the smallest they get when zoomed out.
	static let fullKeySize : CGFloat = 96
	static let minKeySize  : CGFloat = 24
	private static let padding: CGFloat = 22

	private static func spacing( _ layout: DeckLayout ) -> CGFloat {
		layout.cols > 5 ? 10 : 14
	}

	/// The largest key size (up to full size) at which the whole deck fits in `space`.
	static func fittingKeySize( for layout: DeckLayout, in space: CGSize ) -> CGFloat {
		let spacing = spacing( layout )
		let cols    = CGFloat( max( layout.cols, 1 ) )
		let rows    = CGFloat( max( layout.rows, 1 ) )
		let across  = ( space.width  - 2 * padding - spacing * ( cols - 1 ) ) / cols
		let down    = ( space.height - 2 * padding - spacing * ( rows - 1 ) ) / rows
		return max( minKeySize, min( fullKeySize, across, down ) ).rounded( .down )
	}

	var body: some View {
		let layout  = controller.layout( deviceID )
		let spacing = Self.spacing( layout )
		let size    = keySize

		Grid( horizontalSpacing: spacing, verticalSpacing: spacing ) {
			ForEach( 0..<layout.rows, id: \.self ) { row in
				GridRow {
					ForEach( 0..<layout.cols, id: \.self ) { column in
						DeckKeyView( controller: controller, deviceID: deviceID, index: row * layout.cols + column, size: size, selection: $selection )
					}
				}
			}
		}
		.padding( Self.padding )
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
				case .image( let image ):
					selection = index
					controller.setIcon( dropped: image, device: deviceID, key: index, state: .standard )
				case nil:
					return false
			}
			return true
		} isTargeted: { isTargeted = $0 }
		.accessibilityLabel( "Key \(index + 1)" )
		.accessibilityAddTraits( selected ? [ .isButton, .isSelected ] : .isButton )
	}
}
