//
//  Version.swift
//  ESPDeck Bridge
//
//  Version numbers of the app and the firmware, compared part by part.
//

import Foundation

/// A dotted version number, as the app and the firmware use them.
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

	/// Part by part; a missing part counts as 0, so 4.1 equals 4.1.0.
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

/// How an ESPDeck board's firmware compares with the latest release.
enum FirmwareStanding: Equatable {
	case upToDate
	case updateAvailable( Version )
	/// A development build, or a release newer than the last update check.
	case newer
	case unknown

	/// `unknown` without a latest release or a readable running version.
	init( running: String, latest: Version? ) {
		guard let latest, let running = Version( running ) else {
			self = .unknown
			return
		}
		self = running < latest ? .updateAvailable( latest ) : latest < running ? .newer : .upToDate
	}

	/// In words for the USB Setup page; nil when there's nothing to say.
	var description: String? {
		switch self {
			case .upToDate:                       "Up to date"
			case .updateAvailable( let version ): "Update available: \(version)"
			case .newer:                          "Newer than the latest release"
			case .unknown:                        nil
		}
	}

	/// Installing `installing` over `running` goes back to an older version, which needs
	/// confirming. The same version (a rebuild) doesn't.
	static func isDowngrade( installing: String, over running: String ) -> Bool {
		guard let new = Version( installing ), let old = Version( running ) else { return false }
		return new < old
	}
}
