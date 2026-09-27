//
//  KeyInspectorView.swift
//  ESPDeck Bridge
//
//  Assignment, action, label, and per-state icons for the selected key.
//

import SwiftUI

struct KeyInspectorView: View {
	let controller : DeckController
	let deviceID   : String
	let key        : Int

	@State private var confirmingClear = false

	private var assignment: KeyAssignment { controller.assignment( deviceID, key: key ) }

	var body: some View {
		Form {
			Section {
				TargetPicker( controller: controller, assignment: assignment,
							  edit: { change in controller.update( device: deviceID, key: key, change ) } ) { target in
					controller.update( device: deviceID, key: key ) { $0.bind( to: target ) }
				}
				.id( "\(deviceID)/\(key)" )   // fresh mode and search for each key

				if let kind = assignment.kind {
					Picker( "On Press", selection: binding( \.action ) ) {
						ForEach( kind.actions ) { action in
							Text( action.title ).tag( action )
						}
					}
					LabeledContent( "State", value: controller.state( device: deviceID, key: key ).title )
				}
			} header: {
				Text( "Key \(key + 1)" )
			}

			PillRow {
				Pill {
					Button( "Test Action" ) { controller.press( device: deviceID, key: key ) }
						.disabled( assignment.kind == nil || assignment.action == .none )
				}
			}

			Section( "Appearance" ) {
				Toggle( "Show Label", isOn: binding( \.showLabel ) )
				TextField( "Label", text: binding( \.label ), prompt: Text( controller.defaultName( for: assignment ) ?? "Label" ) )
					.disabled( !assignment.showLabel )

				ColorPicker( "Background", selection: backgroundBinding, supportsOpacity: false )
			}

			Section {
				LazyVGrid( columns: [ GridItem( .adaptive( minimum: 76 ), alignment: .top ) ], spacing: 14 ) {
					ForEach( [ KeyState.standard ] + ( assignment.kind?.states ?? [] ) ) { state in
						let face = controller.face( device: deviceID, key: key, state: state )
						IconWell( title: state.title,
								  face: face,
								  icon: controller.artwork( for: face ),
								  hasCustomIcon: assignment.icons[state.rawValue] != nil,
								  customSymbol: assignment.symbol( for: state ),
								  isCurrent: isShowing( state ),
								  onDrop: { controller.setIcon( data: $0, device: deviceID, key: key, state: state ) },
								  onPickSymbol: { controller.setSymbol( $0, device: deviceID, key: key, state: state ) },
								  onRemove: { controller.removeIcon( device: deviceID, key: key, state: state ) } )
					}
				}
				.padding( .vertical, 6 )
			} header: {
				Text( "Icons" )
			} footer: {
				Text( "Click a state to choose an SF Symbol, or drag an image onto it from Finder, a browser, or another app. States without their own icon use Default's; with none at all, the key shows the built-in symbols shown here. Dashed outlines mark states without their own icon." )
			}

			// Copy and Paste together, then a divider, then the destructive Clear Key.
			PillRow {
				VStack( spacing: 10 ) {
					Pill {
						Button( "Copy Key" ) { controller.copyKey( device: deviceID, key: key ) }
							.help( "Copy this key (⌘C)" )
						Divider()
							.frame( height: 18 )
						Button( "Paste Key" ) { controller.pasteKey( device: deviceID, key: key ) }
							.disabled( !controller.clipboardHasKey )
							.help( "Replace this key with the copied one (⌘V)" )
					}

					Divider()
						.frame( maxWidth: 240 )

					Pill {
						Button( "Clear Key", role: .destructive ) { confirmingClear = true }
							.confirmationDialog( "Clear Key \(key + 1)?", isPresented: $confirmingClear ) {
								Button( "Clear Key", role: .destructive ) { controller.clear( device: deviceID, key: key ) }
							} message: {
								Text( "This removes the key's accessory, action, label, background color, and icons." )
							}
					}
				}
			}
		}
		.formStyle( .grouped )
		.headerProminence( .increased )
	}

	/// The current state has its own icon, or falls back to Default.
	private func isShowing( _ state: KeyState ) -> Bool {
		let current = controller.state( device: deviceID, key: key )
		if state == current { return true }
		return state == .standard && assignment.icons[current.rawValue] == nil
	}

	private func binding<Value>( _ path: WritableKeyPath<KeyAssignment, Value> ) -> Binding<Value> {
		Binding {
			controller.assignment( deviceID, key: key )[keyPath: path]
		} set: { value in
			controller.update( device: deviceID, key: key ) { $0[keyPath: path] = value }
		}
	}

	private var backgroundBinding: Binding<Color> {
		Binding {
			assignment.backgroundColor.flatMap( Color.init( hex: ) ) ?? .black
		} set: { color in
			controller.update( device: deviceID, key: key ) { $0.backgroundColor = color.hex }
		}
	}
}
