//
//  MenuOptionRows.swift
//  ESPDeck Bridge
//
//  A menu's own settings, as Form rows: whether it dismisses on action, and where its Close
//  key is and what it shows. Shown for the key that opens the menu, and by
//  the inspector's Menu tab while the menu is open (MenuInspector).
//

import SwiftUI

/// Whether a menu dismisses on action, and its Close key.
struct MenuOptionRows: View {
	let controller : DeckController
	let deviceID   : String
	let menuID     : UUID

	/// A Close key symbol's button, and the gap between two of them.
	private static let symbolSize    : CGFloat = 30
	private static let symbolSpacing : CGFloat = 6
	/// The width of the widest icon grid (Back's five across), which the controls above it match.
	private static let controlWidth  = 5 * symbolSize + 4 * symbolSpacing

	private var menu: DeckMenu? {
		controller.settings( deviceID )?.menus.first { $0.id == menuID }
	}

	var body: some View {
		if let menu {
			// Animated: the description under it changes length, and the rows below move.
			Toggle( isOn: Binding {
				menu.closesOnAction
			} set: { closes in
				withAnimation( .easeInOut( duration: 0.2 ) ) {
					controller.updateMenu( device: deviceID, menuID ) { $0.closesOnAction = closes }
				}
			} ) {
				Text( "Dismiss on Action" )
				Text( menu.closesOnAction
					  ? "Pressing a key in the menu runs the key and closes the menu. Level keys keep the menu open, since they step while held."
					  : "The menu stays open until its Close key is pressed." )
			}
			.toggleStyle( .switch )

			LabeledContent( "Close Key" ) {
				Picker( "Close Key", selection: Binding {
					menu.closeStyle
				} set: { style in
					controller.setMenuCloseStyle( device: deviceID, menuID, style )
				} ) {
					ForEach( MenuCloseStyle.allCases ) { style in
						Label( style.title, systemImage: style.symbols[0] ).tag( style )
					}
				}
				.labelsHidden()
				.scaledFrame( width: Self.controlWidth )
			}

			LabeledContent( "Icon" ) {
				// Two rows: five across for Back, four for Close.
				let symbols = menu.closeStyle.symbols
				let across  = ( symbols.count + 1 ) / 2
				Grid( horizontalSpacing: Self.symbolSpacing, verticalSpacing: Self.symbolSpacing ) {
					ForEach( [ Array( symbols.prefix( across ) ), Array( symbols.dropFirst( across ) ) ], id: \.self ) { row in
						GridRow {
							ForEach( row, id: \.self ) { symbol in
								symbolButton( symbol, chosen: symbol == menu.symbol )
							}
						}
					}
				}
				// Centered under the popup, which is as wide as Back's five across.
				.scaledFrame( width: Self.controlWidth )
			}
			.padding( .top, 2 )
			.padding( .bottom, 8 )
		}
	}

	/// One of the Close key's symbols; the chosen one is filled in the accent color.
	private func symbolButton( _ symbol: String, chosen: Bool ) -> some View {
		Button {
			controller.updateMenu( device: deviceID, menuID ) { $0.closeSymbol = symbol }
		} label: {
			Image( systemName: symbol )
				.foregroundStyle( chosen ? Color.white : Color.primary )
				.scaledFrame( width: Self.symbolSize, height: Self.symbolSize )
				.background( RoundedRectangle( cornerRadius: 7 ).fill( chosen ? AnyShapeStyle( Color.accentColor ) : AnyShapeStyle( .quaternary ) ) )
				.contentShape( Rectangle() )
		}
		.buttonStyle( .plain )
		.accessibilityLabel( symbol )
		.accessibilityAddTraits( chosen ? .isSelected : [] )
	}
}

/// The inspector while a menu is open: Menu (the menu's settings) or Key (the selected key
/// of the menu) above whichever is chosen, with a button that closes the menu. The deck
/// preview beside it shows the menu, so its settings can be seen as they change.
struct MenuInspector<KeyForm: View>: View {
	let controller : DeckController
	let deviceID   : String
	let key        : Int
	let menu       : DeckMenu
	/// The selected key's own settings, as outside a menu.
	@ViewBuilder let keyForm: KeyForm

	private var tab: MenuInspectorTab { controller.window.menuInspectorTab }

	var body: some View {
		VStack( spacing: 0 ) {
			HStack( spacing: 10 ) {
				// Back out of the menu, to the page.
				Button {
					controller.closeMenu( device: deviceID )
				} label: {
					Image( systemName: "chevron.left" )
						.imageScale( .large )
						.fontWeight( .semibold )
				}
				.buttonStyle( .borderless )
				.help( "Close Menu" )
				.accessibilityLabel( "Close Menu" )

				Picker( "Inspector", selection: Bindable( controller.window ).menuInspectorTab ) {
					ForEach( MenuInspectorTab.allCases ) { tab in
						Text( tab.rawValue ).tag( tab )
					}
				}
				.pickerStyle( .segmented )
				.labelsHidden()
			}
			.padding( .horizontal, 20 )
			.padding( .top, 12 )
			.padding( .bottom, 4 )

			switch tab {
				case .menu:
					Form {
						Section {
							MenuOptionRows( controller: controller, deviceID: deviceID, menuID: menu.id )
						} header: {
							SectionHeader( controller.menuName( device: deviceID, menu.id ) )
						}
					}
					.formStyle( .grouped )
				case .key:
					if controller.isMenuClose( device: deviceID, key: key ) {
						closeKeyForm
					} else {
						keyForm
					}
			}
		}
		.background( Color( uiColor: .systemGroupedBackground ) )
	}

	/// The Close key has nothing of its own to edit: its place and icon are the menu's.
	private var closeKeyForm: some View {
		Form {
			Section {
				VStack( alignment: .leading, spacing: 2 ) {
					Text( "Closes the Menu" )
					Text( "This key can't be changed like the menu's other keys. Its place and icon are in the menu's settings." )
						.secondaryCaption()
				}
				.padding( .vertical, 6 )
			} header: {
				SectionHeader( "Key \(key + 1)" )
			}

			PillRow {
				Button( "Menu Settings" ) { controller.window.menuInspectorTab = .menu }
					.buttonStyle( .borderedProminent )
			}
		}
		.formStyle( .grouped )
	}
}
