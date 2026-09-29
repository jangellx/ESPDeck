//
//  KeysPageView.swift
//  ESPDeck Bridge
//
//  The Keys page: the simulated deck beside the selected key's inspector, with a divider
//  to drag between them. The deck is sized to fit its pane unless zoomed out, with the
//  slider under it or by pinching on a trackpad.
//

import SwiftUI

struct KeysPageView: View {
	let controller         : DeckController
	let deviceID           : String
	@Binding var selection : Int

	/// The deck pane's width, set by dragging the divider.
	@AppStorage( "keysPreviewWidth" ) private var previewWidth: Double = 580
	/// The key size chosen with the slider or a pinch, or 0 to size the deck to fit.
	@AppStorage( "keysKeySize" ) private var chosenKeySize: Double = 0

	@State private var dragStartWidth : Double?
	@State private var pinchStartSize : CGFloat?

	private static let minPreviewWidth   : CGFloat = 300
	private static let minInspectorWidth : CGFloat = 380
	/// Around the deck and the controls under it, inside the scroll view.
	private static let contentPadding    : CGFloat = 24

	var body: some View {
		GeometryReader { geometry in
			let width = previewPaneWidth( total: geometry.size.width )
			HStack( spacing: 0 ) {
				previewPane
					.frame( width: width )

				Divider()
					.overlay {
						// Wider than the line, so it's easy to grab.
						Color.clear
							.frame( width: 10 )
							.contentShape( Rectangle() )
							.gesture( resizeGesture( current: width, total: geometry.size.width ) )
							.accessibilityLabel( "Resize the deck preview" )
					}

				KeyInspectorView( controller: controller, deviceID: deviceID, key: selection )
					.frame( maxWidth: .infinity, maxHeight: .infinity )
			}
		}
	}

	// MARK: - Deck pane

	private var previewPane: some View {
		VStack( spacing: 0 ) {
			GeometryReader { geometry in
				let keySize = keySize( in: geometry.size )
				ScrollView( [ .vertical, .horizontal ] ) {
					VStack( spacing: 14 ) {
						DeckGridView( controller: controller, deviceID: deviceID, keySize: keySize, selection: $selection )
						LabelPositionControl( controller: controller, deviceID: deviceID )
						if let device = controller.device( deviceID ), controller.settings( deviceID )?.isDemo != true {
							TransferStatusView( device: device )
								.frame( maxWidth: 520 )
						}
					}
					.padding( Self.contentPadding )
					.frame( minWidth: geometry.size.width )   // centred while it's narrower
				}
				.simultaneousGesture( pinchGesture( current: keySize ) )
				.onChange( of: fittingKeySize( in: geometry.size ), initial: true ) { currentFit = $1 }
			}

			Divider()
			zoomBar
		}
	}

	/// Zoom out with the slider; Size to Fit goes back to the largest keys that fit.
	private var zoomBar: some View {
		HStack( spacing: 8 ) {
			Image( systemName: "square.grid.4x3.fill" )
				.imageScale( .small )
				.foregroundStyle( Color.secondary )
			Slider( value: sliderBinding, in: DeckGridView.minKeySize...DeckGridView.fullKeySize )
				.frame( maxWidth: 180 )
				.accessibilityLabel( "Deck preview size" )
			Image( systemName: "square.grid.2x2.fill" )
				.imageScale( .medium )
				.foregroundStyle( Color.secondary )
			Button( "Size to Fit" ) { chosenKeySize = 0 }
				.disabled( chosenKeySize == 0 )
				.help( "Size the deck preview to fit this pane" )
		}
		.controlSize( .small )
		.padding( .horizontal, 14 )
		.padding( .vertical, 8 )
		.frame( maxWidth: .infinity )
	}

	// MARK: - Sizing

	/// The space the deck itself can have is inside the scroll view's padding.
	private func fittingKeySize( in space: CGSize ) -> CGFloat {
		let inner = CGSize( width: space.width - 2 * Self.contentPadding, height: space.height - 2 * Self.contentPadding )
		return DeckGridView.fittingKeySize( for: controller.layout( deviceID ), in: inner )
	}

	private func keySize( in space: CGSize ) -> CGFloat {
		chosenKeySize > 0 ? Self.clamp( CGFloat( chosenKeySize ) ) : fittingKeySize( in: space )
	}

	/// The slider shows the current size, fitted or chosen; moving it chooses one.
	private var sliderBinding: Binding<CGFloat> {
		Binding {
			chosenKeySize > 0 ? Self.clamp( CGFloat( chosenKeySize ) ) : currentFit
		} set: { size in
			chosenKeySize = Double( Self.clamp( size ).rounded() )
		}
	}

	/// The fitted size, for the slider (which sits outside the deck's GeometryReader).
	@State private var currentFit: CGFloat = DeckGridView.fullKeySize

	private static func clamp( _ size: CGFloat ) -> CGFloat {
		min( max( size, DeckGridView.minKeySize ), DeckGridView.fullKeySize )
	}

	/// Pinching zooms from the size at the start of the pinch; never past full size.
	private func pinchGesture( current: CGFloat ) -> some Gesture {
		MagnifyGesture()
			.onChanged { value in
				let start = pinchStartSize ?? current
				pinchStartSize = start
				chosenKeySize  = Double( Self.clamp( start * value.magnification ).rounded() )
			}
			.onEnded { _ in pinchStartSize = nil }
	}

	// MARK: - Divider

	private func previewPaneWidth( total: CGFloat ) -> CGFloat {
		let maxWidth = max( Self.minPreviewWidth, total - Self.minInspectorWidth )
		return min( max( CGFloat( previewWidth ), Self.minPreviewWidth ), maxWidth )
	}

	private func resizeGesture( current: CGFloat, total: CGFloat ) -> some Gesture {
		DragGesture( minimumDistance: 1, coordinateSpace: .global )
			.onChanged { value in
				let start = dragStartWidth ?? Double( current )
				dragStartWidth = start
				let maxWidth   = max( Self.minPreviewWidth, total - Self.minInspectorWidth )
				previewWidth   = Double( min( max( CGFloat( start ) + value.translation.width, Self.minPreviewWidth ), maxWidth ) )
			}
			.onEnded { _ in dragStartWidth = nil }
	}
}
