//
//  WhatsNewView.swift
//  ESPDeck Bridge
//
//  The What's New window, in the style of Apple's own: a large title, a few features each
//  with a symbol, a headline and a line or two, and Continue. It's shown before the
//  configuration window, which opens when this one is dismissed.
//

import SwiftUI

/// The What's New window's contents.
struct WhatsNewView: View {
	let whatsNew  : WhatsNew
	/// Continue, or Full Version History (`history` true), which also opens that page.
	let dismiss   : ( _ history: Bool ) -> Void

	var body: some View {
		VStack( spacing: 0 ) {
			Spacer( minLength: 24 )

			Text( whatsNew.title )
				.scaledSystemFont( size: 40, weight: .bold )
				.multilineTextAlignment( .center )
				.padding( .horizontal, 40 )

			VStack( alignment: .leading, spacing: 30 ) {
				ForEach( whatsNew.features ) { feature in
					HStack( alignment: .top, spacing: 22 ) {
						Image( systemName: feature.symbol )
							.scaledSystemFont( size: 34, weight: .regular )
							.foregroundStyle( Color.accentColor )
							.symbolRenderingMode( .hierarchical )
							.scaledFrame( width: 56, alignment: .center )
							.accessibilityHidden( true )
						VStack( alignment: .leading, spacing: 4 ) {
							Text( feature.headline )
								.font( .headline )
							Text( feature.description )
								.font( .subheadline )
								.foregroundStyle( Color.secondary )
								.fixedSize( horizontal: false, vertical: true )
						}
						.accessibilityElement( children: .combine )
					}
				}
			}
			.frame( maxWidth: 400, alignment: .leading )
			.padding( .top, 40 )
			.padding( .bottom, 44 )

			Button {
				dismiss( false )
			} label: {
				Text( "Continue" )
					.fontWeight( .medium )
					.frame( width: 180 )
			}
			.buttonStyle( .borderedProminent )
			.buttonBorderShape( .capsule )
			.controlSize( .large )
			.keyboardShortcut( .defaultAction )

			// Quieter than Continue: everything in this version, on the web. It closes this
			// window as Continue does.
			Button( "Full Version History" ) { dismiss( true ) }
				.buttonStyle( .plain )
				.font( .subheadline )
				.foregroundStyle( Color.accentColor )
				.padding( .top, 14 )
				.help( "Opens the list of everything that changed, on GitHub" )

			Spacer( minLength: 24 )
		}
		.frame( maxWidth: .infinity, maxHeight: .infinity )
		.background( Color( uiColor: .systemBackground ) )
	}
}

#Preview {
	WhatsNewView( whatsNew: WhatsNew( markdown: "# What's New in ESPDeck Bridge\n## Menus\nsymbol: square.grid.2x2.fill\nA key can open a menu of more keys.\n## Copy and Paste Actions\nsymbol: doc.on.doc.fill\nMove a press to another key." ) ) { _ in }
		.frame( width: 760, height: 600 )
}
