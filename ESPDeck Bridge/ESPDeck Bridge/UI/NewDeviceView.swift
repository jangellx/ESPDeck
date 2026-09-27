//
//  NewDeviceView.swift
//  ESPDeck Bridge
//
//  A connected ESPDeck that isn't paired with this Mac: pair it by comparing the code
//  shown here with the one on the deck, then pressing Confirm on the deck.
//

import SwiftUI

struct NewDeviceView: View {
	let controller : DeckController
	let client     : ClientID

	var body: some View {
		if let device = controller.newDevices.first( where: { $0.client == client } ) {
			ScrollView {
				VStack( spacing: 22 ) {
					Image( systemName: "lock.shield" )
						.font( .system( size: 52 ) )
						.foregroundStyle( .tint )

					VStack( spacing: 6 ) {
						Text( device.hello.name )
							.font( .title.bold() )
						Text( device.reason.explanation )
							.foregroundStyle( .secondary )
							.multilineTextAlignment( .center )
					}

					details( device )

					pairing( device )
				}
				.frame( maxWidth: 460 )
				.padding( 40 )
				.frame( maxWidth: .infinity )
			}
		} else {
			ContentUnavailableView( "Device Disconnected", systemImage: "wifi.slash",
									description: Text( "It will appear again when it reconnects." ) )
		}
	}

	private func details( _ device: NewDevice ) -> some View {
		Grid( alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6 ) {
			GridRow {
				Text( "Stream Deck" ).foregroundStyle( .secondary )
				Text( device.hello.deck.connected ? ( device.hello.deck.model ?? "Connected" ) : "Not connected" )
			}
			GridRow {
				Text( "Firmware" ).foregroundStyle( .secondary )
				Text( device.hello.firmware )
			}
			GridRow {
				Text( "MAC Address" ).foregroundStyle( .secondary )
				Text( device.hello.id ).monospaced()
			}
			if let address = controller.server.endpoint( of: device.client ) {
				GridRow {
					Text( "IP Address" ).foregroundStyle( .secondary )
					Text( address )
				}
			}
		}
		.font( .callout )
	}

	@ViewBuilder
	private func pairing( _ device: NewDevice ) -> some View {
		if device.reason == .oldFirmware {
			Text( "Install the current firmware with the web installer or over USB, then it can pair." )
				.font( .callout )
				.foregroundStyle( .secondary )
				.multilineTextAlignment( .center )
		} else {
			switch device.pairing {
				case .idle:
					Button( "Pair with This Mac" ) { controller.pair( client ) }
						.buttonStyle( .borderedProminent )
						.controlSize( .large )
					Text( "The deck will show a code to compare with this one, and a Confirm key to press." )
						.font( .caption )
						.foregroundStyle( .secondary )
						.multilineTextAlignment( .center )

				case .waitingForDevice:
					ProgressView( "Waiting for the deck…" )
					cancelButton

				case .confirmOnDeck( let code ):
					VStack( spacing: 10 ) {
						Text( "Check that the deck shows" )
							.foregroundStyle( .secondary )
						Text( code.prefix( 3 ) + " " + code.suffix( 3 ) )
							.font( .system( size: 44, weight: .semibold, design: .monospaced ) )
							.textSelection( .enabled )
						Text( "If it matches, press **Confirm** on the deck (bottom right). If it doesn't, press **Cancel** on the deck: something else may be answering for it." )
							.font( .callout )
							.multilineTextAlignment( .center )
					}
					.padding( 20 )
					.background( RoundedRectangle( cornerRadius: 14, style: .continuous ).fill( Color.secondary.opacity( 0.1 ) ) )
					cancelButton

				case .failed( let message ):
					Label( message, systemImage: "exclamationmark.triangle.fill" )
						.foregroundStyle( .orange )
						.multilineTextAlignment( .center )
					Button( "Try Again" ) { controller.pair( client ) }
			}
		}
	}

	private var cancelButton: some View {
		Button( "Cancel", role: .cancel ) { controller.cancelPairing( client ) }
	}
}
