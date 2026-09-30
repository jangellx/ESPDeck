//
//  SearchField.swift
//  ESPDeck Bridge
//
//  A text field that looks like a search field: a magnifying glass in front and a clear
//  button once there's text. SwiftUI's .searchable belongs to navigation bars and toolbars,
//  not to a field in a form.
//

import SwiftUI

/// A search-styled text field, with an optional focus binding.
struct SearchField: View {
	let prompt       : String
	@Binding var text: String
	var focus        : FocusState<Bool>.Binding?

	var body: some View {
		HStack( spacing: 5 ) {
			Image( systemName: "magnifyingglass" )
				.foregroundStyle( Color.secondary )
				.imageScale( .small )
				.accessibilityHidden( true )

			field

			if !text.isEmpty {
				Button {
					text = ""
				} label: {
					Image( systemName: "xmark.circle.fill" )
						.foregroundStyle( Color.secondary )
				}
				.buttonStyle( .borderless )
				.help( "Clear" )
			}
		}
		.padding( .horizontal, 10 )
		.padding( .vertical, 5 )
		.background( Capsule().fill( Color( uiColor: .tertiarySystemFill ) ) )   // as Apple's search fields
	}

	/// The text field itself, focused through `focus` when there is one.
	@ViewBuilder
	private var field: some View {
		let field = TextField( prompt, text: $text, prompt: Text( prompt ) )
			.textFieldStyle( .plain )
			.accessibilityLabel( prompt )
		if let focus {
			field.focused( focus )
		} else {
			field
		}
	}
}
