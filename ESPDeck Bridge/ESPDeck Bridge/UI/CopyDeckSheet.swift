//
//  CopyDeckSheet.swift
//  ESPDeck Bridge
//
//  Copy From Deck: another deck's settings onto this one, part by part (keys, name, network
//  name, display, sleep, key presses). Any deck this bridge knows can be the source,
//  connected or not.
//

import SwiftUI

/// Copy From Deck: the deck to copy from, and which parts.
struct CopyDeckSheet: View {
	let controller : DeckController
	let deviceID   : String

	@Environment( \.dismiss ) private var dismiss
	@State private var sourceID : String?
	@State private var parts    = DeckCopyPart.fromAnother

	var body: some View {
		let sources = controller.copySources( for: deviceID )
		let source  = sources.first { $0.id == sourceID }
		let online  = controller.device( deviceID )?.isOnline == true

		NavigationStack {
			Form {
				Section {
					Picker( "Copy From", selection: $sourceID ) {
						ForEach( sources ) { deck in
							Text( Self.title( deck, controller: controller ) ).tag( Optional( deck.id ) )
						}
					}
				} footer: {
					Text( "Any deck ESPDeck Bridge knows, connected or not, most recently seen first." )
				}

				Section {
					ForEach( DeckCopyPart.allCases ) { part in
						Toggle( isOn: $parts[contains: part] ) {
							CaptionedText( part.title, caption: part.detail, spacing: 2 )
						}
					}
				} header: {
					SectionHeader( "Copy" )
				} footer: {
					Text( online
						  ? "Replaces these on this deck. Keys can be undone; the rest will go to the deck at once, and a new network name will restart it."
						  : "Replaces these on this deck. It's not connected, so its name, network name, display and sleep timer will go to it when it next connects." )
				}
			}
			.formStyle( .grouped )
			// The most recently seen deck to start with.
			.onAppear { if sourceID == nil { sourceID = sources.first?.id } }
			.navigationTitle( "Copy From Deck" )
			.navigationBarTitleDisplayMode( .inline )
			.toolbar {
				ToolbarItem( placement: .cancellationAction ) {
					Button( "Cancel" ) { dismiss() }
				}
				ToolbarItem( placement: .confirmationAction ) {
					Button( "Copy" ) {
						if let source { controller.copyDeck( from: source, to: deviceID, parts: parts ) }
						dismiss()
					}
					.disabled( source == nil || parts.isEmpty )
				}
			}
		}
		.frame( minWidth: 460, idealWidth: 500, minHeight: 520, idealHeight: 560 )
	}

	/// "Garage ESPDeck", "Test Deck (not connected)", "Office (demo)".
	static func title( _ deck: DeviceSettings, controller: DeckController ) -> String {
		if deck.isDemo { return "\(deck.name) (demo)" }
		return controller.device( deck.id )?.isOnline == true ? deck.name : "\(deck.name) (not connected)"
	}
}

/// Factory Reset, and what to give the deck once it's set up and paired again; then the wait
/// while the deck is told, and a confirmation with a button to close.
struct FactoryResetSheet: View {
	let controller : DeckController
	let deviceID   : String

	@Environment( \.dismiss ) private var dismiss
	/// "" for its own settings, nil for nothing, else another deck's ID.
	@State private var restore: String? = ""

	var body: some View {
		let settings = controller.settings( deviceID )
		let name     = settings?.name ?? "the device"

		Group {
			if controller.factoryResets[deviceID] == .done {
				done( name )
			} else {
				asking( name, settings: settings, working: controller.factoryResets[deviceID] == .resetting )
			}
		}
		// The reset is only followed while this sheet is showing.
		.onDisappear { controller.factoryResets[deviceID] = nil }
	}

	/// What a reset does and what comes back afterwards, with Cancel and Factory Reset; the
	/// same while the deck is told (`working`), with a spinner in the button's place.
	private func asking( _ name: String, settings: DeviceSettings?, working: Bool ) -> some View {
		// A plain stack, sized to what's in it: nothing here needs to scroll.
		VStack( alignment: .leading, spacing: 12 ) {
			Text( "Factory Reset \(name)" )
				.font( .headline )
				.frame( maxWidth: .infinity )

			Text( "\(name) will erase its Wi-Fi settings, name, pairing, and stored key images, and restart in setup mode as if new. Set it up over USB or on its setup page, then pair it again here." )
				.fixedSize( horizontal: false, vertical: true )
				.padding( 14 )
				.frame( maxWidth: .infinity, alignment: .leading )
				.background( .quaternary, in: RoundedRectangle( cornerRadius: 10 ) )

			VStack( alignment: .leading, spacing: 8 ) {
				LabeledContent( "After resetting, restore to" ) {
					Picker( "After resetting, restore to", selection: $restore ) {
						Text( "Its Own Settings" ).tag( Optional( "" ) )
						Text( "Nothing" ).tag( String?.none )
						let others = controller.copySources( for: deviceID ).filter { !$0.isDemo }
						if !others.isEmpty {
							Divider()
							ForEach( others ) { other in
								Text( CopyDeckSheet.title( other, controller: controller ) ).tag( Optional( other.id ) )
							}
						}
					}
					.labelsHidden()
					.disabled( working )
				}
				Group {
					switch restore {
						case "":
							Text( "Its keys stay in ESPDeck Bridge either way. Once it's paired again, it will get back its name, network name, display and sleep settings." )
						case nil:
							Text( "Its keys stay in ESPDeck Bridge. Its name, network name, display and sleep settings will start over." )
						default:
							Text( "Its keys, display, sleep and key press settings will become that deck's now; its display and sleep timer will go to it once it's paired again. Its own name and network name are kept here for it." )
					}
				}
				.secondaryCaption()
				.fixedSize( horizontal: false, vertical: true )
			}
			.padding( 14 )
			.frame( maxWidth: .infinity, alignment: .leading )
			.background( .quaternary, in: RoundedRectangle( cornerRadius: 10 ) )

			HStack {
				Button( "Cancel", role: .cancel ) { dismiss() }
					.disabled( working )
				Spacer()
				// One place for both: the button, then what it set going.
				if working {
					SystemSpinner()
						.fixedSize()
					Text( "Resetting…" )
						.foregroundStyle( .secondary )
				} else {
					Button( "Factory Reset", role: .destructive ) { reset( settings ) }
						.prominentButtonStyle()
						.tint( .red )
				}
			}
			.padding( .top, 4 )
		}
		.padding( 20 )
		.frame( width: 480 )
		.fixedSize( horizontal: false, vertical: true )
		.fittedSheet()
		// Not dismissed by Esc or a click outside while the deck is being told.
		.interactiveDismissDisabled( working )
	}

	/// The deck has started erasing: what happens next, and Done.
	private func done( _ name: String ) -> some View {
		VStack( spacing: 16 ) {
			Image( systemName: "checkmark.circle.fill" )
				.font( .system( size: 40 ) )
				.foregroundStyle( .green )
				.accessibilityHidden( true )
			Text( "\(name) Was Reset" )
				.font( .headline )
				.multilineTextAlignment( .center )
			Text( "\(name) is erasing its storage and will restart in setup mode in a few seconds. Set up the deck over USB or on its setup page, then pair the deck again here." )
				.font( .callout )
				.multilineTextAlignment( .center )
				.fixedSize( horizontal: false, vertical: true )
			Button( "Done" ) { dismiss() }
				.prominentButtonStyle()
				.padding( .top, 4 )
		}
		.padding( 24 )
		.frame( width: 480 )
		.fixedSize( horizontal: false, vertical: true )
		.fittedSheet()
	}


	/// Resets the device, then sets up what it gets back once it's paired again.
	private func reset( _ settings: DeviceSettings? ) {
		guard let settings else { return }
		controller.factoryReset( device: deviceID )
		switch restore {
			case "":
				controller.restoreAfterReset( device: deviceID, from: settings )
			case let id?:
				if let other = controller.settings( id ) {
					// Its own name and network name come back; the rest is the other deck's.
					var source          = other
					source.name         = settings.name
					source.hostname     = settings.hostname
					controller.copyDeck( from: source, to: deviceID, parts: Set( DeckCopyPart.allCases.filter { !$0.isOnDevice } ) )
					controller.restoreAfterReset( device: deviceID, from: source )
				}
			case nil:
				controller.config.settings.pendingRestores[deviceID] = nil
		}
	}
}
