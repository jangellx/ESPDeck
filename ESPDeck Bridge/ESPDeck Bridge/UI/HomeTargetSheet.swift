//
//  HomeTargetSheet.swift
//  ESPDeck Bridge
//
//  Choosing what a key controls, as the Home app chooses accessories: scenes, then each room's
//  accessories, with their icons and states, any number ticked. With several Homes, each Home
//  has its own scenes and rooms. Unlike the Home app, each section folds away under its
//  heading, and stays folded the next time.
//

import SwiftUI

/// How many accessories have answered readCurrentStates. An object of its own, read only by
/// the rows: they redraw as answers arrive, and the sheet's list isn't rebuilt each time.
@Observable
private final class StateAnswers {
	var count = 0
}

/// The Home sheet: scenes and each room's accessories, ticked to choose them.
struct HomeTargetSheet: View {
	let controller : DeckController
	let onDone     : ( _ accessories: [KeyMember], _ scenes: [UUID] ) -> Void

	@Environment( \.dismiss ) private var dismiss
	/// In the order they were ticked; the first accessory becomes the key accessory.
	@State private var accessories : [KeyMember]
	@State private var scenes      : [UUID]
	@State private var search      = ""
	@State private var answers     = StateAnswers()
	/// The headings of the sections folded away; kept between launches.
	@State private var collapsed   = Set( UserDefaults.standard.stringArray( forKey: HomeTargetSheet.collapsedDefault ) ?? [] )

	private static let collapsedDefault = "homeSheetCollapsedSections"
	@FocusState private var searchFocused: Bool

	init( controller: DeckController, accessories: [KeyMember], scenes: [UUID], onDone: @escaping ( [KeyMember], [UUID] ) -> Void ) {
		self.controller   = controller
		self.onDone       = onDone
		_accessories      = State( initialValue: accessories )
		_scenes           = State( initialValue: scenes )
	}

	var body: some View {
		// Gathered into Homes and rooms once each time the list is built, not filtered per section.
		let targets = controller.home.targets().filter { $0.kind != .shortcut && matches( $0 ) }
		let homes   = Self.namedFirst( targets.grouped { $0.home ?? "" } )
		let several = controller.home.hasSeveralHomes

		NavigationStack {
			List {
				ForEach( homes, id: \.key ) { home in
					let homeScenes = home.elements.filter { $0.kind == .scene }
					if !homeScenes.isEmpty {
						section( several ? "\(home.key) · Scenes" : "Scenes", homeScenes )
					}
					let rooms = Self.namedFirst( home.elements.filter { $0.kind != .scene }.grouped { $0.room ?? "" } )
					ForEach( rooms, id: \.key ) { room in
						let name = room.key.isEmpty ? "No Room" : room.key
						section( several ? "\(home.key) · \(name)" : name, room.elements )
					}
				}
				if targets.isEmpty {
					Text( search.isEmpty ? "No accessories or scenes in your Homes." : "No matches" )
						.foregroundStyle( Color.secondary )
				}
			}
			// Above the list rather than a section of it, which spaced it like one; in a bar, so
			// the rows scroll under a blur and not straight behind the field.
			.modifier( TopBar {
				SearchField( prompt: "Search accessories, scenes and rooms", text: $search, focus: $searchFocused )
					.padding( .horizontal, 20 )
					.padding( .top, 6 )
					.padding( .bottom, 6 )
			} )
			.contentMargins( .top, 8, for: .scrollContent )
			.onChange( of: collapsed ) { UserDefaults.standard.set( collapsed.sorted(), forKey: Self.collapsedDefault ) }
			.task {
				// The rows start from HomeKit's cache; ask each accessory for what's true now.
				controller.home.readCurrentStates( of: controller.home.targets() ) { [answers] in answers.count += 1 }
				try? await Task.sleep( for: .milliseconds( 100 ) )   // once the sheet is up
				searchFocused = true
			}
			.navigationTitle( "Home" )
			.navigationBarTitleDisplayMode( .inline )
			.toolbar {
				ToolbarItem( placement: .cancellationAction ) {
					Button {
						dismiss()
					} label: {
						Image( systemName: "xmark" )
							.font( .system( size: 12, weight: .semibold ) )   // Catalyst's default is iPad-sized
					}
					.accessibilityLabel( "Cancel" )
				}
				ToolbarItem( placement: .confirmationAction ) {
					Button {
						onDone( accessories, scenes )
						dismiss()
					} label: {
						Image( systemName: "checkmark" )
							.font( .system( size: 12, weight: .semibold ) )   // Catalyst's default is iPad-sized
					}
					.accessibilityLabel( "Done" )
				}
			}
		}
		.frame( minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 680 )
	}

	// MARK: - Sections

	/// A section that folds away under its heading. A search shows every match, folded or not.
	private func section( _ title: String, _ targets: [HomeTarget] ) -> some View {
		let searching = !search.isEmpty
		let open      = searching || !collapsed.contains( title )
		return Section {
			if open {
				ForEach( targets ) { row( $0 ) }
			}
		} header: {
			HomeSectionHeader( title: title, chosen: targets.count( where: isChosen ), open: open, canFold: !searching ) {
				withAnimation { collapsed[contains: title].toggle() }
			}
		}
	}

	// MARK: - Choosing

	/// The target's row, ticked if it's chosen.
	private func row( _ target: HomeTarget ) -> some View {
		HomeTargetRow( controller: controller, target: target, chosen: isChosen( target ), answers: answers ) { toggle( target ) }
	}

	/// The accessory as a key member; nil for scenes.
	private func member( _ target: HomeTarget ) -> KeyMember? {
		target.accessoryID.map { KeyMember( kind: target.kind, accessoryID: $0, serviceID: target.serviceID ) }
	}

	/// Whether the target is ticked.
	private func isChosen( _ target: HomeTarget ) -> Bool {
		if target.kind == .scene { return target.actionSetID.map( scenes.contains ) ?? false }
		return member( target ).map( accessories.contains ) ?? false
	}

	/// Ticks or unticks the target, keeping the order they were ticked in.
	private func toggle( _ target: HomeTarget ) {
		if target.kind == .scene, let id = target.actionSetID {
			if let index = scenes.firstIndex( of: id ) { scenes.remove( at: index ) } else { scenes.append( id ) }
		} else if let member = member( target ) {
			if let index = accessories.firstIndex( of: member ) { accessories.remove( at: index ) } else { accessories.append( member ) }
		}
	}

	/// The search text is in the target's name, room, Home, or kind.
	private func matches( _ target: HomeTarget ) -> Bool {
		guard !search.isEmpty else { return true }
		return [ target.name, target.room, target.home, target.kind.title ].compactMap { $0 }
			.contains { $0.localizedCaseInsensitiveContains( search ) }
	}

	/// The groups in their order (targets() sorts them), with "" (no room) last.
	private static func namedFirst<Element>( _ groups: [( key: String, elements: [Element] )] ) -> [( key: String, elements: [Element] )] {
		groups.filter { !$0.key.isEmpty } + groups.filter { $0.key.isEmpty }
	}
}

/// Puts `bar` above a scrolling view as a bar: the content scrolls under it and blurs away at
/// its edge (safeAreaBar, iOS 26). Before that, an inset with the bar material behind it.
private struct TopBar<Bar: View>: ViewModifier {
	@ViewBuilder let bar: Bar

	func body( content: Content ) -> some View {
		if #available( iOS 26.0, * ) {
			content.safeAreaBar( edge: .top, spacing: 0 ) { bar }
		} else {
			content.safeAreaInset( edge: .top, spacing: 0 ) { bar.background( .bar ) }
		}
	}
}

/// A section's heading: its title, how many of its rows are ticked (so a folded section
/// still says), and an arrow that points down while it's open. Clicking anywhere on it folds
/// or unfolds the section.
private struct HomeSectionHeader: View {
	let title   : String
	let chosen  : Int
	let open    : Bool
	/// False during a search, when every section is open.
	let canFold : Bool
	let toggle  : () -> Void

	var body: some View {
		HStack( spacing: 6 ) {
			Text( title )
			Spacer( minLength: 8 )
			if chosen > 0 {
				Text( "\(chosen) chosen" )
					.foregroundStyle( Color.accentColor )
			}
			if canFold {
				Image( systemName: "chevron.right" )
					.font( .caption.weight( .semibold ) )
					.rotationEffect( .degrees( open ? 90 : 0 ) )
			}
		}
		.contentShape( Rectangle() )
		.onTapGesture { if canFold { toggle() } }
		.accessibilityAddTraits( canFold ? .isButton : [] )
		.accessibilityHint( !canFold ? "" : open ? "Hides this section's rows" : "Shows this section's rows" )
	}
}

/// Spins a fan's blades while `active` (iOS 18's rotate symbol effect, which turns just the
/// blades of the fan symbols and stops for Reduce Motion).
private struct SpinningSymbol: ViewModifier {
	let active: Bool

	func body( content: Content ) -> some View {
		if #available( iOS 18.0, * ) {
			content.symbolEffect( .rotate, options: .repeat( .continuous ), isActive: active )
		} else {
			content
		}
	}
}

/// One accessory or scene in the Home sheet: its icon (in its current state), name and state,
/// and the tick. Tapping anywhere on it calls `toggle`.
private struct HomeTargetRow: View {
	let controller : DeckController
	let target     : HomeTarget
	let chosen     : Bool
	let answers    : StateAnswers
	let toggle     : () -> Void

	var body: some View {
		let _ = answers.count   // redraws as accessories answer with their current state
		Button( action: toggle ) {
			HStack( spacing: 12 ) {
				icon
					.frame( width: 28, height: 28 )
				VStack( alignment: .leading, spacing: 1 ) {
					Text( target.name )
						.foregroundStyle( Color.primary )
						.lineLimit( 1 )
					if let detail {
						Text( detail )
							.secondaryCaption()
							.lineLimit( 1 )
					}
				}
				Spacer( minLength: 8 )
				Image( systemName: chosen ? "checkmark.circle.fill" : "circle" )
					.font( .title3 )
					.foregroundStyle( chosen ? Color.accentColor : Color.secondary )
			}
			.contentShape( Rectangle() )
		}
		.buttonStyle( .plain )
		.accessibilityAddTraits( chosen ? .isSelected : [] )
	}

	/// A scene's sparkles, or the accessory's symbol in its state (gray when unreachable).
	@ViewBuilder
	private var icon: some View {
		if target.kind == .scene {
			Image( systemName: "sparkles" )
				.font( .title3 )
				.foregroundStyle( Color.orange )
		} else {
			let state     = controller.home.lastKnownState( of: target ).state
			let reachable = controller.home.isReachable( accessoryID: target.accessoryID )
			let symbol    = controller.home.symbol( for: target.kind, accessoryID: target.accessoryID, serviceID: target.serviceID, state: state )
			Image( systemName: symbol )
				.resizable()
				.scaledToFit()
				.foregroundStyle( reachable ? tint( state ) : Color.secondary )
				// A fan that's running turns; not a ceiling fan, whose symbol is seen from below
				// at an angle and looks wrong turning.
				.modifier( SpinningSymbol( active: reachable && state == .on && symbol.hasPrefix( "fan" ) && !symbol.hasPrefix( "fan.ceiling" ) ) )
		}
	}

	/// As on the deck (amber on, green locked or closed…), except that the deck's white (off,
	/// and garage doors, whose symbols carry their state) is gray here, as the Home app shows
	/// accessories that are off.
	private func tint( _ state: KeyState ) -> Color {
		let color = target.kind.tint( for: state )
		return color == .white ? Color.secondary : color
	}

	/// "On", "Closed", "21.5°", "No Response"; nothing for scenes.
	private var detail: String? {
		guard target.kind != .scene else { return nil }
		guard controller.home.isReachable( accessoryID: target.accessoryID ) else { return "No Response" }
		let ( state, value ) = controller.home.lastKnownState( of: target )
		if target.kind == .temperature, let celsius = value as? NSNumber {
			return Measurement( value: celsius.doubleValue, unit: UnitTemperature.celsius )
				.formatted( .measurement( width: .narrow, numberFormatStyle: .number.precision( .fractionLength( 0...1 ) ) ) )
		}
		return state == .standard || state == .unknown ? target.kind.title : state.title
	}
}
