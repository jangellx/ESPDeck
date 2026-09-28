//
//  UpdatesView.swift
//  ESPDeck Bridge
//
//  Firmware update policy and status for every device. The app itself is updated by the
//  App Store.
//

import SwiftUI
import UniformTypeIdentifiers

struct UpdatesView: View {
	let controller: DeckController

	private var updates: UpdateManager { controller.updates }

	var body: some View {
		Form {
			if updates.repository == nil {
				Section {
					Label( "Firmware updates are off in this build: no GitHub repository is set (ESPDECK_GITHUB_REPOSITORY in Config/Signing.xcconfig).", systemImage: "info.circle" )
						.foregroundStyle( .secondary )
				}
			}

			Section {
				if let latest = updates.latestFirmware {
					LabeledContent( "Latest", value: latest.version.description )
				}
				if let unsigned = updates.unsignedFirmware {
					Text( "Firmware \(unsigned.description) on GitHub isn't signed, so it isn't offered. Releases are signed from \(FirmwareSignature.firstSignedRelease) on; an unsigned one can only be installed from a file, on the Mac." )
						.font( .caption )
						.foregroundStyle( .secondary )
				}
				Picker( "Updates", selection: Binding( get: { updates.firmwarePolicy }, set: { updates.firmwarePolicy = $0 } ) ) {
					ForEach( UpdatePolicy.allCases ) { Text( $0.title ).tag( $0 ) }
				}
				ForEach( controller.devices.filter { controller.settings( $0.id )?.isDemo != true } ) { device in
					FirmwareRow( controller: controller, device: device )
				}
			} header: {
				SectionHeader( "ESPDeck Firmware" )
			} footer: {
				Text( "Firmware from GitHub is installed only if it's signed with ESPDeck's release key, and is sent to each ESPDeck over its paired connection. Automatic updates wait until a deck is asleep or hasn't been used for 5 minutes. If new firmware can't reconnect, the device goes back to its previous firmware on its own." )
			}

			Section {
				HStack {
					Button( updates.checking ? "Checking…" : "Check Now" ) {
						Task { await updates.check( userInitiated: true ) }
					}
					.disabled( updates.checking || updates.repository == nil )
					Spacer()
					if let date = updates.lastCheck {
						Text( "Last checked \( date.formatted( .relative( presentation: .named ) ) )" )
							.foregroundStyle( .secondary )
					}
				}
				if let error = updates.checkError {
					Label( error, systemImage: "exclamationmark.triangle.fill" )
						.foregroundStyle( .orange )
				}
			}
		}
		.formStyle( .grouped )
		.navigationTitle( "Updates" )
	}
}

/// One device's firmware version and update control; also used on the Device page. On
/// the Mac, a menu installs development firmware from a file.
struct FirmwareRow: View {
	let controller : DeckController
	let device     : DeckDevice
	/// Replaces the device's name, e.g. with its default name on the Device page.
	var title      : String?

	/// An image checked and waiting for the user to confirm.
	private struct PendingInstall {
		var image  : Data
		var info   : FirmwareImage.AppInfo
		var source : String
	}

	/// What the Firmware menu has selected.
	private enum Choice: Hashable {
		case release
		case file
		case chooseFile
	}

	@State private var pickingFile = false
	@State private var pending     : PendingInstall?
	@State private var problem     : String?
	@State private var choice      = Choice.release
	/// The last file chosen, read and checked, ready to install.
	@State private var chosen      : PendingInstall?

	var body: some View {
		let updates = controller.updates
		let name    = title ?? controller.settings( device.id )?.name ?? device.id

		LabeledContent {
			HStack {
				if let progress = device.firmwareProgress {
					progressView( progress )
				} else {
					firmwareMenu
					installButton
				}
			}
		} label: {
			VStack( alignment: .leading, spacing: 2 ) {
				Text( name )
				Text( device.firmware.map { "Firmware \($0)" } ?? ( device.isOnline ? "Firmware unknown" : "Offline" ) )
					.font( .caption )
					.foregroundStyle( .secondary )
			}
		}
		.fileImporter( isPresented: $pickingFile, allowedContentTypes: [ .data ] ) { result in
			if case .success( let url ) = result {
				prepare( source: url.lastPathComponent ) { try USBSetup.read( url ) }
			} else if chosen == nil {
				choice = .release
			}
		}
		.onChange( of: choice ) { _, new in
			if new == .chooseFile {
				choice      = chosen == nil ? .release : .file   // a sentinel, not a real choice
				pickingFile = true
			}
		}
		.confirmationDialog( pending.map { ( isDowngrade( $0 ) ? "Install older firmware \($0.info.version) on \(name)?" : "Install firmware \($0.info.version) on \(name)?" ) } ?? "",
							 isPresented: Binding( get: { pending != nil }, set: { if !$0 { pending = nil } } ), titleVisibility: .visible ) {
			Button( pending.map( isDowngrade ) == true ? "Install Older Firmware" : "Install" ) {
				if let pending {
					controller.updates.installLocalFirmware( on: device.id, image: pending.image, info: pending.info )
				}
				pending = nil
			}
		} message: {
			if let pending {
				let older = isDowngrade( pending )
					? "This is older than the \(device.firmware ?? "") it's running, and ESPDeck Bridge may expect things it can't do. "
					: ""
				Text( "\(older)From \(pending.source), built \(pending.info.built). Firmware from a file isn't checked against the release signature, so only install builds you trust. The device restarts into it; if it can't reconnect, it goes back to the firmware it runs now." )
			}
		}
		.alert( "Can't Install That Firmware", isPresented: Binding( get: { problem != nil }, set: { if !$0 { problem = nil } } ) ) {
			Button( "OK" ) {}
		} message: {
			Text( problem ?? "" )
		}
	}

	/// Like USB Setup's: the latest signed release, the chosen file, then Choose File… after a
	/// divider (on the Mac, where files can be picked).
	private var firmwareMenu: some View {
		let latest = controller.updates.latestFirmware
		return Picker( "Firmware", selection: $choice ) {
			Text( latest.map { "Latest release (\($0.version.description))" } ?? "No signed release yet" )
				.tag( Choice.release )
			if let chosen {
				Text( "\(chosen.source) (\(chosen.info.version))" )
					.tag( Choice.file )
			}
			if controller.macBridge != nil {
				Divider()
				Text( "Choose File…" )
					.tag( Choice.chooseFile )
			}
		}
		.labelsHidden()
		.fixedSize()
		.disabled( device.status.setupMode || device.firmwareProgress?.isActive == true )
	}

	/// Installs the menu's choice: a release only when it's newer than what the device runs.
	@ViewBuilder
	private var installButton: some View {
		let updates = controller.updates
		switch choice {
			case .file:
				Button( "Install" ) { pending = chosen }
					.disabled( !device.isOnline || device.status.setupMode || chosen == nil )
			default:
				if updates.firmwareUpdateAvailable( for: device ) {
					Button( "Install" ) {
						Task { await updates.installFirmware( on: device.id ) }
					}
					.disabled( !device.isOnline || device.status.setupMode )
				} else if updates.latestFirmware != nil && device.firmware != nil {
					Text( "Up to date" )
						.foregroundStyle( .secondary )
				}
		}
	}

	/// A file install may go back to an older version (the device allows it for files),
	/// so the confirmation says so.
	private func isDowngrade( _ pending: PendingInstall ) -> Bool {
		FirmwareStanding.isDowngrade( installing: pending.info.version, over: device.firmware ?? "" )
	}

	private func prepare( source: String, _ read: () throws -> Data ) {
		do {
			let image = try read()
			let info  = try FirmwareImage.espDeckApp( image )
			// sendFirmware refuses it too; say so now rather than after confirming.
			if device.status.storage == "encrypted", let version = Version( info.version ), version < DeckController.storageEncryptionFirmware {
				problem = "This is firmware \(info.version). This device's stored secrets are encrypted, which firmware before \(DeckController.storageEncryptionFirmware) can't read, so it can't be installed here."
				return
			}
			chosen  = PendingInstall( image: image, info: info, source: source )
			choice  = .file
			pending = chosen
		} catch {
			problem = error.localizedDescription
			if chosen == nil { choice = .release }
		}
	}

	@ViewBuilder
	private func progressView( _ progress: FirmwareProgress ) -> some View {
		switch progress.phase {
			case .downloading:
				ProgressView( "Downloading \(progress.version)…" ).controlSize( .small )
			case .sending( let sent, let total ):
				ProgressView( value: Double( sent ), total: Double( max( total, 1 ) ) ) {
					Text( "Sending \(progress.version)…" ).font( .caption )
				}
				.frame( width: 180 )
			case .installing:
				ProgressView( "Installing…" ).controlSize( .small )
			case .restarting:
				ProgressView( "Restarting…" ).controlSize( .small )
			case .failed( let message ):
				HStack {
					Label( message, systemImage: "exclamationmark.triangle.fill" )
						.foregroundStyle( .orange )
						.font( .caption )
						.lineLimit( 2 )
					Button( "Retry" ) {
						Task { await controller.updates.retryFirmware( on: device.id ) }
					}
					.disabled( !device.isOnline )
				}
		}
	}
}
