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

/// How the deck takes key images; `none` for a deck without displays (the Pedal).
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

extension DeckLayout {
	/// Field by field; anything missing or implausible is the Mini's.
	init( from decoder: Decoder ) throws {
		let container = try decoder.container( keyedBy: CodingKeys.self )
		let mini      = DeckLayout.mini
		model         = container.lenient( String.self, forKey: .model ) ?? mini.model
		rows          = container.lenient( Int.self, forKey: .rows ).flatMap { $0 > 0 ? $0 : nil } ?? mini.rows
		cols          = container.lenient( Int.self, forKey: .cols ).flatMap { $0 > 0 ? $0 : nil } ?? mini.cols
		keySize       = container.lenient( Int.self, forKey: .keySize ).flatMap { $0 > 0 ? $0 : nil } ?? mini.keySize
		format        = container.lenient( KeyImageFormat.self, forKey: .format ) ?? mini.format
		transform     = container.lenient( KeyTransform.self, forKey: .transform ) ?? mini.transform
	}
}

/// What a sleep trigger does to the deck.
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
		id      = container.lenient( UUID.self, forKey: .id ) ?? UUID()
		source  = container.lenient( KeyAssignment.self, forKey: .source ) ?? KeyAssignment()
		state   = container.lenient( KeyState.self, forKey: .state ) ?? .on
		effect  = container.lenient( SleepEffect.self, forKey: .effect ) ?? .wake
		reverse = container.lenient( Bool.self, forKey: .reverse ) ?? false
	}
}

/// Where a deck's key labels go.
enum LabelPosition: String, Codable, CaseIterable, Identifiable {
	case top, bottom

	var id: String { rawValue }
	var title: String { self == .top ? "Top" : "Bottom" }
}

/// Everything the Mac keeps about one device (see the file comment).
struct DeviceSettings: Codable, Equatable, Identifiable {
	/// Wi-Fi MAC address, e.g. "f4:12:fa:00:00:00".
	var id            : String
	var name          : String
	/// A virtual deck for configuring keys without hardware. Its `layout` is chosen
	/// by the user instead of reported.
	var isDemo        = false
	/// Every page of keys; there's always at least one. Stored on a grid `gridColumns` wide,
	/// at row × gridColumns + column, whatever deck is plugged in: a smaller deck shows the
	/// top-left corner and leaves the rest alone for a bigger one. `keys` is the current page
	/// as the deck (`layout`) numbers its keys.
	var pages         : [[KeyAssignment]] = [ [] ]
	/// The page the deck shows (and the Keys page edits).
	var currentPage   = 0
	/// Last layout the device reported, so an offline device's keys still draw correctly.
	var layout        = DeckLayout.mini

	// Mirrored from the ESP32.
	var brightness    = 80
	var orientation   = "auto"
	var sleepTimeout  = 0
	/// Uploads from PlatformIO were allowed when it was last connected.
	var devOTA        = false

	/// Where every key's label goes. Drawn by the bridge, so it works offline too.
	var labelPosition = LabelPosition.bottom

	/// Holding a slider key: how long before it starts repeating, and how often it repeats.
	var repeatDelay   = DeviceSettings.defaultRepeatDelay    // seconds
	var repeatRate    = DeviceSettings.defaultRepeatRate     // per second
	/// How quickly a second tap has to follow for a double tap, and how long a hold is.
	var doubleTapWindow = DeviceSettings.defaultDoubleTapWindow   // seconds
	var holdTime        = DeviceSettings.defaultHoldTime          // seconds
	static let defaultDoubleTapWindow = 0.3
	static let defaultHoldTime        = 0.5
	static let doubleTapWindowRange   = 0.15...1.0
	static let holdTimeRange          = 0.2...3.0
	static let defaultRepeatDelay = 0.5
	static let defaultRepeatRate  = 6.0
	static let repeatDelayRange   = 0.2...1.5
	static let repeatRateRange    = 2.0...20.0

	var sleepTriggers : [SleepTrigger] = []
	/// Run when the deck goes to sleep or wakes, however that happened.
	var onSleep       = KeyAssignment()
	var onWake        = KeyAssignment()

	/// Its name on the network when it isn't the original (defaultHostname), as it last
	/// reported; kept so it can be restored.
	var hostname      : String?
	/// When it last had a session with this bridge.
	var lastSeen      : Date?

	init( id: String, name: String ) {
		self.id   = id
		self.name = name
	}

	/// Field by field. Only the ID is required: without it the device is left out.
	init( from decoder: Decoder ) throws {
		let container = try decoder.container( keyedBy: CodingKeys.self )
		id            = try container.decode( String.self, forKey: .id )
		name          = container.lenient( String.self, forKey: .name ) ?? ""
		isDemo        = container.lenient( Bool.self, forKey: .isDemo ) ?? false
		layout        = container.lenient( DeckLayout.self, forKey: .layout ) ?? .mini
		// A key that can't be read becomes an empty one, so the others keep their places.
		// Before pages, the keys were one list; before the grid, pages were numbered as the
		// deck they were set up on numbers its keys (its last layout).
		if let decoded = try? container.decode( [LenientPage].self, forKey: .pages ), !decoded.isEmpty {
			pages = decoded.map( \.keys )
		} else {
			pages = [ container.lenientArray( of: KeyAssignment.self, forKey: .keys, placeholder: KeyAssignment() ) ?? [] ]
		}
		if container.lenient( Int.self, forKey: .gridColumns ) != Self.gridColumns {
			let old = layout
			pages = pages.map { Self.grid( fromDisplay: $0, layout: old ) }
		}
		currentPage   = min( max( container.lenient( Int.self, forKey: .currentPage ) ?? 0, 0 ), pages.count - 1 )
		brightness    = container.lenient( Int.self, forKey: .brightness ) ?? 80
		orientation   = container.lenient( String.self, forKey: .orientation ) ?? "auto"
		sleepTimeout  = container.lenient( Int.self, forKey: .sleepTimeout ) ?? 0
		devOTA        = container.lenient( Bool.self, forKey: .devOTA ) ?? false
		labelPosition = container.lenient( LabelPosition.self, forKey: .labelPosition ) ?? .bottom
		repeatDelay   = container.lenient( Double.self, forKey: .repeatDelay ) ?? Self.defaultRepeatDelay
		repeatRate    = container.lenient( Double.self, forKey: .repeatRate ) ?? Self.defaultRepeatRate
		doubleTapWindow = container.lenient( Double.self, forKey: .doubleTapWindow ) ?? Self.defaultDoubleTapWindow
		holdTime      = container.lenient( Double.self, forKey: .holdTime ) ?? Self.defaultHoldTime
		sleepTriggers = container.lenientArray( of: SleepTrigger.self, forKey: .sleepTriggers ) ?? []
		onSleep       = container.lenient( KeyAssignment.self, forKey: .onSleep ) ?? KeyAssignment()
		onWake        = container.lenient( KeyAssignment.self, forKey: .onWake ) ?? KeyAssignment()
		hostname      = container.lenient( String.self, forKey: .hostname )
		lastSeen      = container.lenient( Date.self, forKey: .lastSeen )
		if name.isEmpty { name = defaultName }
	}

	/// The device's original name on the network: "espdeck-67e8", from the last two bytes of
	/// its MAC address.
	var defaultHostname: String {
		let bytes = idSuffix.lowercased()
		return bytes.isEmpty ? "espdeck" : "espdeck-\(bytes)"
	}

	/// The last two bytes of the MAC address, as hex digits: "67e8".
	private var idSuffix: String {
		id.split( separator: ":" ).suffix( 2 ).joined()
	}

	/// A network name made from a device name: "Test Deck" becomes "test-deck". Lowercase
	/// letters, digits and single hyphens, at most 32; nil if nothing's left.
	static func hostname( from name: String ) -> String? {
		var result   = ""
		var hyphen   = false
		for scalar in name.lowercased().unicodeScalars {
			if ( "a"..."z" ).contains( scalar ) || ( "0"..."9" ).contains( scalar ) {
				if hyphen && !result.isEmpty { result += "-" }
				result.unicodeScalars.append( scalar )
				hyphen = false
			} else {
				hyphen = true
			}
		}
		let trimmed = String( result.prefix( 32 ) ).trimmingCharacters( in: CharacterSet( charactersIn: "-" ) )
		return trimmed.isEmpty ? nil : trimmed
	}

	/// The name the device calls itself until it's renamed: "ESPDeck 67E8", from the last two
	/// bytes of its MAC address.
	var defaultName: String {
		let bytes = idSuffix.uppercased()
		return bytes.isEmpty ? "ESPDeck" : "ESPDeck \(bytes)"
	}

	private enum CodingKeys: String, CodingKey {
		case id, name, isDemo, pages, gridColumns, currentPage, layout, brightness, orientation, sleepTimeout, devOTA, labelPosition
		case repeatDelay, repeatRate, doubleTapWindow, holdTime, sleepTriggers, onSleep, onWake
		case hostname, lastSeen
		case keys   // before pages
	}

	func encode( to encoder: Encoder ) throws {
		var container = encoder.container( keyedBy: CodingKeys.self )
		try container.encode( id, forKey: .id )
		try container.encode( name, forKey: .name )
		try container.encode( isDemo, forKey: .isDemo )
		try container.encode( pages.map( Self.trimmed ), forKey: .pages )
		try container.encode( Self.gridColumns, forKey: .gridColumns )
		try container.encode( currentPage, forKey: .currentPage )
		try container.encode( layout, forKey: .layout )
		try container.encode( brightness, forKey: .brightness )
		try container.encode( orientation, forKey: .orientation )
		try container.encode( sleepTimeout, forKey: .sleepTimeout )
		try container.encode( devOTA, forKey: .devOTA )
		try container.encode( labelPosition, forKey: .labelPosition )
		try container.encode( repeatDelay, forKey: .repeatDelay )
		try container.encode( repeatRate, forKey: .repeatRate )
		try container.encode( doubleTapWindow, forKey: .doubleTapWindow )
		try container.encode( holdTime, forKey: .holdTime )
		try container.encode( sleepTriggers, forKey: .sleepTriggers )
		try container.encode( onSleep, forKey: .onSleep )
		try container.encode( onWake, forKey: .onWake )
		try container.encodeIfPresent( hostname, forKey: .hostname )
		try container.encodeIfPresent( lastSeen, forKey: .lastSeen )
	}

	/// A page whose unreadable keys become empty ones (see lenientArray(of:forKey:placeholder:)).
	private struct LenientPage: Decodable {
		var keys: [KeyAssignment]
		init( from decoder: Decoder ) throws {
			var container = try decoder.unkeyedContainer()
			keys = container.lenientElements( of: KeyAssignment.self, placeholder: KeyAssignment() )
		}
	}

	/// The widest deck (the XL); a Stream Deck has at most 8 rows too.
	static let gridColumns = 8

	/// The current page's keys, numbered as `layout` numbers them. Setting it writes them back
	/// to their grid places and leaves keys the layout doesn't show alone.
	var keys: [KeyAssignment] {
		get { Self.display( pages[currentPage], layout: layout ) }
		set { pages[currentPage] = Self.store( newValue, into: pages[currentPage], layout: layout ) }
	}

	/// Where a key of `layout` lives on the grid.
	static func gridIndex( _ key: Int, layout: DeckLayout ) -> Int {
		let cols = max( layout.cols, 1 )
		return key / cols * gridColumns + key % cols
	}

	/// The key a grid place is on `layout`, if it shows it.
	static func displayIndex( _ grid: Int, layout: DeckLayout ) -> Int? {
		let row = grid / gridColumns, col = grid % gridColumns
		guard row < layout.rows, col < layout.cols else { return nil }
		return row * layout.cols + col
	}

	/// A Level key whose other key the layout doesn't show; it still steps on its own.
	static let offscreenPartner = Int.max

	/// A grid page as `layout` shows it. Level partners become key numbers too. A Next or
	/// Previous Page key the layout can't show appears in its lower-right or lower-left corner
	/// if that key is empty, so a smaller deck can still change page.
	static func display( _ page: [KeyAssignment], layout: DeckLayout ) -> [KeyAssignment] {
		func at( _ grid: Int ) -> KeyAssignment { grid < page.count ? page[grid] : KeyAssignment() }
		var keys = ( 0..<layout.keyCount ).map { key in
			var assignment = at( gridIndex( key, layout: layout ) )
			if let partner = assignment.slider?.partner {
				assignment.slider?.partner = displayIndex( partner, layout: layout ) ?? offscreenPartner
			}
			return assignment
		}
		for ( action, corner ) in [ ( KeyAction.nextPage, layout.keyCount - 1 ), ( KeyAction.previousPage, layout.keyCount - layout.cols ) ]
		where corner >= 0 && corner < keys.count && keys[corner].isEmpty && !keys.contains( where: { $0.kind == .page && $0.action == action } ) {
			if let hidden = page.indices.first( where: { page[$0].kind == .page && page[$0].action == action && displayIndex( $0, layout: layout ) == nil } ) {
				keys[corner] = page[hidden]
			}
		}
		return keys
	}

	/// Writes `keys` (numbered as `layout` numbers them) into their grid places in `page`.
	static func store( _ keys: [KeyAssignment], into page: [KeyAssignment], layout: DeckLayout ) -> [KeyAssignment] {
		var page  = page
		let shown = display( page, layout: layout )
		// Only keys that changed: an unchanged Next/Previous Page key standing in for a hidden
		// one stays where it is.
		for ( key, assignment ) in keys.enumerated() where key < layout.keyCount && assignment != shown[key] {
			let grid = gridIndex( key, layout: layout )
			while page.count <= grid { page.append( KeyAssignment() ) }
			var stored = assignment
			if let partner = assignment.slider?.partner {
				// A partner the layout doesn't show keeps the grid place it had.
				stored.slider?.partner = partner == offscreenPartner || partner >= layout.keyCount
					? page[grid].slider?.partner ?? offscreenPartner
					: gridIndex( partner, layout: layout )
			}
			page[grid] = stored
		}
		return page
	}

	/// A page numbered as `layout` numbers its keys, onto the grid (older settings files).
	static func grid( fromDisplay keys: [KeyAssignment], layout: DeckLayout ) -> [KeyAssignment] {
		var page: [KeyAssignment] = []
		for ( key, assignment ) in keys.enumerated() {
			let grid = gridIndex( key, layout: layout )
			while page.count <= grid { page.append( KeyAssignment() ) }
			var stored = assignment
			if let partner = assignment.slider?.partner {
				stored.slider?.partner = gridIndex( partner, layout: layout )
			}
			page[grid] = stored
		}
		return page
	}

	/// Without the empty keys at the end, for the file.
	private static func trimmed( _ page: [KeyAssignment] ) -> [KeyAssignment] {
		var page = page
		while let last = page.last, last.isEmpty { page.removeLast() }
		return page
	}

	/// Every page's keys, for what doesn't care about pages (icon files, HomeKit watching).
	var allKeys: [KeyAssignment] { pages.flatMap { $0 } }

	/// The key at `index`, or an empty one past the end of `keys`.
	func key( _ index: Int ) -> KeyAssignment {
		index < keys.count ? keys[index] : KeyAssignment()
	}

	/// Takes every page from `source`, and the page it shows.
	mutating func copyPages( from source: DeviceSettings ) {
		pages       = source.pages.isEmpty ? [ [] ] : source.pages
		currentPage = min( source.currentPage, max( source.pages.count - 1, 0 ) )
	}
}

/// Everything in Settings.json.
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
	/// The symbols last chosen for a pair of slider keys; new pairs start with them.
	var sliderStyle = SliderStyle.chevron
	/// Settings to give a device when it next connects (after a factory reset, or copied
	/// while it was offline), by device ID.
	var pendingRestores: [String: PendingRestore] = [:]

	init() {}

	private enum CodingKeys: String, CodingKey {
		case homeID, devices, legacyKeys, bridgeID, updates, usbScanning, sliderStyle, pendingRestores
		case keys   // single-deck version
	}

	/// Field by field; the single-deck version's keys become legacyKeys.
	init( from decoder: Decoder ) throws {
		let container = try decoder.container( keyedBy: CodingKeys.self )
		homeID      = container.lenient( UUID.self, forKey: .homeID )
		devices     = container.lenientArray( of: DeviceSettings.self, forKey: .devices ) ?? []
		bridgeID    = container.lenient( String.self, forKey: .bridgeID ).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
		updates     = container.lenient( UpdateSettings.self, forKey: .updates ) ?? UpdateSettings()
		usbScanning = container.lenient( Bool.self, forKey: .usbScanning ) ?? true
		sliderStyle = container.lenient( SliderStyle.self, forKey: .sliderStyle ) ?? .chevron
		pendingRestores = container.lenient( [String: PendingRestore].self, forKey: .pendingRestores ) ?? [:]
		legacyKeys  = container.lenientArray( of: KeyAssignment.self, forKey: .legacyKeys, placeholder: KeyAssignment() )
					  ?? container.lenientArray( of: KeyAssignment.self, forKey: .keys, placeholder: KeyAssignment() )
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
		try container.encode( sliderStyle, forKey: .sliderStyle )
		if !pendingRestores.isEmpty { try container.encode( pendingRestores, forKey: .pendingRestores ) }
	}

	/// Where a device is in `devices`.
	func deviceIndex( _ id: String ) -> Int? {
		devices.firstIndex { $0.id == id }
	}
}

/// How firmware updates are found and installed.
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

/// Update preferences, and when updates were last checked for.
struct UpdateSettings: Codable, Equatable {
	var firmwarePolicy = UpdatePolicy.notify
	var lastCheck      : Date?

	init() {}

	init( from decoder: Decoder ) throws {
		let container  = try decoder.container( keyedBy: CodingKeys.self )
		firmwarePolicy = container.lenient( UpdatePolicy.self, forKey: .firmwarePolicy ) ?? .notify
		lastCheck      = container.lenient( Date.self, forKey: .lastCheck )
	}
}
