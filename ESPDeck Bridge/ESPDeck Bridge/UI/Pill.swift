//
//  Pill.swift
//  ESPDeck Bridge
//
//  Capsule-shaped button groups: one or more text buttons in a single pill, separated by
//  Dividers. PillRow centers a pill on its own row in a grouped Form.
//

import SwiftUI

struct Pill<Content: View>: View {
	@ViewBuilder let content: Content

	var body: some View {
		HStack( spacing: 0 ) {
			content
		}
		.buttonStyle( PillSegmentStyle() )
		.background( Capsule().fill( Color.secondary.opacity( 0.14 ) ) )
		.fixedSize()
	}
}

/// A Form row holding a centered pill, with no row background of its own.
struct PillRow<Content: View>: View {
	@ViewBuilder let content: Content

	var body: some View {
		Section {
			HStack {
				Spacer( minLength: 0 )
				content
				Spacer( minLength: 0 )
			}
			.listRowBackground( Color.clear )
			.listRowInsets( EdgeInsets( top: 0, leading: 0, bottom: 0, trailing: 0 ) )
		}
		.listSectionSpacing( .compact )
	}
}

/// One button inside a Pill: padded text in the tint color (red for destructive), dimmed
/// while pressed or disabled. The pill draws the background.
struct PillSegmentStyle: ButtonStyle {
	@Environment( \.isEnabled ) private var isEnabled

	func makeBody( configuration: Configuration ) -> some View {
		configuration.label
			.fontWeight( .medium )
			.foregroundStyle( configuration.role == .destructive ? Color.red : Color.accentColor )
			.padding( .horizontal, 18 )
			.padding( .vertical, 7 )
			.contentShape( Capsule() )
			.opacity( !isEnabled ? 0.35 : configuration.isPressed ? 0.55 : 1 )
	}
}

/// An item in a menu used as a popup: a checkmark beside the current choice.
struct MenuChoice: View {
	let title  : String
	let chosen : Bool

	var body: some View {
		if chosen {
			Label( title, systemImage: "checkmark" )
		} else {
			Text( title )
		}
	}
}
