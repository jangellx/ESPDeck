//
//  CoraProtocolTests.swift
//  ESPDeck BridgeTests
//
//  Reading and writing a Network Dock's messages. There's no dock here to try them on, so
//  these are the one check that they match a real one: the bytes come from Haukcode.
//  StreamDeck's packet capture of Elgato's app and a real dock with a Stream Deck MK.2. A
//  mistake in an offset fails quietly (a wrong port, keys that never register, images the
//  deck ignores), so it's worth catching here.
//

import Foundation
import Testing
@testable import ESPDeck_Bridge

struct CoraProtocolTests {
	/// A payload from its non-zero start, zero-padded to the size the dock sends (512).
	private func payload( _ hex: String, size: Int = 512 ) -> Data {
		var data = Data( hex: hex )!
		data.append( Data( count: size - data.count ) )
		return data
	}

	/// The real dock's capabilities message, with an MK.2 plugged in.
	@Test func capabilitiesFromARealDock() throws {
		let message = payload( "010b7c000203050048004800e001100104050104040000000000d90f8000456c6761746f0000000000000000000000000000000000000000000000000000"
							   + "53747265616d204465636b204d4b2e32000000000000000000000000000000004130305341353230324c4a504359000000000000000000000000000000000000214e" )
		let capabilities = try #require( DockCapabilities( payload: message ) )
		#expect( capabilities.connected )
		#expect( capabilities.rows == 3 )
		#expect( capabilities.columns == 5 )
		#expect( capabilities.keyWidth == 72 && capabilities.keyHeight == 72 )
		#expect( capabilities.vendorID == 0x0FD9 && capabilities.productID == 0x0080 )
		#expect( capabilities.model == "Stream Deck MK.2" )
		#expect( capabilities.serial == "A00SA5202LJPCY" )
		#expect( capabilities.port == 20001 )
		#expect( DockModel.model( productID: capabilities.productID )?.rows == capabilities.rows )
	}

	/// The dock's answers about itself, and its keepalive.
	@Test func dockAnswersFromARealDock() {
		#expect( DockMessage.firmware( payload( "0383000062856235312e30312e303133" ) ) == "1.01.013" )
		#expect( DockMessage.serial( payload( "0384000e414258494135343831304555595a" ) ) == "ABXIA54810EUYZ" )
		#expect( DockMessage.keepalive( payload( "010a020001" ) ) == 0 )
		#expect( DockMessage.firmware( payload( "0384000e4142" ) ) == nil )
	}

	/// A key-state report from the real MK.2: 15 keys, the 11th down.
	@Test func keyStatesFromARealDeck() throws {
		let states = try #require( DeckReport.keyStates( payload( "01000f000000000000000000000001" ) ) )
		#expect( states.count == 15 )
		#expect( states.indices.filter { states[$0] } == [ 10 ] )
		#expect( DeckReport.keyStates( payload( "010a020001" ) ) == nil )   // a keepalive isn't one
	}

	/// Images go out as Elgato's app sends them: 1016 bytes a report, only the last asking
	/// for an acknowledgment (the capture's first report reads 02 07 00 00 f8 03 00 00).
	@Test func imageReports() {
		let image  = Data( ( 0..<2000 ).map { UInt8( $0 % 251 ) } )
		let frames = DeckReport.imageFrames( key: 4, image: image, messageID: 77 )
		#expect( frames.count == 2 )
		#expect( frames.allSatisfy { $0.payload.count == 1024 } )
		#expect( frames[0].payload.prefix( 8 ) == Data( [ 0x02, 0x07, 4, 0, 0xF8, 0x03, 0, 0 ] ) )
		#expect( frames[0].flags == .verbatim && frames[0].messageID == 0 )
		#expect( frames[1].payload.prefix( 8 ) == Data( [ 0x02, 0x07, 4, 1, 0xD8, 0x03, 1, 0 ] ) )
		#expect( frames[1].flags == [ .verbatim, .reqAck ] && frames[1].messageID == 77 )
		#expect( frames[0].payload[8...] + frames[1].payload[8..<( 8 + 984 )] == image )
	}

	/// Frames come back whole however TCP splits them, and a stream that starts mid-frame
	/// (as the capture's does) skips to the next one.
	@Test func readerSplitsAndResyncs() {
		let sent = [
			CoraFrame( payload: payload( "010a020001" ) ),
			CoraFrame( flags: [ .verbatim, .ackNak ], messageID: 1974, payload: Data( count: 4 ) ),
			CoraFrame( payload: payload( "0384000e414258494135343831304555595a" ) ),
		]
		var stream = Data( [ 0x00, 0x00, 0x93, 0x8A, 0x41, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0x03, 0x83 ] )
		for frame in sent { stream.append( frame.encoded ) }

		var reader   = CoraFrameReader()
		var received : [CoraFrame] = []
		var offset   = 0
		while offset < stream.count {
			let end = min( offset + 7, stream.count )
			received += reader.append( stream[offset..<end] )
			offset = end
		}
		#expect( received == sent )
	}
}
