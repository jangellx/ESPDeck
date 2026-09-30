//
//  SliderSection.swift
//  ESPDeck Bridge
//
//  The inspector's settings for a Level key (a slider in the code): which key it pairs with
//  (from a cross of the keys beside it), which way each key moves the level, the step, the
//  pair's icons, and where stacked keys put their labels.
//

import SwiftUI

/// The Level section of the inspector, for a key paired with another to step a level.
struct SliderSection: View {
	let controller : DeckController
	let deviceID   : String
	let key        : Int
	let levels     : [SliderLevel]

	/// A key beside this one that already does something, waiting for Replace.
	@State private var replacing: Int?

	/// Steps offered by the Step stepper, in percent.
	private static let steps: [Double] = [ 1, 2, 5, 10, 15, 20, 25, 30, 40, 50 ]

	var body: some View {
		let assignment = controller.assignment( deviceID, key: key )
		let slider     = assignment.slider

		Section {
			if let slider, levels.count > 1 {
				Picker( "Adjusts", selection: Binding {
					slider.level
				} set: { level in
					controller.updateSlider( device: deviceID, key: key ) { $0.level = level }
				} ) {
					ForEach( levels ) { level in
						Text( level.title ).tag( level )
					}
				}
			}

			LabeledContent {
				SliderPartnerGrid( controller: controller, deviceID: deviceID, key: key, partner: slider?.partner ) { partner in
					if slider?.partner != partner && controller.assignment( deviceID, key: partner ).kind != nil {
						replacing = partner
					} else {
						pair( with: partner, level: slider?.level )
					}
				}
			} label: {
				CaptionedText( "Other Key", caption: slider.map { "Key \($0.partner + 1)" } ?? "Choose the key beside this one that goes with it.", spacing: 4 )
			}
			.padding( .vertical, 6 )
			.confirmationDialog( "Replace Key \( ( replacing ?? 0 ) + 1 )?", isPresented: Binding( presenting: $replacing ) ) {
				Button( "Replace", role: .destructive ) {
					if let partner = replacing { pair( with: partner, level: slider?.level ) }
					replacing = nil
				}
			} message: {
				Text( "It already has \( replacing.flatMap { controller.defaultName( for: controller.assignment( deviceID, key: $0 ) ) } ?? "something" ) on it. Making it this key's other Level key replaces that." )
			}

			if let slider {
				LabeledContent( "This Key" ) {
					HStack {
						Text( slider.raises ? "Increases" : "Decreases" )
						Button( "Swap" ) { controller.swapSliderDirection( device: deviceID, key: key ) }
							.help( "Swap which key increases and which decreases" )
					}
				}

				// The value beside the arrows, not by the label.
				LabeledContent( "Step" ) {
					HStack( spacing: 6 ) {
						Text( "\(Int( slider.step ))%" )
							.monospacedDigit()
						Stepper( "Step" ) {
							let next = Self.steps.first { $0 > slider.step } ?? Self.steps.last!
							controller.updateSlider( device: deviceID, key: key ) { $0.step = next }
						} onDecrement: {
							let next = Self.steps.last { $0 < slider.step } ?? Self.steps.first!
							controller.updateSlider( device: deviceID, key: key ) { $0.step = next }
						}
						.labelsHidden()
					}
				}

				let horizontal = controller.isHorizontalPair( device: deviceID, key, slider.partner )
				if !horizontal {
					Picker( "Labels", selection: Binding {
						slider.labelsFacing
					} set: { facing in
						controller.updateSlider( device: deviceID, key: key ) { $0.labelsFacing = facing }
					} ) {
						Text( "Facing Each Other" ).tag( true )
						Text( "Like Other Keys" ).tag( false )
					}
				}

				VStack( alignment: .leading, spacing: 8 ) {
					Text( "Icons" )
					StylePicker( selection: slider.style, horizontal: horizontal ) { style in
						controller.updateSlider( device: deviceID, key: key ) { $0.style = style }
					}
					.frame( maxWidth: .infinity )   // centered under its heading
				}
				.padding( .top, 6 )
				.padding( .bottom, 4 )

				VStack( alignment: .leading, spacing: 4 ) {
					Toggle( "Double-Tap Goes All the Way", isOn: Binding {
						slider.doubleTapToEnd
					} set: { on in
						controller.updateSlider( device: deviceID, key: key ) { $0.doubleTapToEnd = on }
					} )
					.toggleStyle( .switch )
					Text( "To 100% with the key that increases, 0% with the other. When off, tapping quickly just steps." )
						.secondaryCaption()
				}

				LabeledContent( "State", value: controller.state( device: deviceID, key: key ).title )
			}
		} header: {
			SectionHeader( "Level" )
		} footer: {
			Text( "Tap either key to step once. Hold to keep stepping." )
		}
	}

	/// Pairs this key with `partner`, keeping the level it adjusts (else the first one offered).
	private func pair( with partner: Int, level: SliderLevel? ) {
		controller.makeSlider( device: deviceID, key: key, partner: partner, level: level ?? levels.first ?? .brightness )
	}
}

/// A cross of the keys around this one: itself in the middle, the four beside it to choose
/// from. An arm that would be off the edge of the deck is ghosted.
private struct SliderPartnerGrid: View {
	let controller : DeckController
	let deviceID   : String
	let key        : Int
	let partner    : Int?
	let onPick     : ( Int ) -> Void

	/// Each key's side, and its corners' radius.
	private static let cell   : CGFloat = 38
	private static let corner : CGFloat = 6

	var body: some View {
		let layout = controller.layout( deviceID )
		let cols   = max( layout.cols, 1 )
		let row    = key / cols
		let col    = key % cols

		Grid( horizontalSpacing: 4, verticalSpacing: 4 ) {
			ForEach( -1...1, id: \.self ) { dr in
				GridRow {
					ForEach( -1...1, id: \.self ) { dc in
						let r = row + dr, c = col + dc
						if dr != 0 && dc != 0 {
							Color.clear.frame( width: Self.cell, height: Self.cell )
						} else if r < 0 || c < 0 || r >= layout.rows || c >= cols {
							RoundedRectangle( cornerRadius: Self.corner, style: .continuous )
								.strokeBorder( Color( white: 0.5 ).opacity( 0.35 ), style: StrokeStyle( lineWidth: 1, dash: [ 3, 3 ] ) )
								.frame( width: Self.cell, height: Self.cell )
								.help( "Off the edge of the deck" )
						} else if dr == 0 && dc == 0 {
							thisKey
						} else {
							let index = r * cols + c
							Button {
								onPick( index )
							} label: {
								keyCell( index, chosen: index == partner )
							}
							.buttonStyle( .plain )
							.help( index == partner ? "Paired with Key \(index + 1)" : "Pair with Key \(index + 1)" )
						}
					}
				}
			}
		}
	}

	/// The middle: once paired, this key as it looks; before that, a marker.
	@ViewBuilder private var thisKey: some View {
		if partner != nil {
			keyCell( key, chosen: false )
				.help( "This key" )
		} else {
			RoundedRectangle( cornerRadius: Self.corner, style: .continuous )
				.strokeBorder( Color.accentColor, style: StrokeStyle( lineWidth: 2, dash: [ 4, 3 ] ) )
				.overlay {
					Image( systemName: "smallcircle.filled.circle" )
						.foregroundStyle( .tint )
				}
				.frame( width: Self.cell, height: Self.cell )
				.help( "This key" )
		}
	}

	/// A key as it looks on the deck, outlined in the accent color when `chosen`.
	private func keyCell( _ index: Int, chosen: Bool ) -> some View {
		let preview = controller.device( deviceID ).flatMap { index < $0.keys.count ? $0.keys[index]?.preview : nil }
		return ZStack {
			RoundedRectangle( cornerRadius: Self.corner, style: .continuous )
				.fill( Color( white: 0.13 ) )
			if let preview {
				Image( uiImage: preview )
					.resizable()
					.clipShape( RoundedRectangle( cornerRadius: Self.corner, style: .continuous ) )
			}
		}
		.frame( width: Self.cell, height: Self.cell )
		.keyOutline( cornerRadius: Self.corner, chosen ? Color.accentColor : Color( white: 0.35 ), lineWidth: chosen ? 3 : 1 )
		.accessibilityLabel( "Key \(index + 1)" )
	}
}

/// The icon sets for a pair, four to a row: each shows the raising key's symbol and the
/// lowering one's, pointing the way the pair is laid out.
private struct StylePicker: View {
	let selection  : SliderStyle
	let horizontal : Bool
	let onPick     : ( SliderStyle ) -> Void

	var body: some View {
		Grid( horizontalSpacing: 8, verticalSpacing: 8 ) {
			ForEach( Array( stride( from: 0, to: SliderStyle.allCases.count, by: 4 ) ), id: \.self ) { start in
				GridRow {
					ForEach( SliderStyle.allCases[start..<min( start + 4, SliderStyle.allCases.count )] ) { style in
						button( style )
					}
				}
			}
		}
	}

	/// One icon set: its two symbols, highlighted when it's the one chosen.
	private func button( _ style: SliderStyle ) -> some View {
		Button {
			onPick( style )
		} label: {
			HStack( spacing: 4 ) {
				Image( systemName: style.symbol( raises: !horizontal, horizontal: horizontal ) )
				Image( systemName: style.symbol( raises: horizontal, horizontal: horizontal ) )
			}
			.frame( width: 58, height: 32 )
			.background( RoundedRectangle( cornerRadius: 6, style: .continuous ).fill( style == selection ? Color.accentColor.opacity( 0.2 ) : Color( uiColor: .tertiarySystemFill ) ) )
			.overlay( RoundedRectangle( cornerRadius: 6, style: .continuous ).strokeBorder( style == selection ? Color.accentColor : Color.clear, lineWidth: 2 ) )
			.contentShape( Rectangle() )
		}
		.buttonStyle( .plain )
	}
}
