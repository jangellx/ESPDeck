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

	/// Slider chosen for this key, before its other key is picked.
	@State private var choosingPartner = false

	var body: some View {
		Form {
			Section {
				TargetPicker( controller: controller, assignment: assignment, modes: TargetMode.allCases,
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
					// Lights and fans with a level: switch them, or step the level with two keys.
					if !levels.isEmpty {
						Picker( "Type", selection: sliderTypeBinding ) {
							Text( "Toggle" ).tag( false )
							Text( "Level" ).tag( true )
						}
						.pickerStyle( .segmented )
					}
					// The command is chosen above; Go to Page needs its page.
					if kind == .page && assignment.action == .goToPage {
						let pageCount = controller.pageCount( device: deviceID )
						Stepper( value: Binding {
							min( max( assignment.pageNumber ?? 1, 1 ), max( pageCount, 1 ) )
						} set: { page in
							controller.update( device: deviceID, key: key ) { $0.pageNumber = page }
						}, in: 1...max( pageCount, 1 ) ) {
							LabeledContent( "Page", value: "\(min( assignment.pageNumber ?? 1, max( pageCount, 1 ) )) of \(pageCount)" )
						}
					}
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
			}

			// What a press does: Toggle (or the kind's actions), or Level's two keys.
			if let kind = assignment.kind, kind != .page {
				if isSlider {
					SliderSection( controller: controller, deviceID: deviceID, key: key, levels: levels )
				} else {
					Section {
						onPressMenu
						stateRow
					} header: {
						SectionHeader( levels.isEmpty ? "Action" : "Toggle" )
					} footer: {
						if assignment.isToggleShortcut {
							Text( "Each press runs the shortcut with \u{201C}on\u{201D} or \u{201C}off\u{201D} as its Shortcut Input: the state the key is switching to. If the shortcut ends with Stop and Output of \u{201C}on\u{201D} or \u{201C}off\u{201D}, the key shows that state instead." )
						}
					}
				}
			}

			PillRow {
				Pill {
					Button( "Test Action" ) { controller.press( device: deviceID, key: key ) }
						.disabled( assignment.kind == nil || ( assignment.action == .none && assignment.slider == nil ) )
				}
			}

			Section {
				TextField( "Label", text: binding( \.label ), prompt: Text( controller.defaultName( for: assignment ) ?? "Label" ) )
					.disabled( !assignment.showLabel )
				Toggle( "Show Label", isOn: binding( \.showLabel ) )
					.toggleStyle( .switch )

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
								  onDrop: { controller.setIcon( dropped: $0, device: deviceID, key: key, state: state ) },
								  onPickSymbol: { controller.setSymbol( $0, device: deviceID, key: key, state: state ) },
								  onRemove: { controller.removeIcon( device: deviceID, key: key, state: state ) } )
					}
				}
				.padding( .vertical, 6 )
			} header: {
				SectionHeader( "Icons" )
			} footer: {
				Text( "Click a state to choose an SF Symbol, or drag an image onto it. States without their own icon use Default's, filled for On. Icons with dashed outlines are set to Default." )
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
					}
				}
			}
		}
		.formStyle( .grouped )
		// On the form, not the Clear Key button: rows scrolled out of view aren't built, and
		// the Delete key (Edit ▸ Clear Key) then got no dialog until the button came into view.
		.confirmationDialog( "Clear Key \(key + 1)?", isPresented: confirmingClear ) {
			if let partner = assignment.slider?.partner {
				Button( "Clear Both Level Keys", role: .destructive ) { controller.clear( device: deviceID, key: key ) }
				Button( "Clear Key \(key + 1) Only", role: .destructive ) { controller.clear( device: deviceID, key: key, keepingPartner: true ) }
					.help( "Key \(partner + 1) stays, as an ordinary key" )
			} else {
				Button( "Clear Key", role: .destructive ) { controller.clear( device: deviceID, key: key ) }
			}
		} message: {
			if let partner = assignment.slider?.partner {
				Text( "This removes the key's accessory, action, label, background color, and icons. It's one of a pair of Level keys with Key \(partner + 1), which can be cleared too, or kept as an ordinary key." )
			} else {
				Text( "This removes the key's accessory, action, label, background color, and icons." )
			}
		}
		.onChange( of: key ) { choosingPartner = false }
		.onChange( of: assignment.slider != nil ) { if assignment.slider != nil { choosingPartner = false } }
	}

	private var stateRow: some View {
		LabeledContent( "State", value: controller.state( device: deviceID, key: key ).title )
	}

	private var levels: [SliderLevel] { controller.sliderLevels( for: assignment ) }

	/// A menu rather than a Picker: in a Form, a Picker whose options change (another key, a
	/// shortcut's actions then a light's) kept showing the old choice. This label is always
	/// the key's current action.
	private var onPressMenu: some View {
		let current = assignment
		return LabeledContent( "On Press" ) {
			Menu {
				ForEach( current.actions ) { action in
					Button {
						controller.update( device: deviceID, key: key ) { $0.action = action }
					} label: {
						if action == current.action {
							Label( action.title, systemImage: "checkmark" )
						} else {
							Text( action.title )
						}
					}
				}
			} label: {
				Text( current.actions.contains( current.action ) ? current.action.title : "Choose…" )
			}
			.fixedSize()
		}
	}

	private var isSlider: Bool { assignment.slider != nil || choosingPartner }

	/// Slider waits for the other key to be chosen; Toggle ends the pair (clearing its other key).
	private var sliderTypeBinding: Binding<Bool> {
		Binding {
			isSlider
		} set: { slider in
			if slider {
				choosingPartner = true
			} else {
				choosingPartner = false
				controller.removeSlider( device: deviceID, key: key )
			}
		}
	}

	/// Shared with Edit ▸ Clear Key.
	private var confirmingClear: Binding<Bool> {
		Binding { controller.window.confirmingClearKey } set: { controller.window.confirmingClearKey = $0 }
	}

	/// Key ▸ Assign Accessory/Scene/Shortcut.
	private var modeRequest: Binding<TargetMode?> {
		Binding { controller.window.requestedTargetMode } set: { controller.window.requestedTargetMode = $0 }
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
