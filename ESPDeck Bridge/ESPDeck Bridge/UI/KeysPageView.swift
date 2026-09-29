//
//  KeysPageView.swift
//  ESPDeck Bridge
//
//  The Keys page: the simulated deck beside the selected key's inspector, with a divider
//  to drag between them. The deck is sized to fit its pane unless zoomed, with the bar under
//  it, by pinching on a trackpad, or with View ▸ Zoom In / Zoom Out / Size to Fit.
//

import SwiftUI

struct KeysPageView: View {
	let controller         : DeckController
	let deviceID           : String
	@Binding var selection : Int

	/// The deck pane's width, set by dragging the divider.
	@AppStorage( "keysPreviewWidth" ) private var previewWidth: Double = 580

	@State private var dragStartWidth : Double?
	@State private var pinchStartSize : CGFloat?
	@State private var confirmingDeletePage = false

	private static let minPreviewWidth   : CGFloat = 300
	private static let minInspectorWidth : CGFloat = 380
	/// Around the deck and the controls under it, inside the scroll view.
	private static let contentPadding    : CGFloat = 24
	/// The divider's grab area, centred on its line.
	private static let handleWidth       : CGFloat = 14
	private static let keySizes          = DeckGridView.minKeySize...DeckGridView.fullKeySize

	private var window: WindowState { controller.window }

	var body: some View {
		GeometryReader { geometry in
			let width = previewPaneWidth( total: geometry.size.width )
			HStack( spacing: 0 ) {
				previewPane
					.frame( width: width )
				Divider()
				KeyInspectorView( controller: controller, deviceID: deviceID, key: selection )
					.frame( maxWidth: .infinity, maxHeight: .infinity )
			}
			// Above both panes, so neither takes the clicks meant for it.
			.overlay( alignment: .topLeading ) {
				Color.clear
					.frame( width: Self.handleWidth )
					.frame( maxHeight: .infinity )
					.contentShape( Rectangle() )
					.offset( x: width - Self.handleWidth / 2 )
					.onContinuousHover { phase in
						switch phase {
							case .active: controller.macBridge?.setResizeCursor( true )
							case .ended:  if dragStartWidth == nil { controller.macBridge?.setResizeCursor( false ) }
						}
					}
					.gesture( resizeGesture( current: width, total: geometry.size.width ) )
					.accessibilityLabel( "Resize the deck preview" )
			}
		}
	}

	// MARK: - Deck pane

	private var previewPane: some View {
		VStack( spacing: 0 ) {
			pageBar
			Divider()

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
				.onChange( of: fittingKeySize( in: geometry.size ), initial: true ) { window.deckFitKeySize = $1 }
			}

			Divider()
			zoomBar
		}
	}

	/// Which page the deck shows (and this page edits), and adding or deleting one.
	private var pageBar: some View {
		let count   = controller.pageCount( device: deviceID )
		let current = controller.currentPage( device: deviceID )
		return HStack( spacing: 8 ) {
			Button {
				controller.showPage( device: deviceID, current - 1 )
			} label: {
				Image( systemName: "chevron.left" )
			}
			.buttonStyle( .borderless )
			.disabled( current == 0 )
			.help( "Previous page" )

			Text( "Page \(current + 1) of \(count)" )
				.monospacedDigit()

			Button {
				controller.showPage( device: deviceID, current + 1 )
			} label: {
				Image( systemName: "chevron.right" )
			}
			.buttonStyle( .borderless )
			.disabled( current + 1 >= count )
			.help( "Next page" )

			Spacer()

			Button( "Add Page", systemImage: "plus" ) { controller.addPage( device: deviceID ) }
				.help( "Add a page after this one. This page's lower-right key becomes Next Page, and what was there moves to the new page." )
			Button( "Delete Page…", systemImage: "trash", role: .destructive ) { confirmingDeletePage = true }
				.disabled( count <= 1 )
				.confirmationDialog( "Delete page \(current + 1)?", isPresented: $confirmingDeletePage ) {
					Button( "Delete Page", role: .destructive ) { controller.deletePage( device: deviceID ) }
				} message: {
					Text( "Its keys are removed. Edit ▸ Undo brings it back." )
				}
		}
		.labelStyle( .titleAndIcon )
		.controlSize( .small )
		.padding( .horizontal, 14 )
		.padding( .vertical, 8 )
	}

	/// Smallest and full size at either end of the slider; Size to Fit goes back to the
	/// largest keys that fit.
	private var zoomBar: some View {
		HStack( spacing: 6 ) {
			Button {
				window.zoomDeck( to: DeckGridView.minKeySize, range: Self.keySizes )
			} label: {
				Image( systemName: "square.grid.4x3.fill" )
					.imageScale( .small )
					.foregroundStyle( Color.secondary )
			}
			.buttonStyle( .borderless )
			.help( "Smallest keys" )

			Slider( value: sliderBinding, in: Self.keySizes )
				.frame( maxWidth: 180 )
				.accessibilityLabel( "Deck preview size" )

			Button {
				window.zoomDeck( to: DeckGridView.fullKeySize, range: Self.keySizes )
			} label: {
				Image( systemName: "square.grid.2x2.fill" )
					.imageScale( .medium )
					.foregroundStyle( Color.secondary )
			}
			.buttonStyle( .borderless )
			.help( "Full-size keys" )

			// On (tinted) while the deck follows the pane's size; turning it off keeps the
			// current size.
			Toggle( "Size to Fit", isOn: Binding {
				window.deckKeySize == 0
			} set: { fit in
				window.deckKeySize = fit ? 0 : Double( window.deckFitKeySize.rounded() )
			} )
			.toggleStyle( .button )
			.help( "Size the deck preview to fit this pane (⌘0)" )
			.padding( .leading, 6 )
		}
		.controlSize( .small )
		.padding( .horizontal, 14 )
		.padding( .vertical, 8 )
		.frame( maxWidth: .infinity )
	}

	// MARK: - Sizing

	/// The deck itself gets the space inside the scroll view's padding.
	private func fittingKeySize( in space: CGSize ) -> CGFloat {
		let inner = CGSize( width: space.width - 2 * Self.contentPadding, height: space.height - 2 * Self.contentPadding )
		return DeckGridView.fittingKeySize( for: controller.layout( deviceID ), in: inner )
	}

	private func keySize( in space: CGSize ) -> CGFloat {
		window.deckKeySize > 0 ? min( max( CGFloat( window.deckKeySize ), Self.keySizes.lowerBound ), Self.keySizes.upperBound ) : fittingKeySize( in: space )
	}

	/// The slider shows the current size, fitted or chosen; moving it chooses one.
	private var sliderBinding: Binding<CGFloat> {
		Binding {
			min( max( window.deckEffectiveKeySize, Self.keySizes.lowerBound ), Self.keySizes.upperBound )
		} set: { size in
			window.zoomDeck( to: size, range: Self.keySizes )
		}
	}

	/// Pinching zooms from the size at the start of the pinch; never past full size.
	private func pinchGesture( current: CGFloat ) -> some Gesture {
		MagnifyGesture()
			.onChanged { value in
				let start = pinchStartSize ?? current
				pinchStartSize = start
				window.zoomDeck( to: start * value.magnification, range: Self.keySizes )
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
				controller.macBridge?.setResizeCursor( true )
				let maxWidth   = max( Self.minPreviewWidth, total - Self.minInspectorWidth )
				previewWidth   = Double( min( max( CGFloat( start ) + value.translation.width, Self.minPreviewWidth ), maxWidth ) )
			}
			.onEnded { _ in
				dragStartWidth = nil
				controller.macBridge?.setResizeCursor( false )
			}
	}
}
