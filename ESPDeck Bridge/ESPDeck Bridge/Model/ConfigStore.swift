//
//  ConfigStore.swift
//  ESPDeck Bridge
//
//  Persists BridgeSettings as JSON and the user's source icons as PNG files, both in
//  Application Support.
//

import Observation
import UIKit

@Observable
final class ConfigStore {
	var settings: BridgeSettings {
		didSet {
			if settings != oldValue { save() }
		}
	}

	@ObservationIgnored private let directory     : URL
	@ObservationIgnored private let iconDirectory : URL
	@ObservationIgnored private var iconCache     : [String: UIImage] = [:]
	@ObservationIgnored private let shortcutIconDirectory : URL

	private var settingsURL: URL { directory.appending( path: "Settings.json" ) }

	/// Icons are downscaled to this many pixels on their longest side when imported.
	private static let iconImportSize: CGFloat = 240

	init() {
		let support   = URL.applicationSupportDirectory.appending( path: "ESPDeck Bridge", directoryHint: .isDirectory )
		directory     = support
		iconDirectory = support.appending( path: "Icons", directoryHint: .isDirectory )
		shortcutIconDirectory = support.appending( path: "Shortcut Icons", directoryHint: .isDirectory )
		try? FileManager.default.createDirectory( at: iconDirectory, withIntermediateDirectories: true )
		try? FileManager.default.createDirectory( at: shortcutIconDirectory, withIntermediateDirectories: true )

		Self.migrateFromSandboxContainer( to: support )

		let url = support.appending( path: "Settings.json" )
		if let data    = try? Data( contentsOf: url ),
		   let decoded = try? JSONDecoder().decode( BridgeSettings.self, from: data ) {
			settings = decoded
		} else {
			settings = BridgeSettings()
		}
	}

	/// Early builds were sandboxed (under an older bundle ID), so their settings and icons
	/// live in that app's container. Copy them once if this install has none yet. macOS
	/// may ask for permission to access the other app's data.
	private static func migrateFromSandboxContainer( to support: URL ) {
		let files = FileManager.default
		guard !files.fileExists( atPath: support.appending( path: "Settings.json" ).path( percentEncoded: false ) ) else { return }

		let home = URL( fileURLWithPath: NSHomeDirectory() )
		for bundleID in [ "com.openreelsoftware.ESPDeck-Bridge", "com.tmproductions.ESPDeck-Bridge" ] {
			let old = home.appending( path: "Library/Containers/\(bundleID)/Data/Library/Application Support/ESPDeck Bridge", directoryHint: .isDirectory )
			guard let items = try? files.contentsOfDirectory( at: old, includingPropertiesForKeys: nil ) else { continue }

			for item in items {
				let destination = support.appending( path: item.lastPathComponent )
				try? files.removeItem( at: destination )
				try? files.copyItem( at: item, to: destination )
			}
			print( "[ConfigStore] Copied settings from \(bundleID)'s sandbox container" )
			return
		}
	}

	private func save() {
		do {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [ .prettyPrinted, .sortedKeys ]
			try encoder.encode( settings ).write( to: settingsURL, options: .atomic )
		} catch {
			print( "[ConfigStore] Failed to save settings: \(error)" )
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

	/// Stores dropped image data as a PNG and returns its file name.
	func importIcon( _ data: Data ) -> String? {
		guard let source = UIImage( data: data ) else { return nil }

		let longest = max( source.size.width, source.size.height )
		let scale   = min( 1, Self.iconImportSize / max( longest, 1 ) )
		let size    = CGSize( width: ( source.size.width * scale ).rounded(), height: ( source.size.height * scale ).rounded() )

		let format   = UIGraphicsImageRendererFormat()
		format.scale = 1
		let image    = UIGraphicsImageRenderer( size: size, format: format ).image { _ in
			source.draw( in: CGRect( origin: .zero, size: size ) )
		}
		guard let png = image.pngData() else { return nil }

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

	func setIcon( _ name: String?, device: String, key: Int, state: KeyState ) {
		guard let index = settings.deviceIndex( device ) else { return }
		settings.devices[index].ensureKey( key )
		settings.devices[index].keys[key].icons[state.rawValue] = name
		removeUnusedIcons()
	}

	/// Deletes icon files no key refers to any more.
	func removeUnusedIcons() {
		let keys  = settings.devices.flatMap( \.keys ) + ( settings.legacyKeys ?? [] )
		let used  = Set( keys.flatMap { $0.icons.values } )
		let files = ( try? FileManager.default.contentsOfDirectory( atPath: iconDirectory.path( percentEncoded: false ) ) ) ?? []
		for file in files where !used.contains( file ) {
			try? FileManager.default.removeItem( at: iconDirectory.appending( path: file ) )
			iconCache[file] = nil
		}
	}
}
