//
//  UpdatesView.swift
//  ESPDeck Bridge
//
//  Firmware update policy and status for every device. The app itself is updated by the
//  App Store.
//

import SwiftUI
import UniformTypeIdentifiers

/// The Updates page: the latest firmware, the update policy, and each device's firmware.
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
						.secondaryCaption()
				}
				Picker( "Updates", selection: Bindable( updates ).firmwarePolicy ) {
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
					WarningLabel( error )
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
	/// Replaces the device's name as the heading, e.g. "Firmware" on the Device page, where
	/// the line under it is then just the version. Confirmations still name the device.
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
		let name = controller.settings( device.id )?.name ?? device.id

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
			CaptionedText( title ?? name, caption: device.firmware.map { title == nil ? "Firmware \($0)" : $0 } ?? ( device.isOnline ? "Unknown" : "Offline" ),
						   spacing: 2 )
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
							 isPresented: Binding( presenting: $pending ), titleVisibility: .visible ) {
			Button( pending.map( isDowngrade ) == true ? "Install Older Firmware" : "Install" ) {
				if let pending {
					controller.updates.installLocalFirmware( on: device.id, image: pending.image, info: pending.info )
				}
				pending = nil
			}
		} message: {
			if let pending {
				let older = isDowngrade( pending )
					? "This firmware is older than the \(device.firmware ?? "") the deck is running now, and may not support everything this version of ESPDeck Bridge expects. "
					: ""
				Text( "\(older)Source: \(pending.source), built \(pending.info.built). Firmware from a file isn't checked against the release signature, so only install builds you trust. The device will restart into it; if it can't reconnect, it will go back to the firmware it runs now." )
			}
		}
		.alert( "Can't Install That Firmware", isPresented: Binding( presenting: $problem ) ) {
			Button( "OK" ) {}
		} message: {
			Text( problem ?? "" )
		}
	}

	/// As in USB Setup; Choose File… only on the Mac, where files can be picked.
	private var firmwareMenu: some View {
		FirmwareSourceMenu( releaseTitle: controller.updates.latestReleaseTitle,
							fileTitle: chosen.map { "\($0.source) (\($0.info.version))" },
							isFile: choice == .file,
							chooseRelease: { choice = .release },
							chooseFile: { choice = .file },
							pickFile: controller.macBridge != nil ? { pickingFile = true } : nil )
			.disabled( !device.isOnline || device.status.setupMode || device.firmwareProgress?.isActive == true )
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

	/// Reads and checks a firmware file, then asks to install it; says why if it can't be.
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

	/// An install under way: downloading, sending, installing, restarting, or why it failed.
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
					WarningLabel( message )
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

/// Where firmware comes from: the latest signed release, the chosen file, then Choose File…
/// after a divider. A menu labeled with the current choice rather than a Picker: a Picker
/// kept showing Choose File… after a file was picked, until it was opened again.
struct FirmwareSourceMenu: View {
	let releaseTitle  : String
	/// The chosen file, once there is one.
	let fileTitle     : String?
	/// The file is chosen rather than the release.
	let isFile        : Bool
	let chooseRelease : () -> Void
	let chooseFile    : () -> Void
	/// Opens the file picker; nil where files can't be picked.
	let pickFile      : ( () -> Void )?

	var body: some View {
		Menu {
			Button {
				chooseRelease()
			} label: {
				MenuChoice( title: releaseTitle, chosen: !isFile )
			}
			if let fileTitle {
				Button {
					chooseFile()
				} label: {
					MenuChoice( title: fileTitle, chosen: isFile )
				}
			}
			if let pickFile {
				Divider()
				Button( "Choose File…", action: pickFile )
			}
		} label: {
			Text( isFile ? fileTitle ?? releaseTitle : releaseTitle )
		}
		.fixedSize()
	}
}

extension UpdateManager {
	/// The firmware menus' release choice: the latest signed release, if there is one.
	var latestReleaseTitle: String {
		latestFirmware.map { "Latest release (\($0.version.description))" } ?? "No signed release yet"
	}
}
