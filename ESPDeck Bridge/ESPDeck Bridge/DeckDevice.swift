//
//  DeckDevice.swift
//  ESPDeck Bridge
//
//  Live state of one ESP32: its connection, what it reported, what each key shows, and
//  what the Mac knows about its image cache. Settings live in DeviceSettings.
//

import Observation
import UIKit

@Observable
final class DeckDevice: Identifiable {
	let id: String

	/// The WebSocket client, or nil while the device is offline.
	var client          : ClientID?
	var endpoint        : String?
	/// The protocol version its firmware speaks (hello's `protocol`).
	var protocolVersion : Int?
	var firmware        : String?
	/// Identifies the running build; see DeviceHello.elfSHA256.
	var firmwareBuild   : String?
	var ip              : String?
	var deck            = DeckInfo.disconnected
	var status          = DeviceStatus()

	/// What each key currently shows; the configuration UI draws these.
	var keys     : [RenderedKey?] = []
	var pressed  : Set<Int> = []

	/// The last page change: when, and what each key showed before it, so the Keys page's
	/// preview can pop the new page in a key at a time.
	var pageChange: ( at: Date, previews: [UIImage?] )?

	/// Seconds between keys as a new page pops in, in key order.
	static let pagePopStep: TimeInterval = 0.05

	/// Whether `key` still shows the old page of `pageChange` at `date`.
	func isWaitingForPageChange( key: Int, at date: Date = Date() ) -> Bool {
		guard let change = pageChange, key < change.previews.count else { return false }
		return date < change.at.addingTimeInterval( Double( key ) * Self.pagePopStep )
	}

	/// What each key shows in the Keys page right now: the old page's image for keys still
	/// waiting their turn after a page change.
	var displayedPreviews: [UIImage?] {
		keys.indices.map { key in
			isWaitingForPageChange( key: key ) ? pageChange?.previews[key] : keys[key]?.preview
		}
	}

	/// Set when another key goes down during a press, so chords (like the setup-mode
	/// corner hold) don't trigger key actions.
	@ObservationIgnored var chord        = false
	/// Hashes the ESP32 has cached, as far as we know. `need` corrects mistakes.
	@ObservationIgnored var knownHashes  : Set<String> = []
	/// Hash last sent in `show` for each key.
	@ObservationIgnored var shown        : [Int: String] = [:]
	/// Recently rendered images, so `need` can be answered without re-rendering.
	@ObservationIgnored var recentImages : [String: Data] = [:]
	@ObservationIgnored var recentOrder  : [String] = []
	@ObservationIgnored var pushTask     : Task<Void, Never>?
	/// Where it last authenticated from; kept while it's offline.
	@ObservationIgnored var lastAddress  : String?
	/// For automatic firmware updates, which wait for an idle deck.
	@ObservationIgnored var lastKeyActivity = Date.distantPast
	/// Keys whose press was part of a two-key hold: the device's report of it is ignored.
	@ObservationIgnored var suppressedPresses: Set<Int> = []
	/// The repeatKeys message last sent, so it's only sent when it changes.
	@ObservationIgnored var sentRepeatKeys: HostMessage?

	/// Frames sent and received, newest last, for the Log tab.
	var log          : [TrafficEntry] = []
	static let logLimit = 1000

	/// Keys sent a `show` the deck hasn't confirmed with `shown` yet, and how many keys the
	/// current batch of updates has had, for the progress bar under the simulated deck.
	var pendingShows : [Int: String] = [:]
	var batchTotal   = 0
	@ObservationIgnored var lastProgress = Date()
	@ObservationIgnored var pendingTimeout: Task<Void, Never>?

	/// A firmware update in progress, or the last one's failure.
	var firmwareProgress : FirmwareProgress?
	@ObservationIgnored var firmwareImage: Data?
	/// The end of the chunk sent last: the `received` the device must report next.
	@ObservationIgnored var firmwareChunkEnd: Int?

	var isOnline: Bool { client != nil }

	init( id: String ) {
		self.id = id
	}

	/// Forgets everything learned from a connection.
	func disconnected() {
		client      = nil
		endpoint    = nil
		deck        = .disconnected
		status      = DeviceStatus()
		pressed     = []
		chord       = false
		knownHashes = []
		shown       = [:]
		sentRepeatKeys = nil   // a new session starts with none
		clearPending()
	}

	func clearPending() {
		pendingShows = [:]
		batchTotal   = 0
		pendingTimeout?.cancel()
	}

	func record( _ entry: TrafficEntry ) {
		log.append( entry )
		if log.count > Self.logLimit {
			log.removeFirst( log.count - Self.logLimit )
		}
	}
}

struct FirmwareProgress: Equatable {
	enum Phase: Equatable {
		case downloading
		case sending( sent: Int, total: Int )
		case installing
		case restarting
		case failed( String )
	}

	var version : String
	/// The image's ELF SHA-256, to recognize it after the restart even when its version
	/// number is the one the device ran before (a development build).
	var build   : String?
	var phase   : Phase

	var isActive: Bool {
		if case .failed = phase { return false }
		return true
	}

	init( version: String, build: String? = nil, phase: Phase ) {
		self.version = version
		self.build   = build
		self.phase   = phase
	}

	/// Whether the device runs this image: by build when the device reports its build,
	/// by version otherwise.
	func isRunning( on device: DeckDevice ) -> Bool {
		if let build, let running = device.firmwareBuild {
			return build == running
		}
		return device.firmware == version
	}
}
