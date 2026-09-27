//
//  UpdateManager.swift
//  ESPDeck Bridge
//
//  Checks GitHub Releases for new versions of the app (tags `bridge-vX.Y.Z`, a zipped
//  app) and the firmware (tags `firmware-vX.Y.Z`, see PROTOCOL.md), and installs them
//  according to each one's UpdatePolicy. The repository comes from Info.plist's
//  ESPDeckGitHubRepository (set in Config/Signing.xcconfig).
//

import CryptoKit
import Foundation
import Observation

struct Version: Comparable, CustomStringConvertible {
	let parts: [Int]

	/// "1.2.3", "v1.2.3" or "firmware-v1.2.3"; anything after a "-" in the version itself
	/// (like "-beta") is ignored.
	init?( _ string: String ) {
		let trimmed = string.split( separator: "v" ).last.map( String.init ) ?? string
		let core    = trimmed.split( separator: "-" ).first.map( String.init ) ?? trimmed
		let parts   = core.split( separator: "." ).compactMap { Int( $0 ) }
		guard !parts.isEmpty else { return nil }
		self.parts = parts
	}

	static func < ( lhs: Version, rhs: Version ) -> Bool {
		for index in 0..<max( lhs.parts.count, rhs.parts.count ) {
			let left  = index < lhs.parts.count ? lhs.parts[index] : 0
			let right = index < rhs.parts.count ? rhs.parts[index] : 0
			if left != right { return left < right }
		}
		return false
	}

	static func == ( lhs: Version, rhs: Version ) -> Bool { !( lhs < rhs ) && !( rhs < lhs ) }

	var description: String { parts.map( String.init ).joined( separator: "." ) }
}

struct UpdateRelease: Equatable {
	struct Asset: Equatable {
		var name   : String
		var url    : URL
		var size   : Int
		/// Lowercase hex, from GitHub's asset digest or a `<name>.sha256` asset.
		var sha256 : String?
	}

	var version   : Version
	var title     : String
	var notes     : String
	var page      : URL?
	var published : Date?
	var asset     : Asset
}

@Observable
final class UpdateManager {
	enum AppInstall: Equatable {
		case idle
		case downloading
		case installing
		case failed( String )
	}

	@ObservationIgnored private weak var controller: DeckController?

	private(set) var latestApp      : UpdateRelease?
	private(set) var latestFirmware : UpdateRelease?
	private(set) var checking       = false
	private(set) var checkError     : String?
	private(set) var appInstall     = AppInstall.idle

	@ObservationIgnored private var schedule      : Task<Void, Never>?
	@ObservationIgnored private var firmwareCache : [String: Data] = [:]

	private static let checkInterval: Duration     = .seconds( 6 * 3600 )
	private static let firmwareRetry: Duration     = .seconds( 10 * 60 )
	/// Automatic firmware updates wait until a deck has been left alone this long.
	private static let idleBeforeFirmware: TimeInterval = 5 * 60

	init( controller: DeckController ) {
		self.controller = controller
	}

	var repository: String? {
		let value = Bundle.main.object( forInfoDictionaryKey: "ESPDeckGitHubRepository" ) as? String ?? ""
		return value.contains( "/" ) && !value.contains( "$" ) ? value : nil
	}

	var currentAppVersion: String {
		Bundle.main.object( forInfoDictionaryKey: "CFBundleShortVersionString" ) as? String ?? "0"
	}

	var appUpdateAvailable: Bool {
		guard let latest = latestApp?.version, let current = Version( currentAppVersion ) else { return false }
		return current < latest
	}

	func firmwareUpdateAvailable( for device: DeckDevice ) -> Bool {
		guard let latest = latestFirmware?.version, let running = device.firmware.flatMap( Version.init ) else { return false }
		return running < latest
	}

	private var settings: UpdateSettings {
		get { controller?.config.settings.updates ?? UpdateSettings() }
		set { controller?.config.settings.updates = newValue }
	}

	var appPolicy: UpdatePolicy {
		get { settings.appPolicy }
		set { settings.appPolicy = newValue; reschedule() }
	}

	var firmwarePolicy: UpdatePolicy {
		get { settings.firmwarePolicy }
		set { settings.firmwarePolicy = newValue; reschedule() }
	}

	var lastCheck: Date? { settings.lastCheck }

	// MARK: - Scheduling

	func start() {
		reschedule()
	}

	/// Checks a minute after launch, then every few hours, unless both are manual.
	/// Automatic firmware installs are retried more often, since they wait for idle decks.
	private func reschedule() {
		schedule?.cancel()
		guard repository != nil, appPolicy != .manual || firmwarePolicy != .manual else { return }

		schedule = Task { [weak self] in
			try? await Task.sleep( for: .seconds( 60 ) )
			var sinceCheck = Duration.zero
			var first      = true
			while !Task.isCancelled, let self {
				if first || sinceCheck >= Self.checkInterval {
					await check( userInitiated: false )
					sinceCheck = .zero
					first      = false
				}
				installFirmwareWhereIdle()
				try? await Task.sleep( for: Self.firmwareRetry )
				sinceCheck += Self.firmwareRetry
			}
		}
	}

	// MARK: - Checking

	func check( userInitiated: Bool ) async {
		guard let repository else {
			checkError = "No GitHub repository is configured for updates."
			return
		}
		guard !checking else { return }
		checking   = true
		checkError = nil
		defer { checking = false }

		do {
			let releases   = try await fetchReleases( repository )
			latestApp      = releases.filter { $0.tag.hasPrefix( "bridge-v" ) }.compactMap( \.release ).max { $0.version < $1.version }
			latestFirmware = releases.filter { $0.tag.hasPrefix( "firmware-v" ) }.compactMap( \.release ).max { $0.version < $1.version }
			settings.lastCheck = Date()
		} catch {
			checkError = error is UpdateError ? error.localizedDescription : "Couldn't check for updates: \(error.localizedDescription)"
			return
		}

		if appUpdateAvailable && appPolicy == .automatic && !userInitiated {
			await installApp()
		}
		installFirmwareWhereIdle()
	}

	private struct GitHubRelease: Decodable {
		struct Asset: Decodable {
			var name                 : String
			var browser_download_url : URL
			var size                 : Int
			var digest               : String?
		}

		var tag_name     : String
		var name         : String?
		var body         : String?
		var html_url     : URL?
		var draft        : Bool
		var prerelease   : Bool
		var published_at : Date?
		var assets       : [Asset]

		var tag: String { tag_name }

		/// The release's installable asset: the zipped app, or the OTA firmware image.
		var release: UpdateRelease? {
			guard !draft, !prerelease, let version = Version( tag_name ) else { return nil }
			let isApp = tag_name.hasPrefix( "bridge-v" )
			let match = assets.first { asset in
				isApp ? asset.name.hasSuffix( ".zip" )
					  : asset.name.hasPrefix( "espdeck-firmware-" ) && asset.name.hasSuffix( ".bin" ) && !asset.name.hasSuffix( "-merged.bin" )
			}
			guard let match else { return nil }

			// GitHub's own digest if present, else a companion "<name>.sha256" asset (fetched later).
			let digest = match.digest.flatMap { $0.hasPrefix( "sha256:" ) ? String( $0.dropFirst( 7 ) ).lowercased() : nil }
			let asset  = UpdateRelease.Asset( name: match.name, url: match.browser_download_url, size: match.size, sha256: digest )
			var release = UpdateRelease( version: version, title: name ?? tag_name, notes: body ?? "", page: html_url, published: published_at, asset: asset )
			if digest == nil, let companion = assets.first( where: { $0.name == match.name + ".sha256" } ) {
				release.asset.sha256 = "url:" + companion.browser_download_url.absoluteString
			}
			return release
		}
	}

	private func fetchReleases( _ repository: String ) async throws -> [GitHubRelease] {
		guard let url = URL( string: "https://api.github.com/repos/\(repository)/releases?per_page=30" ) else { throw URLError( .badURL ) }
		var request = URLRequest( url: url )
		request.setValue( "application/vnd.github+json", forHTTPHeaderField: "Accept" )
		request.setValue( "ESPDeck-Bridge/\(currentAppVersion)", forHTTPHeaderField: "User-Agent" )

		let ( data, response ) = try await URLSession.shared.data( for: request )
		switch ( response as? HTTPURLResponse )?.statusCode {
			case 200:
				break
			case 404:
				// Also what GitHub answers for a private repository.
				throw UpdateError.repositoryNotFound( repository )
			case 403, 429:
				throw UpdateError.rateLimited
			default:
				throw URLError( .badServerResponse )
		}
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode( [GitHubRelease].self, from: data )
	}

	/// Downloads an asset and checks its SHA-256. Refuses assets without a published digest.
	private func download( _ asset: UpdateRelease.Asset ) async throws -> Data {
		guard var expected = asset.sha256 else { throw UpdateError.noDigest }
		if expected.hasPrefix( "url:" ), let url = URL( string: String( expected.dropFirst( 4 ) ) ) {
			let ( text, _ ) = try await URLSession.shared.data( from: url )
			expected = String( decoding: text, as: UTF8.self ).split( whereSeparator: \.isWhitespace ).first.map { String( $0 ).lowercased() } ?? ""
		}

		let ( data, response ) = try await URLSession.shared.data( from: asset.url )
		guard ( response as? HTTPURLResponse )?.statusCode == 200 else { throw URLError( .badServerResponse ) }
		guard Data( SHA256.hash( data: data ) ).hex == expected else { throw UpdateError.digestMismatch }
		return data
	}

	enum UpdateError: LocalizedError {
		case noDigest
		case digestMismatch
		case repositoryNotFound( String )
		case rateLimited

		var errorDescription: String? {
			switch self {
				case .noDigest:                    "The release doesn't publish a SHA-256 for its download."
				case .digestMismatch:              "The download didn't match the release's SHA-256."
				case .repositoryNotFound( let r ): "GitHub doesn't show \(r). Update checks need the repository to be public."
				case .rateLimited:                 "GitHub's rate limit was reached; the app will try again later."
			}
		}
	}

	// MARK: - App

	/// Downloads the new app and hands it to the AppKit bundle, which checks its code
	/// signature (same Team ID and bundle ID), swaps it in, and relaunches.
	func installApp() async {
		guard let release = latestApp, appUpdateAvailable else { return }
		guard let bridge = controller?.macBridge else {
			appInstall = .failed( "Updates install only on the Mac." )
			return
		}

		appInstall = .downloading
		do {
			let data    = try await download( release.asset )
			let archive = FileManager.default.temporaryDirectory.appending( path: release.asset.name )
			try data.write( to: archive, options: .atomic )
			appInstall = .installing
			if let message = bridge.installAppUpdate( archivePath: archive.path( percentEncoded: false ) ) {
				appInstall = .failed( message )
			}
			// On success the app quits and the new version launches.
		} catch {
			appInstall = .failed( error.localizedDescription )
		}
	}

	// MARK: - Firmware

	func installFirmware( on id: String ) async {
		guard let controller, let release = latestFirmware, let device = controller.device( id ) else { return }
		// Several things can start an update (the device connecting, an update check finishing,
		// the Install button), sometimes in the same moment. Only one may run; the progress is
		// set below before anything awaits, so a second request always sees the first.
		guard device.firmwareProgress?.isActive != true else { return }
		let version = release.version.description

		do {
			let image: Data
			if let cached = firmwareCache[version] {
				image = cached
			} else {
				device.firmwareProgress = FirmwareProgress( version: version, phase: .downloading )
				image = try await download( release.asset )
				firmwareCache[version] = image
			}
			controller.sendFirmware( device: id, image: image, version: version )
		} catch {
			device.firmwareProgress = FirmwareProgress( version: version, phase: .failed( error.localizedDescription ) )
		}
	}

	/// With automatic firmware updates, updates each connected deck that's asleep or has
	/// been left alone for a while.
	private func installFirmwareWhereIdle() {
		guard firmwarePolicy == .automatic, let controller else { return }
		for device in controller.devices where device.client != nil && firmwareUpdateAvailable( for: device ) {
			guard device.firmwareProgress?.isActive != true, !device.status.setupMode else { continue }
			let idle = device.status.asleep || Date().timeIntervalSince( device.lastKeyActivity ) > Self.idleBeforeFirmware
			if idle {
				Task { await installFirmware( on: device.id ) }
			}
		}
	}

	func deviceConnected( _ id: String ) {
		installFirmwareWhereIdle()
	}

	// MARK: - Status

	var statusItems: [DeckController.StatusItem] {
		var items: [DeckController.StatusItem] = []
		if appUpdateAvailable, let latest = latestApp {
			items.append( .init( text: "ESPDeck Bridge \(latest.version) is available", level: .waiting ) )
		}
		if let controller, let latest = latestFirmware {
			let count = controller.devices.filter { firmwareUpdateAvailable( for: $0 ) }.count
			if count > 0 {
				items.append( .init( text: "Firmware \(latest.version) is available for \(count == 1 ? "1 device" : "\(count) devices")", level: .waiting ) )
			}
		}
		return items
	}
}
