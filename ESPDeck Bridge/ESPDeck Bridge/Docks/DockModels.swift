//
//  DockModels.swift
//  ESPDeck Bridge
//
//  The Stream Decks a Network Dock can drive from here. An ESP32 reports its deck's layout
//  from its own table (DeckKit's, in the firmware); for a dock, the Mac needs one too. This
//  is the same table's models whose images go out as JPEG in 1 KB reports with an 8-byte
//  header. The Mini and the original Stream Deck use older reports, and aren't supported on
//  a dock yet.
//

import Foundation

/// A Stream Deck model ESPDeck Bridge can drive through a Network Dock.
struct DockModel {
	let productID : UInt16
	let name      : String
	let rows      : Int
	let cols      : Int
	/// Image size in pixels; 0 for the Pedal, which has no displays.
	let keySize   : Int
	/// How its key images are turned, as DeckKit has it.
	let transform : KeyTransform

	var format: KeyImageFormat { keySize == 0 ? .none : .jpeg }

	static let all: [DockModel] = [
		DockModel( productID: 0x006D, name: "Stream Deck (Original V2)",            rows: 3, cols: 5, keySize: 72,  transform: .rotate180 ),
		DockModel( productID: 0x0080, name: "Stream Deck MK.2",                     rows: 3, cols: 5, keySize: 72,  transform: .rotate180 ),
		DockModel( productID: 0x00A5, name: "Stream Deck MK.2 Scissor",             rows: 3, cols: 5, keySize: 72,  transform: .rotate180 ),
		DockModel( productID: 0x00B9, name: "Stream Deck 15-Key Module",            rows: 3, cols: 5, keySize: 72,  transform: .rotate180 ),
		DockModel( productID: 0x00E4, name: "Stream Deck 15-Key Module (Scissor)",  rows: 3, cols: 5, keySize: 72,  transform: .rotate180 ),
		DockModel( productID: 0x006C, name: "Stream Deck XL",                       rows: 4, cols: 8, keySize: 96,  transform: .rotate180 ),
		DockModel( productID: 0x008F, name: "Stream Deck XL V2",                    rows: 4, cols: 8, keySize: 96,  transform: .rotate180 ),
		DockModel( productID: 0x00BA, name: "Stream Deck 32-Key Module",            rows: 4, cols: 8, keySize: 96,  transform: .rotate180 ),
		DockModel( productID: 0x009A, name: "Stream Deck Neo",                      rows: 2, cols: 4, keySize: 96,  transform: .rotate180 ),
		DockModel( productID: 0x0084, name: "Stream Deck +",                        rows: 2, cols: 4, keySize: 120, transform: .none ),
		DockModel( productID: 0x0086, name: "Stream Deck Pedal",                    rows: 1, cols: 3, keySize: 0,   transform: .none ),
	]

	/// The model with this USB product ID, if a dock can drive it from here.
	static func model( productID: UInt16 ) -> DockModel? {
		all.first { $0.productID == productID }
	}
}
