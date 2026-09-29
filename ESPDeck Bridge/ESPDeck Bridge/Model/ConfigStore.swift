//
//  ConfigStore.swift
//  ESPDeck Bridge
//
//  Persists BridgeSettings as JSON and the user's source icons as PNG files, both in
//  Application Support: inside the app's container, since the app is sandboxed.
//

import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

@Observable
final class ConfigStore {
	var settings: BridgeSettings {
		didSet {
			if settings != oldValue { scheduleSave() }
		}
	}

	/// Set when Settings.json couldn't be read at launch and was set aside under this name.
	private(set) var unreadableSettings: String?

	@ObservationIgnored private let directory     : URL
	@ObservationIgnored private let iconDirectory : URL
	@ObservationIgnored private var iconCache     : [String: UIImage] = [:]
	@ObservationIgnored private let shortcutIconDirectory : URL
	@ObservationIgnored private var pendingSave   : Task<Void, Never>?
	@ObservationIgnored private var observers     : [NSObjectProtocol] = []

	private var settingsURL: URL { directory.appending( path: "Settings.json" ) }

	/// Icons are downscaled to this many pixels on their longest side when imported.
	nonisolated static let iconImportSize = 240
	/// Dropped images larger than this aren't read.
	nonisolated static let iconFileLimit  = 20 * 1024 * 1024

	/// Changes within this long of each other are saved together.
	private static let saveDelay: Duration = .milliseconds( 500 )
	/// Writes happen here, in order, off the main thread.
	private static let writer = DispatchQueue( label: "com.tmproductions.espdeck.settings", qos: .utility )

	init() {
		let support   = URL.applicationSupportDirectory.appending( path: "ESPDeck Bridge", directoryHint: .isDirectory )
		directory     = support
		iconDirectory = support.appending( path: "Icons", directoryHint: .isDirectory )
		shortcutIconDirectory = support.appending( path: "Shortcut Icons", directoryHint: .isDirectory )
		try? FileManager.default.createDirectory( at: iconDirectory, withIntermediateDirectories: true )
		try? FileManager.default.createDirectory( at: shortcutIconDirectory, withIntermediateDirectories: true )

		let url      = support.appending( path: "Settings.json" )
		var loaded   : BridgeSettings?
		var fileID   : String?
		var setAside : String?
		if FileManager.default.fileExists( atPath: url.path( percentEncoded: false ) ) {
			do {
				let data = try Data( contentsOf: url )
				loaded   = try JSONDecoder().decode( BridgeSettings.self, from: data )
				fileID   = ( ( try? JSONSerialization.jsonObject( with: data ) ) as? [String: Any] )?["bridgeID"] as? String
			} catch {
				// Kept for the user (or a later version) rather than overwritten by the fresh start.
				print( "[ConfigStore] Settings.json couldn't be read: \(error)" )
				setAside = Self.setAside( url )
			}
		}
		settings           = loaded ?? BridgeSettings()
		unreadableSettings = setAside

		// The bridge ID survives settings that had to start over.
		if fileID == nil || fileID?.isEmpty == true, let stored = BridgeIdentity.stored( fileIn: support ) {
			settings.bridgeID = stored
		}
		BridgeIdentity.store( settings.bridgeID, fileIn: support )

		// Quitting, or on iPad being suspended, must not lose a change still waiting to be saved.
		let names = [ UIApplication.willTerminateNotification, UIApplication.didEnterBackgroundNotification ]
		observers = names.map { name in
			NotificationCenter.default.addObserver( forName: name, object: nil, queue: .main ) { [weak self] _ in
				MainActor.assumeIsolated { self?.saveNow( waiting: true ) }
			}
		}
		// A fresh start, or an ID that came from the Keychain, is written out.
		if loaded == nil || fileID != settings.bridgeID {
			scheduleSave()
		}
	}

	/// Moves an unreadable Settings.json to Settings.unreadable-<date>.json; returns that name.
	private static func setAside( _ url: URL ) -> String? {
		let stamp = Date().formatted( .iso8601.year().month().day().time( includingFractionalSeconds: false ).timeSeparator( .omitted ) )
		let name  = "Settings.unreadable-\(stamp).json"
		do {
			try FileManager.default.moveItem( at: url, to: url.deletingLastPathComponent().appending( path: name ) )
			return name
		} catch {
			print( "[ConfigStore] Couldn't set the unreadable settings aside: \(error)" )
			return nil
		}
	}

	private func scheduleSave() {
		pendingSave?.cancel()
		pendingSave = Task { [weak self] in
			try? await Task.sleep( for: Self.saveDelay )
			guard !Task.isCancelled else { return }
			self?.saveNow( waiting: false )
		}
	}

	/// Writes the settings if a save is pending; `waiting` returns only once they're on disk.
	func saveNow( waiting: Bool ) {
		guard let pending = pendingSave else { return }
		pending.cancel()
		pendingSave = nil

		let data: Data
		do {
			data = try settingsData()
		} catch {
			print( "[ConfigStore] Failed to encode settings: \(error)" )
			return
		}
		let url = settingsURL
		Self.writer.async {
			do {
				try data.write( to: url, options: .atomic )
			} catch {
				print( "[ConfigStore] Failed to save settings: \(error)" )
			}
		}
		if waiting {
			Self.writer.sync {}
		}
	}

	/// The settings as Settings.json has them.
	func settingsData() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [ .prettyPrinted, .sortedKeys ]
		return try encoder.encode( settings )
	}

	// MARK: - Moving the bridge

	/// The Icons folder's files by name, for an export to another Mac.
	func iconFiles() -> [String: Data] {
		Self.files( in: iconDirectory )
	}

	func shortcutIconFiles() -> [String: Data] {
		Self.files( in: shortcutIconDirectory )
	}

	/// Replaces the settings and both icon folders, and keeps the bridge ID outside the
	/// settings too (BridgeIdentity): importing a bridge from another Mac, or starting over as
	/// a new one. Written now, not after the usual delay.
	func replaceAll( settings new: BridgeSettings, icons: [String: Data], shortcutIcons: [String: Data] ) {
		Self.replaceFiles( in: iconDirectory, with: icons )
		Self.replaceFiles( in: shortcutIconDirectory, with: shortcutIcons )
		iconCache = [:]
		settings  = new
		scheduleSave()
		saveNow( waiting: true )
		BridgeIdentity.store( new.bridgeID, fileIn: directory )
	}

	/// Only names an export may carry, which leaves out things like .DS_Store.
	private static func files( in directory: URL ) -> [String: Data] {
		let names = ( try? FileManager.default.contentsOfDirectory( atPath: directory.path( percentEncoded: false ) ) ) ?? []
		var files: [String: Data] = [:]
		for name in names where BridgeArchive.isSafeFileName( name ) {
			files[name] = try? Data( contentsOf: directory.appending( path: name ) )
		}
		return files
	}

	private static func replaceFiles( in directory: URL, with files: [String: Data] ) {
		let names = ( try? FileManager.default.contentsOfDirectory( atPath: directory.path( percentEncoded: false ) ) ) ?? []
		for name in names where files[name] == nil {
			try? FileManager.default.removeItem( at: directory.appending( path: name ) )
		}
		for ( name, data ) in files where BridgeArchive.isSafeFileName( name ) {
			do {
				try data.write( to: directory.appending( path: name ), options: .atomic )
			} catch {
				print( "[ConfigStore] Failed to write \(name): \(error)" )
			}
		}
	}

	// MARK: - Shortcut icons

	/// Cached copy of a shortcut's own icon, so keys render before Shortcuts is asked.
	func shortcutIcon( id: String ) -> UIImage? {
		UIImage( contentsOfFile: shortcutIconURL( id ).path( percentEncoded: false ) )
	}

	func storeShortcutIcon( _ png: Data, id: String ) {
		try? png.write( to: shortcutIconURL( id ), options: .atomic )
	}

	private func shortcutIconURL( _ id: String ) -> URL {
		let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
		return shortcutIconDirectory.appending( path: safe + ".png" )
	}

	// MARK: - Icons

	func icon( named name: String ) -> UIImage? {
		if let cached = iconCache[name] { return cached }
		guard let image = UIImage( contentsOfFile: iconDirectory.appending( path: name ).path( percentEncoded: false ) ) else { return nil }
		iconCache[name] = image
		return image
	}

	/// Stores image data as a PNG and returns its file name. Dropped images come here
	/// already made small by `iconPNG( from: )`, off the main thread.
	func importIcon( _ data: Data ) -> String? {
		guard let png = try? Self.iconPNG( from: data ), let image = UIImage( data: png ) else { return nil }

		let name = UUID().uuidString + ".png"
		do {
			try png.write( to: iconDirectory.appending( path: name ), options: .atomic )
		} catch {
			print( "[ConfigStore] Failed to write icon: \(error)" )
			return nil
		}
		iconCache[name] = image
		return name
	}

	nonisolated enum IconProblem: LocalizedError {
		case tooLarge
		case unreadable

		var errorDescription: String? {
			switch self {
				case .tooLarge:   "That image is too large. Use one smaller than \(ConfigStore.iconFileLimit / 1024 / 1024) MB."
				case .unreadable: "That image couldn't be read."
			}
		}
	}

	/// An image as a PNG at most `iconImportSize` pixels on its longest side. ImageIO
	/// decodes it straight to that size, so a huge image never lands in memory whole; it
	/// can run on any thread.
	nonisolated static func iconPNG( from data: Data ) throws -> Data {
		guard data.count <= iconFileLimit else { throw IconProblem.tooLarge }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform:   true,
			kCGImageSourceShouldCacheImmediately:         true,
			kCGImageSourceThumbnailMaxPixelSize:          iconImportSize,
		]
		guard let source = CGImageSourceCreateWithData( data as CFData, [ kCGImageSourceShouldCache: false ] as CFDictionary ),
			  let image  = CGImageSourceCreateThumbnailAtIndex( source, 0, options as CFDictionary ) else { throw IconProblem.unreadable }

		let png = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData( png, UTType.png.identifier as CFString, 1, nil ) else { throw IconProblem.unreadable }
		CGImageDestinationAddImage( destination, image, nil )
		guard CGImageDestinationFinalize( destination ) else { throw IconProblem.unreadable }
		return png as Data
	}

	func setIcon( _ name: String?, device: String, key: Int, state: KeyState ) {
		guard let index = settings.deviceIndex( device ), key < settings.devices[index].keys.count else { return }
		settings.devices[index].keys[key].icons[state.rawValue] = name
		removeUnusedIcons()
	}

	/// Icons an undo could bring back; kept until the app quits.
	var iconsKeptForUndo: Set<String> = []

	/// Deletes icon files no key (on any page) refers to any more.
	func removeUnusedIcons() {
		let keys  = settings.devices.flatMap( \.allKeys ) + ( settings.legacyKeys ?? [] )
		let used  = Set( keys.flatMap { $0.icons.values } ).union( iconsKeptForUndo )
		let files = ( try? FileManager.default.contentsOfDirectory( atPath: iconDirectory.path( percentEncoded: false ) ) ) ?? []
		for file in files where !used.contains( file ) {
			try? FileManager.default.removeItem( at: iconDirectory.appending( path: file ) )
			iconCache[file] = nil
		}
	}
}
