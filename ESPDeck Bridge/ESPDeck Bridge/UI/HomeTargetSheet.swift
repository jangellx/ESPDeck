//
//  HomeTargetSheet.swift
//  ESPDeck Bridge
//
//  Choosing what a key controls, as the Home app chooses accessories: scenes, then each room's
//  accessories, with their icons and states, any number ticked. With several Homes, each Home
//  has its own scenes and rooms.
//

import SwiftUI

struct HomeTargetSheet: View {
	let controller : DeckController
	let onDone     : ( _ accessories: [KeyMember], _ scenes: [UUID] ) -> Void

	@Environment( \.dismiss ) private var dismiss
	/// In the order they were ticked; the first accessory becomes the key accessory.
	@State private var accessories : [KeyMember]
	@State private var scenes      : [UUID]
	@State private var search      = ""

	init( controller: DeckController, accessories: [KeyMember], scenes: [UUID], onDone: @escaping ( [KeyMember], [UUID] ) -> Void ) {
		self.controller   = controller
		self.onDone       = onDone
		_accessories      = State( initialValue: accessories )
		_scenes           = State( initialValue: scenes )
	}

	var body: some View {
		let targets = controller.home.targets().filter { $0.kind != .shortcut && matches( $0 ) }
		let homes   = Self.ordered( targets.map { $0.home ?? "" } )
		let several = controller.home.hasSeveralHomes

		NavigationStack {
			List {
				ForEach( homes, id: \.self ) { home in
					let inHome = targets.filter { ( $0.home ?? "" ) == home }
					let homeScenes = inHome.filter { $0.kind == .scene }
					if !homeScenes.isEmpty {
						Section( several ? "\(home) · Scenes" : "Scenes" ) {
							ForEach( homeScenes ) { row( $0 ) }
						}
					}
					let rooms = Self.ordered( inHome.filter { $0.kind != .scene }.map { $0.room ?? "" } )
					ForEach( rooms, id: \.self ) { room in
						Section( several ? "\(home) · \(room.isEmpty ? "No Room" : room)" : ( room.isEmpty ? "No Room" : room ) ) {
							ForEach( inHome.filter { $0.kind != .scene && ( $0.room ?? "" ) == room } ) { row( $0 ) }
						}
					}
				}
				if targets.isEmpty {
					Text( search.isEmpty ? "No accessories or scenes in your Homes." : "No matches" )
						.foregroundStyle( Color.secondary )
				}
			}
			// Above the list rather than a section of it, which spaced it like one.
			.safeAreaInset( edge: .top, spacing: 0 ) {
				SearchField( prompt: "Search accessories, scenes and rooms", text: $search )
					.padding( .horizontal, 20 )
					.padding( .top, 6 )
					.padding( .bottom, 2 )
			}
			.contentMargins( .top, 8, for: .scrollContent )
			.navigationTitle( "Home" )
			.navigationBarTitleDisplayMode( .inline )
			.toolbar {
				ToolbarItem( placement: .cancellationAction ) {
					Button {
						dismiss()
					} label: {
						Image( systemName: "xmark" )
					}
					.accessibilityLabel( "Cancel" )
				}
				ToolbarItem( placement: .confirmationAction ) {
					Button {
						onDone( accessories, scenes )
						dismiss()
					} label: {
						Image( systemName: "checkmark" )
					}
					.accessibilityLabel( "Done" )
				}
			}
		}
		.frame( minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 680 )
	}

	// MARK: - Rows

	/// Icon (in its current state), name and state, and the tick.
	private func row( _ target: HomeTarget ) -> some View {
		let chosen = isChosen( target )
		return Button {
			toggle( target )
		} label: {
			HStack( spacing: 12 ) {
				icon( target )
					.frame( width: 28, height: 28 )
				VStack( alignment: .leading, spacing: 1 ) {
					Text( target.name )
						.foregroundStyle( Color.primary )
						.lineLimit( 1 )
					if let detail = detail( target ) {
						Text( detail )
							.font( .caption )
							.foregroundStyle( Color.secondary )
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

	@ViewBuilder
	private func icon( _ target: HomeTarget ) -> some View {
		if target.kind == .scene {
			Image( systemName: "sparkles" )
				.font( .title3 )
				.foregroundStyle( Color.orange )
		} else {
			let state     = controller.home.lastKnownState( of: target ).state
			let reachable = controller.home.isReachable( accessoryID: target.accessoryID )
			Image( systemName: controller.home.symbol( for: target.kind, accessoryID: target.accessoryID, serviceID: target.serviceID, state: state ) )
				.resizable()
				.scaledToFit()
				.foregroundStyle( reachable ? tint( target.kind, state ) : Color.secondary )
		}
	}

	/// Garage doors and sensors keep white on the deck; here they need to show on white.
	private func tint( _ kind: KeyKind, _ state: KeyState ) -> Color {
		let color = kind.tint( for: state )
		return color == .white ? Color.accentColor : color
	}

	/// "On", "Closed", "21.5°", "No Response"; nothing for scenes.
	private func detail( _ target: HomeTarget ) -> String? {
		guard target.kind != .scene else { return nil }
		guard controller.home.isReachable( accessoryID: target.accessoryID ) else { return "No Response" }
		let ( state, value ) = controller.home.lastKnownState( of: target )
		if target.kind == .temperature, let celsius = value as? NSNumber {
			return Measurement( value: celsius.doubleValue, unit: UnitTemperature.celsius )
				.formatted( .measurement( width: .narrow, numberFormatStyle: .number.precision( .fractionLength( 0...1 ) ) ) )
		}
		return state == .standard || state == .unknown ? target.kind.title : state.title
	}

	// MARK: - Choosing

	private func member( _ target: HomeTarget ) -> KeyMember? {
		target.accessoryID.map { KeyMember( kind: target.kind, accessoryID: $0, serviceID: target.serviceID ) }
	}

	private func isChosen( _ target: HomeTarget ) -> Bool {
		if target.kind == .scene { return target.actionSetID.map( scenes.contains ) ?? false }
		return member( target ).map( accessories.contains ) ?? false
	}

	private func toggle( _ target: HomeTarget ) {
		if target.kind == .scene, let id = target.actionSetID {
			if let index = scenes.firstIndex( of: id ) { scenes.remove( at: index ) } else { scenes.append( id ) }
		} else if let member = member( target ) {
			if let index = accessories.firstIndex( of: member ) { accessories.remove( at: index ) } else { accessories.append( member ) }
		}
	}

	private func matches( _ target: HomeTarget ) -> Bool {
		guard !search.isEmpty else { return true }
		return [ target.name, target.room, target.home, target.kind.title ].compactMap { $0 }
			.contains { $0.localizedCaseInsensitiveContains( search ) }
	}

	/// In order of first appearance (targets() sorts them), without repeats; "" (no room) last.
	private static func ordered( _ values: [String] ) -> [String] {
		var seen: Set<String> = []
		let unique = values.filter { seen.insert( $0 ).inserted }
		return unique.filter { !$0.isEmpty } + unique.filter { $0.isEmpty }
	}
}
