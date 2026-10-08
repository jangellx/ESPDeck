//
//  DeviceSettingsView.swift
//  ESPDeck Bridge
//
//  One ESP32's name, display, sleep behavior, setup mode, and how it stores its secrets.
//  Settings the ESP32 owns (name, brightness, orientation, sleep timer) can only change while
//  it's connected.
//

import SwiftUI
import UniformTypeIdentifiers

/// The Device page: a demo deck's few settings, or a real device's.
struct DeviceSettingsView: View {
	let controller : DeckController
	let deviceID   : String

	@State private var nameDraft        = ""
	@State private var brightness       = 80.0
	@State private var confirmingReset  = false
	@State private var confirmingEncrypt = false
	@State private var confirmingClearAll = false
	@State private var copyingDeck      = false
	@FocusState private var nameFocused: Bool

	/// Sleep After's choices.
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

	/// Shared with Device ▸ Forget Device.
	private var confirmingForget: Binding<Bool> { Bindable( controller.window ).confirmingForget }

	/// The name field and brightness slider start from the device's settings.
	private func syncDrafts( _ settings: DeviceSettings? ) {
		guard let settings else { return }
		nameDraft  = settings.name
		brightness = Double( settings.brightness )
	}

	/// Renames the device to the field's name; an empty field goes back to the current name.
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

				Picker( "Model", selection: demoModelBinding ) {
					ForEach( DeckLayout.presets, id: \.model ) { layout in
						Text( "\(layout.model) (\(layout.rows) × \(layout.cols))" ).tag( layout.model )
					}
				}
			} header: {
				SectionHeader( "Demo Deck" )
			} footer: {
				Text( "A demo deck lets you lay out keys without hardware. Its keys show live HomeKit states and Test Action works; nothing is sent to a device. Changing the model keeps keys that no longer fit, and they return if you switch back." )
			}

			Section {
				CopyKeysMenu( controller: controller, deviceID: deviceID )
				Button( "Delete Demo Deck…", role: .destructive ) { controller.window.confirmingForget = true }
					.confirmationDialog( "Delete \(settings.name)?", isPresented: confirmingForget ) {
						Button( "Delete Demo Deck", role: .destructive ) { controller.forget( device: deviceID ) }
					} message: {
						Text( "This will remove its key assignments." )
					}
			} footer: {
				Text( "To use this layout on a real deck, open that device's Keys page and choose Copy Keys From under the deck. Keys are matched by row and column, so layouts carry across deck sizes." )
			}
		}
		.formStyle( .grouped )
	}

	/// The demo deck's model, by name.
	private var demoModelBinding: Binding<String> {
		Binding {
			controller.settings( deviceID )?.layout.model ?? DeckLayout.mini.model
		} set: { model in
			if let layout = DeckLayout.presets.first( where: { $0.model == model } ) {
				controller.setDemoLayout( device: deviceID, layout )
			}
		}
	}

	/// A real device's settings, and what it's doing.
	@ViewBuilder
	private func form( _ settings: DeviceSettings, _ device: DeckDevice ) -> some View {
		let online = device.isOnline

		Form {
			// A deck with nothing on it yet (new, say): offer another deck's setup.
			if settings.pages.allSatisfy( { $0.allSatisfy( \.isEmpty ) } ), !controller.copySources( for: deviceID ).isEmpty {
				Section {
					HStack {
						Label( "Start from another deck's keys and settings?", systemImage: "square.on.square" )
						Spacer()
						Button( "Copy From Deck…" ) { copyingDeck = true }
					}
				}
			}

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
						Text( status.stateText )
					}
				}
				.alignmentGuide( .listRowSeparatorLeading ) { _ in 0 }
				LabeledContent( "Stream Deck", value: deckDescription( settings, device ) )
				FirmwareRow( controller: controller, device: device, title: "Firmware" )
				NetworkNameRow( controller: controller, device: device, settings: settings )
				LabeledContent( "MAC Address", value: deviceID )
				if let ip = device.ip, online {
					LabeledContent( "IP Address", value: ip )
				}
				if let wifi = device.status.wifi, online {
					LabeledContent( "Wi-Fi", value: wifiDescription( wifi ) )
				}
			} header: {
				SectionHeader( "Device" )
			} footer: {
				if !online {
					Text( "This device is offline. Its keys can still be edited; they'll be sent when it reconnects. Name, display, and sleep timer changes need it online." )
				}
			}

			Section {
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
			} header: {
				SectionHeader( "Display" )
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
				// Whichever applies: only one is ever enabled.
				if device.status.asleep {
					Button( "Wake Now" ) { controller.wake( device: deviceID ) }
				} else {
					Button( "Sleep Now" ) { controller.sleep( device: deviceID ) }
				}
			} header: {
				SectionHeader( "Sleep" )
			} footer: {
				Text( "Sleep turns the deck's keys off. Pressing any key wakes it, and that press doesn't trigger the key." )
			}
			.disabled( !online )

			Section {
				// Each rounded to its slider's step.
				SettingSlider( title: "Repeat Delay", value: settings.repeatDelay, range: DeviceSettings.repeatDelayRange, step: 0.1,
							   text: Self.seconds( settings.repeatDelay, digits: 1 ) ) { delay in
					controller.updateSettings( device: deviceID ) { $0.repeatDelay = ( delay * 10 ).rounded() / 10 }
				}
				SettingSlider( title: "Repeat Speed", value: settings.repeatRate, range: DeviceSettings.repeatRateRange, step: 1,
							   text: "\(Int( settings.repeatRate )) / s" ) { rate in
					controller.updateSettings( device: deviceID ) { $0.repeatRate = rate.rounded() }
				}
				SettingSlider( title: "Double-Tap Speed", value: settings.doubleTapWindow, range: DeviceSettings.doubleTapWindowRange, step: 0.05,
							   text: Self.seconds( settings.doubleTapWindow, digits: 2 ) ) { window in
					controller.updateSettings( device: deviceID ) { $0.doubleTapWindow = ( window * 20 ).rounded() / 20 }
				}
				SettingSlider( title: "Hold Time", value: settings.holdTime, range: DeviceSettings.holdTimeRange, step: 0.1,
							   text: Self.seconds( settings.holdTime, digits: 1 ) ) { time in
					controller.updateSettings( device: deviceID ) { $0.holdTime = ( time * 10 ).rounded() / 10 }
				}
			} header: {
				SectionHeader( "Key Presses" )
			} footer: {
				Text( "Holding a Level key steps it again and again: after the repeat delay, this many steps a second. A second tap within the double-tap time is a double tap, and a key held for the hold time is a hold, for keys with a double tap or hold (Keys page). Keys without one act as soon as they're released." )
			}

			ForEach( settings.sleepTriggers ) { trigger in
				TriggerSection( controller: controller, deviceID: deviceID, trigger: trigger )
			}

			Section {
				Button( "Add Trigger", systemImage: "plus" ) {
					controller.updateSettings( device: deviceID ) { $0.sleepTriggers.append( SleepTrigger() ) }
				}
			} header: {
				if settings.sleepTriggers.isEmpty { SectionHeader( "Triggers" ) }
			} footer: {
				Text( "Sleep or wake the deck when a HomeKit accessory changes state, e.g. wake it when the office light turns on." )
			}

			CommandSection( controller: controller, deviceID: deviceID, title: "On Sleep", path: \.onSleep,
							footer: "Runs whenever the deck goes to sleep, whatever put it to sleep." )
			CommandSection( controller: controller, deviceID: deviceID, title: "On Wake", path: \.onWake,
							footer: "Runs whenever the deck wakes, whatever woke it." )

			Section {
				HStack {
					if device.status.setupMode {
						Button( "Exit Setup Mode" ) { controller.setSetupMode( device: deviceID, false ) }
					} else {
						Button( "Enter Setup Mode" ) { controller.setSetupMode( device: deviceID, true ) }
							.disabled( !online )
					}
					InfoButton( help: "About setup mode",
								text: "Setup mode shows QR codes on the deck for joining the device's own Wi-Fi network and opening its setup page, where you can change its Wi-Fi network and name. You can also enter it by holding the top-left and bottom-right keys for 5 seconds." )
				}
				HStack {
					Button( "Copy From Deck…" ) { copyingDeck = true }
						.disabled( controller.copySources( for: deviceID ).isEmpty )
					InfoButton( help: "About Copy From Deck",
								text: "Copies another deck's keys and settings onto this one: choose which (keys and pages, name, network name, display, sleep, key presses). Any deck ESPDeck Bridge knows can be copied, including ones that aren't connected. Pairing keys and Wi-Fi passwords are never copied." )
				}
			} header: {
				SectionHeader( "Setup" )
			}

			// The ones that take something away, apart from the rest.
			Section {
				HStack {
					Button( "Clear All Keys…", role: .destructive ) { confirmingClearAll = true }
						.disabled( settings.pages.count == 1 && settings.pages[0].allSatisfy( \.isEmpty ) )
						.confirmationDialog( "Clear all keys on \(settings.name)?", isPresented: $confirmingClearAll, titleVisibility: .visible ) {
							Button( "Clear All Keys", role: .destructive ) { controller.clearAllKeys( device: deviceID ) }
						} message: {
							Text( settings.pages.count > 1
								  ? "This will clear every key on all \(settings.pages.count) pages and leave one empty page. Edit ▸ Undo brings them back."
								  : "This will clear every key. Edit ▸ Undo brings them back." )
						}
					InfoButton( help: "About Clear All Keys",
								text: "Clear All Keys empties every key on every page of this deck and leaves one blank page. Its name, Wi-Fi network, pairing and other settings stay as they are, and Edit ▸ Undo brings the keys back." )
				}
				HStack {
					Button( "Factory Reset Device…", role: .destructive ) { confirmingReset = true }
						.disabled( !online )
					InfoButton( help: "About Factory Reset",
								text: "Factory Reset erases the device itself: its Wi-Fi settings, name, pairing and stored key images. It will restart in setup mode as if new. Its key layout stays in ESPDeck Bridge, and once you set it up and pair it again, it will get back its own settings, or it can be restored to another deck's settings." )
				}
				HStack {
					Button( "Forget Device…", role: .destructive ) { controller.window.confirmingForget = true }
						.confirmationDialog( "Forget \(settings.name)?", isPresented: confirmingForget ) {
							Button( "Forget Device", role: .destructive ) { controller.forget( device: deviceID ) }
						} message: {
							Text( "This will remove its key assignments and settings from ESPDeck Bridge. If it connects again, it will appear as a new device." )
						}
					InfoButton( help: "About Forget Device",
								text: "Forget Device removes it from ESPDeck Bridge, with its key assignments and settings, and unpairs it, but leaves its Wi-Fi settings alone. If it connects again, it will appear as a new device." )
				}
			}

			SecuritySection( controller: controller, device: device, confirming: $confirmingEncrypt )

			DeveloperSection( controller: controller, device: device )

			StatusLightSection()
		}
		.formStyle( .grouped )
		// Here rather than on a button: a Form only builds the rows on screen, and the offer
		// at the top opens it too.
		.sheet( isPresented: $copyingDeck ) {
			CopyDeckSheet( controller: controller, deviceID: deviceID )
		}
		// These two here as well: a row is built again when what it shows changes (the deck's
		// status arriving, say), and a sheet on the row closed with it, just after opening.
		.sheet( isPresented: $confirmingReset ) {
			FactoryResetSheet( controller: controller, deviceID: deviceID )
		}
		.sheet( isPresented: $confirmingEncrypt ) {
			EncryptStorageSheet( controller: controller, device: device, name: settings.name )
		}
	}

	/// "0.4 s": a time in seconds, to `digits` decimal places.
	private static func seconds( _ value: Double, digits: Int ) -> String {
		value.formatted( .number.precision( .fractionLength( digits ) ) ) + " s"
	}

	/// The Stream Deck's model, serial number and firmware, as far as they're known.
	private func deckDescription( _ settings: DeviceSettings, _ device: DeckDevice ) -> String {
		guard device.isOnline else { return "\(settings.layout.model) (last seen)" }
		guard device.deck.connected else { return "Not connected" }
		var parts = [ device.deck.model ?? settings.layout.model ]
		if let serial = device.deck.serial, !serial.isEmpty { parts.append( serial ) }
		if let firmware = device.deck.firmware, !firmware.isEmpty { parts.append( "firmware \(firmware)" ) }
		return parts.joined( separator: " · " )
	}

	/// The network it's set up for (never its password, which stays on the device).
	private func wifiDescription( _ wifi: DeviceStatus.WiFi ) -> String {
		guard !wifi.ssid.isEmpty else { return "None set up" }
		return wifi.connected ? wifi.ssid : "\(wifi.ssid) · not connected"
	}

	/// The model's own transform, as far as we can tell: the one in effect while the
	/// setting is Automatic.
	private func defaultTransformTitle( _ device: DeckDevice ) -> String {
		guard controller.settings( deviceID )?.orientation == "auto", let transform = device.deck.transform else { return "model default" }
		return transform.title
	}

	/// "auto" or a KeyTransform's raw value.
	private var orientationBinding: Binding<String> {
		Binding {
			controller.settings( deviceID )?.orientation ?? "auto"
		} set: {
			controller.setOrientation( device: deviceID, $0 )
		}
	}

	/// Sleep After, in seconds; 0 for never.
	private var sleepBinding: Binding<Int> {
		Binding {
			controller.settings( deviceID )?.sleepTimeout ?? 0
		} set: {
			controller.setSleepTimeout( device: deviceID, seconds: $0 )
		}
	}
}

/// A setting's slider with its value beside it, for the Key Presses section.
private struct SettingSlider: View {
	let title : String
	let value : Double
	let range : ClosedRange<Double>
	let step  : Double
	/// The value as shown, e.g. "0.4 s".
	let text  : String
	let set   : ( Double ) -> Void

	var body: some View {
		LabeledContent( title ) {
			HStack {
				Slider( value: Binding { value } set: { set( $0 ) }, in: range, step: step )
					.frame( maxWidth: 200 )
				Text( text )
					.monospacedDigit()
					.scaledFrame( width: 44, alignment: .trailing )
			}
		}
	}
}

/// Wording for the Security section.
private enum StorageText {
	/// The confirmation's title, naming the device.
	static func confirmTitle( _ name: String ) -> String { "Encrypt the secrets stored on \(name)?" }

	/// What encrypting does, and that it can't be undone: the sheet's two paragraphs.
	static let confirmWhat      = "This will generate an encryption key, and use it to encrypt the Wi-Fi password, pairing key, and developer password stored on the dev kit, so that they can no longer be extracted from the flash if the device is stolen."
	static let confirmPermanent = "Turning on encryption is permanent. It works by burning the key into the chip's eFuse, and this dev kit will always encrypt what it stores going forward. The encrypted data can still be replaced, but cannot be read from the device's flash directly. The dev kit can still be re-flashed (including to be used for something besides ESPDeck), reset, paired again, renamed and will otherwise continue to work normally."

	static let learnMore = "The dev kit keeps your Wi-Fi password, its pairing key and the developer password in its flash. When Unencrypted (Standard), anyone who takes it can read them over USB, and the pairing key could let them trigger this deck's actions from your network. Encrypted mode stores them with a key burned into the chip that no software can read, so the flash alone gives nothing away. New devices are encrypted when they're first set up, over USB or on their setup page, unless Standard mode is chosen there.\n\nEnabling encryption is permanent: the key can't be removed, so this dev kit always encrypts what it stores. The settings themselves can still be changed any time (Wi-Fi network, name, pairing), and updates, factory reset and the web installer work as before (a reset starts over with empty storage, still encrypted). ESPDeck Bridge won't install firmware older than 4.1.0 on it, since that can't read encrypted storage."
}

/// How the device stores its secrets, and encrypting them (Standard → Encrypted only). A
/// device still on Standard gets a recommendation to encrypt, never a question it must answer.
private struct SecuritySection: View {
	let controller : DeckController
	let device     : DeckDevice
	/// Opens the Encrypt sheet, which the form presents (see there).
	@Binding var confirming : Bool

	@State private var learningMore = false

	var body: some View {
		let storage = device.status.storage

		Section {
			LabeledContent( "Stored Secrets", value: stateText( storage ) )
			if storage == "plain" && device.isOnline && controller.storageEncryption[device.id] != .encrypting {
				recommendation
			} else if storage != "encrypted" && controller.storageEncryption[device.id] != .encrypting {
				HStack {
					Button( "Encrypt Stored Secrets Now…" ) { confirming = true }
						.disabled( !controller.canEncryptStorage( device ) )
					if let note = unavailableNote( storage ) {
						Spacer()
						Text( note )
							.secondaryCaption()
							.multilineTextAlignment( .trailing )
					}
				}
			}
			switch controller.storageEncryption[device.id] {
				case .encrypting:
					ProgressView( "Encrypting; the deck will restart when it's done…" )
				case .failed( let message ):
					WarningLabel( message )
				case nil:
					EmptyView()
			}
		} header: {
			SectionHeader( "Security" )
		}
	}

	/// For a device on Standard storage: a highlighted suggestion with the button, which the
	/// user can act on or leave.
	private var recommendation: some View {
		HStack( alignment: .top, spacing: 10 ) {
			Image( systemName: "lock.shield.fill" )
				.font( .title2 )
				.foregroundStyle( .tint )
			VStack( alignment: .leading, spacing: 6 ) {
				Text( "Encrypt stored secrets (recommended)" )
					.font( .body.weight( .semibold ) )
				Text( "Wi-Fi password and bridge pairing are currently stored unencrypted, meaning anyone can read them off the dev kit over USB. Encrypting adds a permanent key that makes it impossible to read them from the device." )
					.font( .callout )
				HStack {
					Button( "Encrypt Stored Secrets Now…" ) { confirming = true }
						.foregroundStyle( .tint )
						.disabled( !controller.canEncryptStorage( device ) )
					if let note = unavailableNote( device.status.storage ) {
						Text( note )
							.font( .caption )
					}
				}
				// The whole line toggles it, not just the chevron (as a DisclosureGroup would).
				Button {
					withAnimation( .easeInOut( duration: 0.2 ) ) { learningMore.toggle() }
				} label: {
					HStack( spacing: 6 ) {
						Image( systemName: "chevron.right" )
							.font( .caption.weight( .semibold ) )
							.rotationEffect( .degrees( learningMore ? 90 : 0 ) )
						Text( "Learn More" )
						Spacer()
					}
					.contentShape( Rectangle() )
				}
				.buttonStyle( .plain )
				if learningMore {
					Text( StorageText.learnMore )
						.font( .callout )
				}
			}
		}
		.foregroundStyle( Color.primary )   // black on the tint, for readability
		.padding( 10 )
		.frame( maxWidth: .infinity, alignment: .leading )
		.background( Color.accentColor.opacity( 0.08 ), in: RoundedRectangle( cornerRadius: 8 ) )
		.padding( .bottom, 6 )
	}

	/// Stored Secrets' value: Encrypted or Standard, or unknown while offline.
	private func stateText( _ storage: String? ) -> String {
		guard device.isOnline else { return "Unknown while offline" }
		switch storage {
			case "encrypted": return "Encrypted"
			case "plain":     return "Standard"
			default:          return "Standard (not encrypted)"
		}
	}

	/// Why Encrypt Stored Secrets can't be used on this device now, if it can't.
	private func unavailableNote( _ storage: String? ) -> String? {
		guard device.isOnline else { return nil }
		switch storage {
			case nil:           return "Needs firmware 4.1.0 or later."
			case "unsupported": return "This chip has no free eFuse key block to encrypt with."
			default:            return device.status.setupMode ? "Leave setup mode first." : nil
		}
	}
}

/// Encrypt Stored Secrets: what it does and that it's permanent, with Cancel and Encrypt; then
/// the wait while the deck encrypts and restarts; then how it went, with a button to close.
private struct EncryptStorageSheet: View {
	let controller : DeckController
	let device     : DeckDevice
	let name       : String

	@Environment( \.dismiss ) private var dismiss
	/// Encrypt was clicked: from then on the sheet shows the wait, and then the outcome.
	@State private var started = false

	/// Where the sheet has got to.
	private enum Phase: Equatable {
		case asking
		/// The deck is encrypting (still connected) or restarting (gone for the moment).
		case working( restarting: Bool )
		case done
		case failed( String )
	}

	private var phase: Phase {
		guard started else { return .asking }
		switch controller.storageEncryption[device.id] {
			case .encrypting:           return .working( restarting: !device.isOnline )
			case .failed( let message ): return .failed( message )
			// Finished without a failure; the deck saying so is what makes it done.
			case nil:
				return device.status.storage == "encrypted" ? .done : .failed( "The deck didn't start encrypting. Close this and try again." )
		}
	}

	var body: some View {
		let phase = phase
		VStack( spacing: 16 ) {
			Image( systemName: phase == .done ? "checkmark.shield.fill" : "lock.shield.fill" )
				.scaledSystemFont( size: 40 )
				.foregroundStyle( phase == .done ? AnyShapeStyle( .green ) : AnyShapeStyle( .tint ) )
				.accessibilityHidden( true )

			switch phase {
				case .asking, .working:
					Text( StorageText.confirmTitle( name ) )
						.font( .headline )
						.multilineTextAlignment( .center )
					VStack( alignment: .leading, spacing: 10 ) {
						Text( StorageText.confirmWhat )
						Text( StorageText.confirmPermanent )
					}
					.font( .callout )
					.fixedSize( horizontal: false, vertical: true )

					HStack {
						Button( "Cancel", role: .cancel ) { dismiss() }
							.disabled( phase != .asking )
						Spacer()
						// One place for both: the button, then what it set going.
						if case .working( let restarting ) = phase {
							SystemSpinner()
								.fixedSize()
							Text( restarting ? "Restarting…" : "Encrypting…" )
								.foregroundStyle( .secondary )
						} else {
							Button( "Encrypt" ) {
								started = true
								controller.encryptStorage( device: device.id )
							}
							.prominentButtonStyle()
							.disabled( !controller.canEncryptStorage( device ) )
						}
					}
					.padding( .top, 4 )

				case .done:
					Text( "Encryption Enabled" )
						.font( .headline )
					Text( "The Wi-Fi password, pairing key and developer password on \(name) are now stored encrypted." )
						.font( .callout )
						.multilineTextAlignment( .center )
						.fixedSize( horizontal: false, vertical: true )
					Button( "Done" ) { dismiss() }
						.prominentButtonStyle()
						.padding( .top, 4 )

				case .failed( let message ):
					Text( "Encryption Wasn't Confirmed" )
						.font( .headline )
					WarningLabel( message )
						.font( .callout )
						.fixedSize( horizontal: false, vertical: true )
					Button( "Close" ) { dismiss() }
						.prominentButtonStyle()
						.padding( .top, 4 )
			}
		}
		.padding( 24 )
		.frame( width: 480 )
		// As tall as its content, and the sheet with it: a sheet is otherwise a standard size,
		// which left space above and below.
		.fixedSize( horizontal: false, vertical: true )
		.fittedSheet()
		// Not dismissed by Esc or a click outside while the deck is in the middle of it.
		.interactiveDismissDisabled( { if case .working = phase { true } else { false } }() )
	}
}

/// Uploads from PlatformIO over Wi-Fi (ArduinoOTA), off until allowed here. The device
/// gets the hash of this Mac's developer password, which PlatformIO reads from
/// ota_password.txt.
private struct DeveloperSection: View {
	let controller : DeckController
	let device     : DeckDevice

	var body: some View {
		// Firmware before 4.0.0 got the password's hash unencrypted; it can only turn uploads off.
		let supported = ( device.protocolVersion ?? 0 ) >= DeckController.devOTAProtocol
		let allowed   = device.status.devOTA ?? false

		Section {
			Toggle( "Allow uploads through PlatformIO", isOn: Binding {
				allowed
			} set: { on in
				controller.setDevOTA( device: device.id, enabled: on )
			} )
			.toggleStyle( .switch )
			.disabled( !device.isOnline || ( !supported && !allowed ) )
			if device.isOnline && !supported {
				Text( allowed ? "This firmware can't get the password safely. Turn uploads off, and update to firmware 4.0.0 or later to turn them on again."
							  : "Needs firmware 4.0.0 or later." )
					.secondaryCaption()
			}
			if controller.developerPassword != nil {
				DeveloperPasswordRows( controller: controller )
			}
		} header: {
			SectionHeader( "Developer" )
		} footer: {
			Text( "Lets `pio run -t upload` send firmware to this device over Wi-Fi. Save the developer password as ota_password.txt in the ESPDeck Device folder of your checkout, where PlatformIO reads it. It's for development: anyone on your network with the password can replace the firmware, so it's off by default." )
		}
	}
}

/// This Mac's developer password: shown on request, copied, saved as ota_password.txt,
/// replaced with one of the user's own, or regenerated.
private struct DeveloperPasswordRows: View {
	let controller : DeckController

	@State private var revealed      = false
	@State private var saving        = false
	@State private var choosingOwn   = false
	@State private var regenerating  = false
	@State private var result        : String?

	private var password: String { controller.developerPassword ?? "" }

	var body: some View {
		LabeledContent( "Developer Password" ) {
			HStack( spacing: 10 ) {
				Text( revealed ? password : String( repeating: "•", count: password.count ) )
					.font( .body.monospaced() )
					.textSelection( .enabled )
					.lineLimit( 1 )
				Button {
					revealed.toggle()
				} label: {
					Image( systemName: revealed ? "eye.slash" : "eye" )
				}
				.buttonStyle( .borderless )
				.help( revealed ? "Hide the password" : "Show the password" )
				Button( "Copy" ) {
					// This Mac only (not Universal Clipboard), and gone after two minutes.
					UIPasteboard.general.setItems( [ [ UTType.plainText.identifier: password ] ],
												   options: [ .localOnly: true, .expirationDate: Date( timeIntervalSinceNow: 120 ) ] )
				}
				.help( "Copies the password for two minutes" )
			}
		}

		HStack {
			Button( "Save as ota_password.txt…" ) { saving = true }
			Spacer()
			Menu( "More" ) {
				Button( "Use My Own Password…" ) { choosingOwn = true }
				Button( "Regenerate Password…" ) { regenerating = true }
			}
			.fixedSize()
		}
		.fileExporter( isPresented: $saving, document: PasswordFile( password: password ), contentType: .plainText,
					   defaultFilename: "ota_password.txt" ) { _ in }
		.confirmationDialog( "Make a new developer password?", isPresented: $regenerating, titleVisibility: .visible ) {
			Button( "Regenerate Password" ) {
				result = controller.replaceDeveloperPassword().summary
			}
		} message: {
			Text( regenerateMessage )
		}
		.sheet( isPresented: $choosingOwn ) {
			OwnPasswordSheet { password in
				result = controller.replaceDeveloperPassword( with: password ).summary
			}
		}

		if let result {
			Text( "\(result) Save the new password as ota_password.txt again." )
				.secondaryCaption()
		}
	}

	/// Connected devices that allow uploads get the new password; offline ones keep the old one.
	private var regenerateMessage: String {
		let offline = controller.devices.filter { device in
			!device.isOnline && controller.settings( device.id ).map { $0.devOTA && !$0.isDemo } == true
		}.compactMap { controller.settings( $0.id )?.name }
		var text = "Connected devices that allow uploads through PlatformIO will get the new password right away. Save it as ota_password.txt again afterward."
		if !offline.isEmpty {
			let names = ListFormatter.localizedString( byJoining: offline )
			text += " \(names) \(offline.count == 1 ? "is" : "are") offline and will keep the old password; turn uploads off and on again for \(offline.count == 1 ? "it" : "them") later."
		}
		return text
	}
}

/// A password the user picks instead of the generated one.
private struct OwnPasswordSheet: View {
	let use: ( String ) -> Void

	@Environment( \.dismiss ) private var dismiss
	@State private var password = ""

	var body: some View {
		let problem = DevOTAPassword.problem( password )
		NavigationStack {
			Form {
				Section {
					SecureField( "Password", text: $password, prompt: Text( "At least 8 characters" ) )
				} footer: {
					Text( ( password.isEmpty ? nil : problem ) ?? "Replaces this Mac's developer password. Connected devices that allow uploads through PlatformIO get it right away." )
				}
			}
			.formStyle( .grouped )
			.navigationTitle( "Use My Own Password" )
			.toolbar {
				ToolbarItem( placement: .cancellationAction ) {
					Button( "Cancel" ) { dismiss() }
				}
				ToolbarItem( placement: .confirmationAction ) {
					Button( "Use Password" ) {
						use( password )
						dismiss()
					}
					.disabled( problem != nil )
				}
			}
		}
		.frame( minWidth: 380, minHeight: 220 )
	}
}

/// ota_password.txt for the save dialog: the password alone.
private struct PasswordFile: FileDocument {
	static let readableContentTypes: [UTType] = [ .plainText ]

	var password: String

	init( password: String ) {
		self.password = password
	}

	init( configuration: ReadConfiguration ) throws {
		password = String( decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self )
	}

	func fileWrapper( configuration: WriteConfiguration ) throws -> FileWrapper {
		FileWrapper( regularFileWithContents: DevOTAPassword.fileContents( password ) )
	}
}

/// Replaces this device's keys with another device's (demo or real), after confirming.
struct CopyKeysMenu: View {
	let controller : DeckController
	let deviceID   : String

	/// A device, and one of its pages or nil for all of them, waiting for Replace.
	@State private var pending: ( source: String, page: Int? )?

	var body: some View {
		let devices = controller.config.settings.devices
		let others  = devices.filter { $0.id != deviceID }
		let this    = devices.first { $0.id == deviceID }

		Menu( "Copy Keys From" ) {
			ForEach( others ) { other in
				let name = other.isDemo ? "\(other.name) (demo)" : other.name
				if other.pages.count > 1 {
					Menu( name ) {
						Button( "All Pages" ) { pending = ( other.id, nil ) }
						Divider()
						ForEach( other.pages.indices, id: \.self ) { page in
							Button( "Page \(page + 1)" ) { pending = ( other.id, page ) }
						}
					}
				} else {
					Button( name ) { pending = ( other.id, nil ) }
				}
			}
			// Another page of this device onto the one showing.
			if let this, this.pages.count > 1 {
				Divider()
				Menu( "This Device" ) {
					ForEach( this.pages.indices.filter { $0 != this.currentPage }, id: \.self ) { page in
						Button( "Page \(page + 1)" ) { pending = ( deviceID, page ) }
					}
				}
			}
		}
		.disabled( others.isEmpty && ( this?.pages.count ?? 1 ) < 2 )
		.confirmationDialog( pending?.page == nil ? "Replace this device's keys?" : "Replace this page's keys?",
							 isPresented: Binding( presenting: $pending ) ) {
			Button( "Replace Keys", role: .destructive ) {
				if let pending {
					controller.copyKeys( from: pending.source, to: deviceID, page: pending.page )
				}
				pending = nil
			}
		} message: {
			let source = pending.flatMap { controller.settings( $0.source ) }
			let name   = pending?.source == deviceID ? "this device" : source?.name ?? "the other device"
			if let page = pending?.page {
				Text( "The page showing will be replaced with page \(page + 1) of \(name), key for key by row and column. Its other pages will stay as they are." )
			} else {
				Text( "Every page will be replaced with \(name)'s pages, key for key by row and column. Keys a deck can't show will be kept for a bigger one." )
			}
		}
	}
}

/// "When <accessory> changes to <state>, <sleep|wake>."
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
				Picker( "Changes to", selection: binding( \.state ) ) {
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
				Toggle( "\(trigger.effect.opposite.title) the deck when the accessory changes to \(opposite.title)", isOn: binding( \.reverse ) )
					.toggleStyle( .switch )
			}
		} header: {
			HStack {
				SectionHeader( "Trigger" )
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

	/// Changes this trigger in the device's settings.
	private func update( _ change: ( inout SleepTrigger ) -> Void ) {
		controller.updateSettings( device: deviceID ) { settings in
			guard let index = settings.sleepTriggers.firstIndex( where: { $0.id == trigger.id } ) else { return }
			change( &settings.sleepTriggers[index] )
		}
	}

	/// One of the trigger's properties, changed through update(_:).
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

	/// The command as it's set now; empty when there's none.
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
			SectionHeader( title )
		} footer: {
			Text( footer )
		}
	}

	/// The command's action, for the Action picker.
	private var actionBinding: Binding<KeyAction> {
		Binding {
			command.action
		} set: { value in
			controller.updateSettings( device: deviceID ) { $0[keyPath: path].action = value }
		}
	}
}

/// The device's name on the network, which routers list it by, and changing it to its own
/// name or back. Firmware before 4.1.0 always uses the original. The deck restarts to change
/// it, so the buttons wait (with a spinner) until it's back or `restartTimeout` has passed.
private struct NetworkNameRow: View {
	let controller : DeckController
	let device     : DeckDevice
	let settings   : DeviceSettings

	/// The name asked for, while the deck restarts to take it.
	@State private var changingTo  : String?
	/// The deck has gone offline since the change was asked for: it's restarting.
	@State private var wentOffline = false
	/// It didn't come back in time.
	@State private var timedOut    = false

	/// How long a restart may take: back on Wi-Fi, found the bridge, authenticated.
	private static let restartTimeout: Duration = .seconds( 45 )

	/// Asks the deck for a name (nil: its original) and starts waiting for it to restart.
	private func change( to hostname: String? ) {
		timedOut    = false
		wentOffline = false
		changingTo  = hostname ?? settings.defaultHostname
		controller.setHostname( device: device.id, hostname )
	}

	var body: some View {
		// As it reports it, or as it last did while it isn't connected.
		let current  = device.status.hostname ?? settings.hostname ?? settings.defaultHostname
		let proposed = DeviceSettings.hostname( from: settings.name )
		let settable = device.isOnline && device.status.hostname != nil   // connected, with firmware that can

		VStack( alignment: .leading, spacing: 6 ) {
			LabeledContent( "Network Name", value: current )
			Text( "The deck can be found on your network as \(current).local." )
				.secondaryCaption()
			// While it restarts for a change it's offline, and the buttons stay to show the wait.
			if changingTo == nil && !device.isOnline {
				Text( "The deck changes this itself, so it needs to be connected to change it." )
					.secondaryCaption()
			} else if changingTo == nil && device.status.hostname == nil {
				Text( "Changing it needs firmware 4.1.0 or later." )
					.secondaryCaption()
			} else {
				// One control, which is whatever applies now: the change waiting on a restart, a
				// change to the device's name, or (once it has that name) a reset to the original.
				HStack {
					if changingTo != nil {
						SystemSpinner()
							.fixedSize()
						Text( "Changed; restarting deck…" )
							.foregroundStyle( .secondary )
					} else if let proposed, proposed != current {
						Button( "Change to \u{201C}\(proposed)\u{201D}" ) { change( to: proposed ) }
							.disabled( !settable )
							.help( "Name it after the device, as your router will list it" )
					} else if current != settings.defaultHostname {
						Button( "Reset to \u{201C}\(settings.defaultHostname)\u{201D}" ) { change( to: nil ) }
							.disabled( !settable )
							.help( "Back to its original name" )
					} else {
						// Already the original, and the device's name gives nothing else to use.
						Button( "Change to Device Name" ) {}
							.disabled( true )
					}
					Spacer()
				}
				.buttonStyle( .borderless )
				if timedOut {
					Text( "The deck hasn't come back yet. It may still be restarting; if it doesn't reconnect, check that it has power." )
						.font( .caption )
						.foregroundStyle( .orange )
				}
				Text( "The device will restart to use the new name. Depending on your router, the old name can stay in its list for some time, until the device's address is renewed. PlatformIO will use the new name." )
					.secondaryCaption()
			}
		}
		.padding( .vertical, 2 )
		// Done once it reports the new name, or has been away and come back (it may spell
		// the name its own way).
		.onChange( of: current ) { if current == changingTo { changingTo = nil } }
		.onChange( of: device.isOnline ) { _, online in
			guard changingTo != nil else { return }
			if !online { wentOffline = true } else if wentOffline { changingTo = nil }
		}
		// Or when it has taken too long.
		.task( id: changingTo ) {
			guard changingTo != nil else { return }
			try? await Task.sleep( for: Self.restartTimeout )
			guard !Task.isCancelled else { return }
			changingTo = nil
			timedOut   = true
		}
	}
}

/// What the dev board's status light means (StatusLed in the firmware).
private struct StatusLightSection: View {
	private enum Style { case solid, pulsing, blinking }

	/// One color and pattern of the light, and what it means.
	private struct Entry: Identifiable {
		let color   : Color
		let style   : Style
		let title   : String
		let meaning : String
		var id: String { title }
	}

	private static let entries: [Entry] = [
		Entry( color: .blue, style: .pulsing, title: "Pulsing blue", meaning: "Setup mode" ),
		Entry( color: .yellow, style: .pulsing, title: "Pulsing yellow", meaning: "Looking for Wi-Fi" ),
		Entry( color: Color( red: 0.3, green: 0.9, blue: 0.35 ), style: .pulsing, title: "Pulsing green", meaning: "On Wi-Fi, looking for ESPDeck Bridge or waiting on it (to be unpaired, say)" ),
		Entry( color: .green, style: .solid, title: "Green", meaning: "Connected to ESPDeck Bridge; brighter while data moves" ),
		Entry( color: .white, style: .solid, title: "White", meaning: "A key is pressed" ),
		Entry( color: Color( red: 0.85, green: 0.2, blue: 0.85 ), style: .blinking, title: "Blinking magenta", meaning: "Pairing; steady once the code is confirmed on the deck" ),
	]

	var body: some View {
		Section {
			ForEach( Self.entries ) { entry in
				HStack( spacing: 12 ) {
					light( entry )
					CaptionedText( entry.title, caption: entry.meaning )
				}
				.accessibilityElement( children: .combine )
			}
		} header: {
			SectionHeader( "Status Light" )
		} footer: {
			Text( "The light on the ESP32-S3 board. While the deck is asleep, green is off and the others are very dim." )
		}
	}

	/// The light itself: a dot that's steady, pulses, or blinks, as the board's does.
	private func light( _ entry: Entry ) -> some View {
		Circle()
			.fill( entry.color )
			.overlay( Circle().strokeBorder( .tertiary, lineWidth: 1 ) )   // white on white
			.scaledFrame( width: 14, height: 14 )
			.phaseAnimator( entry.style == .solid ? [ 1.0 ] : [ 1.0, 0.2 ] ) { view, opacity in
				view.opacity( opacity )
			} animation: { _ in
				entry.style == .blinking ? .linear( duration: 0.01 ).delay( 0.25 ) : .easeInOut( duration: 1 )
			}
			.scaledFrame( width: 28 )
			.accessibilityHidden( true )
	}
}
