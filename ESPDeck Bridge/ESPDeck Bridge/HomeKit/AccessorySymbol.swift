//
//  AccessorySymbol.swift
//  ESPDeck Bridge
//
//  An SF Symbol for an accessory, close to the icon the Home app shows. HomeKit doesn't give
//  apps the Home app's icons (or the one a user chose there), so this goes by what it does
//  give: the service type, the accessory's category and its name ("Nightstand", "Ceiling
//  Fan"). Only lights, outlets, switches and fans get one; garage doors, locks and sensors
//  keep their state symbols, which say more.
//

import HomeKit
import UIKit

extension HomeObserver {
	/// The accessory's symbol in `state`, or the kind's own when there isn't a better one.
	func symbol( for kind: KeyKind, accessoryID: UUID?, serviceID: UUID?, state: KeyState ) -> String {
		let fallback = kind.symbol( for: state )
		guard kind == .power || kind == .fan, let accessory = accessory( accessoryID ) else { return fallback }
		let service = accessory.services.first { $0.uniqueIdentifier == serviceID }
		guard let base = Self.baseSymbol( kind: kind, accessory: accessory, service: service ) else { return fallback }
		guard UIImage( systemName: base ) != nil else { return fallback }
		return SymbolCounterpart.variant( of: base, for: state == .on ? .on : .off )
	}

	/// For Off; `symbol(for:…)` makes it On's (lamp.table.fill, lightswitch.on).
	private static func baseSymbol( kind: KeyKind, accessory: HMAccessory, service: HMService? ) -> String? {
		let name     = [ service?.name, accessory.name ].compactMap { $0 }.joined( separator: " " ).lowercased()
		let has      = { ( words: [String] ) in words.contains { name.contains( $0 ) } }
		let type     = service?.serviceType
		let category = accessory.category.categoryType

		if kind == .fan || type == HMServiceTypeFan || category == HMAccessoryCategoryTypeFan {
			if has( [ "ceiling" ] ) { return "fan.ceiling" }
			if has( [ "desk", "table" ] ) { return "fan.desk" }
			if has( [ "floor", "tower", "stand" ] ) { return "fan.floor" }
			return kind == .fan || type == HMServiceTypeFan ? "fan" : nil
		}
		if type == HMServiceTypeAirPurifier || category == HMAccessoryCategoryTypeAirPurifier { return "air.purifier" }
		if category == HMAccessoryCategoryTypeAirHumidifier || category == HMAccessoryCategoryTypeAirDehumidifier { return "humidifier" }
		if type == HMServiceTypeOutlet || category == HMAccessoryCategoryTypeOutlet { return "poweroutlet.type.b" }

		// Lights, and switches named for what they light.
		let light = type == HMServiceTypeLightbulb || category == HMAccessoryCategoryTypeLightbulb
		if light || has( [ "lamp", "light" ] ) {
			if has( [ "chandelier" ] ) { return "chandelier" }
			if has( [ "strip", "led", "tape" ] ) { return "light.strip.2" }
			if has( [ "recessed", "can light", "downlight", "pot light" ] ) { return "light.recessed" }
			if has( [ "ceiling", "pendant", "overhead" ] ) { return "lamp.ceiling" }
			if has( [ "floor" ] ) { return "lamp.floor" }
			if has( [ "desk" ] ) { return "lamp.desk" }
			if has( [ "lamp", "nightstand", "bedside", "table" ] ) { return "lamp.table" }
			if light { return "lightbulb" }
		}
		if type == HMServiceTypeSwitch || category == HMAccessoryCategoryTypeSwitch || category == HMAccessoryCategoryTypeProgrammableSwitch {
			return "lightswitch.off"
		}
		return nil
	}
}
