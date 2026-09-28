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
				Picker( "Updates", selection: Binding( get: { updates.firmwarePolicy }, set: { updates.firmwarePolicy = $0 } ) ) {
					ForEach( UpdatePolicy.allCases ) { Text( $0.title ).tag( $0 ) }
				}
				ForEach( controller.devices.filter { controller.settings( $0.id )?.isDemo != true } ) { device in
					FirmwareRow( controller: controller, device: device )
				}
			} header: {
				SectionHeader( "ESPDeck Firmware" )
			} footer: {
				Text( "Firmware is sent to each ESPDeck over its paired connection. Automatic updates wait until a deck is asleep or hasn't been used for 5 minutes. If new firmware can't reconnect, the device goes back to its previous firmware on its own." )
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

	@State private var pickingFile = false
	@State private var pending     : PendingInstall?
	@State private var problem     : String?

	var body: some View {
		let updates = controller.updates
		let name    = title ?? controller.settings( device.id )?.name ?? device.id

		LabeledContent {
			HStack {
				if let progress = device.firmwareProgress {
					progressView( progress )
				} else if updates.firmwareUpdateAvailable( for: device ), let latest = updates.latestFirmware {
					Button( "Update to \(latest.version.description)" ) {
						Task { await updates.installFirmware( on: device.id ) }
					}
					.disabled( !device.isOnline || device.status.setupMode )
				} else if device.firmware != nil {
					Text( updates.latestFirmware == nil ? "" : "Up to date" )
						.foregroundStyle( .secondary )
				}
				if controller.macBridge != nil {
					developmentMenu
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
				Text( "\(older)From \(pending.source), built \(pending.info.built). The device restarts into it; if it can't reconnect, it goes back to the firmware it runs now." )
			}
		}
		.alert( "Can't Install That Firmware", isPresented: Binding( get: { problem != nil }, set: { if !$0 { problem = nil } } ) ) {
			Button( "OK" ) {}
		} message: {
			Text( problem ?? "" )
		}
	}

	/// For development: any ESPDeck app image, whatever its version.
	private var developmentMenu: some View {
		Menu {
			Button( "Install Firmware from File…" ) { pickingFile = true }
		} label: {
			Image( systemName: "ellipsis.circle" )
		}
		.menuStyle( .borderlessButton )
		.menuIndicator( .hidden )
		.fixedSize()
		.help( "Install development firmware" )
		.disabled( !device.isOnline || device.status.setupMode || device.firmwareProgress?.isActive == true )
	}

	/// A file install may go back to an older version (the device allows it for files),
	/// so the confirmation says so.
	private func isDowngrade( _ pending: PendingInstall ) -> Bool {
		FirmwareStanding.isDowngrade( installing: pending.info.version, over: device.firmware ?? "" )
	}

	private func prepare( source: String, _ read: () throws -> Data ) {
		do {
			let image = try read()
			pending = PendingInstall( image: image, info: try FirmwareImage.espDeckApp( image ), source: source )
		} catch {
			problem = error.localizedDescription
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
