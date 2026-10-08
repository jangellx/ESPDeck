//
//  KeysPageView.swift
//  ESPDeck Bridge
//
//  The Keys page: the simulated deck beside the selected key's inspector, or above it
//  (WindowState.keysLayout), with a divider to drag between them. The deck is sized to fit its pane unless zoomed, with the bar under
//  it, by pinching on a trackpad, or with View ▸ Zoom In / Zoom Out / Size to Fit.
//

import SwiftUI

/// The Keys page: the deck preview pane, a draggable divider, and the key inspector.
struct KeysPageView: View {
	let controller         : DeckController
	let deviceID           : String
	@Binding var selection : Int

	/// The deck pane's width beside the inspector, set by dragging the divider.
	@AppStorage( "keysPreviewWidth" ) private var previewWidth: Double = 580
	/// Its height above the inspector.
	@AppStorage( "keysPreviewHeight" ) private var previewHeight: Double = 420

	/// The pane's width or height when a drag of the divider began.
	@State private var dragStartExtent : Double?
	/// The layout on screen, while it differs from the one chosen: the inspector slides away
	/// in the old one before it slides back in the new one. nil otherwise.
	@State private var shownLayout     : WindowState.KeysLayout?
	/// The inspector is off the edge it slides to (the right, or the bottom), and the deck
	/// has the whole page.
	@State private var inspectorAway   = false
	@Environment( \.accessibilityReduceMotion ) private var reduceMotion
	@State private var pinchStartSize : CGFloat?
	/// A page with keys on it, waiting for Delete Page.
	@State private var deletingPage   : Int?

	private static let minPreviewWidth    : CGFloat = 300
	private static let minInspectorWidth  : CGFloat = 380
	/// Above the inspector: room for the bars, a small deck and the controls under it.
	private static let minPreviewHeight   : CGFloat = 320
	private static let minInspectorHeight : CGFloat = 200
	/// Around the deck and the controls under it, inside the scroll view.
	private static let contentPadding    : CGFloat = 24
	/// The divider's grab area, centered on its line.
	private static let handleWidth       : CGFloat = 14
	private static let keySizes          = DeckGridView.minKeySize...DeckGridView.fullKeySize

	private var window: WindowState { controller.window }

	/// The preview above the inspector, rather than beside it.
	private var stacked: Bool { ( shownLayout ?? window.keysLayout ) == .stacked }

	var body: some View {
		GeometryReader { geometry in
			// Along the way the panes are laid out: across, or down.
			let total     = stacked ? geometry.size.height : geometry.size.width
			let extent    = previewExtent( total: total )
			// The inspector keeps its size as it slides off; the deck grows into its place.
			let inspector = max( total - extent - 1, 0 )
			// One layout or the other around the same two panes, so switching keeps their state.
			let layout    = stacked ? AnyLayout( VStackLayout( spacing: 0 ) ) : AnyLayout( HStackLayout( spacing: 0 ) )
			layout {
				previewPane
					.frame( width: stacked ? nil : ( inspectorAway ? total : extent ), height: stacked ? ( inspectorAway ? total : extent ) : nil )
				Divider()
				KeyInspectorView( controller: controller, deviceID: deviceID, key: selection )
					.frame( width: stacked ? nil : inspector, height: stacked ? inspector : nil )
					.frame( maxWidth: .infinity, maxHeight: .infinity )
			}
			// Pinned to the page's corner and cut off at its edges, which is where the
			// inspector goes while it's away.
			.frame( width: geometry.size.width, height: geometry.size.height, alignment: .topLeading )
			.clipped()
			// Above both panes, so neither takes the clicks meant for it.
			.overlay( alignment: .topLeading ) {
				if !inspectorAway {
					Color.clear
						.frame( width: stacked ? nil : Self.handleWidth, height: stacked ? Self.handleWidth : nil )
						.frame( maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity )
						.contentShape( Rectangle() )
						.offset( x: stacked ? 0 : extent - Self.handleWidth / 2, y: stacked ? extent - Self.handleWidth / 2 : 0 )
						.onContinuousHover { phase in
							switch phase {
								case .active: setResizeCursor( true )
								case .ended:  if dragStartExtent == nil { setResizeCursor( false ) }
							}
						}
						.gesture( resizeGesture( current: extent, total: total ) )
						.accessibilityLabel( "Resize the deck preview" )
				}
			}
		}
		.onChange( of: window.keysLayout ) { old, _ in changeLayout( from: old ) }
	}

	/// How long the inspector takes to slide away, and to slide back, in seconds.
	private static let slideAway = 0.3
	private static let slideBack = 0.38
	/// Away: slow to start, fastest as it leaves. Back: fast as it arrives, slowing to a stop.
	/// Cubic curves, since SwiftUI's own easeIn and easeOut are gentle enough to look even
	/// over so short a move.
	private static let awayCurve = Animation.timingCurve( 0.32, 0, 0.67, 0, duration: slideAway )
	private static let backCurve = Animation.timingCurve( 0.33, 1, 0.68, 1, duration: slideBack )

	/// Another layout was chosen: the inspector slides off its edge in the old one, the panes
	/// are rearranged while only the deck shows, and it slides back in from its new edge.
	private func changeLayout( from old: WindowState.KeysLayout ) {
		guard !reduceMotion else {
			shownLayout   = nil
			inspectorAway = false
			return
		}
		// Midway through an earlier change, the layout on screen is the one to leave.
		shownLayout = shownLayout ?? old
		withAnimation( Self.awayCurve ) { inspectorAway = true }
		Task {
			try? await Task.sleep( for: .seconds( Self.slideAway ) )
			shownLayout = nil
			withAnimation( Self.backCurve ) { inspectorAway = false }
		}
	}

	// MARK: - Deck pane

	/// The page and zoom bars, the scrolling deck, and the controls fixed under it.
	private var previewPane: some View {
		VStack( spacing: 0 ) {
			pageBar
			// Zoom under the pages: the bar at the bottom holds the rest.
			zoomBar
				.padding( .horizontal, 14 )
				.padding( .bottom, 8 )
			Divider()

			GeometryReader { geometry in
				let keySize = keySize( in: geometry.size )
				ScrollView( [ .vertical, .horizontal ] ) {
					VStack( spacing: 14 ) {
						DeckGridView( controller: controller, deviceID: deviceID, keySize: keySize, selection: $selection )
					}
					.padding( Self.contentPadding )
					.frame( minWidth: geometry.size.width )   // centered while it's narrower
				}
				.simultaneousGesture( pinchGesture( current: keySize ) )
				.onChange( of: fittingKeySize( in: geometry.size ), initial: true ) { window.deckFitKeySize = $1 }
			}

			Divider()
			// Fixed under the deck, so they don't move when it scrolls or zooms.
			VStack( spacing: 8 ) {
				LabelPositionControl( controller: controller, deviceID: deviceID )
				Text( "Shift-click a key to press it, as on the deck: shift-double-click for its Double Tap, shift-hold for its Hold (a Level key keeps stepping)." )
					.secondaryCaption()
					.multilineTextAlignment( .center )
					.fixedSize( horizontal: false, vertical: true )
					.frame( maxWidth: .infinity )
			}
			.padding( .horizontal, 14 )
			.padding( .vertical, 10 )
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
			ScrollView( .horizontal ) {
				HStack( spacing: 6 ) {
					ForEach( 0..<count, id: \.self ) { page in
						pageButton( page, current: current, pills: count >= 10 )
					}
					Button {
						controller.addPage( device: deviceID )
					} label: {
						Image( systemName: "plus" )
							.scaledFrame( width: 22, height: 22 )
							.background( Circle().strokeBorder( .tertiary, lineWidth: 1 ) )
							.contentShape( Circle() )
					}
					.buttonStyle( .plain )
					.help( "Add a page after this one. This page's lower-right key becomes Next Page, and what was there moves to the new page." )
				}
				.padding( .vertical, 1 )
			}
			.scrollIndicators( .hidden )
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
							 isPresented: Binding( presenting: Bindable( controller ).pendingLevelMove ),
							 titleVisibility: .visible ) {
			Button( "Move It and Clear Key \( ( controller.pendingLevelMove?.partner ?? 0 ) + 1 )", role: .destructive ) {
				if let move = controller.pendingLevelMove { controller.moveKeyClearingPartner( move ) }
				controller.pendingLevelMove = nil
			}
		} message: {
			Text( "It's a Level key paired with Key \( ( controller.pendingLevelMove?.partner ?? 0 ) + 1 ), which would land off the edge of the deck if they moved together." )
		}
		.confirmationDialog( "Confirm Delete Page", isPresented: Binding( presenting: $deletingPage ), titleVisibility: .visible ) {
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
				.overlay( Capsule().strokeBorder( selected ? AnyShapeStyle( .clear ) : AnyShapeStyle( .tertiary ), lineWidth: 1 ) )
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
		HStack( spacing: 2 ) {   // the buttons' hover backgrounds add their own room
			Button {
				window.zoomDeck( to: DeckGridView.minKeySize, range: Self.keySizes )
			} label: {
				Image( systemName: "square.grid.4x3.fill" )
					.imageScale( .small )
					.foregroundStyle( Color.secondary )
			}
			.buttonStyle( HoverButtonStyle() )
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
			.buttonStyle( HoverButtonStyle() )
			.help( "Full-size keys" )

			// Blue while the deck follows the pane's size (a button-style Toggle doesn't tint on
			// Mac Catalyst); turning it off keeps the current size.
			let fitting = window.deckKeySize == 0
			Button( "Size to Fit" ) {
				window.deckKeySize = fitting ? Double( window.deckFitKeySize.rounded() ) : 0
			}
			.fittingButtonStyle( on: fitting )
			.help( fitting ? "The deck preview fits this pane; click to keep this size (⌘0)" : "Size the deck preview to fit this pane (⌘0)" )
			.accessibilityAddTraits( fitting ? .isSelected : [] )
			.padding( .leading, 6 )
		}
		.controlSize( .small )
		.frame( maxWidth: .infinity )
	}

	// MARK: - Sizing

	/// The deck itself gets the space inside the scroll view's padding.
	private func fittingKeySize( in space: CGSize ) -> CGFloat {
		let inner = CGSize( width: space.width - 2 * Self.contentPadding, height: space.height - 2 * Self.contentPadding )
		return DeckGridView.fittingKeySize( for: controller.layout( deviceID ), in: inner )
	}

	/// The chosen key size, within range, or the one that fits while sizing to fit.
	private func keySize( in space: CGSize ) -> CGFloat {
		window.deckKeySize > 0 ? Self.clamped( CGFloat( window.deckKeySize ) ) : fittingKeySize( in: space )
	}

	/// A key size within the range the preview offers.
	private static func clamped( _ size: CGFloat ) -> CGFloat {
		min( max( size, keySizes.lowerBound ), keySizes.upperBound )
	}

	/// The slider shows the current size, fitted or chosen; moving it chooses one.
	private var sliderBinding: Binding<CGFloat> {
		Binding {
			Self.clamped( window.deckEffectiveKeySize )
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

	/// The pointer for dragging the divider the way it moves in this layout.
	private func setResizeCursor( _ active: Bool ) {
		if stacked {
			controller.macBridge?.setRowResizeCursor( active )
		} else {
			controller.macBridge?.setResizeCursor( active )
		}
	}

	/// The deck pane's width (beside the inspector) or height (above it), as dragged, leaving
	/// the inspector its minimum.
	private func previewExtent( total: CGFloat ) -> CGFloat {
		clampedExtent( CGFloat( stacked ? previewHeight : previewWidth ), total: total )
	}

	/// `extent` within the deck pane's minimum and what leaves the inspector its own.
	private func clampedExtent( _ extent: CGFloat, total: CGFloat ) -> CGFloat {
		let minPreview   = stacked ? Self.minPreviewHeight : Self.minPreviewWidth
		let minInspector = stacked ? Self.minInspectorHeight : Self.minInspectorWidth
		return min( max( extent, minPreview ), max( minPreview, total - minInspector ) )
	}

	/// Dragging the divider, from the pane's size at the start of the drag, with the resize cursor.
	private func resizeGesture( current: CGFloat, total: CGFloat ) -> some Gesture {
		DragGesture( minimumDistance: 1, coordinateSpace: .global )
			.onChanged { value in
				let start = dragStartExtent ?? Double( current )
				dragStartExtent = start
				setResizeCursor( true )
				let moved  = stacked ? value.translation.height : value.translation.width
				let extent = Double( clampedExtent( CGFloat( start ) + moved, total: total ) )
				if stacked {
					previewHeight = extent
				} else {
					previewWidth = extent
				}
			}
			.onEnded { _ in
				dragStartExtent = nil
				setResizeCursor( false )
			}
	}
}

private extension View {
	/// Size to Fit's look: filled blue while on, the ordinary bordered button while off.
	@ViewBuilder
	func fittingButtonStyle( on: Bool ) -> some View {
		if on {
			buttonStyle( .borderedProminent )
		} else {
			buttonStyle( .bordered )
		}
	}
}
