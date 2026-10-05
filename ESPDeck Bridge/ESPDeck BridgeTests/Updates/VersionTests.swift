//
//  VersionTests.swift
//  ESPDeck BridgeTests
//
//  Version numbers decide whether a firmware update is offered and whether an install is a
//  downgrade that needs confirming, so reading and comparing them is checked here.
//

import Testing
@testable import ESPDeck_Bridge

/// Reading version strings, comparing them, and what that means for a board's firmware.
struct VersionTests {
	/// Release tags and plain numbers all read as the same parts.
	@Test( arguments: [ "4.1.0", "v4.1.0", "firmware-v4.1.0", "4.1.0-beta", "firmware-v4.1.0-rc1" ] )
	func readsEveryFormAReleaseUses( _ string: String ) throws {
		let version = try #require( Version( string ) )
		#expect( version.parts == [ 4, 1, 0 ] )
	}

	/// Nothing to read is no version, not version zero.
	@Test( arguments: [ "", "dev", "-" ] )
	func rejectsStringsWithoutNumbers( _ string: String ) {
		#expect( Version( string ) == nil )
	}

	/// Parts compare as numbers, so 4.10 is after 4.9.
	@Test func comparesPartsAsNumbers() throws {
		let older = try #require( Version( "4.9.0" ) )
		let newer = try #require( Version( "4.10.0" ) )
		#expect( older < newer )
		#expect( ( newer < older ) == false )
	}

	/// A missing part counts as zero.
	@Test func treatsMissingPartsAsZero() throws {
		let short = try #require( Version( "4.1" ) )
		let long  = try #require( Version( "4.1.0" ) )
		#expect( short == long )
		#expect( ( short < long ) == false )
	}

	/// What USB Setup and Updates say about a board, for each way its firmware can compare.
	@Test func standsAgainstTheLatestRelease() throws {
		let latest = try #require( Version( "4.1.0" ) )
		#expect( FirmwareStanding( running: "4.0.2", latest: latest ) == .updateAvailable( latest ) )
		#expect( FirmwareStanding( running: "4.1.0", latest: latest ) == .upToDate )
		#expect( FirmwareStanding( running: "4.2.0", latest: latest ) == .newer )
		#expect( FirmwareStanding( running: "dev", latest: latest ) == .unknown )
		#expect( FirmwareStanding( running: "4.1.0", latest: nil ) == .unknown )
	}

	/// Only going back to an older version is a downgrade; the same version again is not.
	@Test func flagsOnlyOlderInstallsAsDowngrades() {
		#expect( FirmwareStanding.isDowngrade( installing: "4.0.0", over: "4.1.0" ) )
		#expect( FirmwareStanding.isDowngrade( installing: "4.1.0", over: "4.1.0" ) == false )
		#expect( FirmwareStanding.isDowngrade( installing: "4.2.0", over: "4.1.0" ) == false )
		#expect( FirmwareStanding.isDowngrade( installing: "dev", over: "4.1.0" ) == false )
	}
}
