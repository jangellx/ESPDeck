//
//  NewDeviceView.swift
//  ESPDeck Bridge
//
//  A connected ESPDeck that isn't paired with this Mac: pair it by comparing the code
//  shown here with the one on the deck, confirming here that they match, and holding
//  Confirm on the deck.
//

import SwiftUI

struct NewDeviceView: View {
	let controller : DeckController
	let client     : ClientID

	/// The name of the deck whose pairing on this Mac a new one would replace, while asking.
	@State private var replacing: String?

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
		} else if !device.reason.canPair {
			Text( "Open the deck's setup page: hold its top-left and bottom-right keys for 5 seconds, scan the QR codes, then choose Unpair. It then shows up here ready to pair." )
				.font( .callout )
				.foregroundStyle( .secondary )
				.multilineTextAlignment( .center )
		} else {
			switch device.pairing {
				case .idle:
					Button( "Pair with This Mac" ) { startPairing( device ) }
						.buttonStyle( .borderedProminent )
						.controlSize( .large )
						.confirmationDialog( "Replace the existing pairing for \(replacing ?? "")?",
											 isPresented: Binding( get: { replacing != nil }, set: { if !$0 { replacing = nil } } ), titleVisibility: .visible ) {
							Button( "Replace Pairing", role: .destructive ) { controller.pair( client, replacing: true ) }
						} message: {
							Text( replaceMessage( device ) )
						}
					Text( "The deck will show a code to compare with the one shown here. If they match, you confirm here and hold Confirm on the deck." )
						.font( .caption )
						.foregroundStyle( .secondary )
						.multilineTextAlignment( .center )

				case .waitingForDevice:
					ProgressView( "Waiting for the deck…" )
					cancelButton

				case .compare( let code, let deckConfirmed ):
					codeBox( code ) {
						Text( "Does the deck show this code?" )
							.font( .headline )
						HStack( spacing: 12 ) {
							Button( "It Doesn't Match", role: .destructive ) { controller.rejectCode( client ) }
							Button( "The Deck Shows This Code" ) { controller.confirmCode( client ) }
								.buttonStyle( .borderedProminent )
						}
						Text( deckConfirmed ? "It was confirmed on the deck."
											: "If it doesn't match, something else may be answering for the deck: don't pair." )
							.font( .caption )
							.foregroundStyle( .secondary )
							.multilineTextAlignment( .center )
					}
					cancelButton

				case .confirmOnDeck( let code ):
					codeBox( code ) {
						Text( "Now hold **Confirm** on the deck (bottom right) until it shows “Waiting for Mac”. On a Stream Deck Pedal, hold any pedal." )
							.font( .callout )
							.multilineTextAlignment( .center )
					}
					cancelButton

				case .finishing:
					ProgressView( "Finishing…" )

				case .failed( let message ):
					Label( message, systemImage: "exclamationmark.triangle.fill" )
						.foregroundStyle( .orange )
						.multilineTextAlignment( .center )
					Button( "Try Again" ) { startPairing( device ) }
			}
		}
	}

	/// Pairs at once, or first asks to replace this Mac's pairing for the same device ID.
	private func startPairing( _ device: NewDevice ) {
		if let name = controller.existingPairingName( for: device.hello.id ) {
			replacing = name
		} else {
			controller.pair( client )
		}
	}

	private func replaceMessage( _ device: NewDevice ) -> String {
		var text = "This Mac is already paired with a deck with this MAC address (\(device.hello.id)). Pairing this one replaces that pairing, and keeps its key layout."
		if controller.device( device.hello.id )?.isOnline == true {
			text += " That deck is connected right now, and will be disconnected."
		}
		return text
	}

	private func codeBox<Content: View>( _ code: String, @ViewBuilder content: () -> Content ) -> some View {
		VStack( spacing: 12 ) {
			Text( code.prefix( 3 ) + " " + code.suffix( 3 ) )
				.font( .system( size: 44, weight: .semibold, design: .monospaced ) )
				.textSelection( .enabled )
			content()
		}
		.padding( 20 )
		.background( RoundedRectangle( cornerRadius: 14, style: .continuous ).fill( Color.secondary.opacity( 0.1 ) ) )
	}

	private var cancelButton: some View {
		Button( "Cancel", role: .cancel ) { controller.cancelPairing( client ) }
	}
}
