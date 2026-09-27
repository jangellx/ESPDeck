//
//  UpdatesView.swift
//  ESPDeck Bridge
//
//  Update policies and status for the app and for every device's firmware.
//

import SwiftUI

struct UpdatesView: View {
	let controller: DeckController

	private var updates: UpdateManager { controller.updates }

	var body: some View {
		Form {
			if updates.repository == nil {
				Section {
					Label( "Updates are off in this build: no GitHub repository is set (ESPDECK_GITHUB_REPOSITORY in Config/Signing.xcconfig).", systemImage: "info.circle" )
						.foregroundStyle( .secondary )
				}
			}

			Section {
				LabeledContent( "Installed", value: updates.currentAppVersion )
				if let latest = updates.latestApp {
					LabeledContent( "Latest", value: latest.version.description )
				}
				appInstallRow
				Picker( "Updates", selection: Binding( get: { updates.appPolicy }, set: { updates.appPolicy = $0 } ) ) {
					ForEach( UpdatePolicy.allCases ) { Text( $0.title ).tag( $0 ) }
				}
				if let latest = updates.latestApp, updates.appUpdateAvailable {
					releaseNotes( latest )
				}
			} header: {
				Text( "ESPDeck Bridge" )
			} footer: {
				Text( "Updates come from the project's GitHub Releases. Before installing, the app checks the download's SHA-256 and that it's signed by the same developer." )
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
				Text( "ESPDeck Firmware" )
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

	@ViewBuilder private var appInstallRow: some View {
		switch updates.appInstall {
			case .idle:
				if updates.appUpdateAvailable {
					Button( "Install and Relaunch" ) { Task { await updates.installApp() } }
				} else if updates.latestApp != nil {
					Text( "ESPDeck Bridge is up to date." ).foregroundStyle( .secondary )
				}
			case .downloading:
				ProgressView( "Downloading…" )
			case .installing:
				ProgressView( "Installing…" )
			case .failed( let message ):
				Label( message, systemImage: "exclamationmark.triangle.fill" )
					.foregroundStyle( .orange )
				Button( "Try Again" ) { Task { await updates.installApp() } }
		}
	}

	@ViewBuilder
	private func releaseNotes( _ release: UpdateRelease ) -> some View {
		if !release.notes.isEmpty {
			DisclosureGroup( "What's New in \(release.version.description)" ) {
				Text( ( try? AttributedString( markdown: release.notes, options: .init( interpretedSyntax: .inlineOnlyPreservingWhitespace ) ) ) ?? AttributedString( release.notes ) )
					.font( .callout )
					.frame( maxWidth: .infinity, alignment: .leading )
			}
		}
		if let page = release.page {
			Link( "View Release on GitHub", destination: page )
		}
	}
}

/// One device's firmware version and update control; also used on the Device page.
struct FirmwareRow: View {
	let controller : DeckController
	let device     : DeckDevice
	/// Replaces the device's name, e.g. with its default name on the Device page.
	var title      : String?

	var body: some View {
		let updates = controller.updates
		let name    = title ?? controller.settings( device.id )?.name ?? device.id

		LabeledContent {
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
		} label: {
			VStack( alignment: .leading, spacing: 2 ) {
				Text( name )
				Text( device.firmware.map { "Firmware \($0)" } ?? ( device.isOnline ? "Firmware unknown" : "Offline" ) )
					.font( .caption )
					.foregroundStyle( .secondary )
			}
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
						Task { await controller.updates.installFirmware( on: device.id ) }
					}
					.disabled( !device.isOnline )
				}
		}
	}
}
