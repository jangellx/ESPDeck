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
	@State private var deletingPage: Int?

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
						Text( "Shift-click a key to run it, as if pressed on the deck; hold a Level key to keep stepping." )
							.font( .caption )
							.foregroundStyle( Color.secondary )
							.multilineTextAlignment( .center )
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

	/// "Page ① ② ③ +", as in Elgato's software: the deck shows (and this page edits) the
	/// highlighted one. Right-click a page to delete it.
	private var pageBar: some View {
		let count   = controller.pageCount( device: deviceID )
		let current = controller.currentPage( device: deviceID )
		return HStack( spacing: 6 ) {
			Text( "Page" )
				.foregroundStyle( Color.secondary )
			ScrollView( .horizontal, showsIndicators: false ) {
				HStack( spacing: 6 ) {
					ForEach( 0..<count, id: \.self ) { page in
						pageButton( page, current: current, pills: count >= 10 )
					}
					Button {
						controller.addPage( device: deviceID )
					} label: {
						Image( systemName: "plus" )
							.frame( width: 22, height: 22 )
							.background( Circle().strokeBorder( Color.secondary.opacity( 0.5 ), lineWidth: 1 ) )
							.contentShape( Circle() )
					}
					.buttonStyle( .plain )
					.help( "Add a page after this one. This page's lower-right key becomes Next Page, and what was there moves to the new page." )
				}
				.padding( .vertical, 1 )
			}
			Spacer( minLength: 0 )
			Button {
				requestDelete( current )
			} label: {
				Image( systemName: "trash" )
			}
			.buttonStyle( .borderless )
			.disabled( count <= 1 )
			.help( "Delete this page" )
		}
		.controlSize( .small )
		.padding( .horizontal, 14 )
		.padding( .vertical, 8 )
		.confirmationDialog( "Move Key \( ( controller.pendingLevelMove?.source ?? 0 ) + 1 ) Alone?",
							 isPresented: Binding( get: { controller.pendingLevelMove != nil }, set: { if !$0 { controller.pendingLevelMove = nil } } ),
							 titleVisibility: .visible ) {
			Button( "Move It and Clear Key \( ( controller.pendingLevelMove?.partner ?? 0 ) + 1 )", role: .destructive ) {
				if let move = controller.pendingLevelMove { controller.moveKeyClearingPartner( move ) }
				controller.pendingLevelMove = nil
			}
		} message: {
			Text( "It's a Level key paired with Key \( ( controller.pendingLevelMove?.partner ?? 0 ) + 1 ), which would land off the edge of the deck if they moved together." )
		}
		.confirmationDialog( "Confirm Delete Page", isPresented: Binding( get: { deletingPage != nil }, set: { if !$0 { deletingPage = nil } } ),
							 titleVisibility: .visible ) {
			Button( "Delete Page", role: .destructive ) {
				if let page = deletingPage { controller.deletePage( device: deviceID, page ) }
				deletingPage = nil
			}
		} message: {
			Text( "Are you sure you want to delete this page and all keys?" )
		}
	}

	/// A number in a circle (a pill from 10 pages); filled for the page shown.
	private func pageButton( _ page: Int, current: Int, pills: Bool ) -> some View {
		let selected = page == current
		return Button {
			controller.showPage( device: deviceID, page )
		} label: {
			Text( "\(page + 1)" )
				.font( .callout.weight( selected ? .semibold : .regular ) )
				.monospacedDigit()
				.foregroundStyle( selected ? Color.white : Color.primary )
				.frame( minWidth: 22, minHeight: 22 )
				.padding( .horizontal, pills ? 6 : 0 )
				.background( Capsule().fill( selected ? Color.accentColor : Color.clear ) )
				.overlay( Capsule().strokeBorder( selected ? Color.clear : Color.secondary.opacity( 0.5 ), lineWidth: 1 ) )
				.contentShape( Capsule() )
		}
		.buttonStyle( .plain )
		.help( "Page \(page + 1)" )
		.contextMenu {
			Button( "Delete Page \(page + 1)…", systemImage: "trash", role: .destructive ) { requestDelete( page ) }
				.disabled( controller.pageCount( device: deviceID ) <= 1 )
		}
	}

	/// Asks first unless the page has nothing on it but Next and Previous.
	private func requestDelete( _ page: Int ) {
		if controller.isPageEmpty( device: deviceID, page ) {
			controller.deletePage( device: deviceID, page )
		} else {
			deletingPage = page
		}
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
