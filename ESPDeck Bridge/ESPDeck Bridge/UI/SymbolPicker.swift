//
//  SymbolPicker.swift
//  ESPDeck Bridge
//
//  Searchable grid of SF Symbols, shown in a popover from an icon well.
//

import SwiftUI

struct SymbolPicker: View {
	let current     : String?
	let removeTitle : String
	/// The state has an icon of its own to remove.
	let canRemove   : Bool
	let onPick      : ( String ) -> Void
	let onRemove    : () -> Void

	@State private var query    = ""
	@State private var category = "all"
	@FocusState private var searchFocused: Bool

	private let catalog = SymbolCatalog.shared

	var body: some View {
		let symbols = catalog.symbols( matching: query, in: category )

		VStack( alignment: .leading, spacing: 10 ) {
			HStack {
				TextField( "Search symbols", text: $query )
					.textFieldStyle( .roundedBorder )
					.focused( $searchFocused )
					.onSubmit {
						// Accept an exact symbol name even if it isn't in the catalog.
						let name = query.trimmingCharacters( in: .whitespaces )
						if UIImage( systemName: name ) != nil { onPick( name ) }
					}

				if !catalog.categories.isEmpty {
					Picker( "Category", selection: $category ) {
						ForEach( catalog.categories ) { category in
							Label( category.title, systemImage: category.icon ).tag( category.key )
						}
					}
					.labelsHidden()
					.frame( width: 170 )
				}
			}

			ScrollView {
				LazyVGrid( columns: [ GridItem( .adaptive( minimum: 44 ), spacing: 6 ) ], spacing: 6 ) {
					ForEach( symbols, id: \.self ) { name in
						Button {
							onPick( name )
						} label: {
							Image( systemName: name )
								.font( .system( size: 20 ) )
								.frame( width: 44, height: 40 )
								.background( RoundedRectangle( cornerRadius: 6 ).fill( name == current ? Color.accentColor.opacity( 0.35 ) : Color.clear ) )
								.contentShape( Rectangle() )
						}
						.buttonStyle( .plain )
						.help( name )
					}
				}
			}

			HStack {
				Text( symbols.isEmpty ? "No matching symbols. Press Return to use a name exactly as typed." : "\(symbols.count) symbols" )
					.font( .caption )
					.foregroundStyle( .secondary )
				Spacer()
				Button( removeTitle, role: .destructive, action: onRemove )
					.disabled( !canRemove )
			}
		}
		.padding( 14 )
		.frame( width: 460, height: 420 )
		.onAppear { searchFocused = true }
	}
}
