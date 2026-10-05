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

/// The picker's tabs: what kind of thing an assignment controls.
enum TargetMode: String, CaseIterable, Identifiable {
	/// One accessory (sleep triggers, which watch one).
	case accessory = "Accessory"
	/// Only what kind a scene is: there's no Scene tab, the Home tab lists scenes.
	case scene     = "Scene"
	/// Keys and commands: any mix of accessories and scenes, from a Home-style sheet.
	case home      = "Home"
	case shortcut  = "Shortcut"
	/// Keys only: page commands.
	case page      = "Page"

	var id: String { rawValue }

	/// Keys' tabs, and sleep and wake commands'.
	static let keyModes: [TargetMode]  = [ .home, .shortcut, .page ]
	static let homeModes: [TargetMode] = [ .home, .shortcut ]

	/// The tab showing a kind among `modes`: accessories and scenes share Home.
	static func of( _ kind: KeyKind?, in modes: [TargetMode] ) -> TargetMode {
		let mode = TargetMode( kind: kind )
		return modes.contains( .home ) && ( mode == .accessory || mode == .scene ) ? .home : mode
	}

	/// The mode a kind belongs to; accessories for no kind.
	init( kind: KeyKind? ) {
		switch kind {
			case .scene:    self = .scene
			case .shortcut: self = .shortcut
			case .page:     self = .page
			default:        self = .accessory
		}
	}

	/// Whether this tab lists `target`: Home lists accessories and scenes.
	func includes( _ target: HomeTarget ) -> Bool {
		let mode = TargetMode( kind: target.kind )
		return mode == self || ( self == .home && ( mode == .accessory || mode == .scene ) )
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
		if kind != .power && kind != .fan {
			slider = nil
		}
		if kind != .page {
			pageNumber = nil
		}
		scenes = nil   // a single target
		if target?.kind != nil {
			if kindChanged || !actions.contains( action ) {
				action = actions.first ?? .none
			}
		} else {
			action = .none
		}
	}
}

private extension KeyAssignment {
	/// Adds an accessory to the key's group, or binds to it when there's none yet.
	mutating func addAccessory( _ target: HomeTarget ) {
		guard TargetMode( kind: kind ) == .accessory, !members.isEmpty,
			  let accessoryID = target.accessoryID else {
			bind( to: target )   // the first accessory is the key accessory
			return
		}
		let member = KeyMember( kind: target.kind, accessoryID: accessoryID, serviceID: target.serviceID )
		guard !members.contains( member ) else { return }
		others = ( others ?? [] ) + [ member ]
	}
}

private extension TargetMode {
	/// The search field's prompt for this mode.
	func searchPrompt( severalHomes: Bool ) -> String {
		switch self {
			case .accessory: severalHomes ? "Search accessories, rooms, Homes, or types" : "Search accessories, rooms, or types"
			case .shortcut:  "Search shortcuts or folders"
			case .page, .home, .scene: ""
		}
	}

	/// Why there's nothing to choose: no HomeKit access yet, no homes, or nothing of this kind.
	func emptyExplanation( in controller: DeckController ) -> String {
		let status = controller.home.authorization
		if !status.contains( .determined ) { return "Waiting for HomeKit access…" }
		if !status.contains( .authorized ) { return "ESPDeck Bridge doesn't have HomeKit access. Allow it in System Settings → Privacy & Security → HomeKit." }
		if controller.home.homes.isEmpty    { return "No HomeKit homes found for this iCloud account." }
		return controller.home.hasSeveralHomes ? "No supported accessories in your Homes." : "No supported accessories in this home."
	}
}

/// What an assignment controls: a tab per mode, and each mode's rows.
struct TargetPicker: View {
	let controller : DeckController
	let assignment : KeyAssignment
	var modes      : [TargetMode] = TargetMode.homeModes
	/// Limits accessories to certain kinds, e.g. ones with states for sleep triggers.
	var kindFilter : ( ( KeyKind ) -> Bool )?
	/// Several accessories at once, with one "key accessory": applies a change to the
	/// assignment. Without it, accessories are picked one at a time through onSelect.
	var edit       : ( ( ( inout KeyAssignment ) -> Void ) -> Void )?
	/// A mode to switch to, from the Key menu; cleared once taken.
	var modeRequest: Binding<TargetMode?>?
	let onSelect   : ( HomeTarget? ) -> Void

	@State private var mode = TargetMode.accessory

	var body: some View {
		let targets = targets( for: mode )

		Group {
			if modes.count > 1 {
				TargetModePicker( modes: modes, kind: assignment.kind, mode: $mode )
			}

			if mode == .page {
				PageCommandRows( kind: assignment.kind, action: assignment.action, edit: edit )
			} else if mode == .home {
				ChosenTargetRows( controller: controller, assignment: assignment, edit: edit )
			} else {
				TargetChoiceRows( controller: controller, assignment: assignment, mode: mode, targets: targets, edit: edit, onSelect: onSelect )
			}
		}
		.onAppear {
			syncMode()
			takeModeRequest()
		}
		.onChange( of: assignment.kind ) { syncMode() }
		.onChange( of: modeRequest?.wrappedValue ) { takeModeRequest() }
		.onChange( of: mode ) {
			// TargetChoiceRows clears its own search.
			if modes == TargetMode.keyModes {   // a key's picker
				controller.window.lastKeyTargetMode = mode
			}
			if mode == .shortcut && !controller.shortcutsLoaded {
				controller.reloadShortcuts()
			}
		}
	}

	/// What `mode` offers, limited by kindFilter.
	private func targets( for mode: TargetMode ) -> [HomeTarget] {
		let all = mode == .shortcut ? controller.shortcuts : controller.home.targets().filter { mode.includes( $0 ) }
		guard let kindFilter else { return all }
		return all.filter { kindFilter( $0.kind ) }
	}

	/// Switches to the mode the Key menu asked for, once.
	private func takeModeRequest() {
		guard let request = modeRequest?.wrappedValue else { return }
		if modes.contains( request ) { mode = request }
		modeRequest?.wrappedValue = nil
	}

	/// Shows the tab for what's bound, and loads shortcuts when that's their tab.
	private func syncMode() {
		// A blank key keeps the tab the last key was on.
		let bound = assignment.kind == nil && modes == TargetMode.keyModes ? controller.window.lastKeyTargetMode : TargetMode.of( assignment.kind, in: modes )
		mode = modes.contains( bound ) ? bound : ( modes.first ?? .accessory )
		if mode == .shortcut && !controller.shortcutsLoaded {
			controller.reloadShortcuts()
		}
	}
}

// MARK: - Mode tabs

/// The segmented tabs choosing what kind of thing the assignment controls.
private struct TargetModePicker: View {
	let modes : [TargetMode]
	/// What the assignment is bound to now, for the dot.
	let kind  : KeyKind?
	@Binding var mode: TargetMode

	var body: some View {
		Picker( "Controls", selection: $mode ) {
			ForEach( modes ) { mode in
				// A dot marks the tab holding what the key does now, to find it again after
				// looking through the others.
				let assigned = kind != nil && TargetMode.of( kind, in: modes ) == mode
				Text( assigned ? "• \(mode.rawValue)" : mode.rawValue ).tag( mode )
			}
		}
		.pickerStyle( .segmented )
	}
}

// MARK: - Home: accessories and scenes

/// Accessories & Scenes: what the key controls (the starred accessory decides its state),
/// each removable, and the sheet to choose them.
private struct ChosenTargetRows: View {
	let controller : DeckController
	let assignment : KeyAssignment
	/// Applies a change to the assignment; without it the rows are read-only.
	let edit       : ( ( ( inout KeyAssignment ) -> Void ) -> Void )?

	/// The Accessories & Scenes sheet is up.
	@State private var choosing = false

	/// Names include their Home only when there's more than one.
	private var severalHomes: Bool { controller.home.hasSeveralHomes }

	var body: some View {
		let targets = controller.home.targets()
		let scenes  = assignment.allScenes
		if TargetMode( kind: assignment.kind ) == .accessory {
			MemberRows( members: assignment.members, targets: targets, severalHomes: severalHomes, adding: false, edit: edit )
		}
		ForEach( scenes, id: \.self ) { id in
			HStack( spacing: 10 ) {
				Image( systemName: "sparkles" )
					.foregroundStyle( Color.orange )
				VStack( alignment: .leading, spacing: 1 ) {
					Text( targets.first { $0.actionSetID == id }?.name ?? "Missing Scene" )
						.lineLimit( 1 )
					Text( [ severalHomes ? targets.first { $0.actionSetID == id }?.home : nil, "Scene" ].compactMap { $0 }.joined( separator: " · " ) )
						.secondaryCaption()
				}
				.frame( maxWidth: .infinity, alignment: .leading )
				RemoveButton {
					edit? { assignment in
						assignment.setHomeTargets( accessories: assignment.members, scenes: assignment.allScenes.filter { $0 != id } )
					}
				}
			}
		}

		let chosen = !assignment.members.isEmpty || !scenes.isEmpty
		Button {
			choosing = true
		} label: {
			Label( chosen ? "Change Accessories & Scenes…" : "Choose Accessories & Scenes…", systemImage: chosen ? "checklist" : "plus" )
		}
		.disabled( edit == nil )
		.sheet( isPresented: $choosing ) {
			HomeTargetSheet( controller: controller, accessories: assignment.members, scenes: scenes ) { accessories, scenes in
				edit? { $0.setHomeTargets( accessories: accessories, scenes: scenes ) }
			}
		}
		if targets.isEmpty {
			Text( TargetMode.home.emptyExplanation( in: controller ) )
				.secondaryCaption()
		}
	}
}

// MARK: - One target

/// The target menu (or several accessories), search, and why the list may be empty.
private struct TargetChoiceRows: View {
	let controller : DeckController
	let assignment : KeyAssignment
	/// Accessory, scene or shortcut.
	let mode       : TargetMode
	/// What the mode offers.
	let targets    : [HomeTarget]
	/// Applies a change to the assignment, for several accessories at once.
	let edit       : ( ( ( inout KeyAssignment ) -> Void ) -> Void )?
	let onSelect   : ( HomeTarget? ) -> Void

	@State private var search = ""

	private static let maxSearchResults = 25

	/// Choosing several accessories at once, rather than one from the menu.
	private var multiple: Bool { edit != nil && mode == .accessory }

	/// Names include their Home only when there's more than one.
	private var severalHomes: Bool { controller.home.hasSeveralHomes }

	var body: some View {
		if multiple {
			MemberRows( members: TargetMode( kind: assignment.kind ) == .accessory ? assignment.members : [], targets: targets, severalHomes: severalHomes, edit: edit )
		} else {
			VStack( alignment: .trailing, spacing: 6 ) {
				// A fixed-width label; long item titles otherwise squeeze it.
				LabeledContent {
					TargetMenu( targets: targets, assignment: assignment, mode: mode, severalHomes: severalHomes, shortcutsLoaded: controller.shortcutsLoaded, onSelect: onSelect )
				} label: {
					Text( mode == .accessory ? "Accessory" : mode.rawValue )
						.fixedSize()
				}
				// In the same row as the popup it reloads.
				if mode == .shortcut {
					ShortcutStatus( controller: controller, isEmpty: targets.isEmpty )
				}
			}
		}

		SearchField( prompt: mode.searchPrompt( severalHomes: severalHomes ), text: $search )
			// Each tab starts with an empty search.
			.onChange( of: mode ) { search = "" }

		if !search.isEmpty {
			let matches = targets.filter( matchesSearch )
			if matches.isEmpty {
				Text( "No matches" )
					.foregroundStyle( .secondary )
			}
			ForEach( matches.prefix( Self.maxSearchResults ) ) { target in
				Button {
					if multiple { edit? { $0.addAccessory( target ) } } else { onSelect( target ) }
					search = ""
				} label: {
					VStack( alignment: .leading, spacing: 2 ) {
						Text( target.name )
						if let detail = detail( for: target ) {
							Text( detail )
								.secondaryCaption()
						}
					}
					.frame( maxWidth: .infinity, alignment: .leading )
					.contentShape( Rectangle() )
				}
				.buttonStyle( .plain )
			}
		}

		if mode != .shortcut && targets.isEmpty {
			Text( mode.emptyExplanation( in: controller ) )
				.secondaryCaption()
		}
	}

	/// Under a search result: its folder, or its Home, room and kind.
	private func detail( for target: HomeTarget ) -> String? {
		let home = severalHomes ? target.home : nil
		return switch target.kind {
			case .shortcut: target.room
			default:        [ home, target.room, target.kind.title ].compactMap { $0 }.joined( separator: " · " )
		}
	}

	/// Every word searched for is in the target's name, room, kind, or Home.
	private func matchesSearch( _ target: HomeTarget ) -> Bool {
		let terms = search.split( separator: " " ).map( String.init )
		let text  = [ target.name, target.room ?? "", target.kind.title, severalHomes ? target.home ?? "" : "" ].joined( separator: " " )
		return terms.allSatisfy { text.localizedStandardContains( $0 ) }
	}
}

/// Room submenus for accessories, folder submenus for shortcuts, a flat list for scenes.
private struct TargetMenu: View {
	let targets         : [HomeTarget]
	let assignment      : KeyAssignment
	let mode            : TargetMode
	/// Names include their Home only when there's more than one.
	let severalHomes    : Bool
	/// Whether the shortcut list has loaded, so a missing one can be told from an unloaded one.
	let shortcutsLoaded : Bool
	let onSelect        : ( HomeTarget? ) -> Void

	var body: some View {
		Menu {
			Button( "None" ) { onSelect( nil ) }
			Divider()

			switch mode {
				case .shortcut:
					// Folders as submenus, unfiled shortcuts at the top level.
					let filed = targets.filter { $0.room != nil }.grouped { $0.room ?? "" }
					ForEach( filed, id: \.key ) { folder in
						Menu( folder.key ) {
							ForEach( folder.elements ) { target in
								menuItem( target, title: target.name )
							}
						}
					}
					let unfiled = targets.filter { $0.room == nil }
					ForEach( unfiled ) { target in
						menuItem( target, title: target.name )
					}
				case .accessory:
					HomeMenus( targets: targets, severalHomes: severalHomes ) { targets in
						RoomMenus( targets: targets, ungroupedTitle: mode.ungroupedTitle ) { target in
							menuItem( target, title: "\(target.name) (\(target.kind.title))" )
						}
					}
				case .page, .home, .scene:
					EmptyView()   // PageCommandRows and ChosenTargetRows, not this menu
			}
		} label: {
			// Menus size to their label, so shorten long names before they push the row wider.
			Text( Self.shortened( currentTitle ) )
				.lineLimit( 1 )
				.truncationMode( .middle )
				.frame( maxWidth: .infinity, alignment: .leading )
		}
	}

	/// A target in the menu, ticked when it's the one bound.
	private func menuItem( _ target: HomeTarget, title: String ) -> some View {
		Button {
			onSelect( target )
		} label: {
			MenuChoice( title: title, chosen: target.matches( assignment ) )
		}
	}

	/// `text` with its middle cut out to fit `limit` characters.
	private static func shortened( _ text: String, limit: Int = 42 ) -> String {
		guard text.count > limit else { return text }
		let half = ( limit - 1 ) / 2
		return String( text.prefix( half ) ) + "…" + String( text.suffix( half ) )
	}

	/// The menu's label: what's bound in this mode, with its Home and room.
	private var currentTitle: String {
		// Something bound in another mode reads as None here.
		guard let kind = assignment.kind, TargetMode( kind: kind ) == mode else { return "None" }
		guard let target = targets.first( where: { $0.matches( assignment ) } ) else {
			switch mode {
				case .accessory: return "Missing Accessory"
				case .shortcut:
					// Before the list loads, show the remembered name rather than "missing".
					return shortcutsLoaded ? "Missing Shortcut" : ( assignment.shortcutName ?? "Shortcut" )
				case .page:
					return assignment.action.title
				case .home, .scene:
					return "Missing"
			}
		}
		let home = severalHomes ? target.home.map { "\($0) › " } ?? "" : ""
		if kind == .shortcut { return target.name }
		let place = target.room.map { "\($0) › " } ?? ""
		return "\(home)\(place)\(target.name) (\(kind.title))"
	}
}

/// Under the Shortcut popup: why the list is empty, if it is, and Reload Shortcuts.
private struct ShortcutStatus: View {
	let controller : DeckController
	/// No shortcuts to choose from.
	let isEmpty    : Bool

	var body: some View {
		HStack( alignment: .firstTextBaseline ) {
			if let error = controller.shortcutError {
				WarningLabel( error )
					.font( .caption )
			} else if isEmpty && controller.shortcutsLoaded {
				Text( "No shortcuts found." )
					.secondaryCaption()
			}
			Spacer()
			Button( "Reload Shortcuts" ) { controller.reloadShortcuts() }
		}
	}
}

// MARK: - Submenus

/// A submenu per Home when there are several; otherwise the content itself.
private struct HomeMenus<Content: View>: View {
	let targets      : [HomeTarget]
	let severalHomes : Bool
	/// The menu items for one Home's targets.
	@ViewBuilder let content: ( [HomeTarget] ) -> Content

	var body: some View {
		if severalHomes {
			ForEach( targets.grouped { $0.home ?? "" }, id: \.key ) { home in
				Menu( home.key ) {
					content( home.elements )
				}
			}
		} else {
			content( targets )
		}
	}
}

/// A submenu per room (or folder), each with `item` for its targets.
private struct RoomMenus<Item: View>: View {
	let targets        : [HomeTarget]
	/// The submenu for targets without a room.
	let ungroupedTitle : String
	/// The menu item for one target.
	@ViewBuilder let item: ( HomeTarget ) -> Item

	var body: some View {
		ForEach( targets.grouped { $0.room ?? ungroupedTitle }, id: \.key ) { room in
			Menu( room.key ) {
				ForEach( room.elements ) { target in
					item( target )
				}
			}
		}
	}
}

// MARK: - Page commands

/// Keys only: which page command. Go to Page's number is the inspector's.
private struct PageCommandRows: View {
	/// What the assignment is bound to now.
	let kind   : KeyKind?
	/// The assignment's action: the page command, once it's bound to a page.
	let action : KeyAction
	/// Applies a change to the assignment; without it nothing can be chosen.
	let edit   : ( ( ( inout KeyAssignment ) -> Void ) -> Void )?

	var body: some View {
		LabeledContent( "Command" ) {
			Picker( "Command", selection: Binding {
				kind == .page ? action : KeyAction.none
			} set: { action in
				guard let edit, action != .none else { return }
				edit { assignment in
					assignment.bind( to: HomeTarget( kind: .page, name: "Page", room: nil ) )
					assignment.action = action
				}
			} ) {
				if kind != .page {
					Text( "Choose…" ).tag( KeyAction.none )
				}
				ForEach( KeyKind.page.actions ) { action in
					Label( action.title, systemImage: Self.pageSymbol( action ) ).tag( action )
				}
			}
			.labelsHidden()
			.fixedSize()
		}
	}

	/// Roughly what each page command's key shows.
	private static func pageSymbol( _ action: KeyAction ) -> String {
		switch action {
			case .nextPage:     "chevron.right"
			case .previousPage: "chevron.left"
			case .firstPage:    "chevron.left.to.line"
			case .lastPage:     "chevron.right.to.line"
			case .goToPage:     "number.circle.fill"
			default:            "doc.fill"
		}
	}
}

// MARK: - Several accessories

/// The key accessory (starred) and the others, then a menu to add more.
private struct MemberRows: View {
	/// The key's accessories, the key accessory first.
	let members      : [KeyMember]
	/// The accessories to name the members from, and to add from.
	let targets      : [HomeTarget]
	/// Names include their Home only when there's more than one.
	let severalHomes : Bool
	/// Whether to offer the menu that adds accessories; the Home sheet adds them otherwise.
	var adding       = true
	/// Applies a change to the assignment.
	let edit         : ( ( ( inout KeyAssignment ) -> Void ) -> Void )?

	var body: some View {
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
					Text( name( of: member ) )
						.lineLimit( 1 )
						.truncationMode( .middle )
					Text( [ place( of: member ), member.kind.title, index == 0 && members.count > 1 ? "key accessory" : nil ].compactMap { $0 }.joined( separator: " · " ) )
						.secondaryCaption()
						.lineLimit( 1 )
				}
				.frame( maxWidth: .infinity, alignment: .leading )

				RemoveButton {
					remove( member )
				}
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

		if !adding {
			EmptyView()   // the sheet adds them
		} else if canAddMore {
			// The hint sits under the button, in the same row.
			VStack( alignment: .leading, spacing: 4 ) {
				Menu {
					HomeMenus( targets: addable, severalHomes: severalHomes ) { targets in
						// Only accessories are added here, so the ungrouped ones have no room.
						RoomMenus( targets: targets, ungroupedTitle: TargetMode.accessory.ungroupedTitle ) { target in
							Button( "\(target.name) (\(target.kind.title))" ) {
								edit? { $0.addAccessory( target ) }
							}
						}
					}
				} label: {
					Label( members.isEmpty ? "Choose Accessory" : "Add Accessory", systemImage: "plus" )
				}
				.fixedSize()
				if members.count == 1 {
					Text( "Add more accessories to control them together with this key." )
						.secondaryCaption()
				}
			}
		} else {
			Text( "Only accessories that can be switched, opened or locked can join a group." )
				.secondaryCaption()
		}
	}

	/// With a key accessory already chosen, only accessories a key press can act on.
	private var addable: [HomeTarget] {
		targets.filter { target in
			!members.contains { $0.accessoryID == target.accessoryID && $0.serviceID == target.serviceID && $0.kind == target.kind }
				&& ( members.isEmpty || target.kind.targetCharacteristicType != nil )
		}
	}

	/// Removes an accessory; removing the key accessory promotes the next one.
	private func remove( _ member: KeyMember ) {
		edit? { assignment in
			let members = assignment.members
			if members.first == member {
				// Promote the next one, or unbind (a key with scenes keeps them).
				guard members.count > 1 else {
					if assignment.allScenes.isEmpty {
						assignment.bind( to: nil )
						assignment.others = nil
					} else {
						assignment.setHomeTargets( accessories: [], scenes: assignment.allScenes )
					}
					return
				}
				assignment.setKeyMember( members[1], others: Array( members.dropFirst( 2 ) ) )
			} else {
				assignment.others = ( assignment.others ?? [] ).filter { $0 != member }
			}
		}
	}

	/// Makes `member` the key accessory, the old one first among the others.
	private func makeKey( _ member: KeyMember ) {
		edit? { assignment in
			let members = assignment.members
			guard let old = members.first, old != member else { return }
			assignment.setKeyMember( member, others: [ old ] + members.dropFirst().filter { $0 != member } )
		}
	}

	/// The accessory's name, or "Missing Accessory" once it's gone from the Home.
	private func name( of member: KeyMember ) -> String {
		targets.first { $0.accessoryID == member.accessoryID && $0.serviceID == member.serviceID && $0.kind == member.kind }?.name ?? "Missing Accessory"
	}

	/// "Room", or "Home · Room" with several Homes.
	private func place( of member: KeyMember ) -> String? {
		guard let target = targets.first( where: { $0.accessoryID == member.accessoryID && $0.serviceID == member.serviceID } ) else { return nil }
		let parts = [ severalHomes ? target.home : nil, target.room ].compactMap { $0 }
		return parts.isEmpty ? nil : parts.joined( separator: " · " )
	}
}

/// A red minus that removes an accessory or scene from the list.
private struct RemoveButton: View {
	let action: () -> Void

	var body: some View {
		Button( action: action ) {
			Image( systemName: "minus.circle.fill" )
				.foregroundStyle( .red )
		}
		.buttonStyle( .borderless )
		.help( "Remove" )
	}
}
