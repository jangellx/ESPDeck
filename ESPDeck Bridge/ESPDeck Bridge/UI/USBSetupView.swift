//
//  USBSetupView.swift
//  ESPDeck Bridge
//
//  The USB Setup page (Mac only): the boards plugged into this Mac and what each runs,
//  installing ESPDeck on one, then giving it Wi-Fi and a name over the same cable. See
//  USBSetup.
//

import SwiftUI
import UniformTypeIdentifiers

struct USBSetupView: View {
	let controller          : DeckController
	@Binding var selection  : String?

	@State private var nameDraft        = ""
	@State private var ssid             = ""
	@State private var otherSSID        = ""
	@State private var password         = ""
	@State private var pickingFile      = false
	@State private var chosenFile       : ( url: URL, version: String )?
	@State private var fileProblem      : String?
	@State private var confirmingOlder  = false

	/// The picker's "Other Network…" tag: longer than any network name (32 bytes).
	private static let otherNetwork = "(other network, typed in by hand)"

	private var setup: USBSetup { controller.usbSetup }

	var body: some View {
		Form {
			scanningSection
			if setup.scanning {
				boardsSection
				if setup.selectedBoard != nil {
					firmwareSection
				}
				if let info = setup.selectedBoard?.espDeck {
					wifiSection
					nameSection( info )
				}
				if case .joined( let network ) = setup.wifi {
					nextSection( network )
				}
			}
		}
		.formStyle( .grouped )
		.navigationTitle( "USB Setup" )
		.onAppear( perform: appeared )
		.onChange( of: setup.selectedBoard?.espDeck?.name ) { nameDraft = setup.selectedBoard?.espDeck?.name ?? "" }
		.onChange( of: setup.networks ) {
			if ssid.isEmpty, let strongest = setup.networks.first { ssid = strongest.ssid }
		}
		.fileImporter( isPresented: $pickingFile, allowedContentTypes: [ .data ] ) { result in
			if case .success( let url ) = result { choose( url ) }
		}
		.alert( "Can't Use That File", isPresented: Binding( get: { fileProblem != nil }, set: { if !$0 { fileProblem = nil } } ) ) {
			Button( "OK" ) {}
		} message: {
			Text( fileProblem ?? "" )
		}
	}

	private func appeared() {
		nameDraft  = setup.selectedBoard?.espDeck?.name ?? ""
		if controller.updates.latestFirmware == nil && controller.updates.repository != nil {
			Task { await controller.updates.check( userInitiated: true ) }
		}
	}

	// MARK: - Scanning

	private var scanningSection: some View {
		Section {
			Toggle( "Look for boards plugged in over USB", isOn: Binding( get: { setup.scanning }, set: { setup.scanning = $0 } ) )
		} footer: {
			if setup.scanning {
				Text( "When an ESP32 is plugged into its own USB port, ESPDeck Bridge briefly asks what it's running, then lets go of it. Other ports are left alone until you ask." )
			} else {
				Text( "Scanning is off: ESPDeck Bridge doesn't watch or open USB ports. Turn it on to set up a board over USB." )
			}
		}
	}

	// MARK: - Boards

	private var boardsSection: some View {
		Section {
			if setup.boards.isEmpty {
				Label( "No board is plugged in.", systemImage: "cable.connector.slash" )
					.foregroundStyle( .secondary )
			}
			ForEach( setup.boards ) { board in
				boardRow( board )
			}
		} header: {
			SectionHeader( setup.boards.count > 1 ? "Boards" : "Board" )
		} footer: {
			Text( setup.boards.count > 1
				  ? "Click the board to set up. Use a USB data cable (not a charge-only one) and the board's port labeled USB."
				  : "Use a USB data cable (not a charge-only one) and the board's port labeled USB. Boards with a second port labeled COM or UART work through that one too." )
		}
		.disabled( setup.install.isBusy )
	}

	private func boardRow( _ board: USBSetup.Board ) -> some View {
		let choosable = setup.boards.count > 1
		let chosen    = setup.selectedBoard?.id == board.id

		return Button {
			setup.selectedPath = board.port.path
		} label: {
			HStack( alignment: .top, spacing: 10 ) {
				if choosable {
					Image( systemName: chosen ? "checkmark.circle.fill" : "circle" )
						.foregroundStyle( chosen ? Color.accentColor : Color.secondary )
				}
				VStack( alignment: .leading, spacing: 3 ) {
					Text( board.espDeck.map { "\($0.name)" } ?? board.port.title )
					ForEach( details( board ), id: \.self ) { line in
						Text( line )
							.font( .caption )
							.foregroundStyle( .secondary )
					}
				}
				.frame( maxWidth: .infinity, alignment: .leading )
				switch board.answer {
					case .asking:
						ProgressView().controlSize( .small )
					case .notAsked:
						Button( "Check" ) { setup.ask( board ) }
							.help( "Asks the board what it's running. On a USB serial chip, opening the port can restart the board." )
					case .silent:
						Button( "Ask Again" ) { setup.ask( board ) }
					case .answered:
						EmptyView()
				}
			}
			.contentShape( Rectangle() )
		}
		.buttonStyle( .plain )
	}

	/// What it runs, how that compares with the latest release, and what hardware it is.
	private func details( _ board: USBSetup.Board ) -> [String] {
		var lines: [String] = []
		switch board.answer {
			case .asking:
				lines.append( "Asking what it's running…" )
			case .answered( let info ) where info.isESPDeck:
				let standing = FirmwareStanding( running: info.version, latest: controller.updates.latestFirmware?.version ).description
				lines.append( ( [ "ESPDeck \(info.version)", standing ].compactMap { $0 } ).joined( separator: " · " ) )
			case .answered( let info ):
				lines.append( "Runs \(info.firmware) \(info.version), not ESPDeck" )
			case .silent:
				lines.append( "Didn't answer: it may be running other firmware, or waiting in flashing mode." )
			case .notAsked:
				lines.append( "Not checked yet." )
		}
		if let hardware = board.hardware {
			lines.append( hardware )
		} else if let chip = board.espDeck?.chip {
			lines.append( chip )
		} else {
			lines.append( "Looks like an ESP32 board. Its model is checked when installing." )
		}
		return lines
	}

	// MARK: - Firmware

	private var firmwareSection: some View {
		Section {
			Picker( "Firmware", selection: Binding( get: { setup.source }, set: { setup.source = $0 } ) ) {
				Text( controller.updates.latestFirmware.map { "Latest release (\($0.version.description))" } ?? "Latest release" )
					.tag( USBSetup.Source.release )
				if let chosenFile {
					Text( "\(chosenFile.url.lastPathComponent) (\(chosenFile.version))" )
						.tag( USBSetup.Source.file( chosenFile.url ) )
				}
			}
			.disabled( setup.install.isBusy )

			HStack {
				Button( "Choose File…" ) { pickingFile = true }
					.disabled( setup.install.isBusy )
				Spacer()
				if setup.install.isBusy {
					Button( "Stop", role: .cancel ) { setup.cancelInstall() }
				}
				Button( "Install Firmware" ) { installTapped() }
					.buttonStyle( .borderedProminent )
					.disabled( setup.selectedBoard == nil || setup.install.isBusy )
			}
			.confirmationDialog( olderTitle, isPresented: $confirmingOlder, titleVisibility: .visible ) {
				Button( "Install Older Firmware" ) { setup.installFirmware() }
			} message: {
				Text( "The board runs a newer version than the one you chose. ESPDeck Bridge may expect things the older firmware can't do." )
			}

			installStatus
		} header: {
			SectionHeader( "Firmware" )
		} footer: {
			Text( "Installing keeps the board's Wi-Fi settings, name, and pairing. Before writing anything, it checks that the board is an ESP32-S3 with enough flash and the PSRAM ESPDeck needs. If the board can't be switched to flashing mode by itself, hold BOOT, press and release RST, release BOOT, then click Install Firmware again." )
		}
	}

	private var olderTitle: String {
		"Install \(setup.sourceVersion ?? "this firmware") over \(setup.selectedBoard?.espDeck?.version ?? "the newer one")?"
	}

	/// Going back to an older version asks first; the same version (a rebuild) doesn't.
	private func installTapped() {
		if let running = setup.selectedBoard?.espDeck?.version, let installing = setup.sourceVersion,
		   FirmwareStanding.isDowngrade( installing: installing, over: running ) {
			confirmingOlder = true
		} else {
			setup.installFirmware()
		}
	}

	@ViewBuilder private var installStatus: some View {
		switch setup.install {
			case .idle:
				EmptyView()
			case .preparing( let text ):
				ProgressView( text )
					.controlSize( .small )
			case .running( let stage, let fraction ):
				ProgressView( value: fraction ) {
					Text( stage )
				}
			case .finished( let text ):
				Label( text, systemImage: "checkmark.circle.fill" )
					.foregroundStyle( .green )
			case .failed( let message ):
				Label( message, systemImage: "exclamationmark.triangle.fill" )
					.foregroundStyle( .orange )
		}
	}

	private func choose( _ url: URL ) {
		do {
			let image = try USBSetup.read( url )
			let app   = try FirmwareImage.regions( fullImage: image ).app
			chosenFile   = ( url, app.version )
			setup.source = .file( url )
		} catch {
			fileProblem = error.localizedDescription
		}
	}

	// MARK: - Wi-Fi

	private var wifiSection: some View {
		Section {
			Picker( "Network", selection: $ssid ) {
				if setup.networks.isEmpty {
					Text( setup.findingNetworks ? "Looking for networks…" : "Click Find Networks" ).tag( "" )
				}
				ForEach( setup.networks ) { network in
					Label {
						Text( network.ssid )
					} icon: {
						Image( systemName: network.secure ? "lock.fill" : "wifi" )
					}
					.tag( network.ssid )
				}
				Divider()
				Text( "Other Network…" ).tag( Self.otherNetwork )
			}
			if ssid == Self.otherNetwork {
				TextField( "Network Name", text: $otherSSID )
			}
			SecureField( "Password", text: $password )
				.onSubmit( join )

			HStack {
				Button( setup.findingNetworks ? "Looking…" : "Find Networks" ) { setup.findNetworks() }
					.disabled( setup.findingNetworks )
				Spacer()
				Button( "Join Network" ) { join() }
					.disabled( wifiProblem != nil || isJoining )
			}
			if let problem = wifiProblem, !joinSSID.isEmpty {
				Text( problem )
					.font( .caption )
					.foregroundStyle( .secondary )
			}
			switch setup.wifi {
				case .joining:
					ProgressView( "Joining…" ).controlSize( .small )
				case .failed( let message ):
					Label( message, systemImage: "exclamationmark.triangle.fill" )
						.foregroundStyle( .orange )
				case .idle, .joined:
					EmptyView()
			}
		} header: {
			SectionHeader( "Wi-Fi" )
		} footer: {
			Text( "The board needs a 2.4 GHz network, the same one this Mac is on. It keeps the network once it has joined it." )
		}
		.disabled( setup.install.isBusy )
	}

	private var joinSSID: String {
		ssid == Self.otherNetwork ? otherSSID : ssid
	}

	private var isJoining: Bool {
		if case .joining = setup.wifi { return true }
		return false
	}

	/// What's wrong with the network name or password, if anything.
	private var wifiProblem: String? {
		let name = joinSSID.utf8.count
		if name == 0 { return "Choose a network." }
		if name > 32 { return "Network names have at most 32 characters." }
		if !password.isEmpty && ( password.utf8.count < 8 || password.utf8.count > 63 ) { return "Wi-Fi passwords have 8 to 63 characters." }
		return nil
	}

	private func join() {
		guard wifiProblem == nil else { return }
		setup.join( ssid: joinSSID, password: password )
	}

	// MARK: - Name

	private func nameSection( _ info: USBSetup.DeviceInfo ) -> some View {
		Section {
			HStack {
				TextField( "Name", text: $nameDraft )
					.onSubmit( saveName )
				Button( "Rename" ) { saveName() }
					.disabled( nameProblem != nil || nameDraft == info.name || setup.rename == .saving )
			}
			if let problem = nameProblem, !nameDraft.isEmpty {
				Text( problem )
					.font( .caption )
					.foregroundStyle( .secondary )
			}
			if case .failed( let message ) = setup.rename {
				Label( message, systemImage: "exclamationmark.triangle.fill" )
					.foregroundStyle( .orange )
			}
		} header: {
			SectionHeader( "Name" )
		} footer: {
			Text( "The device keeps its name. If it's connected to ESPDeck Bridge, the new name shows up there right away." )
		}
		.disabled( setup.install.isBusy )
	}

	private var trimmedName: String {
		nameDraft.trimmingCharacters( in: .whitespacesAndNewlines )
	}

	private var nameProblem: String? {
		if trimmedName.isEmpty { return "Enter a name." }
		if trimmedName.utf8.count > 32 { return "That name is too long; names have at most 32 characters." }
		return nil
	}

	private func saveName() {
		guard nameProblem == nil else { return }
		nameDraft = trimmedName
		setup.setName( trimmedName )
	}

	// MARK: - Next

	private func nextSection( _ network: String ) -> some View {
		Section {
			let name    = setup.selectedBoard?.espDeck?.name ?? "The device"
			let arrival = setup.arrival( named: name )
			Label( network.isEmpty ? "\(name) joined the network." : "\(name) joined “\(network)”.", systemImage: "checkmark.circle.fill" )
				.foregroundStyle( .green )

			if let arrival {
				HStack {
					Text( arrival.needsPairing ? "It found ESPDeck Bridge and is waiting to be paired." : "It's connected to ESPDeck Bridge." )
					Spacer()
					Button( arrival.needsPairing ? "Pair It" : "Show It" ) { selection = arrival.selection }
				}
			} else {
				Label( "Waiting for it to find ESPDeck Bridge…", systemImage: "antenna.radiowaves.left.and.right" )
					.foregroundStyle( .secondary )
			}
		} header: {
			SectionHeader( "Next" )
		} footer: {
			Text( nextSteps )
		}
	}

	/// Pairing needs a key press on the deck, and on the board's native USB port the Mac is
	/// where the deck would be.
	private var nextSteps: String {
		let pairing = "A new device appears under New Devices in the sidebar. Click Pair, check that the deck shows the same code, and press Confirm on the deck."
		if setup.selectedBoard?.port.isEspressif == true {
			return "It connects to ESPDeck Bridge over Wi-Fi within a few seconds. To use it, unplug it from this Mac, connect the Stream Deck to its USB port with the OTG adapter, and power it. \(pairing)"
		}
		return "It connects to ESPDeck Bridge over Wi-Fi within a few seconds. \(pairing)"
	}
}
