//
//  InfoButton.swift
//  ESPDeck Bridge
//
//  An ⓘ button that shows an explanation in a popover, for controls whose details would
//  otherwise need a paragraph under the section.
//

import SwiftUI

/// An ⓘ that shows `text` in a popover; `help` is its tooltip and spoken name.
struct InfoButton: View {
	let help : String
	let text : String

	@State private var showing = false

	var body: some View {
		Button {
			showing = true
		} label: {
			Image( systemName: "info.circle" )
		}
		.buttonStyle( .borderless )
		.help( help )
		.accessibilityLabel( help )
		.popover( isPresented: $showing ) {
			Text( text )
				.frame( width: 280 )
				.fixedSize( horizontal: false, vertical: true )
				.padding()
		}
	}
}
