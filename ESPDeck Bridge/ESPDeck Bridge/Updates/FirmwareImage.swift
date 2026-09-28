//
//  FirmwareImage.swift
//  ESPDeck Bridge
//
//  Reads ESP-IDF firmware files: an app image's own description (version, project name,
//  build), and the flash layout of a full image for installing over USB.
//

import Foundation

enum FirmwareImage {
	/// The name ESP-IDF builds into the app description: `project()` in CMakeLists.txt.
	static let projectName  = "ESPDeck"
	static let esp32S3ChipID = 9

	enum Problem: LocalizedError {
		case notFirmware
		case wrongChip
		case wrongProject( String )
		case appImageOnly
		case damaged( String )

		var errorDescription: String? {
			switch self {
				case .notFirmware:              "That file isn't ESP32 firmware."
				case .wrongChip:                "That firmware is for a different kind of ESP32, not the ESP32-S3."
				case .wrongProject( let name ): "That's firmware for \(name.isEmpty ? "another project" : "“\(name)”"), not ESPDeck."
				case .appImageOnly:             "That's an update image, which doesn't include the bootloader. For USB, choose the full image (the one ending in -merged.bin)."
				case .damaged( let what ):      "That firmware looks damaged: \(what)."
			}
		}
	}

	/// The app description (esp_app_desc_t) every ESP-IDF app image carries: after the
	/// 24-byte image header and the first segment's 8-byte header.
	struct AppInfo: Equatable {
		var version     : String
		var projectName : String
		/// Compile date and time, as the compiler's __DATE__ and __TIME__.
		var date        : String
		var time        : String
		/// Hex SHA-256 of the ELF file: tells builds with the same version apart.
		var elfSHA256   : String

		var built: String { "\(date) at \(time)" }
	}

	/// Reads an app image's description. Doesn't check which project it's from.
	static func appInfo( _ image: Data ) throws -> AppInfo {
		let bytes = [UInt8]( image.prefix( 32 + 256 ) )
		guard bytes.count >= 32 + 208, bytes[0] == 0xE9, word( bytes, 32 ) == 0xABCD_5432 else { throw Problem.notFirmware }
		guard Int( bytes[12] ) | Int( bytes[13] ) << 8 == esp32S3ChipID else { throw Problem.wrongChip }
		// magic, secure_version, reserv1[2], version[32], project_name[32], time[16],
		// date[16], idf_ver[32], app_elf_sha256[32]
		return AppInfo( version: string( bytes, 48, 32 ), projectName: string( bytes, 80, 32 ), date: string( bytes, 128, 16 ),
						time: string( bytes, 112, 16 ), elfSHA256: bytes[176..<208].map { String( format: "%02x", $0 ) }.joined() )
	}

	/// An app image for this project; anything else is refused.
	static func espDeckApp( _ image: Data ) throws -> AppInfo {
		let info = try appInfo( image )
		guard info.projectName == projectName else { throw Problem.wrongProject( info.projectName ) }
		return info
	}

	// MARK: - Full images

	/// Bytes to write at a flash offset.
	struct Region: Equatable {
		var offset : Int
		var data   : Data
	}

	/// A partition table entry (esp_partition_info_t).
	struct Partition {
		var type    : UInt8
		var subtype : UInt8
		var offset  : Int
		var size    : Int

		var isApp     : Bool { type == 0x00 }
		/// otadata, which says which app slot to boot.
		var isOTAData : Bool { type == 0x01 && subtype == 0x00 }
		/// Data a reinstall must keep: NVS (Wi-Fi, name, pairing), the image cache, and so on.
		var isKept    : Bool { type == 0x01 && !isOTAData }
	}

	static let partitionTableOffset = 0x8000

	/// 32-byte entries starting 0xAA 0x50, until the MD5 entry (0xEB 0xEB) or erased flash.
	static func partitions( _ table: Data ) -> [Partition] {
		let bytes = [UInt8]( table.prefix( 0xC00 ) )
		var partitions: [Partition] = []
		for start in stride( from: 0, to: bytes.count - 31, by: 32 ) where bytes[start] == 0xAA && bytes[start + 1] == 0x50 {
			partitions.append( Partition( type: bytes[start + 2], subtype: bytes[start + 3],
										  offset: Int( word( bytes, start + 4 ) ), size: Int( word( bytes, start + 8 ) ) ) )
		}
		return partitions
	}

	/// The flash the partition table needs: where its last partition ends. Found in the
	/// regions to write (a full image's first region, or the table's own); nil without one.
	static func requiredFlashSize( _ regions: [Region] ) -> Int? {
		guard let region = regions.first( where: { $0.offset <= partitionTableOffset && partitionTableOffset < $0.offset + $0.data.count } ) else { return nil }
		let start = region.data.startIndex + partitionTableOffset - region.offset
		let table = partitions( region.data.subdata( in: start..<min( start + 0xC00, region.data.endIndex ) ) )
		return table.map { $0.offset + $0.size }.max()
	}

	/// Splits a full image (bootloader, partition table, otadata and app from offset 0, as
	/// release.sh and the web installer have it) into the regions to write: everything but
	/// the data partitions it lists. The image fills those with 0xFF, and writing them would
	/// erase the device's settings. Also returns the app's description.
	static func regions( fullImage image: Data ) throws -> ( regions: [Region], app: AppInfo ) {
		guard image.first == 0xE9 else { throw Problem.notFirmware }
		if ( try? appInfo( image ) ) != nil { throw Problem.appImageOnly }
		guard image.count > partitionTableOffset + 0xC00 else { throw Problem.damaged( "it's too short" ) }

		let table = partitions( image.subdata( in: partitionTableOffset..<partitionTableOffset + 0xC00 ) )
		guard let app = table.filter( \.isApp ).min( by: { $0.offset < $1.offset } ), app.offset < image.count else {
			throw Problem.damaged( "it has no app" )
		}
		let info = try espDeckApp( image.subdata( in: app.offset..<image.count ) )

		var regions: [Region] = []
		var start   = 0
		for kept in table.filter( \.isKept ).sorted( by: { $0.offset < $1.offset } ) where kept.offset < image.count {
			if kept.offset > start {
				regions.append( Region( offset: start, data: image.subdata( in: start..<kept.offset ) ) )
			}
			start = max( start, kept.offset + kept.size )
		}
		if start < image.count {
			regions.append( Region( offset: start, data: image.subdata( in: start..<image.count ) ) )
		}
		return ( regions, info )
	}

	// MARK: - Helpers

	private static func word( _ bytes: [UInt8], _ offset: Int ) -> UInt32 {
		UInt32( bytes[offset] ) | UInt32( bytes[offset + 1] ) << 8 | UInt32( bytes[offset + 2] ) << 16 | UInt32( bytes[offset + 3] ) << 24
	}

	/// A NUL-padded C string field.
	private static func string( _ bytes: [UInt8], _ offset: Int, _ length: Int ) -> String {
		let field = bytes[offset..<offset + length]
		return String( decoding: field.prefix { $0 != 0 }, as: UTF8.self )
	}
}
