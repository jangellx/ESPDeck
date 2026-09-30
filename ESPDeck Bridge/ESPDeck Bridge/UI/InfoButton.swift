//
//  InfoButton.swift
//  ESPDeck Bridge
//
//  An ⓘ button that shows an explanation in a popover, for controls whose details would
//  otherwise need a paragraph under the section.
//

import SwiftUI

/// An ⓘ that shows `text` in a popover; `help` is its tooltip and spoken name. The text is
/// Markdown (bold, links; line breaks kept), and following a link closes the popover.
struct InfoButton: View {
	let help : String
	let text : String

	@State private var showing = false
	@Environment( \.openURL ) private var openURL

	/// `text` with its Markdown applied, or as it is if it isn't valid Markdown.
	private var styled: AttributedString {
		( try? AttributedString( markdown: text, options: .init( interpretedSyntax: .inlineOnlyPreservingWhitespace ) ) )
			?? AttributedString( text )
	}

	var body: some View {
		Button {
			showing = true
		} label: {
			Image( systemName: "info.circle" )
				.sidebarAccent()   // white on a selected sidebar row
		}
		.buttonStyle( .borderless )
		.help( help )
		.accessibilityLabel( help )
		.popover( isPresented: $showing ) {
			Text( styled )
				.frame( width: 280 )
				.fixedSize( horizontal: false, vertical: true )
				.padding()
				.environment( \.openURL, OpenURLAction { url in
					showing = false
					openURL( url )
					return .handled
				} )
		}
	}
}
