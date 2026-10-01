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
								  ? "Plug the deck's board into this Mac with a USB cable, using its port labeled USB, to unpair it from the bridge."
								  : "To unpair this deck from the bridge, turn on “Look for boards plugged in over USB” in USB Setup, then plug it into this Mac." )
						} icon: {
							Image( systemName: "cable.connector" )
						}
					}
					Label {
						Text( "Or on the deck:" ).bold()
							+ Text( " hold its top-left and bottom-right keys for 5 seconds, scan the QR codes to open the setup page, and choose Unpair." )
					} icon: {
						Image( systemName: "qrcode" )
					}
					Label {
						Text( "Once the deck is unpaired, it will show up under New Devices: pair it, and it will pick up its old keys and settings. They can also be copied onto another deck with Copy From Deck on that deck's Device page." )
					} icon: {
						Image( systemName: "square.on.square" )
					}
				}
				.frame( maxWidth: .infinity, alignment: .leading )

				Button( "Show Keys and Settings", action: showDevice )
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
			Label {
				Text( "The deck is plugged into this Mac over USB." ).bold()
			} icon: {
				Image( systemName: "cable.connector" )
			}
			Button( "Unpair Over USB", role: .destructive ) { setup.unpair( board ) }
				.prominentButtonStyle()
				.tint( .red )
				.disabled( setup.unpairing == .working )
				// Centered, with the spinner beside it rather than pushing it over.
				.overlay( alignment: .trailing ) {
					if setup.unpairing == .working && setup.unpairingPath == board.port.path {
						ProgressView()
							.controlSize( .small )
							.offset( x: 28 )
					}
				}
				.frame( maxWidth: .infinity )
				.padding( .vertical, 4 )
			switch setup.unpairingPath == board.port.path ? setup.unpairing : .idle {
				case .done:
					Text( "Unpaired. It will reconnect as a new device in a moment, ready to pair." )
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
