//
//  DeviceSettings.swift
//  ESPDeck Bridge
//
//  Persisted configuration: one DeviceSettings per ESP32, keyed by its MAC address.
//  The ESP32 owns its name, brightness, orientation and sleep timeout (the Mac mirrors
//  them from `hello` and edits them with commands); everything else lives here.
//

import Foundation

/// How key images are reoriented for the deck's panel. See PROTOCOL.md.
enum KeyTransform: String, Codable, CaseIterable, Identifiable {
	case none
	case transpose
	case rotate90
	case rotate270
	case rotate180

	var id: String { rawValue }

	var title: String {
		switch self {
			case .none:      "None"
			case .transpose: "Transpose"
			case .rotate90:  "Rotate 90° Clockwise"
			case .rotate270: "Rotate 90° Counterclockwise"
			case .rotate180: "Rotate 180°"
		}
	}
}

enum KeyImageFormat: String, Codable {
	case bmp
	case jpeg
	case none
}

/// A deck's key grid and image requirements, as reported by the ESP32.
struct DeckLayout: Codable, Equatable {
	var model     = "Stream Deck Mini"
	var rows      = 2
	var cols      = 3
	var keySize   = 80
	var format    = KeyImageFormat.bmp
	var transform = KeyTransform.transpose

	var keyCount: Int { rows * cols }

	/// Used for a device that has never reported a deck.
	static let mini = DeckLayout()

	/// Models offered for demo decks; the same values the firmware reports.
	static let presets: [DeckLayout] = [
		.mini,
		DeckLayout( model: "Stream Deck MK.2", rows: 3, cols: 5, keySize: 72, format: .jpeg, transform: .rotate180 ),
		DeckLayout( model: "Stream Deck XL", rows: 4, cols: 8, keySize: 96, format: .jpeg, transform: .rotate180 ),
		DeckLayout( model: "Stream Deck Neo", rows: 2, cols: 4, keySize: 96, format: .jpeg, transform: .rotate180 ),
		DeckLayout( model: "Stream Deck +", rows: 2, cols: 4, keySize: 120, format: .jpeg, transform: .none ),
		DeckLayout( model: "Stream Deck Pedal", rows: 1, cols: 3, keySize: 72, format: .none, transform: .none ),
	]
}

enum SleepEffect: String, Codable, CaseIterable, Identifiable {
	case wake
	case sleep

	var id: String { rawValue }
	var title: String { self == .sleep ? "Sleep" : "Wake" }
	var opposite: SleepEffect { self == .sleep ? .wake : .sleep }
}

/// "When <accessory> becomes <state>, <wake|sleep> the deck", and optionally the reverse
/// when it changes back.
struct SleepTrigger: Codable, Equatable, Identifiable {
	var id      = UUID()
	/// Only the target fields (kind, accessory, service) are used.
	var source  = KeyAssignment()
	var state   = KeyState.on
	var effect  = SleepEffect.wake
	/// Also do the opposite effect when the accessory reaches the opposite state.
	var reverse = false

	init() {}

	init( from decoder: Decoder ) throws {
		let container = try decoder.container( keyedBy: CodingKeys.self )
		id      = try container.decodeIfPresent( UUID.self, forKey: .id ) ?? UUID()
		source  = try container.decodeIfPresent( KeyAssignment.self, forKey: .source ) ?? KeyAssignment()
		state   = try container.decodeIfPresent( KeyState.self, forKey: .state ) ?? .on
		effect  = try container.decodeIfPresent( SleepEffect.self, forKey: .effect ) ?? .wake
		reverse = try container.decodeIfPresent( Bool.self, forKey: .reverse ) ?? false
	}
}

enum LabelPosition: String, Codable, CaseIterable, Identifiable {
	case top, bottom

	var id: String { rawValue }
	var title: String { self == .top ? "Top" : "Bottom" }
}

struct DeviceSettings: Codable, Equatable, Identifiable {
	/// Wi-Fi MAC address, e.g. "f4:12:fa:00:00:00".
	var id            : String
	var name          : String
	/// A virtual deck for configuring keys without hardware. Its `layout` is chosen
	/// by the user instead of reported.
	var isDemo        = false
	var keys          : [KeyAssignment] = []
	/// Last layout the device reported, so an offline device's keys still draw correctly.
	var layout        = DeckLayout.mini

	// Mirrored from the ESP32.
	var brightness    = 80
	var orientation   = "auto"
	var sleepTimeout  = 0

	/// Where every key's label goes. Drawn by the bridge, so it works offline too.
	var labelPosition = LabelPosition.bottom

	var sleepTriggers : [SleepTrigger] = []
	/// Run when the deck goes to sleep or wakes, however that happened.
	var onSleep       = KeyAssignment()
	var onWake        = KeyAssignment()

	init( id: String, name: String ) {
		self.id   = id
		self.name = name
	}

	init( from decoder: Decoder ) throws {
		let container = try decoder.container( keyedBy: CodingKeys.self )
		id            = try container.decode( String.self, forKey: .id )
		name          = try container.decode( String.self, forKey: .name )
		isDemo        = try container.decodeIfPresent( Bool.self, forKey: .isDemo ) ?? false
		keys          = try container.decodeIfPresent( [KeyAssignment].self, forKey: .keys ) ?? []
		layout        = try container.decodeIfPresent( DeckLayout.self, forKey: .layout ) ?? .mini
		brightness    = try container.decodeIfPresent( Int.self, forKey: .brightness ) ?? 80
		orientation   = try container.decodeIfPresent( String.self, forKey: .orientation ) ?? "auto"
		sleepTimeout  = try container.decodeIfPresent( Int.self, forKey: .sleepTimeout ) ?? 0
		labelPosition = try container.decodeIfPresent( LabelPosition.self, forKey: .labelPosition ) ?? .bottom
		sleepTriggers = try container.decodeIfPresent( [SleepTrigger].self, forKey: .sleepTriggers ) ?? []
		onSleep       = try container.decodeIfPresent( KeyAssignment.self, forKey: .onSleep ) ?? KeyAssignment()
		onWake        = try container.decodeIfPresent( KeyAssignment.self, forKey: .onWake ) ?? KeyAssignment()
	}

	/// The name the device calls itself until it's renamed: "ESPDeck 67E8", from the last two
	/// bytes of its MAC address.
	var defaultName: String {
		let bytes = id.split( separator: ":" ).suffix( 2 ).joined().uppercased()
		return bytes.isEmpty ? "ESPDeck" : "ESPDeck \(bytes)"
	}

	/// The key at `index`, or an empty one past the end of `keys`.
	func key( _ index: Int ) -> KeyAssignment {
		index < keys.count ? keys[index] : KeyAssignment()
	}

	/// Grows `keys` so `index` is valid.
	mutating func ensureKey( _ index: Int ) {
		while keys.count <= index { keys.append( KeyAssignment() ) }
	}
}

struct BridgeSettings: Codable, Equatable {
	/// The Home picked before the app covered every Home. Unused; kept so it round-trips.
	var homeID     : UUID?
	var devices    : [DeviceSettings] = []
	/// Keys from the single-deck version, given to the first device that connects.
	var legacyKeys : [KeyAssignment]?
	/// This bridge's identity in the Bonjour TXT record and in pairings.
	var bridgeID   = UUID().uuidString.lowercased()
	var updates    = UpdateSettings()
	/// USB Setup watches for boards plugged into the Mac.
	var usbScanning = true

	init() {}

	private enum CodingKeys: String, CodingKey {
		case homeID, devices, legacyKeys, bridgeID, updates, usbScanning
		case keys   // single-deck version
	}

	init( from decoder: Decoder ) throws {
		let container = try decoder.container( keyedBy: CodingKeys.self )
		homeID     = try container.decodeIfPresent( UUID.self, forKey: .homeID )
		devices    = try container.decodeIfPresent( [DeviceSettings].self, forKey: .devices ) ?? []
		bridgeID   = try container.decodeIfPresent( String.self, forKey: .bridgeID ) ?? UUID().uuidString.lowercased()
		updates    = try container.decodeIfPresent( UpdateSettings.self, forKey: .updates ) ?? UpdateSettings()
		usbScanning = try container.decodeIfPresent( Bool.self, forKey: .usbScanning ) ?? true
		legacyKeys = try container.decodeIfPresent( [KeyAssignment].self, forKey: .legacyKeys )
					 ?? container.decodeIfPresent( [KeyAssignment].self, forKey: .keys )
		if !devices.isEmpty { legacyKeys = nil }
	}

	func encode( to encoder: Encoder ) throws {
		var container = encoder.container( keyedBy: CodingKeys.self )
		try container.encodeIfPresent( homeID, forKey: .homeID )
		try container.encode( devices, forKey: .devices )
		try container.encodeIfPresent( legacyKeys, forKey: .legacyKeys )
		try container.encode( bridgeID, forKey: .bridgeID )
		try container.encode( updates, forKey: .updates )
		try container.encode( usbScanning, forKey: .usbScanning )
	}

	func deviceIndex( _ id: String ) -> Int? {
		devices.firstIndex { $0.id == id }
	}
}

enum UpdatePolicy: String, Codable, CaseIterable, Identifiable {
	case automatic
	case notify
	case manual

	var id: String { rawValue }

	var title: String {
		switch self {
			case .automatic: "Install Automatically"
			case .notify:    "Check Automatically, Ask to Install"
			case .manual:    "Check Manually"
		}
	}
}

struct UpdateSettings: Codable, Equatable {
	var firmwarePolicy = UpdatePolicy.notify
	var lastCheck      : Date?

	init() {}

	init( from decoder: Decoder ) throws {
		let container  = try decoder.container( keyedBy: CodingKeys.self )
		firmwarePolicy = try container.decodeIfPresent( UpdatePolicy.self, forKey: .firmwarePolicy ) ?? .notify
		lastCheck      = try container.decodeIfPresent( Date.self, forKey: .lastCheck )
	}
}
