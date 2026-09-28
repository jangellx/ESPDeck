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

	private var assignment: KeyAssignment { controller.assignment( deviceID, key: key ) }

	var body: some View {
		Form {
			Section {
				TargetPicker( controller: controller, assignment: assignment,
							  edit: { change in controller.update( device: deviceID, key: key, change ) },
							  modeRequest: modeRequest ) { target in
					controller.update( device: deviceID, key: key ) { $0.bind( to: target ) }
				}
				.id( "\(deviceID)/\(key)" )   // fresh mode and search for each key

				if let kind = assignment.kind {
					if kind == .shortcut {
						Picker( "Type", selection: shortcutTogglesBinding ) {
							Text( "One-Shot" ).tag( false )
							Text( "On/Off" ).tag( true )
						}
						.pickerStyle( .segmented )
					}
					Picker( "On Press", selection: binding( \.action ) ) {
						ForEach( assignment.actions ) { action in
							Text( action.title ).tag( action )
						}
					}
					LabeledContent( "State", value: controller.state( device: deviceID, key: key ).title )
				}
			} header: {
				let cols = max( controller.layout( deviceID ).cols, 1 )
				HStack( alignment: .firstTextBaseline ) {
					SectionHeader( "Key \(key + 1)" )
					Spacer()
					Text( "Row \(key / cols + 1), Column \(key % cols + 1)" )
						.font( .subheadline )
						.foregroundStyle( Color.secondary )   // not .secondary: see SectionHeader
						.textCase( nil )
				}
			} footer: {
				// In the footer, so the button sits right under the section it tests.
				VStack( alignment: .leading, spacing: 10 ) {
					Pill {
						Button( "Test Action" ) { controller.press( device: deviceID, key: key ) }
							.disabled( assignment.kind == nil || assignment.action == .none )
					}
					.font( .body )   // footers use a smaller font; match the other pills
					.frame( maxWidth: .infinity )
					if assignment.isToggleShortcut {
						Text( "Each press runs the shortcut with \u{201C}on\u{201D} or \u{201C}off\u{201D} as its Shortcut Input: the state the key is switching to. If the shortcut ends with Stop and Output of \u{201C}on\u{201D} or \u{201C}off\u{201D}, the key shows that state instead." )
					}
				}
				.padding( .top, 4 )
			}

			Section {
				Toggle( "Show Label", isOn: binding( \.showLabel ) )
				TextField( "Label", text: binding( \.label ), prompt: Text( controller.defaultName( for: assignment ) ?? "Label" ) )
					.disabled( !assignment.showLabel )

				ColorPicker( "Background", selection: backgroundBinding, supportsOpacity: false )
			} header: {
				SectionHeader( "Appearance" )
			}

			Section {
				LazyVGrid( columns: [ GridItem( .adaptive( minimum: 76 ), alignment: .top ) ], spacing: 14 ) {
					ForEach( [ KeyState.standard ] + assignment.states ) { state in
						let face = controller.face( device: deviceID, key: key, state: state )
						IconWell( title: state.title,
								  face: face,
								  icon: controller.artwork( for: face ),
								  hasCustomIcon: assignment.icons[state.rawValue] != nil,
								  customSymbol: assignment.symbol( for: state ),
								  isCurrent: isShowing( state ),
								  onDrop: { controller.setIcon( dropped: $0, device: deviceID, key: key, state: state ) },
								  onPickSymbol: { controller.setSymbol( $0, device: deviceID, key: key, state: state ) },
								  onRemove: { controller.removeIcon( device: deviceID, key: key, state: state ) } )
					}
				}
				.padding( .vertical, 6 )
			} header: {
				SectionHeader( "Icons" )
			} footer: {
				Text( "Click a state to choose an SF Symbol, or drag an image onto it. States without their own icon use Default's, filled for On." )
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
						Button( "Clear Key", role: .destructive ) { controller.window.confirmingClearKey = true }
							.confirmationDialog( "Clear Key \(key + 1)?", isPresented: confirmingClear ) {
								Button( "Clear Key", role: .destructive ) { controller.clear( device: deviceID, key: key ) }
							} message: {
								Text( "This removes the key's accessory, action, label, background color, and icons." )
							}
					}
				}
			}
		}
		.formStyle( .grouped )
	}

	/// Shared with Edit ▸ Clear Key.
	private var confirmingClear: Binding<Bool> {
		Binding { controller.window.confirmingClearKey } set: { controller.window.confirmingClearKey = $0 }
	}

	/// Key ▸ Assign Accessory/Scene/Shortcut.
	private var modeRequest: Binding<TargetMode?> {
		Binding { controller.window.requestedTargetMode } set: { controller.window.requestedTargetMode = $0 }
	}

	/// The current state has its own icon, or falls back to Default.
	private func isShowing( _ state: KeyState ) -> Bool {
		let current = controller.state( device: deviceID, key: key )
		if state == current { return true }
		return state == .standard && assignment.icons[current.rawValue] == nil
	}

	/// One-Shot or On/Off, for shortcut keys. Switching picks that type's first action.
	private var shortcutTogglesBinding: Binding<Bool> {
		Binding {
			assignment.isToggleShortcut
		} set: { toggles in
			controller.update( device: deviceID, key: key ) { assignment in
				assignment.shortcutToggles = toggles ? true : nil
				assignment.shortcutState   = nil
				assignment.action          = assignment.actions.first ?? .none
			}
		}
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
