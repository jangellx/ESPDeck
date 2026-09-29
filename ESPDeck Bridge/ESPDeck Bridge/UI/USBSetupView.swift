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
	/// "Encrypt stored secrets", for a new board with plain storage.
	@State private var encrypt          = true
	@State private var pickingFile      = false
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
				if case .joined( let network ) = setup.wifi, let joined = setup.joinedBoard {
					nextSection( network, joined )
				}
			}
			assemblySection
		}
		.formStyle( .grouped )
		.navigationTitle( "USB Setup" )
		.onAppear( perform: appeared )
		.onChange( of: setup.selectedBoard?.espDeck?.name ) { nameDraft = setup.selectedBoard?.espDeck?.name ?? "" }
		// A board that can be asked for networks, once it's showing.
		.onChange( of: setup.selectedBoard?.espDeck != nil ? setup.selectedBoard?.id : nil ) { setup.findNetworksOnce() }
		// The network the board is set up for, or else the strongest one.
		.onChange( of: savedSSID ) { if let savedSSID { ssid = savedSSID } }
		.onChange( of: setup.networks ) {
			if ssid.isEmpty, let first = savedSSID ?? setup.networks.first?.ssid { ssid = first }
		}
		// On unless Standard was chosen for this board before.
		.onChange( of: setup.selectedBoard?.espDeck?.storage?.setup, initial: true ) { _, choice in
			encrypt = choice != "standard"
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

	/// Releases found a while ago may not be the latest any more, so the page checks again
	/// when it has been a few minutes.
	private static let recheckAfter: TimeInterval = 5 * 60

	private func appeared() {
		nameDraft   = setup.selectedBoard?.espDeck?.name ?? ""
		if ssid.isEmpty, let savedSSID { ssid = savedSSID }
		setup.findNetworksOnce()
		let updates = controller.updates
		let stale   = updates.lastCheck.map { Date().timeIntervalSince( $0 ) > Self.recheckAfter } ?? true
		if updates.repository != nil && ( updates.latestFirmware == nil || stale ) {
			Task { await updates.check( userInitiated: true ) }
		}
	}

	// MARK: - Scanning

	private var scanningSection: some View {
		Section {
			// A switch, so the symbol in front of the text can't be taken for a checkbox.
			Toggle( isOn: Binding( get: { setup.scanning }, set: { setup.scanning = $0 } ) ) {
				Label {
					Text( "Look for boards plugged in over USB" )
				} icon: {
					Image( systemName: "magnifyingglass.circle" )
						.foregroundStyle( .tint )
				}
			}
			.toggleStyle( .switch )
		} footer: {
			if setup.scanning {
				Text( "When an ESP32 is plugged into this computer, ESPDeck Bridge briefly asks what it's running, then releases it." )
			} else {
				Text( "Scanning is off: ESPDeck Bridge doesn't watch or open USB ports. Turn it on to set up a board over USB." )
			}
		}
	}

	// MARK: - Boards

	private var boardsSection: some View {
		Section {
			if setup.boards.isEmpty {
				VStack( spacing: 12 ) {
					USBConnectionIllustration()
						.frame( height: 130 )
						.frame( maxWidth: .infinity )
					Label( "No board is plugged in.", systemImage: "cable.connector.slash" )
						.foregroundStyle( .secondary )
				}
				.padding( .vertical, 8 )
			}
			ForEach( setup.boards ) { board in
				boardRow( board )
					.padding( .vertical, 8 )
					.padding( .horizontal, 4 )
			}
		} header: {
			SectionHeader( "Board Info" )
		} footer: {
			Text( ( setup.boards.count > 1 ? "Click the board to set up. " : "" )
				  + "Connect a USB data cable (not a charge-only one) to the board's port labeled USB. On some boards the second port (labeled COM or UART) doesn't power the board." )
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
						HStack( alignment: .firstTextBaseline, spacing: 6 ) {
							Text( "•" )
							Text( line )
						}
						.font( .callout )
						.foregroundStyle( .primary )
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
		if let network = board.espDeck?.network {
			if network.ssid.isEmpty {
				lines.append( "No Wi-Fi set up" )
			} else {
				lines.append( "Wi-Fi: \(network.ssid)" + ( network.connected ? "" : " (not connected)" ) )
			}
		}
		if let storage = board.espDeck?.storage {
			lines.append( storage.isEncrypted ? "Stored secrets: encrypted" : "Stored secrets: not encrypted" )
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
			LabeledContent( "Firmware" ) {
				// The popup with its refresh button, and when releases were last looked for
				// under it.
				VStack( alignment: .leading, spacing: 4 ) {
					HStack( spacing: 6 ) {
						sourcePicker
						if controller.updates.repository != nil {
							refreshReleasesButton
						}
					}
					if controller.updates.repository != nil {
						releaseCheck
					}
				}
			}

			HStack {
				Spacer()
				if setup.install.isBusy {
					Button( "Stop", role: .cancel ) { setup.cancelInstall() }
				}
				Button( "Install Firmware" ) { installTapped() }
					.prominentButtonStyle()
					// Nothing to install while "No signed release yet" is chosen.
					.disabled( setup.selectedBoard == nil || setup.install.isBusy
							   || ( setup.source == .release && controller.updates.latestFirmware == nil ) )
			}
			// A row that starts with a spacer gets a divider only as wide as its button.
			.alignmentGuide( .listRowSeparatorLeading ) { _ in 0 }
			.confirmationDialog( olderTitle, isPresented: $confirmingOlder, titleVisibility: .visible ) {
				Button( "Install Older Firmware" ) { setup.installFirmware() }
			} message: {
				Text( "The board runs a newer version than the one you chose. ESPDeck Bridge may expect things the older firmware can't do." )
			}

			installStatus
		} header: {
			SectionHeader( "1. Install Firmware" )
		} footer: {
			Text( "Installing keeps the board's Wi-Fi settings, name, and pairing. Before writing anything, it verifies that the board is an ESP32-S3 with enough flash and the PSRAM for ESPDeck. If the board can't enter flash mode by itself, hold BOOT, press and release RST, release BOOT, then click Install Firmware again." )
		}
	}

	/// The latest release, a chosen file, and Choose File… at the end, which opens the file
	/// picker. A menu labelled with the current choice rather than a Picker: a Picker kept
	/// showing Choose File… after a file was picked, until it was opened again.
	private var sourcePicker: some View {
		let latest       = controller.updates.latestFirmware
		// As in Updates.
		let releaseTitle = latest.map { "Latest release (\($0.version.description))" } ?? "No signed release yet"
		let fileTitle    = setup.chosenFile.map { "\($0.url.lastPathComponent) (\($0.version))" }
		let isFile: Bool = { if case .file = setup.source { true } else { false } }()

		return Menu {
			Button {
				setup.source = .release
			} label: {
				MenuChoice( title: releaseTitle, chosen: !isFile )
			}
			if let chosenFile = setup.chosenFile, let fileTitle {
				Button {
					setup.source = .file( chosenFile.url )
				} label: {
					MenuChoice( title: fileTitle, chosen: isFile )
				}
			}
			Divider()
			Button( "Choose File…" ) { pickingFile = true }
		} label: {
			Text( isFile ? fileTitle ?? releaseTitle : releaseTitle )
		}
		.fixedSize()
		.disabled( setup.install.isBusy )
	}

	/// Looks for new releases; a spinner while it does.
	private var refreshReleasesButton: some View {
		let updates = controller.updates
		return RefreshButton( busy: updates.checking, help: "Check for new releases" ) {
			Task { await updates.check( userInitiated: true ) }
		}
		.disabled( setup.install.isBusy )
	}

	/// When releases were last looked for, under the popup.
	@ViewBuilder private var releaseCheck: some View {
		let updates = controller.updates
		Group {
			if updates.checking {
				Text( "Checking for new releases…" )
			} else if let error = updates.checkError {
				Label( error, systemImage: "exclamationmark.triangle.fill" )
					.foregroundStyle( .orange )
			} else if let date = updates.lastCheck {
				Text( "Last checked \( date.formatted( .relative( presentation: .named ) ) )" )
			}
		}
		.font( .caption )
		.foregroundStyle( .secondary )
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
				// The stage on its own line: as the bar's label, each change (per flash region)
				// rebuilt the bar, which then animated up from the start again.
				VStack( alignment: .leading, spacing: 4 ) {
					Text( stage )
					ProgressView( value: fraction )
						.animation( nil, value: fraction )
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
			try setup.choose( url )
		} catch {
			fileProblem = error.localizedDescription
		}
	}

	// MARK: - Wi-Fi

	private var wifiSection: some View {
		Section {
			LabeledContent( "Network" ) {
				HStack( spacing: 6 ) {
					networkPicker
					RefreshButton( busy: setup.findingNetworks, help: "Look for networks again" ) { setup.findNetworks() }
				}
			}
			if ssid == Self.otherNetwork {
				TextField( "Network Name", text: $otherSSID )
			}
			SecureField( "Password", text: $password )
				.onSubmit( join )
			if storageChoice {
				VStack( alignment: .leading, spacing: 4 ) {
					Toggle( "Encrypt stored secrets (recommended)", isOn: $encrypt )
						.toggleStyle( .switch )
					Text( "Permanent for this chip, which gets a one-time key; the Wi-Fi network, name and pairing stay changeable." )
						.font( .caption )
						.foregroundStyle( .secondary )
				}
			}

			// While joining, the button makes way for a spinner.
			HStack {
				if isJoining {
					ProgressView()
						.controlSize( .small )
					Text( "Joining…" )
						.foregroundStyle( .secondary )
				} else {
					Button( "Join Network" ) { join() }
						.disabled( wifiProblem != nil )
				}
			}
			.frame( maxWidth: .infinity )
			.alignmentGuide( .listRowSeparatorLeading ) { _ in 0 }   // full-width divider
			if let problem = wifiProblem, !joinSSID.isEmpty {
				Text( problem )
					.font( .caption )
					.foregroundStyle( .secondary )
			}
			if case .failed( let message ) = setup.wifi {
				Label( message, systemImage: "exclamationmark.triangle.fill" )
					.foregroundStyle( .orange )
			}
			// Where the button was pressed, not only in step 4 further down.
			if case .joined( let network ) = setup.wifi {
				Label( "Joined \u{201C}\(network)\u{201D}. The board keeps this network from now on.", systemImage: "checkmark.circle.fill" )
					.foregroundStyle( .green )
			}
		} header: {
			SectionHeader( "2. Set Up Wi-Fi" )
		} footer: {
			Text( "The board needs a 2.4 GHz network, the same one this Mac is on. It keeps the network once it has joined it." )
		}
		.disabled( setup.install.isBusy )
	}

	private var networkPicker: some View {
		Picker( "Network", selection: $ssid ) {
			if setup.networks.isEmpty {
				Text( setup.findingNetworks ? "Looking for networks…" : "No networks found" ).tag( "" )
			} else if ssid.isEmpty {
				// Otherwise the popup shows the first network, as if it were chosen.
				Text( "Choose…" ).tag( "" )
			}
			ForEach( setup.networks ) { network in
				Label {
					Text( network.ssid )
				} icon: {
					Image( systemName: network.secure ? "lock.fill" : "wifi" )
				}
				.tag( network.ssid )
			}
			// Set up for a network it can't see now (out of range, or hidden).
			if let savedSSID, !setup.networks.contains( where: { $0.ssid == savedSSID } ) {
				Text( "\(savedSSID) (current setting)" ).tag( savedSSID )
			}
			Divider()
			Text( "Other Network…" ).tag( Self.otherNetwork )
		}
		.labelsHidden()
		.fixedSize()
	}

	/// The network the selected board is set up for, when its firmware says.
	private var savedSSID: String? {
		setup.selectedBoard?.espDeck?.network.flatMap { $0.ssid.isEmpty ? nil : $0.ssid }
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

	/// A new board with plain storage (firmware 4.1.0 and later): joining encrypts it unless
	/// the box is unchecked.
	private var storageChoice: Bool {
		setup.selectedBoard?.espDeck?.storage?.offersChoice ?? false
	}

	private func join() {
		guard wifiProblem == nil else { return }
		setup.join( ssid: joinSSID, password: password, encrypt: storageChoice ? encrypt : nil )
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
			SectionHeader( "3. Name Your Device" )
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

	private func nextSection( _ network: String, _ joined: USBSetup.JoinedBoard ) -> some View {
		Section {
			let arrival = setup.arrival( of: joined )
			HStack {
				// One row, so no divider comes between joining and finding the bridge.
				VStack( alignment: .leading, spacing: 8 ) {
					Label {
						Text( network.isEmpty ? "\(joined.name) joined the network." : "\(joined.name) joined “\(network)”." )
					} icon: {
						Image( systemName: "checkmark.circle.fill" )
							.foregroundStyle( .green )
					}
					if let arrival {
						Label {
							Text( arrival.status )
						} icon: {
							Image( systemName: "checkmark.circle.fill" )
								.foregroundStyle( .green )
						}
					} else {
						Label( "Waiting for it to find ESPDeck Bridge…", systemImage: "antenna.radiowaves.left.and.right" )
							.foregroundStyle( .secondary )
					}
				}
				Spacer()
				if let arrival {
					Button( arrival.needsPairing ? "Pair It" : "Show It" ) { selection = arrival.selection }
				}
			}
			.padding( .vertical, 4 )
		} header: {
			SectionHeader( "4. Pair It with This Mac" )
		} footer: {
			// The link opens Getting Started's Putting It Together.
			Text( LocalizedStringKey( nextSteps ) )
				.environment( \.openURL, OpenURLAction { _ in
					showAssembly()
					return .handled
				} )
		}
	}

	/// Pairing needs Confirm held on the deck, and on the board's native USB port the Mac is
	/// where the deck would be.
	private var nextSteps: String {
		let pairing = "It then appears under New Devices in the sidebar: click Pair, check that the deck shows the same code, and hold Confirm on the deck."
		let guide   = "[Putting It Together](espdeck:assembly)"
		if setup.selectedBoard?.port.isEspressif != false {
			return "The device connects to ESPDeck Bridge over Wi-Fi within a few seconds. Pairing needs the Stream Deck, so unplug the board from this Mac and connect it to the deck and power, as in \(guide). \(pairing)"
		}
		return "The device connects to ESPDeck Bridge over Wi-Fi within a few seconds. \(pairing) The deck needs to be connected; see \(guide)."
	}

	/// What comes after USB Setup, as on Getting Started's Connect to This Mac, and the way
	/// to the sheet about it.
	private var assemblySection: some View {
		Section {
			VStack( alignment: .leading, spacing: 14 ) {
				GuideStepText( step: PartsView.unplugStep, primaryDetail: true )
				Button {
					showAssembly()
				} label: {
					HStack( spacing: 6 ) {
						Text( GuideSheet.assembly.rawValue )
						Image( systemName: "chevron.right" )
					}
				}
				.prominentButtonStyle()   // only the button, not the whole row, is clickable
				.frame( maxWidth: .infinity )
			}
			// The title's line box leaves room above it, so less padding there than under the button.
			.padding( .top, 2 )
			.padding( .bottom, 10 )
		}
	}

	/// Getting Started's Putting It Together sheet, on the USB path.
	private func showAssembly() {
		controller.window.guidePath  = .usb
		controller.window.guideSheet = .assembly
		selection                    = SidebarItem.parts
	}
}

/// The circular arrow that looks again, replaced by a spinner of the same size while looking.
private struct RefreshButton: View {
	let busy   : Bool
	let help   : String
	let action : () -> Void

	var body: some View {
		ZStack {
			if busy {
				ProgressView()
					.controlSize( .small )
			} else {
				Button( action: action ) {
					Image( systemName: "arrow.clockwise" )
				}
				.buttonStyle( .borderless )
				.help( help )
				.accessibilityLabel( help )
			}
		}
		.frame( width: 18, height: 18 )
	}
}
