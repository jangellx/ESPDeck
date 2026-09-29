//
//  SliderSection.swift
//  ESPDeck Bridge
//
//  The inspector's settings for a slider key: which key it pairs with (from a 3 × 3 grid
//  around it), which way each key moves the level, the step, and the pair's icons.
//

import SwiftUI

struct SliderSection: View {
	let controller : DeckController
	let deviceID   : String
	let key        : Int
	let levels     : [SliderLevel]

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
					controller.makeSlider( device: deviceID, key: key, partner: partner, level: slider?.level ?? levels.first ?? .brightness )
				}
			} label: {
				VStack( alignment: .leading, spacing: 4 ) {
					Text( "Other Key" )
					Text( slider.map { "Key \($0.partner + 1)" } ?? "Choose the key beside this one that goes with it. Its current setup is replaced." )
						.font( .caption )
						.foregroundStyle( Color.secondary )
				}
			}

			if let slider {
				LabeledContent( "This Key" ) {
					HStack {
						Text( slider.raises ? "Increases" : "Decreases" )
						Button( "Swap" ) { controller.swapSliderDirection( device: deviceID, key: key ) }
							.help( "Swap which key increases and which decreases" )
					}
				}

				Stepper {
					LabeledContent( "Step", value: "\(Int( slider.step ))%" )
				} onIncrement: {
					let next = Self.steps.first { $0 > slider.step } ?? Self.steps.last!
					controller.updateSlider( device: deviceID, key: key ) { $0.step = next }
				} onDecrement: {
					let next = Self.steps.last { $0 < slider.step } ?? Self.steps.first!
					controller.updateSlider( device: deviceID, key: key ) { $0.step = next }
				}

				VStack( alignment: .leading, spacing: 8 ) {
					Text( "Icons" )
					StylePicker( selection: slider.style,
								 horizontal: controller.isHorizontalPair( device: deviceID, key, slider.partner ) ) { style in
						controller.updateSlider( device: deviceID, key: key ) { $0.style = style }
					}
				}
			}
		} header: {
			SectionHeader( "Slider" )
		} footer: {
			Text( "Press either key to step the level; hold it to keep stepping (the delay and speed are on the Device page). The upper (or left) key shows the name and the other the level, unless they have their own labels. Either key can also have any icon, under Icons." )
		}
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

	private static let cell: CGFloat = 38

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
							RoundedRectangle( cornerRadius: 6, style: .continuous )
								.strokeBorder( Color( white: 0.5 ).opacity( 0.35 ), style: StrokeStyle( lineWidth: 1, dash: [ 3, 3 ] ) )
								.frame( width: Self.cell, height: Self.cell )
								.help( "Off the edge of the deck" )
						} else if dr == 0 && dc == 0 {
							keyCell( r * cols + c, style: .this )
						} else {
							let index = r * cols + c
							Button {
								onPick( index )
							} label: {
								keyCell( index, style: index == partner ? .chosen : .choice )
							}
							.buttonStyle( .plain )
							.help( index == partner ? "Paired with Key \(index + 1)" : "Pair with Key \(index + 1)" )
						}
					}
				}
			}
		}
	}

	private enum CellStyle { case this, chosen, choice }

	private func keyCell( _ index: Int, style: CellStyle ) -> some View {
		let preview = controller.device( deviceID ).flatMap { index < $0.keys.count ? $0.keys[index]?.preview : nil }
		return ZStack {
			RoundedRectangle( cornerRadius: 6, style: .continuous )
				.fill( style == .this ? Color.accentColor : Color( white: 0.13 ) )
			if let preview, style != .this {
				Image( uiImage: preview )
					.resizable()
					.clipShape( RoundedRectangle( cornerRadius: 6, style: .continuous ) )
					.opacity( 0.8 )
			}
			Text( "\(index + 1)" )
				.font( .caption.weight( .semibold ) )
				.foregroundStyle( .white )
				.shadow( radius: 2 )
		}
		.frame( width: Self.cell, height: Self.cell )
		.overlay {
			RoundedRectangle( cornerRadius: 6, style: .continuous )
				.strokeBorder( style == .chosen ? Color.accentColor : Color( white: 0.35 ), lineWidth: style == .chosen ? 3 : 1 )
		}
		.accessibilityLabel( "Key \(index + 1)" )
	}
}

/// The icon sets for a pair: each shows the raising key's symbol and the lowering one's,
/// pointing the way the pair is laid out.
private struct StylePicker: View {
	let selection  : SliderStyle
	let horizontal : Bool
	let onPick     : ( SliderStyle ) -> Void

	var body: some View {
		LazyVGrid( columns: [ GridItem( .adaptive( minimum: 58 ), spacing: 8 ) ], alignment: .leading, spacing: 8 ) {
			ForEach( SliderStyle.allCases ) { style in
				Button {
					onPick( style )
				} label: {
					HStack( spacing: 4 ) {
						Image( systemName: style.symbol( raises: horizontal ? false : true, horizontal: horizontal ) )
						Image( systemName: style.symbol( raises: horizontal ? true : false, horizontal: horizontal ) )
					}
					.frame( width: 58, height: 32 )
					.background( RoundedRectangle( cornerRadius: 6, style: .continuous ).fill( style == selection ? Color.accentColor.opacity( 0.2 ) : Color( uiColor: .tertiarySystemFill ) ) )
					.overlay( RoundedRectangle( cornerRadius: 6, style: .continuous ).strokeBorder( style == selection ? Color.accentColor : Color.clear, lineWidth: 2 ) )
					.contentShape( Rectangle() )
				}
				.buttonStyle( .plain )
			}
		}
	}
}
