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
		let source  = sources.first { $0.id == sourceID } ?? sources.first
		let online  = controller.device( deviceID )?.isOnline == true

		NavigationStack {
			Form {
				Section {
					Picker( "Copy From", selection: Binding( get: { source?.id }, set: { sourceID = $0 } ) ) {
						ForEach( sources ) { deck in
							Text( Self.title( deck, controller: controller ) ).tag( Optional( deck.id ) )
						}
					}
				} footer: {
					Text( "Any deck ESPDeck Bridge knows, connected or not, most recently seen first." )
				}

				Section {
					ForEach( DeckCopyPart.allCases ) { part in
						Toggle( isOn: Binding( get: { parts.contains( part ) }, set: { on in
							if on { parts.insert( part ) } else { parts.remove( part ) }
						} ) ) {
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

/// Factory Reset, and what to give the deck once it's set up and paired again.
struct FactoryResetSheet: View {
	let controller : DeckController
	let deviceID   : String

	@Environment( \.dismiss ) private var dismiss
	/// "" for its own settings, nil for nothing, else another deck's ID.
	@State private var restore: String? = ""

	var body: some View {
		let settings = controller.settings( deviceID )
		let name     = settings?.name ?? "the device"

		NavigationStack {
			Form {
				Section {
					Text( "\(name) will erase its Wi-Fi settings, name, pairing, and stored key images, and restart in setup mode as if new. Set it up over USB or on its setup page, then pair it again here." )
				}
				Section {
					Picker( "Then Restore", selection: $restore ) {
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
				} footer: {
					switch restore {
						case "":
							Text( "Its keys stay in ESPDeck Bridge either way. Once it's paired again, it will get back its name, network name, display and sleep settings." )
						case nil:
							Text( "Its keys stay in ESPDeck Bridge. Its name, network name, display and sleep settings will start over." )
						default:
							Text( "Its keys, display, sleep and key press settings will become that deck's now; its display and sleep timer will go to it once it's paired again. Its own name and network name are kept here for it." )
					}
				}
			}
			.formStyle( .grouped )
			.navigationTitle( "Factory Reset \(name)" )
			.navigationBarTitleDisplayMode( .inline )
			.toolbar {
				ToolbarItem( placement: .cancellationAction ) {
					Button( "Cancel" ) { dismiss() }
				}
				ToolbarItem( placement: .confirmationAction ) {
					Button( "Factory Reset", role: .destructive ) {
						reset( settings )
						dismiss()
					}
				}
			}
		}
		.frame( minWidth: 440, idealWidth: 480, minHeight: 340, idealHeight: 380 )
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
