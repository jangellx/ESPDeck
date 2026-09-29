//
//  TargetPicker.swift
//  ESPDeck Bridge
//
//  Chooses what an assignment controls: an accessory (room submenus), a scene, or a
//  shortcut (folder submenus), with search. With several Homes, accessories and scenes
//  are grouped by Home first. Used for keys, sleep/wake commands, and sleep triggers.
//  Produces Form rows; put it inside a Section.
//

import HomeKit
import SwiftUI

enum TargetMode: String, CaseIterable, Identifiable {
	case accessory = "Accessories"
	case scene     = "Scene"
	case shortcut  = "Shortcut"

	var id: String { rawValue }

	init( kind: KeyKind? ) {
		switch kind {
			case .scene:    self = .scene
			case .shortcut: self = .shortcut
			default:        self = .accessory
		}
	}

	func includes( _ target: HomeTarget ) -> Bool {
		TargetMode( kind: target.kind ) == self
	}

	/// Submenu for targets without a room or folder.
	var ungroupedTitle: String { self == .shortcut ? "Other Shortcuts" : "No Room" }
}

extension KeyAssignment {
	/// Makes `member` the key accessory, keeping the action when it still applies.
	mutating func setKeyMember( _ member: KeyMember, others: [KeyMember] ) {
		let kindChanged = kind != member.kind
		kind        = member.kind
		accessoryID = member.accessoryID
		serviceID   = member.serviceID
		self.others = others.isEmpty ? nil : others
		if kindChanged && !member.kind.actions.contains( action ) {
			action = member.kind.actions.first ?? .none
		}
	}

	/// Binds to a target. nil unbinds but keeps icons and label.
	mutating func bind( to target: HomeTarget? ) {
		let kindChanged = kind != target?.kind
		kind         = target?.kind
		accessoryID  = target?.accessoryID
		serviceID    = target?.serviceID
		actionSetID  = target?.actionSetID
		shortcutID   = target?.shortcutID
		shortcutName = target?.kind == .shortcut ? target?.name : nil
		others       = nil
		if kind != .shortcut {
			shortcutToggles = nil
		}
		shortcutState = nil
		if target?.kind != nil {
			if kindChanged || !actions.contains( action ) {
				action = actions.first ?? .none
			}
		} else {
			action = .none
		}
	}
}

struct TargetPicker: View {
	let controller : DeckController
	let assignment : KeyAssignment
	var modes      : [TargetMode] = TargetMode.allCases
	/// Limits accessories to certain kinds, e.g. ones with states for sleep triggers.
	var kindFilter : ( ( KeyKind ) -> Bool )?
	/// Several accessories at once, with one "key accessory": applies a change to the
	/// assignment. Without it, accessories are picked one at a time through onSelect.
	var edit       : ( ( ( inout KeyAssignment ) -> Void ) -> Void )?
	/// A mode to switch to, from the Key menu; cleared once taken.
	var modeRequest: Binding<TargetMode?>?
	let onSelect   : ( HomeTarget? ) -> Void

	private var multiple: Bool { edit != nil && mode == .accessory }

	@State private var mode   = TargetMode.accessory
	@State private var search = ""

	private static let maxSearchResults = 25

	var body: some View {
		let targets = targets( for: mode )

		Group {
			if modes.count > 1 {
				Picker( "Controls", selection: $mode ) {
					ForEach( modes ) { mode in
						Text( mode.rawValue ).tag( mode )
					}
				}
				.pickerStyle( .segmented )
			}

			if multiple {
				memberRows( targets )
			} else {
				VStack( alignment: .trailing, spacing: 6 ) {
					// A fixed-width label; long item titles otherwise squeeze it.
					LabeledContent {
						targetMenu( targets )
					} label: {
						Text( mode == .accessory ? "Accessory" : mode.rawValue )
							.fixedSize()
					}
					// In the same row as the popup it reloads.
					if mode == .shortcut {
						shortcutStatus( targets )
					}
				}
			}

			SearchField( prompt: searchPrompt, text: $search )

			if !search.isEmpty {
				let matches = targets.filter( matchesSearch )
				if matches.isEmpty {
					Text( "No matches" )
						.foregroundStyle( .secondary )
				}
				ForEach( matches.prefix( Self.maxSearchResults ) ) { target in
					Button {
						if multiple { add( target ) } else { onSelect( target ) }
						search = ""
					} label: {
						VStack( alignment: .leading, spacing: 2 ) {
							Text( target.name )
							if let detail = detail( for: target ) {
								Text( detail )
									.font( .caption )
									.foregroundStyle( .secondary )
							}
						}
						.frame( maxWidth: .infinity, alignment: .leading )
						.contentShape( Rectangle() )
					}
					.buttonStyle( .plain )
				}
			}

			if mode != .shortcut && targets.isEmpty {
				Text( emptyExplanation )
					.font( .caption )
					.foregroundStyle( .secondary )
			}
		}
		.onAppear {
			syncMode()
			takeModeRequest()
		}
		.onChange( of: assignment.kind ) { syncMode() }
		.onChange( of: modeRequest?.wrappedValue ) { takeModeRequest() }
		.onChange( of: mode ) {
			search = ""
			if mode == .shortcut && !controller.shortcutsLoaded {
				controller.reloadShortcuts()
			}
		}
	}

	private func targets( for mode: TargetMode ) -> [HomeTarget] {
		let all = mode == .shortcut ? controller.shortcuts : controller.home.targets().filter { mode.includes( $0 ) }
		guard let kindFilter else { return all }
		return all.filter { kindFilter( $0.kind ) }
	}

	// MARK: - Several accessories

	/// The key accessory (starred) and the others, then a menu to add more.
	@ViewBuilder
	private func memberRows( _ targets: [HomeTarget] ) -> some View {
		let members   = TargetMode( kind: assignment.kind ) == .accessory ? assignment.members : []
		let canAddMore = members.first.map { $0.kind.targetCharacteristicType != nil } ?? true

		ForEach( Array( members.enumerated() ), id: \.element ) { index, member in
			HStack( spacing: 10 ) {
				// The star picks the key accessory, which only means something with two or more.
				if members.count > 1 {
					Button {
						makeKey( member )
					} label: {
						Image( systemName: index == 0 ? "star.fill" : "star" )
							.foregroundStyle( index == 0 ? Color.yellow : Color.secondary )
					}
					.buttonStyle( .borderless )
					.disabled( index == 0 )
					.help( index == 0 ? "The key accessory: its state is the key's state" : "Make this the key accessory" )
				}

				VStack( alignment: .leading, spacing: 1 ) {
					Text( name( of: member, in: targets ) )
						.lineLimit( 1 )
						.truncationMode( .middle )
					Text( [ place( of: member, in: targets ), member.kind.title, index == 0 && members.count > 1 ? "key accessory" : nil ].compactMap { $0 }.joined( separator: " · " ) )
						.font( .caption )
						.foregroundStyle( .secondary )
						.lineLimit( 1 )
				}
				.frame( maxWidth: .infinity, alignment: .leading )

				Button {
					remove( member )
				} label: {
					Image( systemName: "minus.circle.fill" )
						.foregroundStyle( .red )
				}
				.buttonStyle( .borderless )
				.help( "Remove" )
			}
		}

		if members.count > 1 {
			// Laid out like the member rows (same spacing, star at the same size) so the stars line up.
			HStack( alignment: .firstTextBaseline, spacing: 10 ) {
				Image( systemName: "star.fill" )
				Text( "The starred accessory is the key accessory: the key shows its state, and Toggle turns everything on or off based on it. Click another star to change it." )
					.font( .caption )
					.frame( maxWidth: .infinity, alignment: .leading )
			}
			.foregroundStyle( .secondary )
		}

		if canAddMore {
			// The hint sits under the button, in the same row.
			VStack( alignment: .leading, spacing: 4 ) {
				Menu {
					byHome( addable( targets, members: members ) ) { targets in
						roomMenus( targets ) { target in
							Button( "\(target.name) (\(target.kind.title))" ) { add( target ) }
						}
					}
				} label: {
					Label( members.isEmpty ? "Choose Accessory" : "Add Accessory", systemImage: "plus" )
				}
				.fixedSize()
				if members.count == 1 {
					Text( "Add more accessories to control them together with this key." )
						.font( .caption )
						.foregroundStyle( .secondary )
				}
			}
		} else {
			Text( "Only accessories that can be switched, opened or locked can join a group." )
				.font( .caption )
				.foregroundStyle( .secondary )
		}
	}

	/// With a key accessory already chosen, only accessories a key press can act on.
	private func addable( _ targets: [HomeTarget], members: [KeyMember] ) -> [HomeTarget] {
		targets.filter { target in
			!members.contains { $0.accessoryID == target.accessoryID && $0.serviceID == target.serviceID && $0.kind == target.kind }
				&& ( members.isEmpty || target.kind.targetCharacteristicType != nil )
		}
	}

	private func add( _ target: HomeTarget ) {
		guard let edit else { return }
		edit { assignment in
			guard TargetMode( kind: assignment.kind ) == .accessory, !assignment.members.isEmpty,
				  let accessoryID = target.accessoryID else {
				assignment.bind( to: target )   // the first accessory is the key accessory
				return
			}
			let member = KeyMember( kind: target.kind, accessoryID: accessoryID, serviceID: target.serviceID )
			guard !assignment.members.contains( member ) else { return }
			assignment.others = ( assignment.others ?? [] ) + [ member ]
		}
	}

	private func remove( _ member: KeyMember ) {
		edit? { assignment in
			let members = assignment.members
			if members.first == member {
				// Promote the next one, or unbind.
				guard members.count > 1 else {
					assignment.bind( to: nil )
					assignment.others = nil
					return
				}
				assignment.setKeyMember( members[1], others: Array( members.dropFirst( 2 ) ) )
			} else {
				assignment.others = ( assignment.others ?? [] ).filter { $0 != member }
			}
		}
	}

	private func makeKey( _ member: KeyMember ) {
		edit? { assignment in
			let members = assignment.members
			guard let old = members.first, old != member else { return }
			assignment.setKeyMember( member, others: [ old ] + members.dropFirst().filter { $0 != member } )
		}
	}

	private func name( of member: KeyMember, in targets: [HomeTarget] ) -> String {
		targets.first { $0.accessoryID == member.accessoryID && $0.serviceID == member.serviceID && $0.kind == member.kind }?.name ?? "Missing Accessory"
	}

	/// "Room", or "Home · Room" with several Homes.
	private func place( of member: KeyMember, in targets: [HomeTarget] ) -> String? {
		guard let target = targets.first( where: { $0.accessoryID == member.accessoryID && $0.serviceID == member.serviceID } ) else { return nil }
		let parts = [ severalHomes ? target.home : nil, target.room ].compactMap { $0 }
		return parts.isEmpty ? nil : parts.joined( separator: " · " )
	}

	/// Room submenus for accessories, folder submenus for shortcuts, a flat list for scenes.
	private func targetMenu( _ targets: [HomeTarget] ) -> some View {
		Menu {
			Button( "None" ) { onSelect( nil ) }
			Divider()

			switch mode {
				case .scene:
					byHome( targets ) { targets in
						ForEach( targets ) { target in
							menuItem( target, title: target.name )
						}
					}
				case .shortcut:
					// Folders as submenus, unfiled shortcuts at the top level.
					ForEach( groups( in: targets.filter { $0.room != nil } ), id: \.self ) { folder in
						Menu( folder ) {
							ForEach( targets.filter { $0.room == folder } ) { target in
								menuItem( target, title: target.name )
							}
						}
					}
					ForEach( targets.filter { $0.room == nil } ) { target in
						menuItem( target, title: target.name )
					}
				case .accessory:
					byHome( targets ) { targets in
						roomMenus( targets ) { target in
							menuItem( target, title: "\(target.name) (\(target.kind.title))" )
						}
					}
			}
		} label: {
			// Menus size to their label, so shorten long names before they push the row wider.
			Text( Self.shortened( currentTitle( targets ) ) )
				.lineLimit( 1 )
				.truncationMode( .middle )
				.frame( maxWidth: .infinity, alignment: .leading )
		}
	}

	private static func shortened( _ text: String, limit: Int = 42 ) -> String {
		guard text.count > limit else { return text }
		let half = ( limit - 1 ) / 2
		return String( text.prefix( half ) ) + "…" + String( text.suffix( half ) )
	}

	private func groups( in targets: [HomeTarget] ) -> [String] {
		Self.ordered( targets.map { $0.room ?? mode.ungroupedTitle } )
	}

	private static func ordered( _ values: [String] ) -> [String] {
		var seen: [String] = []
		for value in values where !seen.contains( value ) {
			seen.append( value )
		}
		return seen
	}

	private var severalHomes: Bool { controller.home.hasSeveralHomes }

	/// A submenu per Home when there are several; otherwise the content itself.
	@ViewBuilder
	private func byHome<Content: View>( _ targets: [HomeTarget], @ViewBuilder content: @escaping ( [HomeTarget] ) -> Content ) -> some View {
		if severalHomes {
			ForEach( Self.ordered( targets.map { $0.home ?? "" } ), id: \.self ) { home in
				Menu( home ) {
					content( targets.filter { ( $0.home ?? "" ) == home } )
				}
			}
		} else {
			content( targets )
		}
	}

	private func roomMenus<Item: View>( _ targets: [HomeTarget], @ViewBuilder item: @escaping ( HomeTarget ) -> Item ) -> some View {
		ForEach( groups( in: targets ), id: \.self ) { room in
			Menu( room ) {
				ForEach( targets.filter { ( $0.room ?? mode.ungroupedTitle ) == room } ) { target in
					item( target )
				}
			}
		}
	}

	private func menuItem( _ target: HomeTarget, title: String ) -> some View {
		Button {
			onSelect( target )
		} label: {
			if target.matches( assignment ) {
				Label( title, systemImage: "checkmark" )
			} else {
				Text( title )
			}
		}
	}

	private func currentTitle( _ targets: [HomeTarget] ) -> String {
		// Something bound in another mode reads as None here.
		guard let kind = assignment.kind, TargetMode( kind: kind ) == mode else { return "None" }
		guard let target = targets.first( where: { $0.matches( assignment ) } ) else {
			switch mode {
				case .scene:     return "Missing Scene"
				case .accessory: return "Missing Accessory"
				case .shortcut:
					// Before the list loads, show the remembered name rather than "missing".
					return controller.shortcutsLoaded ? "Missing Shortcut" : ( assignment.shortcutName ?? "Shortcut" )
			}
		}
		let home = severalHomes ? target.home.map { "\($0) › " } ?? "" : ""
		if kind == .shortcut { return target.name }
		if kind == .scene { return home + target.name }
		let place = target.room.map { "\($0) › " } ?? ""
		return "\(home)\(place)\(target.name) (\(kind.title))"
	}

	private func detail( for target: HomeTarget ) -> String? {
		let home = severalHomes ? target.home : nil
		return switch target.kind {
			case .shortcut: target.room
			case .scene:    home
			default:        [ home, target.room, target.kind.title ].compactMap { $0 }.joined( separator: " · " )
		}
	}

	/// Under the Shortcut popup: why the list is empty, if it is, and Reload Shortcuts.
	private func shortcutStatus( _ targets: [HomeTarget] ) -> some View {
		HStack( alignment: .firstTextBaseline ) {
			if let error = controller.shortcutError {
				Label( error, systemImage: "exclamationmark.triangle.fill" )
					.font( .caption )
					.foregroundStyle( .orange )
			} else if targets.isEmpty && controller.shortcutsLoaded {
				Text( "No shortcuts found." )
					.font( .caption )
					.foregroundStyle( .secondary )
			}
			Spacer()
			Button( "Reload Shortcuts" ) { controller.reloadShortcuts() }
		}
	}

	private func matchesSearch( _ target: HomeTarget ) -> Bool {
		let terms = search.split( separator: " " ).map( String.init )
		let text  = [ target.name, target.room ?? "", target.kind.title, severalHomes ? target.home ?? "" : "" ].joined( separator: " " )
		return terms.allSatisfy { text.localizedStandardContains( $0 ) }
	}

	private func takeModeRequest() {
		guard let request = modeRequest?.wrappedValue else { return }
		if modes.contains( request ) { mode = request }
		modeRequest?.wrappedValue = nil
	}

	private func syncMode() {
		let bound = TargetMode( kind: assignment.kind )
		mode = modes.contains( bound ) ? bound : ( modes.first ?? .accessory )
		if mode == .shortcut && !controller.shortcutsLoaded {
			controller.reloadShortcuts()
		}
	}

	private var searchPrompt: String {
		switch mode {
			case .accessory: severalHomes ? "Search accessories, rooms, Homes, or types" : "Search accessories, rooms, or types"
			case .scene:     "Search scenes"
			case .shortcut:  "Search shortcuts or folders"
		}
	}

	private var emptyExplanation: String {
		let status = controller.home.authorization
		if !status.contains( .determined ) { return "Waiting for HomeKit access…" }
		if !status.contains( .authorized ) { return "ESPDeck Bridge doesn't have HomeKit access. Allow it in System Settings → Privacy & Security → HomeKit." }
		if controller.home.homes.isEmpty    { return "No HomeKit homes found for this iCloud account." }
		if severalHomes { return mode == .scene ? "No scenes in your Homes." : "No supported accessories in your Homes." }
		return mode == .scene ? "No scenes in this home." : "No supported accessories in this home."
	}
}
