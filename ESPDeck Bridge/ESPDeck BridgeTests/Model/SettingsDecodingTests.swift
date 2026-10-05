//
//  SettingsDecodingTests.swift
//  ESPDeck BridgeTests
//
//  Settings.json holds every deck's keys. A field this version can't read must cost that
//  field and nothing else, and what's written must read back the same.
//

import Foundation
import Testing
@testable import ESPDeck_Bridge

/// Reading and writing Settings.json.
struct SettingsDecodingTests {
	/// Decodes `json` as the bridge's settings.
	private func settings( _ json: String ) throws -> BridgeSettings {
		try JSONDecoder().decode( BridgeSettings.self, from: Data( json.utf8 ) )
	}

	/// What's saved reads back the same.
	@Test func roundTripsThroughJSON() throws {
		var device = DeviceSettings( id: "f4:12:fa:00:00:01", name: "Garage" )
		device.brightness    = 55
		device.labelPosition = .top
		device.hostname      = "garage-deck"
		var original = BridgeSettings()
		original.devices     = [ device ]
		original.usbScanning = false

		let decoded = try JSONDecoder().decode( BridgeSettings.self, from: JSONEncoder().encode( original ) )
		#expect( decoded == original )
	}

	/// Fields that can't be read fall back to their defaults; the deck and the rest of the
	/// file survive.
	@Test func keepsADeckWhoseFieldsCannotBeRead() throws {
		let decoded = try settings( """
			{ "bridgeID": "abc",
			  "usbScanning": "yes",
			  "devices": [ { "id": "aa:bb", "name": "Office", "labelPosition": "sideways", "brightness": "bright" } ] }
			""" )
		let device = try #require( decoded.devices.first )
		#expect( decoded.bridgeID == "abc" )
		#expect( decoded.usbScanning, "an unreadable value falls back to the default, on" )
		#expect( device.name == "Office" )
		#expect( device.labelPosition == .bottom )
		#expect( device.brightness == 80 )
		#expect( device.pages.count == 1, "a deck always has at least one page" )
	}

	/// An entry that isn't a deck is dropped without taking its neighbors with it.
	@Test func skipsEntriesThatAreNotDecks() throws {
		let decoded = try settings( """
			{ "devices": [ 42, { "id": "aa:bb", "name": "Office" }, "junk", { "id": "cc:dd", "name": "Garage" } ] }
			""" )
		#expect( decoded.devices.map( \.name ) == [ "Office", "Garage" ] )
	}

	/// The single-deck version's keys wait for the first deck to connect.
	@Test func keepsKeysFromTheSingleDeckVersion() throws {
		let decoded = try settings( #"{ "keys": [ {}, {}, {} ] }"# )
		#expect( decoded.devices.isEmpty )
		#expect( decoded.legacyKeys?.count == 3 )
	}

	/// An empty file is a fresh start with an identity of its own.
	@Test func startsFreshFromAnEmptyFile() throws {
		let decoded = try settings( "{}" )
		#expect( decoded.devices.isEmpty )
		#expect( decoded.bridgeID.isEmpty == false )
	}
}
