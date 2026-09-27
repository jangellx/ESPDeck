//
//  DeviceSettingsView.swift
//  ESPDeck Bridge
//
//  One ESP32's name, display, sleep behavior, and setup mode. Settings the ESP32 owns
//  (name, brightness, orientation, sleep timer) can only change while it's connected.
//

import SwiftUI

struct DeviceSettingsView: View {
	let controller : DeckController
	let deviceID   : String

	@State private var nameDraft        = ""
	@State private var brightness       = 80.0
	@State private var confirmingForget = false
	@State private var confirmingReset  = false
	@FocusState private var nameFocused: Bool

	private static let sleepChoices: [( title: String, seconds: Int )] = [
		( "Never", 0 ), ( "1 minute", 60 ), ( "2 minutes", 120 ), ( "5 minutes", 300 ), ( "10 minutes", 600 ),
		( "15 minutes", 900 ), ( "30 minutes", 1800 ), ( "1 hour", 3600 ), ( "2 hours", 7200 ),
	]

	var body: some View {
		if let settings = controller.settings( deviceID ), let device = controller.device( deviceID ) {
			Group {
				if settings.isDemo {
					demoForm( settings )
				} else {
					form( settings, device )
				}
			}
				.onAppear { syncDrafts( settings ) }
				.onChange( of: deviceID ) { syncDrafts( controller.settings( deviceID ) ) }
				.onChange( of: settings.name ) { nameDraft = settings.name }
				.onChange( of: settings.brightness ) { brightness = Double( settings.brightness ) }
		}
	}

	private func syncDrafts( _ settings: DeviceSettings? ) {
		guard let settings else { return }
		nameDraft  = settings.name
		brightness = Double( settings.brightness )
	}

	private func commitName( _ settings: DeviceSettings ) {
		if nameDraft.trimmingCharacters( in: .whitespacesAndNewlines ).isEmpty {
			nameDraft = settings.name
		} else if nameDraft != settings.name {
			controller.rename( device: deviceID, to: nameDraft )
		}
	}

	/// A demo deck has no hardware: just a name, a model, and ways to move its keys.
	private func demoForm( _ settings: DeviceSettings ) -> some View {
		Form {
			Section {
				TextField( "Name", text: $nameDraft )
					.onSubmit { controller.renameDemo( device: deviceID, to: nameDraft ) }
					.onChange( of: nameDraft ) { controller.renameDemo( device: deviceID, to: nameDraft ) }

				labelPositionPicker

				Picker( "Model", selection: demoModelBinding ) {
					ForEach( DeckLayout.presets, id: \.model ) { layout in
						Text( "\(layout.model) (\(layout.rows) × \(layout.cols))" ).tag( layout.model )
					}
				}
			} header: {
				Text( "Demo Deck" )
			} footer: {
				Text( "A demo deck lets you lay out keys without hardware. Its keys show live HomeKit states and Test Action works; nothing is sent to a device. Changing the model keeps keys that no longer fit, and they return if you switch back." )
			}

			Section {
				CopyKeysMenu( controller: controller, deviceID: deviceID )
				Button( "Delete Demo Deck…", role: .destructive ) { confirmingForget = true }
					.confirmationDialog( "Delete \(settings.name)?", isPresented: $confirmingForget ) {
						Button( "Delete Demo Deck", role: .destructive ) { controller.forget( device: deviceID ) }
					} message: {
						Text( "This removes its key assignments." )
					}
			} footer: {
				Text( "To use this layout on a real deck, open that device's Device page and choose Copy Keys From. Keys are matched by row and column, so layouts carry across deck sizes." )
			}
		}
		.formStyle( .grouped )
	}

	/// Drawn by the bridge, so it can change while the device is offline.
	private var labelPositionPicker: some View {
		Picker( "Labels", selection: Binding {
			controller.settings( deviceID )?.labelPosition ?? .bottom
		} set: { position in
			controller.setLabelPosition( device: deviceID, position )
		} ) {
			ForEach( LabelPosition.allCases ) { position in
				Text( position.title ).tag( position )
			}
		}
		.pickerStyle( .segmented )
	}

	private var demoModelBinding: Binding<String> {
		Binding {
			controller.settings( deviceID )?.layout.model ?? DeckLayout.mini.model
		} set: { model in
			if let layout = DeckLayout.presets.first( where: { $0.model == model } ) {
				controller.setDemoLayout( device: deviceID, layout )
			}
		}
	}

	@ViewBuilder
	private func form( _ settings: DeviceSettings, _ device: DeckDevice ) -> some View {
		let online = device.isOnline

		Form {
			Section {
				// Renamed on Return or when the field loses focus; an empty field goes back to the current name.
				TextField( "Name", text: $nameDraft, prompt: Text( settings.defaultName ) )
					.focused( $nameFocused )
					.onSubmit { commitName( settings ) }
					.onChange( of: nameFocused ) { if !nameFocused { commitName( settings ) } }
				.disabled( !online )

				LabeledContent( "Status" ) {
					let status = controller.status( device: device )
					HStack( spacing: 6 ) {
						StatusIndicator( level: status.level )
						Text( status.text.components( separatedBy: ": " ).last ?? status.text )
					}
				}
				.alignmentGuide( .listRowSeparatorLeading ) { _ in 0 }
				LabeledContent( "Stream Deck", value: deckDescription( settings, device ) )
				FirmwareRow( controller: controller, device: device, title: settings.defaultName )
				LabeledContent( "MAC Address", value: deviceID )
				if let ip = device.ip, online {
					LabeledContent( "IP Address", value: ip )
				}
			} header: {
				Text( "Device" )
			} footer: {
				if !online {
					Text( "This device is offline. Its keys can still be edited; they're sent when it reconnects. Name, display, and sleep timer changes need it online." )
				}
			}

			Section( "Display" ) {
				LabeledContent( "Brightness" ) {
					Slider( value: $brightness, in: 0...100, step: 5 ) { editing in
						if !editing { controller.setBrightness( device: deviceID, Int( brightness ) ) }
					}
				}
				.disabled( !online )
				Picker( "Image Orientation", selection: orientationBinding ) {
					Text( "Automatic (\(defaultTransformTitle( device )))" ).tag( "auto" )
					Divider()
					ForEach( KeyTransform.allCases ) { transform in
						Text( transform.title ).tag( transform.rawValue )
					}
				}
				.disabled( !online )
				labelPositionPicker
			}

			Section {
				Picker( "Sleep After", selection: sleepBinding ) {
					ForEach( Self.sleepChoices, id: \.seconds ) { choice in
						Text( choice.title ).tag( choice.seconds )
					}
					if !Self.sleepChoices.contains( where: { $0.seconds == settings.sleepTimeout } ) {
						Text( "\(settings.sleepTimeout) seconds" ).tag( settings.sleepTimeout )
					}
				}
				HStack {
					Button( "Sleep Now" ) { controller.sleep( device: deviceID ) }
						.disabled( device.status.asleep )
					Button( "Wake Now" ) { controller.wake( device: deviceID ) }
						.disabled( !device.status.asleep )
				}
			} header: {
				Text( "Sleep" )
			} footer: {
				Text( "Sleep turns the deck's keys off. Pressing any key wakes it, and that press doesn't trigger the key." )
			}
			.disabled( !online )

			ForEach( settings.sleepTriggers ) { trigger in
				TriggerSection( controller: controller, deviceID: deviceID, trigger: trigger )
			}

			Section {
				Button( "Add Trigger", systemImage: "plus" ) {
					controller.updateSettings( device: deviceID ) { $0.sleepTriggers.append( SleepTrigger() ) }
				}
			} header: {
				if settings.sleepTriggers.isEmpty { Text( "Triggers" ) }
			} footer: {
				Text( "Sleep or wake the deck when a HomeKit accessory changes state, e.g. wake it when the office light turns on." )
			}

			CommandSection( controller: controller, deviceID: deviceID, title: "On Sleep", path: \.onSleep,
							footer: "Runs whenever the deck goes to sleep, whatever put it to sleep." )
			CommandSection( controller: controller, deviceID: deviceID, title: "On Wake", path: \.onWake,
							footer: "Runs whenever the deck wakes, whatever woke it." )

			Section {
				if device.status.setupMode {
					Button( "Exit Setup Mode" ) { controller.setSetupMode( device: deviceID, false ) }
				} else {
					Button( "Enter Setup Mode" ) { controller.setSetupMode( device: deviceID, true ) }
						.disabled( !online )
				}
				CopyKeysMenu( controller: controller, deviceID: deviceID )
				Button( "Factory Reset Device…", role: .destructive ) { confirmingReset = true }
					.disabled( !online )
					.confirmationDialog( "Factory reset \(settings.name)?", isPresented: $confirmingReset ) {
						Button( "Factory Reset", role: .destructive ) { controller.factoryReset( device: deviceID ) }
					} message: {
						Text( "The ESPDeck erases its Wi-Fi settings, name, pairing, and stored key images, and restarts in setup mode as if new. Its key layout stays in ESPDeck Bridge and returns once you set it up and pair it again." )
					}
				Button( "Forget Device…", role: .destructive ) { confirmingForget = true }
					.confirmationDialog( "Forget \(settings.name)?", isPresented: $confirmingForget ) {
						Button( "Forget Device", role: .destructive ) { controller.forget( device: deviceID ) }
					} message: {
						Text( "This removes its key assignments and settings from ESPDeck Bridge. If it connects again, it appears as a new device." )
					}
			} header: {
				Text( "Setup" )
			} footer: {
				Text( "Setup mode shows QR codes on the deck for joining the device's own Wi-Fi network and opening its setup page, where you can change its Wi-Fi network and name. You can also enter it by holding the top-left and bottom-right keys for 5 seconds.\n\nFactory Reset erases the device itself. Forget Device removes it from ESPDeck Bridge (and unpairs it) but leaves its Wi-Fi settings alone." )
			}
		}
		.formStyle( .grouped )
		.headerProminence( .increased )
	}

	private func deckDescription( _ settings: DeviceSettings, _ device: DeckDevice ) -> String {
		guard device.isOnline else { return "\(settings.layout.model) (last seen)" }
		guard device.deck.connected else { return "Not connected" }
		var parts = [ device.deck.model ?? settings.layout.model ]
		if let serial = device.deck.serial, !serial.isEmpty { parts.append( serial ) }
		if let firmware = device.deck.firmware, !firmware.isEmpty { parts.append( "firmware \(firmware)" ) }
		return parts.joined( separator: " · " )
	}

	/// The model's own transform, as far as we can tell: the one in effect while the
	/// setting is Automatic.
	private func defaultTransformTitle( _ device: DeckDevice ) -> String {
		guard controller.settings( deviceID )?.orientation == "auto", let transform = device.deck.transform else { return "model default" }
		return transform.title
	}

	private var orientationBinding: Binding<String> {
		Binding {
			controller.settings( deviceID )?.orientation ?? "auto"
		} set: {
			controller.setOrientation( device: deviceID, $0 )
		}
	}

	private var sleepBinding: Binding<Int> {
		Binding {
			controller.settings( deviceID )?.sleepTimeout ?? 0
		} set: {
			controller.setSleepTimeout( device: deviceID, seconds: $0 )
		}
	}
}

/// Replaces this device's keys with another device's (demo or real), after confirming.
private struct CopyKeysMenu: View {
	let controller : DeckController
	let deviceID   : String

	@State private var pendingSource: String?

	var body: some View {
		let others = controller.config.settings.devices.filter { $0.id != deviceID }

		Menu( "Copy Keys From" ) {
			ForEach( others ) { other in
				Button( other.isDemo ? "\(other.name) (demo)" : other.name ) { pendingSource = other.id }
			}
		}
		.disabled( others.isEmpty )
		.confirmationDialog( "Replace this device's keys?", isPresented: Binding( get: { pendingSource != nil }, set: { if !$0 { pendingSource = nil } } ) ) {
			Button( "Replace Keys", role: .destructive ) {
				if let source = pendingSource {
					controller.copyKeys( from: source, to: deviceID )
				}
				pendingSource = nil
			}
		} message: {
			Text( "Every key is replaced with the matching key (same row and column) from \(pendingSource.flatMap { controller.settings( $0 )?.name } ?? "the other device"). Keys outside its layout become empty." )
		}
	}
}

/// "When <accessory> becomes <state>, <sleep|wake>."
private struct TriggerSection: View {
	let controller : DeckController
	let deviceID   : String
	let trigger    : SleepTrigger

	var body: some View {
		Section {
			TargetPicker( controller: controller, assignment: trigger.source, modes: [ .accessory ],
						  kindFilter: { !$0.states.isEmpty } ) { target in
				update { trigger in
					trigger.source.bind( to: target )
					if let states = target?.kind.states, !states.contains( trigger.state ), let first = states.first {
						trigger.state = first
					}
				}
			}

			if let kind = trigger.source.kind {
				Picker( "Becomes", selection: binding( \.state ) ) {
					ForEach( kind.states ) { state in
						Text( state.title ).tag( state )
					}
				}
			}

			Picker( "Then", selection: binding( \.effect ) ) {
				ForEach( SleepEffect.allCases ) { effect in
					Text( "\(effect.title) the Deck" ).tag( effect )
				}
			}
			.pickerStyle( .segmented )

			if let opposite = trigger.state.opposite {
				Toggle( "\(trigger.effect.opposite.title) the deck when it becomes \(opposite.title)", isOn: binding( \.reverse ) )
			}
		} header: {
			HStack {
				Text( "Trigger" )
				Spacer()
				Button( "Remove", role: .destructive ) {
					controller.updateSettings( device: deviceID ) { settings in
						settings.sleepTriggers.removeAll { $0.id == trigger.id }
					}
				}
				.buttonStyle( .borderless )
				.font( .caption )
			}
		}
	}

	private func update( _ change: ( inout SleepTrigger ) -> Void ) {
		controller.updateSettings( device: deviceID ) { settings in
			guard let index = settings.sleepTriggers.firstIndex( where: { $0.id == trigger.id } ) else { return }
			change( &settings.sleepTriggers[index] )
		}
	}

	private func binding<Value>( _ path: WritableKeyPath<SleepTrigger, Value> ) -> Binding<Value> {
		Binding {
			trigger[keyPath: path]
		} set: { value in
			update { $0[keyPath: path] = value }
		}
	}
}

/// An action run on sleep or wake: an accessory action, a scene, or a shortcut.
private struct CommandSection: View {
	let controller : DeckController
	let deviceID   : String
	let title      : String
	let path       : WritableKeyPath<DeviceSettings, KeyAssignment>
	let footer     : String

	private var command: KeyAssignment {
		controller.settings( deviceID )?[keyPath: path] ?? KeyAssignment()
	}

	var body: some View {
		Section {
			TargetPicker( controller: controller, assignment: command,
						  edit: { change in controller.updateSettings( device: deviceID ) { change( &$0[keyPath: path] ) } } ) { target in
				controller.updateSettings( device: deviceID ) { $0[keyPath: path].bind( to: target ) }
			}

			if let kind = command.kind {
				Picker( "Action", selection: actionBinding ) {
					ForEach( kind.actions ) { action in
						Text( action.title ).tag( action )
					}
				}
				Button( "Test" ) { controller.perform( command, context: title ) }
					.disabled( command.action == .none )
			}
		} header: {
			Text( title )
		} footer: {
			Text( footer )
		}
	}

	private var actionBinding: Binding<KeyAction> {
		Binding {
			command.action
		} set: { value in
			controller.updateSettings( device: deviceID ) { $0[keyPath: path].action = value }
		}
	}
}
