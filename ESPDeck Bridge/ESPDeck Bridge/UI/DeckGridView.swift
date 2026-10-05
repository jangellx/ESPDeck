//
//  DeckGridView.swift
//  ESPDeck Bridge
//
//  A simulated Stream Deck, laid out like the device's own model, showing the same
//  images as the physical deck.
//

import SwiftUI

/// The deck's keys in its model's rows and columns, on a dark rounded body.
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

	/// Between keys: closer on the wide models.
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
		// Read once here and handed to each key as its own image and flags: a key's view then
		// redraws only when what it shows changes, not whenever any key's does.
		let device  = controller.device( deviceID )
		let keys    = device?.keys ?? []
		let pressed = device?.pressed ?? []
		let change  = device?.pageChange

		Grid( horizontalSpacing: spacing, verticalSpacing: spacing ) {
			ForEach( 0..<layout.rows, id: \.self ) { row in
				GridRow {
					ForEach( 0..<layout.cols, id: \.self ) { column in
						let index   = row * layout.cols + column
						let changed = change.flatMap { index < $0.previews.count ? $0 : nil }
						DeckKeyView( controller: controller, deviceID: deviceID, index: index, size: size,
									 preview: index < keys.count ? keys[index]?.preview : nil,
									 pressed: pressed.contains( index ), selected: selection == index,
									 changedAt: changed?.at, oldPreview: changed?.previews[index], selection: $selection )
					}
				}
			}
		}
		.padding( Self.padding )
		.background( RoundedRectangle( cornerRadius: 26 ).fill( Color( white: 0.13 ) ) )
		.overlay( RoundedRectangle( cornerRadius: 26 ).strokeBorder( Color( white: 0.25 ), lineWidth: 1 ) )
	}
}

/// One key of the simulated deck: its image, selection and press highlights, and dragging
/// and dropping. A new page pops in a key at a time, as the deck's keys fill in over USB: each
/// key keeps the old page's image until its turn, then the new one fades up over it.
private struct DeckKeyView: View {
	let controller         : DeckController
	let deviceID           : String
	let index              : Int
	let size               : CGFloat
	/// What the key shows now; nil before it has been rendered.
	let preview            : UIImage?
	/// Held down on the deck, or shift-clicked here.
	let pressed            : Bool
	let selected           : Bool
	/// The last page change, and what this key showed before it.
	let changedAt          : Date?
	let oldPreview         : UIImage?
	/// Only written here (a click selects the key); `selected` says whether it is.
	@Binding var selection : Int
	@State private var isTargeted = false
	/// The page change this key has already swapped for.
	@State private var swappedFor: Date?

	/// The page this key's command goes to, if it's one that changes page, run as the deck would.
	private func goToPage() {
		let assignment = controller.assignment( deviceID, key: index )
		guard assignment.kind == .page,
			  [ .nextPage, .previousPage, .firstPage, .lastPage, .goToPage ].contains( assignment.action ) else { return }
		controller.performPage( assignment, device: deviceID )
	}

	var body: some View {
		let current  = preview
		// Only just after the change: a key that appears later (another page, back again) doesn't.
		let recent   = changedAt.flatMap { -$0.timeIntervalSinceNow < Double( index ) * DeckDevice.pagePopStep + 0.5 ? $0 : nil }
		let waiting  = recent.map { $0 != swappedFor } ?? false
		let radius   = size * 0.125

		// On its turn the new image fades up quickly over the old one.
		ZStack {
			if recent != nil, let old = oldPreview {
				Image( uiImage: old )
					.resizable()
					.interpolation( .high )
			}
			Group {
				if let current {
					Image( uiImage: current )
						.resizable()
						.interpolation( .high )
				} else {
					Color.black
				}
			}
			.opacity( waiting ? 0 : 1 )
			// Only the fade up: hiding it at the change is instant.
			.animation( waiting ? nil : .easeOut( duration: 0.15 ), value: waiting )
		}
		.frame( width: size, height: size )
		.clipShape( RoundedRectangle( cornerRadius: radius ) )
		.overlay {
			// Held on the physical deck: flash it here too.
			RoundedRectangle( cornerRadius: radius )
				.fill( Color.white.opacity( pressed ? 0.45 : 0 ) )
		}
		.keyOutline( cornerRadius: radius, pressed ? Color.white : isTargeted ? Color.accentColor : selected ? Color.accentColor.opacity( 0.9 ) : Color( white: 0.3 ),
					 lineWidth: pressed || isTargeted || selected ? 3 : 1 )
		.scaleEffect( pressed ? 0.94 : 1 )
		.animation( .easeOut( duration: 0.08 ), value: pressed )
		.contentShape( Rectangle() )
		.onTapGesture {
			// Leave any text field, so Cmd-C / Cmd-V go to the key instead of the text.
			ConfigurationHostingController.takeKeyboardFocus()
			selection = index
		}
		// Double-click a Next, Previous, First, Last or Go to Page key to go there, as pressing
		// it on the deck would. Alongside the click above, so selecting isn't delayed.
		.simultaneousGesture( TapGesture( count: 2 ).onEnded { goToPage() } )
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
			if let current {
				Image( uiImage: current )
					.resizable()
					.frame( width: size, height: size )
					.clipShape( RoundedRectangle( cornerRadius: radius ) )
			}
		}
		.dropDestination( for: DeckDrop.self ) { items, _ in
			switch items.first {
				case .key( let source ):
					guard source != index else { return false }
					controller.moveKey( device: deviceID, from: source, to: index )
					selection = index   // the selection follows the dragged key
				case .image( let image ):
					selection = index
					controller.setIcon( dropped: image, device: deviceID, key: index, state: .standard )
				case nil:
					return false
			}
			return true
		} isTargeted: { isTargeted = $0 }
		// Where it is in the window, for shift-click (ConfigurationHostingController).
		.onGeometryChange( for: CGRect.self ) { $0.frame( in: .global ) } action: { frame in
			controller.previewKeyFrames[index] = frame
			controller.previewDevice           = deviceID
		}
		.onDisappear { controller.previewKeyFrames[index] = nil }
		.task( id: changedAt ) {
			guard let at = changedAt else { return }
			let due = at.addingTimeInterval( Double( index ) * DeckDevice.pagePopStep )
			if due > Date() { try? await Task.sleep( for: .seconds( due.timeIntervalSinceNow ) ) }
			guard !Task.isCancelled else { return }
			swappedFor = at
		}
		.accessibilityLabel( "Key \(index + 1)" )
		.accessibilityAddTraits( selected ? [ .isButton, .isSelected ] : .isButton )
	}
}

extension View {
	/// A key's outline, drawn inside the edge of its rounded square; dashed with `dash`.
	func keyOutline( cornerRadius: CGFloat, _ color: Color, lineWidth: CGFloat, dash: [CGFloat] = [] ) -> some View {
		overlay {
			RoundedRectangle( cornerRadius: cornerRadius )
				.strokeBorder( color, style: StrokeStyle( lineWidth: lineWidth, dash: dash ) )
		}
	}
}
