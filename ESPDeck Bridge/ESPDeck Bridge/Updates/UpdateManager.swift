//
//  UpdateManager.swift
//  ESPDeck Bridge
//
//  Checks GitHub Releases for new firmware (tags `firmware-vX.Y.Z`, see PROTOCOL.md) and
//  installs it according to the firmware UpdatePolicy. The repository comes from
//  Info.plist's ESPDeckGitHubRepository (set in Config/Signing.xcconfig). Only releases
//  signed with the firmware key are offered, and every download is checked against its
//  signature (FirmwareSignature) before it's installed. The app itself is updated by the
//  App Store.
//

import CryptoKit
import Foundation
import Observation

/// A signed firmware release on GitHub, and the files to download from it.
struct UpdateRelease: Equatable {
	/// A file of the release.
	struct Asset: Equatable {
		var name      : String
		var url       : URL
		var size      : Int
		/// Lowercase hex, from GitHub's asset digest or a `<name>.sha256` asset.
		var sha256    : String?
		/// The `<name>.sig` asset: its Ed25519 signature (FirmwareSignature).
		var signature : URL?
	}

	var version   : Version
	/// The OTA image, for updates over Wi-Fi.
	var asset     : Asset
	/// For firmware, the full flash image (`-merged.bin`) for installing over USB.
	var fullImage : Asset?
}

/// Firmware updates: checking GitHub, downloading, and installing on the decks.
@Observable
final class UpdateManager {
	@ObservationIgnored private weak var controller: DeckController?

	private(set) var latestFirmware   : UpdateRelease?
	/// A release newer than latestFirmware that isn't signed, so it isn't offered.
	private(set) var unsignedFirmware : Version?
	private(set) var checking         = false
	private(set) var checkError       : String?

	@ObservationIgnored private var schedule      : Task<Void, Never>?
	@ObservationIgnored private var firmwareCache : [String: Data] = [:]
	/// The development image last installed from a file on each device, so Retry sends it
	/// again rather than the latest release.
	@ObservationIgnored private var localImages   : [String: ( image: Data, info: FirmwareImage.AppInfo )] = [:]

	private static let firstCheckDelay: Duration   = .seconds( 60 )
	private static let checkInterval: Duration     = .seconds( 6 * 3600 )
	private static let firmwareRetry: Duration     = .seconds( 10 * 60 )
	/// Automatic firmware updates wait until a deck has been left alone this long.
	private static let idleBeforeFirmware: TimeInterval = 5 * 60

	init( controller: DeckController ) {
		self.controller = controller
	}

	/// "owner/name" from Info.plist; nil when the build doesn't set one.
	var repository: String? {
		let value = Bundle.main.object( forInfoDictionaryKey: "ESPDeckGitHubRepository" ) as? String ?? ""
		return value.contains( "/" ) && !value.contains( "$" ) ? value : nil
	}

	/// The app's own version, for the User-Agent and exports.
	var currentAppVersion: String {
		Bundle.main.object( forInfoDictionaryKey: "CFBundleShortVersionString" ) as? String ?? "0"
	}

	/// Whether the latest release is newer than what the device runs.
	func firmwareUpdateAvailable( for device: DeckDevice ) -> Bool {
		guard let latest = latestFirmware?.version, let running = device.firmware.flatMap( Version.init ) else { return false }
		return running < latest
	}

	/// Update preferences, kept in the bridge's settings.
	private var settings: UpdateSettings {
		get { controller?.config.settings.updates ?? UpdateSettings() }
		set { controller?.config.settings.updates = newValue }
	}

	/// How firmware updates happen; changing it reschedules the checks.
	var firmwarePolicy: UpdatePolicy {
		get { settings.firmwarePolicy }
		set {
			settings.firmwarePolicy = newValue
			reschedule()
		}
	}

	/// When updates were last checked for.
	var lastCheck: Date? { settings.lastCheck }

	// MARK: - Scheduling

	/// Starts the periodic checks, at launch.
	func start() {
		reschedule()
	}

	/// Checks a minute after launch, then every few hours, unless updates are manual.
	/// Automatic firmware installs are retried more often, since they wait for idle decks.
	private func reschedule() {
		schedule?.cancel()
		guard repository != nil, firmwarePolicy != .manual else { return }

		schedule = Task { [weak self] in
			try? await Task.sleep( for: Self.firstCheckDelay )
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

	/// Finds the latest signed release (and a newer unsigned one), then installs it where
	/// automatic updates allow. `userInitiated` isn't used.
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
			let releases     = try await fetchReleases( repository ).filter { $0.tag.hasPrefix( "firmware-v" ) }
			latestFirmware   = releases.compactMap( \.release ).max { $0.version < $1.version }
			// The newest unsigned release, when it's newer than every signed one: the Updates
			// page explains why it isn't offered.
			let unsigned     = releases.filter { $0.release == nil }.compactMap( \.unsignedVersion ).max()
			unsignedFirmware = unsigned.flatMap { version in latestFirmware.map( { $0.version < version } ) ?? true ? version : nil }
			settings.lastCheck = Date()
		} catch {
			checkError = error is UpdateError ? error.localizedDescription : "Couldn't check for updates: \(error.localizedDescription)"
			return
		}

		installFirmwareWhereIdle()
	}

	/// A release as GitHub's API lists it; only the fields used here.
	private struct GitHubRelease: Decodable {
		struct Asset: Decodable {
			var name                 : String
			var browser_download_url : URL
			var size                 : Int
			var digest               : String?
		}

		var tag_name     : String
		var draft        : Bool
		var prerelease   : Bool
		var assets       : [Asset]

		var tag: String { tag_name }

		/// The release's OTA firmware image, and its full image for USB. Nil for a release
		/// without a signature for its OTA image (all before 4.1.0).
		var release: UpdateRelease? {
			guard !draft, !prerelease, let version = Version( tag_name ), let match = otaImage, signature( of: match ) != nil else { return nil }

			var release = UpdateRelease( version: version, asset: asset( match ) )
			if let merged = assets.first( where: { $0.name.hasPrefix( "espdeck-firmware-" ) && $0.name.hasSuffix( "-merged.bin" ) } ) {
				release.fullImage = asset( merged )
			}
			return release
		}

		/// A published firmware release that has no signature, so it isn't offered.
		var unsignedVersion: Version? {
			guard !draft, !prerelease, otaImage != nil else { return nil }
			return Version( tag_name )
		}

		/// The OTA image: espdeck-firmware-….bin, but not the -merged.bin full image.
		private var otaImage: Asset? {
			assets.first { asset in
				asset.name.hasPrefix( "espdeck-firmware-" ) && asset.name.hasSuffix( ".bin" ) && !asset.name.hasSuffix( "-merged.bin" )
			}
		}

		/// Where the asset's "<name>.sig" is, if the release has one.
		private func signature( of match: Asset ) -> URL? {
			assets.first( where: { $0.name == match.name + FirmwareSignature.fileSuffix } )?.browser_download_url
		}

		/// GitHub's own digest if present, else a companion "<name>.sha256" asset (fetched
		/// later), and the companion "<name>.sig".
		private func asset( _ match: Asset ) -> UpdateRelease.Asset {
			let digest = match.digest.flatMap { $0.hasPrefix( "sha256:" ) ? String( $0.dropFirst( 7 ) ).lowercased() : nil }
			var asset  = UpdateRelease.Asset( name: match.name, url: match.browser_download_url, size: match.size, sha256: digest,
											  signature: signature( of: match ) )
			if digest == nil, let companion = assets.first( where: { $0.name == match.name + ".sha256" } ) {
				asset.sha256 = "url:" + companion.browser_download_url.absoluteString
			}
			return asset
		}
	}

	/// The repository's latest releases, from GitHub's API.
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
		return try JSONDecoder().decode( [GitHubRelease].self, from: data )
	}

	/// Larger than any firmware image, full or OTA, can be: the app partition is smaller.
	static let maximumFirmwareSize = 8 * 1024 * 1024

	/// Downloads an asset and checks its size, SHA-256 and signature. Refuses assets without
	/// a published digest or signature.
	private func download( _ asset: UpdateRelease.Asset ) async throws -> Data {
		guard var expected = asset.sha256 else { throw UpdateError.noDigest }
		guard let signatureURL = asset.signature else { throw UpdateError.noSignature }
		guard asset.size > 0, asset.size <= Self.maximumFirmwareSize else { throw UpdateError.badSize }
		if expected.hasPrefix( "url:" ) {
			guard let url = URL( string: String( expected.dropFirst( 4 ) ) ) else { throw UpdateError.noDigest }
			let ( text, response ) = try await URLSession.shared.data( from: url )
			guard ( response as? HTTPURLResponse )?.statusCode == 200 else { throw UpdateError.digestUnavailable }
			expected = String( decoding: text, as: UTF8.self ).split( whereSeparator: \.isWhitespace ).first.map { String( $0 ).lowercased() } ?? ""
		}
		guard expected.count == 64, expected.allSatisfy( \.isHexDigit ) else { throw UpdateError.digestUnavailable }

		let ( data, response ) = try await URLSession.shared.data( from: asset.url )
		guard ( response as? HTTPURLResponse )?.statusCode == 200 else { throw URLError( .badServerResponse ) }
		guard data.count == asset.size else { throw UpdateError.badSize }
		guard Data( SHA256.hash( data: data ) ).hex == expected else { throw UpdateError.digestMismatch }

		// The signature covers exactly the bytes that get installed.
		let ( signature, signatureResponse ) = try await URLSession.shared.data( from: signatureURL )
		guard ( signatureResponse as? HTTPURLResponse )?.statusCode == 200 else { throw UpdateError.signatureUnavailable }
		guard FirmwareSignature.isValid( signature, for: data ) else { throw UpdateError.badSignature }
		return data
	}

	/// Why checking, downloading or verifying failed.
	enum UpdateError: LocalizedError {
		case noDigest
		case digestUnavailable
		case digestMismatch
		case noSignature
		case signatureUnavailable
		case badSignature
		case badSize
		case repositoryNotFound( String )
		case rateLimited
		case noFullImage
		case noRelease( String? )

		var errorDescription: String? {
			switch self {
				case .noDigest:                    "The release doesn't publish a SHA-256 for its download."
				case .digestUnavailable:           "Couldn't get the SHA-256 the release publishes for its download."
				case .digestMismatch:              "The download didn't match the release's SHA-256."
				case .noSignature:                 "The release isn't signed, so ESPDeck Bridge won't install it. Releases are signed from \(FirmwareSignature.firstSignedRelease) on."
				case .signatureUnavailable:        "Couldn't get the release's signature."
				case .badSignature:                "The download isn't signed by ESPDeck's release key, so it wasn't installed."
				case .badSize:                     "The download isn't the size the release lists, or is too large to be firmware."
				case .repositoryNotFound( let r ): "GitHub doesn't show \(r). Update checks need the repository to be public."
				case .rateLimited:                 "GitHub's rate limit was reached; the app will try again later."
				case .noFullImage:                 "The latest firmware release has no full image for installing over USB."
				case .noRelease( let problem ):    problem ?? "GitHub doesn't list a signed firmware release (\(FirmwareSignature.firstSignedRelease) or later)."
			}
		}
	}

	// MARK: - Firmware

	/// Downloads (once) and sends the latest release to the device, unless it's updating.
	func installFirmware( on id: String ) async {
		guard let controller, let release = latestFirmware, let device = controller.device( id ) else { return }
		// Several things can start an update (the device connecting, an update check finishing,
		// the Install button), sometimes in the same moment. Only one may run; the progress is
		// set below before anything awaits, so a second request always sees the first.
		guard device.firmwareProgress?.isActive != true else { return }
		let version = release.version.description
		localImages[id] = nil

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

	/// A development image from a file, checked by FirmwareImage to be ESPDeck's.
	func installLocalFirmware( on id: String, image: Data, info: FirmwareImage.AppInfo ) {
		guard let controller, controller.device( id )?.firmwareProgress?.isActive != true else { return }
		localImages[id] = ( image, info )
		controller.sendLocalFirmware( device: id, image: image, info: info )
	}

	/// After a failed install: the same file again if that's what failed, else the latest
	/// release.
	func retryFirmware( on id: String ) async {
		if let local = localImages[id], let progress = controller?.device( id )?.firmwareProgress, progress.build == local.info.elfSHA256 {
			installLocalFirmware( on: id, image: local.image, info: local.info )
		} else {
			await installFirmware( on: id )
		}
	}

	/// The latest release's full flash image, for installing over USB, checked against its
	/// published SHA-256 and signature. Checks for updates first if that hasn't happened yet.
	func downloadFullFirmware() async throws -> ( image: Data, version: String ) {
		if latestFirmware == nil {
			await check( userInitiated: true )
		}
		guard let release = latestFirmware else { throw UpdateError.noRelease( checkError ) }
		guard let asset = release.fullImage else { throw UpdateError.noFullImage }
		return ( try await download( asset ), release.version.description )
	}

	/// With automatic firmware updates, updates each connected deck that's asleep or has
	/// been left alone for a while.
	private func installFirmwareWhereIdle() {
		guard firmwarePolicy == .automatic, let controller else { return }
		for device in controller.devices where device.isOnline && firmwareUpdateAvailable( for: device ) {
			guard device.firmwareProgress?.isActive != true, !device.status.setupMode else { continue }
			let idle = device.status.asleep || Date().timeIntervalSince( device.lastKeyActivity ) > Self.idleBeforeFirmware
			if idle {
				Task { await installFirmware( on: device.id ) }
			}
		}
	}

	/// A deck connected: it may be due an automatic update.
	func deviceConnected() {
		installFirmwareWhereIdle()
	}

	// MARK: - Status

	/// The menu bar's line about available firmware, if there is any.
	var statusItems: [DeckController.StatusItem] {
		var items: [DeckController.StatusItem] = []
		if let controller, let latest = latestFirmware {
			let count = controller.devices.filter { firmwareUpdateAvailable( for: $0 ) }.count
			if count > 0 {
				items.append( .init( text: "Firmware \(latest.version) is available for \(count == 1 ? "1 device" : "\(count) devices")", level: .waiting ) )
			}
		}
		return items
	}
}
