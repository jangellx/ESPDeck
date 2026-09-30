//
//  NeedsUnpairingView.swift
//  ESPDeck Bridge
//
//  A known deck that's connected but can't be authenticated (this Mac has no key for it, or
//  it's paired with another bridge): how to unpair it, on its setup page or over USB from
//  here, instead of its keys. Its keys and settings stay, for when it's paired again.
//

import SwiftUI

/// A known deck's page while it needs unpairing: the ways to unpair it, in place of its keys.
struct NeedsUnpairingView: View {
	let controller : DeckController
	let deviceID   : String
	let stuck      : NewDevice
	/// Shows its keys and settings after all.
	let showDevice : () -> Void

	var body: some View {
		let name  = controller.settings( deviceID )?.name ?? stuck.hello.name
		let setup = controller.usbSetup
		let board = setup.board( forDevice: deviceID )

		ScrollView {
			VStack( spacing: 22 ) {
				UnpairedDeviceHeader( name: name, explanation: stuck.reason.explanation )

				VStack( alignment: .leading, spacing: 14 ) {
					if let board, board.espDeck != nil {
						usbUnpair( board, setup: setup )
					} else {
						Label {
							Text( setup.scanning
								  ? "Plug it into this Mac with a USB cable, in the board's port labeled USB, to unpair it from here."
								  : "To unpair it from here, turn on USB Setup's “Look for boards plugged in over USB”, then plug it into this Mac." )
						} icon: {
							Image( systemName: "cable.connector" )
						}
					}
					Label {
						Text( "Or on the deck: hold its top-left and bottom-right keys for 5 seconds, scan the QR codes to open its setup page, and choose Unpair." )
					} icon: {
						Image( systemName: "qrcode" )
					}
					Label {
						Text( "Once it's unpaired, it shows under New Devices: pair it, and it picks up its keys and settings where it left off. They're kept here meanwhile, under Not Connected, and can be copied onto another deck with Copy From Deck on that deck's Device page." )
					} icon: {
						Image( systemName: "square.on.square" )
					}
				}
				.frame( maxWidth: .infinity, alignment: .leading )

				Button( "Show Its Keys and Settings", action: showDevice )
					.buttonStyle( .borderless )
			}
			.frame( maxWidth: 480 )
			.padding( 40 )
			.frame( maxWidth: .infinity )
		}
	}

	/// Unpairing the board plugged in over USB, and how that went.
	@ViewBuilder
	private func usbUnpair( _ board: USBSetup.Board, setup: USBSetup ) -> some View {
		VStack( alignment: .leading, spacing: 8 ) {
			Label( "It's plugged into this Mac over USB.", systemImage: "cable.connector" )
			HStack {
				Button( "Unpair Over USB" ) { setup.unpair( board ) }
					.prominentButtonStyle()
					.disabled( setup.unpairing == .working )
				if setup.unpairing == .working && setup.unpairingPath == board.port.path {
					ProgressView().controlSize( .small )
				}
			}
			switch setup.unpairingPath == board.port.path ? setup.unpairing : .idle {
				case .done:
					Text( "Unpaired. It reconnects as a new device in a moment, ready to pair." )
						.font( .callout )
						.foregroundStyle( .secondary )
				case .failed( let problem ):
					Text( problem )
						.font( .callout )
						.foregroundStyle( .orange )
				default:
					Text( "Its Wi-Fi settings and everything else stay as they are: only its pairing is removed, so this Mac can pair with it again." )
						.font( .callout )
						.foregroundStyle( .secondary )
			}
		}
	}
}
