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

struct DeviceSettingsView: View {
	let controller : DeckController
	let deviceID   : String

	@State private var nameDraft        = ""
	@State private var brightness       = 80.0
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

	/// Shared with Device ▸ Forget Device.
	private var confirmingForget: Binding<Bool> {
		Binding { controller.window.confirmingForget } set: { controller.window.confirmingForget = $0 }
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
						Text( "This removes its key assignments." )
					}
			} footer: {
				Text( "To use this layout on a real deck, open that device's Keys page and choose Copy Keys From under the deck. Keys are matched by row and column, so layouts carry across deck sizes." )
			}
		}
		.formStyle( .grouped )
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
						Text( ( status.text.components( separatedBy: ": " ).last ?? status.text ).capitalizedFirst )
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
					Text( "This device is offline. Its keys can still be edited; they're sent when it reconnects. Name, display, and sleep timer changes need it online." )
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
				LabeledContent( "Repeat Delay" ) {
					HStack {
						Slider( value: Binding {
							settings.repeatDelay
						} set: { delay in
							controller.updateSettings( device: deviceID ) { $0.repeatDelay = ( delay * 10 ).rounded() / 10 }
						}, in: DeviceSettings.repeatDelayRange, step: 0.1 )
						.frame( maxWidth: 200 )
						Text( settings.repeatDelay.formatted( .number.precision( .fractionLength( 1 ) ) ) + " s" )
							.monospacedDigit()
							.frame( width: 44, alignment: .trailing )
					}
				}
				LabeledContent( "Repeat Speed" ) {
					HStack {
						Slider( value: Binding {
							settings.repeatRate
						} set: { rate in
							controller.updateSettings( device: deviceID ) { $0.repeatRate = rate.rounded() }
						}, in: DeviceSettings.repeatRateRange, step: 1 )
						.frame( maxWidth: 200 )
						Text( "\(Int( settings.repeatRate )) / s" )
							.monospacedDigit()
							.frame( width: 44, alignment: .trailing )
					}
				}
			} header: {
				SectionHeader( "Slider Keys" )
			} footer: {
				Text( "Holding a slider key (Keys page ▸ Type ▸ Slider) steps it again and again: after the delay, this many steps a second." )
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
					Button( "Factory Reset Device…", role: .destructive ) { confirmingReset = true }
						.disabled( !online )
						.confirmationDialog( "Factory reset \(settings.name)?", isPresented: $confirmingReset ) {
							Button( "Factory Reset", role: .destructive ) { controller.factoryReset( device: deviceID ) }
						} message: {
							Text( "The ESPDeck erases its Wi-Fi settings, name, pairing, and stored key images, and restarts in setup mode as if new. Its key layout stays in ESPDeck Bridge and returns once you set it up and pair it again." )
						}
					InfoButton( help: "About Factory Reset",
								text: "Factory Reset erases the device itself: its Wi-Fi settings, name, pairing and stored key images. It restarts in setup mode as if new. Its key layout stays in ESPDeck Bridge and comes back once you set it up and pair it again." )
				}
				HStack {
					Button( "Forget Device…", role: .destructive ) { controller.window.confirmingForget = true }
						.confirmationDialog( "Forget \(settings.name)?", isPresented: confirmingForget ) {
							Button( "Forget Device", role: .destructive ) { controller.forget( device: deviceID ) }
						} message: {
							Text( "This removes its key assignments and settings from ESPDeck Bridge. If it connects again, it appears as a new device." )
						}
					InfoButton( help: "About Forget Device",
								text: "Forget Device removes it from ESPDeck Bridge, with its key assignments and settings, and unpairs it, but leaves its Wi-Fi settings alone. If it connects again, it appears as a new device." )
				}
			} header: {
				SectionHeader( "Setup" )
			}

			SecuritySection( controller: controller, device: device, name: settings.name )

			DeveloperSection( controller: controller, device: device )
		}
		.formStyle( .grouped )
	}

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

/// Wording for the Security section.
private enum StorageText {
	static func confirmTitle( _ name: String ) -> String { "Encrypt the secrets stored on \(name)?" }

	static let confirmMessage = "This encrypts the Wi-Fi password, pairing key and developer password stored on the dev kit, so someone who takes it and reads its flash can't recover them. Its settings and pairing move across, so it keeps working as it does now.\n\nTurning encryption on is permanent: it burns a one-time key into the chip, so this dev kit always encrypts what it stores from now on. What it stores isn't locked in: you can still change its Wi-Fi network, rename it, pair it again or reset it, and it keeps working and updating as before.\n\nKeep the deck powered for the few seconds it takes. It restarts when it's done."

	static let learnMore = "The dev kit keeps your Wi-Fi password, its pairing key and the developer password in its flash. Unencrypted (Standard), anyone who takes it can read them over USB, and the pairing key could let them trigger this deck's actions from your network. Encrypted stores them with a key burned into the chip that no software can read, so the flash alone gives nothing away. New devices are encrypted when they're first set up, over USB or on their setup page, unless Standard is chosen there.\n\nEnabling encryption is permanent: the key can't be removed, so this dev kit always encrypts what it stores. The settings themselves can still be changed any time (Wi-Fi network, name, pairing), and updates, factory reset and the web installer work as before (a reset starts over with empty storage, still encrypted). ESPDeck Bridge won't install firmware older than 4.1.0 on it, since that can't read encrypted storage."
}

/// How the device stores its secrets, and encrypting them (Standard → Encrypted only). A
/// device still on Standard gets a recommendation to encrypt, never a question it must answer.
private struct SecuritySection: View {
	let controller : DeckController
	let device     : DeckDevice
	let name       : String

	@State private var confirming   = false
	@State private var learningMore = false

	var body: some View {
		let storage = device.status.storage

		Section {
			LabeledContent( "Stored Secrets", value: stateText( storage ) )
			if storage == "plain" && device.isOnline && controller.storageEncryption[device.id] != .encrypting {
				recommendation
			} else if storage != "encrypted" && controller.storageEncryption[device.id] != .encrypting {
				HStack {
					Button( "Encrypt Stored Secrets…" ) { confirming = true }
						.disabled( !controller.canEncryptStorage( device ) )
					if let note = unavailableNote( storage ) {
						Spacer()
						Text( note )
							.font( .caption )
							.foregroundStyle( .secondary )
							.multilineTextAlignment( .trailing )
					}
				}
			}
			switch controller.storageEncryption[device.id] {
				case .encrypting:
					ProgressView( "Encrypting; the deck restarts when it's done…" )
				case .failed( let message ):
					Label( message, systemImage: "exclamationmark.triangle.fill" )
						.foregroundStyle( .orange )
				case nil:
					EmptyView()
			}
		} header: {
			SectionHeader( "Security" )
		}
		.confirmationDialog( StorageText.confirmTitle( name ), isPresented: $confirming, titleVisibility: .visible ) {
			Button( "Encrypt" ) { controller.encryptStorage( device: device.id ) }
		} message: {
			Text( StorageText.confirmMessage )
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
					Button( "Encrypt Stored Secrets…" ) { confirming = true }
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

	private func stateText( _ storage: String? ) -> String {
		guard device.isOnline else { return "Unknown while offline" }
		switch storage {
			case "encrypted": return "Encrypted"
			case "plain":     return "Standard"
			default:          return "Standard (not encrypted)"
		}
	}

	private func unavailableNote( _ storage: String? ) -> String? {
		guard device.isOnline else { return nil }
		switch storage {
			case nil:           return "Needs firmware 4.1.0 or later."
			case "unsupported": return "This chip has no free eFuse key block to encrypt with."
			default:            return device.status.setupMode ? "Leave setup mode first." : nil
		}
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
			Toggle( "Allow uploads from PlatformIO", isOn: Binding {
				allowed
			} set: { on in
				controller.setDevOTA( device: device.id, enabled: on )
			} )
			.toggleStyle( .switch )
			.disabled( !device.isOnline || ( !supported && !allowed ) )
			if device.isOnline && !supported {
				Text( allowed ? "This firmware can't get the password safely. Turn uploads off, and update to firmware 4.0.0 or later to turn them on again."
							  : "Needs firmware 4.0.0 or later." )
					.font( .caption )
					.foregroundStyle( .secondary )
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
				.font( .caption )
				.foregroundStyle( .secondary )
		}
	}

	/// Connected devices that allow uploads get the new password; offline ones keep the old one.
	private var regenerateMessage: String {
		let offline = controller.devices.filter { device in
			!device.isOnline && controller.settings( device.id ).map { $0.devOTA && !$0.isDemo } == true
		}.compactMap { controller.settings( $0.id )?.name }
		var text = "Connected devices that allow uploads from PlatformIO get the new password right away. Save it as ota_password.txt again afterward."
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
					Text( problem != nil && !password.isEmpty ? problem! : "Replaces this Mac's developer password. Connected devices that allow uploads from PlatformIO get it right away." )
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
							 isPresented: Binding( get: { pending != nil }, set: { if !$0 { pending = nil } } ) ) {
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
				Text( "The page showing is replaced with page \(page + 1) of \(name), key for key by row and column. Its other pages stay as they are." )
			} else {
				Text( "Every page is replaced with \(name)'s pages, key for key by row and column. Keys a deck can't show are kept for a bigger one." )
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
			SectionHeader( title )
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

/// The device's name on the network, which routers list it by, and changing it to its own
/// name or back. Firmware before 4.1.0 always uses the original.
private struct NetworkNameRow: View {
	let controller : DeckController
	let device     : DeckDevice
	let settings   : DeviceSettings

	var body: some View {
		let current  = device.status.hostname ?? settings.defaultHostname
		let proposed = DeviceSettings.hostname( from: settings.name )
		let settable = device.isOnline && device.status.hostname != nil

		VStack( alignment: .leading, spacing: 6 ) {
			LabeledContent( "Network Name", value: current )
			Text( "How it shows up on your network: in your router's list of devices, and as \(current).local." )
				.font( .caption )
				.foregroundStyle( Color.secondary )
			if device.isOnline && device.status.hostname == nil {
				Text( "Changing it needs firmware 4.1.0 or later." )
					.font( .caption )
					.foregroundStyle( Color.secondary )
			} else {
				HStack {
					Button( proposed.map { "Use \u{201C}\($0)\u{201D}" } ?? "Use Device Name" ) {
						controller.setHostname( device: device.id, proposed )
					}
					.disabled( !settable || proposed == nil || proposed == current )
					.help( "Name it after the device, as your router will list it" )
					Button( "Reset" ) { controller.setHostname( device: device.id, nil ) }
						.disabled( !settable || current == settings.defaultHostname )
						.help( "Back to \(settings.defaultHostname)" )
				}
				.buttonStyle( .borderless )
				Text( "The device restarts to use a new name. Depending on your router, the old name can stay in its list for a while, until the device's address is renewed. Uploads from PlatformIO use the new name too." )
					.font( .caption )
					.foregroundStyle( Color.secondary )
			}
		}
		.padding( .vertical, 2 )
	}
}
