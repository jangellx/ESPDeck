//
//  MenuOptionRows.swift
//  ESPDeck Bridge
//
//  A menu's own settings, as Form rows: how it closes and, for one that's closed manually,
//  where its Close key is and what it shows. Shown for the key that opens the menu and for
//  the Close key itself.
//

import SwiftUI

/// How a menu closes, and its Close key.
struct MenuOptionRows: View {
	let controller : DeckController
	let deviceID   : String
	let menuID     : UUID

	private var menu: DeckMenu? {
		controller.settings( deviceID )?.menus.first { $0.id == menuID }
	}

	var body: some View {
		if let menu {
			Picker( "Closes", selection: binding( \.dismissal, of: menu ) ) {
				ForEach( MenuDismissal.allCases ) { dismissal in
					Text( dismissal.title ).tag( dismissal )
				}
			}
			.pickerStyle( .segmented )

			if menu.dismissal == .manual {
				Picker( "Close Key", selection: Binding {
					menu.closeStyle
				} set: { style in
					controller.updateMenu( device: deviceID, menuID ) { menu in
						menu.closeStyle  = style
						menu.closeSymbol = nil   // the other style's symbols
					}
				} ) {
					ForEach( MenuCloseStyle.allCases ) { style in
						Label( style.title, systemImage: style.symbols[0] ).tag( style )
					}
				}

				LabeledContent( "Icon" ) {
					LazyVGrid( columns: [ GridItem( .adaptive( minimum: 30 ), spacing: 6 ) ], alignment: .trailing, spacing: 6 ) {
						ForEach( menu.closeStyle.symbols, id: \.self ) { symbol in
							symbolButton( symbol, chosen: symbol == menu.symbol )
						}
					}
				}
			}

			Text( menu.dismissal == .onAction
				  ? "Pressing a key in the menu runs the key and closes the menu. Level keys keep the menu open, since they step while held."
				  : "The menu stays open until its Close key is pressed. The Close key takes the menu's \( menu.closeStyle == .back ? "top left" : "top right" ) key." )
				.secondaryCaption()
		}
	}

	/// One of the Close key's symbols; the chosen one is filled in the accent color.
	private func symbolButton( _ symbol: String, chosen: Bool ) -> some View {
		Button {
			controller.updateMenu( device: deviceID, menuID ) { $0.closeSymbol = symbol }
		} label: {
			Image( systemName: symbol )
				.foregroundStyle( chosen ? Color.white : Color.primary )
				.scaledFrame( width: 30, height: 30 )
				.background( RoundedRectangle( cornerRadius: 7 ).fill( chosen ? AnyShapeStyle( Color.accentColor ) : AnyShapeStyle( .quaternary ) ) )
				.contentShape( Rectangle() )
		}
		.buttonStyle( .plain )
		.accessibilityLabel( symbol )
		.accessibilityAddTraits( chosen ? .isSelected : [] )
	}

	/// One of the menu's settings.
	private func binding<Value>( _ path: WritableKeyPath<DeckMenu, Value>, of menu: DeckMenu ) -> Binding<Value> {
		Binding {
			menu[keyPath: path]
		} set: { value in
			controller.updateMenu( device: deviceID, menuID ) { $0[keyPath: path] = value }
		}
	}
}

/// The inspector for an open menu's Close key, which has nothing of its own to edit: the
/// menu's settings, and a way out of the menu.
struct MenuCloseKeyInspector: View {
	let controller : DeckController
	let deviceID   : String
	let key        : Int
	let menu       : DeckMenu

	var body: some View {
		Form {
			Section {
				MenuOptionRows( controller: controller, deviceID: deviceID, menuID: menu.id )
			} header: {
				VStack( alignment: .leading, spacing: 4 ) {
					SectionHeader( "Key \(key + 1): Close Menu" )
					Text( "This key closes the menu. It can't be changed like the menu's other keys." )
						.secondaryCaption()
						.textCase( nil )
				}
			}

			PillRow {
				Button( "Close Menu" ) { controller.closeMenu( device: deviceID ) }
					.buttonStyle( .borderedProminent )
			}
		}
		.formStyle( .grouped )
	}
}
