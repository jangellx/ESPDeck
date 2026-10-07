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

/// The USB Setup page: scanning, the boards found, and setting one up in numbered steps.
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

	private var setup: USBSetup { controller.usbSetup }

	var body: some View {
		Form {
			ScanningSection( setup: setup )
			if setup.scanning {
				BoardsSection( setup: setup,
							   latestVersion: controller.updates.latestFirmware?.version,
							   bridgeID: controller.config.settings.bridgeID )
				// The steps are only for a board on its own USB port (which is also what it shows as
				// in flashing mode). On its COM port there's just its row, saying to move the cable:
				// the app can't tell which deck that is, and installing there was never the tested way.
				let onUSBPort = setup.selectedBoard?.port.isEspressif == true
				if onUSBPort {
					FirmwareSection( setup: setup, updates: controller.updates, pickingFile: $pickingFile )
				}
				if onUSBPort, let info = setup.selectedBoard?.espDeck {
					WiFiSection( setup: setup, savedSSID: savedSSID, ssid: $ssid, otherSSID: $otherSSID,
								 password: $password, encrypt: $encrypt )
					NameSection( setup: setup, name: info.name, nameDraft: $nameDraft )
				}
				if onUSBPort, case .joined( let network ) = setup.wifi, let joined = setup.joinedBoard {
					NextSection( setup: setup, window: controller.window, network: network, joined: joined,
								 selection: $selection )
				}
			}
			// Not for a board on its COM port either: its one instruction there is to move the cable.
			if setup.selectedBoard == nil || setup.selectedBoard?.port.isEspressif == true {
				AssemblySection( window: controller.window, selection: $selection )
			}
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
		.alert( "Can't Use That File", isPresented: Binding( presenting: $fileProblem ) ) {
			Button( "OK" ) {}
		} message: {
			Text( fileProblem ?? "" )
		}
	}

	/// Releases found a while ago may not be the latest any more, so the page checks again
	/// when it has been a few minutes.
	private static let recheckAfter: TimeInterval = 5 * 60

	/// Fills in the name and network, looks for networks, and checks for releases if it's due.
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

	/// Makes a picked file the source, or says why it can't be.
	private func choose( _ url: URL ) {
		do {
			try setup.choose( url )
		} catch {
			fileProblem = error.localizedDescription
		}
	}

	/// The network the selected board is set up for, when its firmware says.
	private var savedSSID: String? {
		setup.selectedBoard?.espDeck?.network.flatMap { $0.ssid.isEmpty ? nil : $0.ssid }
	}
}

/// Shows Getting Started's Putting It Together sheet, on the USB path.
@MainActor private func showAssembly( in window: WindowState, selection: Binding<String?> ) {
	window.guidePath        = .usb
	window.guideSheet       = .assembly
	selection.wrappedValue  = SidebarItem.parts
}

// MARK: - Scanning

/// The switch that turns scanning for boards on and off.
private struct ScanningSection: View {
	let setup : USBSetup

	var body: some View {
		Section {
			// A switch, so the symbol in front of the text can't be taken for a checkbox.
			Toggle( isOn: Bindable( setup ).scanning ) {
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
				Text( "When an ESP32-S3 is plugged into this computer, ESPDeck Bridge briefly asks what it's running, then releases it." )
			} else {
				Text( "Scanning is off: ESPDeck Bridge doesn't watch or open USB ports. Turn it on to set up a board over USB." )
			}
		}
	}
}

// MARK: - Boards

/// The boards plugged in, or a picture of plugging one in while there are none.
private struct BoardsSection: View {
	let setup         : USBSetup
	/// The latest release's version, to say how each board's firmware compares.
	let latestVersion : Version?
	/// This bridge, to say whether a board is paired with it.
	let bridgeID      : String

	var body: some View {
		Section {
			if setup.boards.isEmpty {
				VStack( spacing: 12 ) {
					// At the size it's drawn for, as in Getting Started: smaller, its labels are hard to read.
					USBConnectionIllustration()
						.frame( height: USBConnectionIllustration.space.height )
						.frame( maxWidth: .infinity )
					Label( "No board is plugged in.", systemImage: "cable.connector.slash" )
						.foregroundStyle( .secondary )
				}
				.padding( .vertical, 8 )
			}
			ForEach( setup.boards ) { board in
				BoardRow( setup: setup, board: board, latestVersion: latestVersion, bridgeID: bridgeID )
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
}

/// A board and what it's said about itself, chosen by clicking when there are several.
private struct BoardRow: View {
	let setup         : USBSetup
	let board         : USBSetup.Board
	/// The latest release's version, to say how the board's firmware compares.
	let latestVersion : Version?
	/// This bridge, to say whether the board is paired with it.
	let bridgeID      : String

	var body: some View {
		let choosable = setup.boards.count > 1
		let chosen    = setup.selectedBoard?.id == board.id

		Button {
			setup.selectedPath = board.port.path
		} label: {
			HStack( alignment: .top, spacing: 10 ) {
				if choosable {
					Image( systemName: chosen ? "checkmark.circle.fill" : "circle" )
						.foregroundStyle( chosen ? Color.accentColor : Color.secondary )
				}
				VStack( alignment: .leading, spacing: 3 ) {
					Text( board.espDeck.map { "\($0.name)" } ?? board.port.title )
					ForEach( details, id: \.self ) { line in
						HStack( alignment: .firstTextBaseline, spacing: 6 ) {
							Text( "•" )
							Text( line )
						}
						.font( .callout )
						.foregroundStyle( .primary )
					}
					// On the board's serial chip, Check still says what it runs, but setup is done on
					// the USB port, the one the app knows the board by (its serial number there is
					// the deck's ID).
					if !board.port.isEspressif {
						WarningLabel( "This is the board's COM (UART) port. Plug the cable into its port labeled USB instead: ESPDeck Bridge will recognize the board there on its own, and the setup steps will appear." )
							.font( .callout )
							.padding( .top, 2 )
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
	private var details: [String] {
		var lines: [String] = []
		switch board.answer {
			case .asking:
				lines.append( "Asking what it's running…" )
			case .answered( let info ) where info.isESPDeck:
				let standing = FirmwareStanding( running: info.version, latest: latestVersion ).description
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
		if let hostname = board.espDeck?.network?.hostname {
			lines.append( "Network name: \(hostname) (\(hostname).local)" )
		}
		if let paired = board.espDeck?.pairedBridge {
			lines.append( paired.isEmpty ? "Not paired" : paired == bridgeID ? "Paired with this Mac" : "Paired with another ESPDeck Bridge" )
		}
		if let storage = board.espDeck?.storage {
			lines.append( storage.isEncrypted ? "Stored secrets: encrypted" : "Stored secrets: not encrypted" )
		}
		if let hardware = board.hardware {
			lines.append( hardware )
		} else if let chip = board.espDeck?.chip {
			lines.append( chip )
		} else {
			lines.append( "Looks like an ESP32 board; installing checks that it's an ESP32-S3." )
		}
		return lines
	}
}

// MARK: - Firmware

/// Step 1: the firmware to install, and installing it.
private struct FirmwareSection: View {
	let setup                : USBSetup
	let updates              : UpdateManager
	/// Opens the page's file picker.
	@Binding var pickingFile : Bool

	/// Asking before installing older firmware than the board runs.
	@State private var confirmingOlder = false

	var body: some View {
		Section {
			LabeledContent( "Firmware" ) {
				// The popup with its refresh button, and when releases were last looked for
				// under it.
				VStack( alignment: .leading, spacing: 4 ) {
					HStack( spacing: 6 ) {
						FirmwareSourcePicker( setup: setup, updates: updates, pickingFile: $pickingFile )
						if updates.repository != nil {
							RefreshReleasesButton( setup: setup, updates: updates )
						}
					}
					if updates.repository != nil {
						ReleaseCheckStatus( updates: updates )
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
							   || ( setup.source == .release && updates.latestFirmware == nil ) )
			}
			// A row that starts with a spacer gets a divider only as wide as its button.
			.alignmentGuide( .listRowSeparatorLeading ) { _ in 0 }
			.confirmationDialog( olderTitle, isPresented: $confirmingOlder, titleVisibility: .visible ) {
				Button( "Install Older Firmware" ) { setup.installFirmware() }
			} message: {
				Text( "The board runs a newer version than the one you chose. ESPDeck Bridge may expect things the older firmware can't do." )
			}

			InstallStatus( install: setup.install )
		} header: {
			SectionHeader( "1. Install Firmware" )
		} footer: {
			Text( "Installing will keep the board's Wi-Fi settings, name, and pairing. Before writing anything, it will verify that the board is an ESP32-S3 with enough flash and the PSRAM for ESPDeck. If the board can't enter flash mode by itself, hold BOOT, press and release RST, release BOOT, then click Install Firmware again." )
		}
	}

	/// Asking before installing older firmware than the board runs.
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
}

/// The firmware to install: the latest release or a chosen file. As in Updates.
private struct FirmwareSourcePicker: View {
	let setup                : USBSetup
	let updates              : UpdateManager
	/// Opens the page's file picker.
	@Binding var pickingFile : Bool

	var body: some View {
		let isFile: Bool = { if case .file = setup.source { true } else { false } }()
		FirmwareSourceMenu( releaseTitle: updates.latestReleaseTitle,
							fileTitle: setup.chosenFile.map { "\($0.url.lastPathComponent) (\($0.version))" },
							isFile: isFile,
							chooseRelease: { setup.source = .release },
							chooseFile: { if let chosenFile = setup.chosenFile { setup.source = .file( chosenFile.url ) } },
							pickFile: { pickingFile = true } )
			.disabled( setup.install.isBusy )
	}
}

/// Looks for new releases; a spinner while it does.
private struct RefreshReleasesButton: View {
	let setup   : USBSetup
	let updates : UpdateManager

	var body: some View {
		RefreshButton( busy: updates.checking, help: "Check for new releases" ) {
			Task { await updates.check( userInitiated: true ) }
		}
		.disabled( setup.install.isBusy )
	}
}

/// When releases were last looked for, under the popup.
private struct ReleaseCheckStatus: View {
	let updates : UpdateManager

	var body: some View {
		Group {
			if updates.checking {
				Text( "Checking for new releases…" )
			} else if let error = updates.checkError {
				WarningLabel( error )
			} else if let date = updates.lastCheck {
				Text( "Last checked \( date.formatted( .relative( presentation: .named ) ) )" )
			}
		}
		.secondaryCaption()
	}
}

/// How the install is going, or how it ended.
private struct InstallStatus: View {
	let install : USBSetup.Install

	var body: some View {
		switch install {
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
				WarningLabel( message )
		}
	}
}

// MARK: - Wi-Fi

/// Step 2: the network and password, and joining it.
private struct WiFiSection: View {
	let setup              : USBSetup
	/// The network the selected board is set up for, when its firmware says.
	let savedSSID          : String?
	@Binding var ssid      : String
	@Binding var otherSSID : String
	@Binding var password  : String
	/// "Encrypt stored secrets", for a new board with plain storage.
	@Binding var encrypt   : Bool

	/// The picker's "Other Network…" tag: longer than any network name (32 bytes).
	static let otherNetwork = "(other network, typed in by hand)"

	var body: some View {
		Section {
			LabeledContent( "Network" ) {
				HStack( spacing: 6 ) {
					NetworkPicker( setup: setup, savedSSID: savedSSID, ssid: $ssid )
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
						.secondaryCaption()
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
					.secondaryCaption()
			}
			if case .failed( let message ) = setup.wifi {
				WarningLabel( message )
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

	/// The network to join: the one chosen, or the one typed in.
	private var joinSSID: String {
		ssid == Self.otherNetwork ? otherSSID : ssid
	}

	/// The board is joining a network now.
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

	/// Joins the network, if the name and password can be.
	private func join() {
		guard wifiProblem == nil else { return }
		setup.join( ssid: joinSSID, password: password, encrypt: storageChoice ? encrypt : nil )
	}
}

/// The networks the board can see, its current one, and Other Network….
private struct NetworkPicker: View {
	let setup         : USBSetup
	/// The network the selected board is set up for, when its firmware says.
	let savedSSID     : String?
	@Binding var ssid : String

	var body: some View {
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
			Text( "Other Network…" ).tag( WiFiSection.otherNetwork )
		}
		.labelsHidden()
		.fixedSize()
	}
}

// MARK: - Name

/// Step 3: renaming the board.
private struct NameSection: View {
	let setup              : USBSetup
	/// The name the board has now.
	let name               : String
	@Binding var nameDraft : String

	var body: some View {
		Section {
			HStack {
				TextField( "Name", text: $nameDraft )
					.onSubmit( saveName )
				Button( "Rename" ) { saveName() }
					.disabled( nameProblem != nil || nameDraft == name || setup.rename == .saving )
			}
			if let problem = nameProblem, !nameDraft.isEmpty {
				Text( problem )
					.secondaryCaption()
			}
			if case .failed( let message ) = setup.rename {
				WarningLabel( message )
			}
		} header: {
			SectionHeader( "3. Name Your Deck" )
		} footer: {
			Text( "The device keeps its name. If it's connected to ESPDeck Bridge, the new name will show up there right away." )
		}
		.disabled( setup.install.isBusy )
	}

	/// The name as it'll be saved.
	private var trimmedName: String {
		nameDraft.trimmingCharacters( in: .whitespacesAndNewlines )
	}

	/// What's wrong with the name, if anything.
	private var nameProblem: String? {
		if trimmedName.isEmpty { return "Enter a name." }
		if trimmedName.utf8.count > 32 { return "That name is too long; names have at most 32 characters." }
		return nil
	}

	/// Renames the board, if the name can be.
	private func saveName() {
		guard nameProblem == nil else { return }
		nameDraft = trimmedName
		setup.setName( trimmedName )
	}
}

// MARK: - Next

/// Step 4: the board that joined a network, until it has found this bridge and after.
private struct NextSection: View {
	let setup              : USBSetup
	let window             : WindowState
	/// The network it joined.
	let network            : String
	let joined             : USBSetup.JoinedBoard
	/// The sidebar's selection.
	@Binding var selection : String?

	var body: some View {
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
					showAssembly( in: window, selection: $selection )
					return .handled
				} )
		}
	}

	/// Pairing needs Confirm held on the deck, and on the board's native USB port the Mac is
	/// where the deck would be.
	private var nextSteps: String {
		let pairing = "It will then appear under New Devices in the sidebar: click Pair, check that it shows the same code, and press and hold Confirm on the deck."
		let guide   = "[Putting It Together](espdeck:assembly)"
		if setup.selectedBoard?.port.isEspressif != false {
			return "The deck will connect to ESPDeck Bridge over Wi-Fi within a few seconds. Pairing needs the Stream Deck, so unplug the board from this Mac and connect it to the deck and power, as in \(guide). \(pairing)"
		}
		return "The deck will connect to ESPDeck Bridge over Wi-Fi within a few seconds. \(pairing) The deck needs to be connected; see \(guide)."
	}
}

/// What comes after USB Setup, as on Getting Started's Connect to This Mac, and the way
/// to the sheet about it.
private struct AssemblySection: View {
	let window             : WindowState
	/// The sidebar's selection.
	@Binding var selection : String?

	var body: some View {
		Section {
			VStack( alignment: .leading, spacing: 14 ) {
				GuideStepText( step: PartsView.unplugStep, primaryDetail: true )
				Button {
					showAssembly( in: window, selection: $selection )
				} label: {
					ForwardLabel( title: GuideSheet.assembly.rawValue )
				}
				.prominentButtonStyle()   // only the button, not the whole row, is clickable
				.frame( maxWidth: .infinity )
			}
			.padding( .vertical, 8 )   // even, as Board Info's rows
		}
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
				// Not ProgressView, which hides itself in a Form row (see SystemSpinner).
				SystemSpinner()
					.fixedSize()
					.scaleEffect( 0.8 )
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
