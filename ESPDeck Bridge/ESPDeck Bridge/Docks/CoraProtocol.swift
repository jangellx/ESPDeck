//
//  CoraProtocol.swift
//  ESPDeck Bridge
//
//  Elgato's "Cora" protocol, which a Stream Deck Network Dock speaks over TCP: frames, and
//  the messages ESPDeck Bridge sends and reads in them. Nothing here touches the network
//  (DockLink does).
//
//  Elgato doesn't document it. This follows two MIT-licensed projects that worked it out,
//  Haukcode.StreamDeck (a client, written against a real dock) and DeckBridge (a stand-in
//  dock), and was checked against the packet capture of Elgato's app and a real dock that
//  Haukcode.StreamDeck publishes.
//
//  A dock has two ports. The dock's own (5343, advertised over Bonjour as _elg._tcp)
//  answers questions about the dock and says which port the Stream Deck plugged into it is
//  on; that port carries the Stream Deck's own USB HID reports, wrapped in frames.
//

import Foundation

/// One frame: a 16-byte header, then the payload.
///   0  magic 43 93 8A 41
///   4  flags (LE16)
///   6  HID operation
///   8  message ID (LE32), echoed by replies and acknowledgments
///   12 payload length (LE32)
struct CoraFrame: Equatable {
	struct Flags: OptionSet, Equatable {
		let rawValue: UInt16
		/// The payload is a HID report, passed on as is.
		static let verbatim  = Flags( rawValue: 0x8000 )
		/// Asks for an acknowledgment once it's been handled.
		static let reqAck    = Flags( rawValue: 0x4000 )
		/// An acknowledgment, of the frame with the same message ID.
		static let ackNak    = Flags( rawValue: 0x0200 )
		/// The answer to a request with the same message ID.
		static let result    = Flags( rawValue: 0x0100 )
	}

	/// What the frame does with its HID report.
	enum Operation: UInt8 {
		case write     = 0
		case sendReport = 1
		case getReport = 2
	}

	static let magic: [UInt8] = [ 0x43, 0x93, 0x8A, 0x41 ]
	static let headerSize     = 16
	/// Anything longer is a corrupt length, not a frame (images go out 1 KB at a time).
	static let maxPayload     = 64 * 1024

	var flags     : Flags
	var operation : UInt8
	var messageID : UInt32
	var payload   : Data

	init( flags: Flags = [], operation: Operation = .write, messageID: UInt32 = 0, payload: Data ) {
		self.flags     = flags
		self.operation = operation.rawValue
		self.messageID = messageID
		self.payload   = payload
	}

	/// The frame as it goes on the wire.
	var encoded: Data {
		var data = Data( Self.magic )
		data.appendLE( flags.rawValue )
		data.append( operation )
		data.append( 0 )
		data.appendLE( messageID )
		data.appendLE( UInt32( payload.count ) )
		data.append( payload )
		return data
	}
}

/// Splits a TCP stream into frames. A stream that loses its place (bytes that aren't a
/// header) skips ahead to the next magic.
struct CoraFrameReader {
	private var buffer = Data()

	/// Adds bytes from the connection and returns every frame now complete.
	mutating func append( _ bytes: Data ) -> [CoraFrame] {
		buffer.append( bytes )
		var frames: [CoraFrame] = []
		while buffer.count >= CoraFrame.headerSize {
			let start = buffer.startIndex
			guard buffer.prefix( 4 ).elementsEqual( CoraFrame.magic ) else {
				// Lost: drop to the next magic, keeping a tail that could be the start of one.
				if let next = buffer.dropFirst().firstRange( of: Data( CoraFrame.magic ) ) {
					buffer = buffer[next.lowerBound...]
					continue
				}
				buffer = buffer.suffix( 3 )
				break
			}
			let length = Int( buffer.readLE( UInt32.self, at: 12 ) )
			guard length <= CoraFrame.maxPayload else {
				buffer = buffer.dropFirst( 4 )   // not a real header: look for the next one
				continue
			}
			guard buffer.count >= CoraFrame.headerSize + length else { break }
			let payloadStart = start + CoraFrame.headerSize
			var frame = CoraFrame( payload: Data( buffer[payloadStart..<payloadStart + length] ) )
			frame.flags     = CoraFrame.Flags( rawValue: buffer.readLE( UInt16.self, at: 4 ) )
			frame.operation = buffer[start + 6]
			frame.messageID = buffer.readLE( UInt32.self, at: 8 )
			frames.append( frame )
			buffer = Data( buffer[( payloadStart + length )...] )
		}
		return frames
	}
}

// MARK: - The dock's own port

/// What the dock says about the Stream Deck plugged into it (its 01 0B message):
///   4        0x02 with a Stream Deck plugged in
///   5, 6     rows, columns
///   8, 10    key image width, height (LE16)
///   26, 28   USB vendor and product ID (LE16)
///   30       manufacturer, 62 model name, 94 serial number (ASCII, NUL-padded, 32 each)
///   126      the port the Stream Deck is on (LE16)
/// Checked against a real dock with a Stream Deck MK.2: 3 rows, 5 columns, 72 × 72, PID
/// 0x0080, port 20001.
struct DockCapabilities: Equatable {
	var connected : Bool
	var rows      : Int
	var columns   : Int
	var keyWidth  : Int
	var keyHeight : Int
	var vendorID  : UInt16
	var productID : UInt16
	var model     : String
	var serial    : String
	var port      : UInt16

	/// The payload of a capabilities message, or nil if it isn't one.
	init?( payload: Data ) {
		guard payload.count >= 128, payload[payload.startIndex] == 0x01, payload[payload.startIndex + 1] == 0x0B else { return nil }
		connected = payload[payload.startIndex + 4] == 0x02
		rows      = Int( payload[payload.startIndex + 5] )
		columns   = Int( payload[payload.startIndex + 6] )
		keyWidth  = Int( payload.readLE( UInt16.self, at: 8 ) )
		keyHeight = Int( payload.readLE( UInt16.self, at: 10 ) )
		vendorID  = payload.readLE( UInt16.self, at: 26 )
		productID = payload.readLE( UInt16.self, at: 28 )
		model     = payload.asciiString( at: 62, length: 32 )
		serial    = payload.asciiString( at: 94, length: 32 )
		port      = payload.readLE( UInt16.self, at: 126 )
	}
}

/// Messages on the dock's own port. Questions are 1024-byte payloads, 03 then a report ID,
/// sent with no flags; answers echo those two bytes.
enum DockMessage {
	static let questionSize = 1024

	/// The dock's firmware (answered with "1.01.013" at byte 8).
	static let firmwareReport: UInt8     = 0x83
	/// The dock's serial number (its length at byte 3, the number from byte 4).
	static let serialReport: UInt8       = 0x84
	/// The capabilities message (DockCapabilities).
	static let capabilitiesReport: UInt8 = 0x1C
	/// The answer to a keepalive.
	static let keepaliveAckReport: UInt8 = 0x1A

	/// A question for the dock.
	static func question( _ report: UInt8 ) -> CoraFrame {
		var payload = Data( count: questionSize )
		payload[0] = 0x03
		payload[1] = report
		return CoraFrame( payload: payload )
	}

	/// The answer to a keepalive (01 0A …), sent on whichever port it came on: 03 1A and the
	/// connection number the keepalive carried at byte 5.
	static func keepaliveAck( connection: UInt8 ) -> CoraFrame {
		var payload = Data( count: questionSize )
		payload[0] = 0x03
		payload[1] = keepaliveAckReport
		payload[2] = connection
		return CoraFrame( payload: payload )
	}

	/// A keepalive's connection number, if the payload is a keepalive. Both ports send them,
	/// every few seconds, and expect an answer.
	static func keepalive( _ payload: Data ) -> UInt8? {
		guard payload.count >= 6, payload[payload.startIndex] == 0x01, payload[payload.startIndex + 1] == 0x0A else { return nil }
		return payload[payload.startIndex + 5]
	}

	/// The answer to `question( report )`, if the payload is one.
	static func isAnswer( _ payload: Data, to report: UInt8 ) -> Bool {
		payload.count >= 2 && payload[payload.startIndex] == 0x03 && payload[payload.startIndex + 1] == report
	}

	/// The firmware version in an answer to firmwareReport.
	static func firmware( _ payload: Data ) -> String? {
		guard isAnswer( payload, to: firmwareReport ) else { return nil }
		let text = payload.asciiString( at: 8, length: 8 )
		return text.isEmpty ? nil : text
	}

	/// The serial number in an answer to serialReport.
	static func serial( _ payload: Data ) -> String? {
		guard isAnswer( payload, to: serialReport ), payload.count > 4 else { return nil }
		let length = min( Int( payload[payload.startIndex + 3] ), payload.count - 4 )
		let text   = payload.asciiString( at: 4, length: length )
		return text.isEmpty ? nil : text
	}
}

// MARK: - The Stream Deck's port

/// The Stream Deck's HID reports, as the dock passes them on.
enum DeckReport {
	/// The largest image report; 8 bytes of header, then up to 1016 bytes of the image.
	static let imageReportSize = 1024
	static let imageHeaderSize = 8
	/// Feature reports go out as 32 bytes.
	static let featureSize     = 32

	/// The image for one key, in as many reports as it takes:
	/// 02 07, key, 1 on the last, length (LE16), page number (LE16), then the data. Only the
	/// last asks for an acknowledgment, which the dock sends once the deck has the image.
	static func imageFrames( key: Int, image: Data, messageID: UInt32 ) -> [CoraFrame] {
		let room   = imageReportSize - imageHeaderSize
		let pages  = max( 1, ( image.count + room - 1 ) / room )
		return ( 0..<pages ).map { page in
			let start  = image.startIndex + page * room
			let chunk  = image[start..<min( start + room, image.endIndex )]
			let last   = page == pages - 1
			var report = Data( count: imageReportSize )
			report[0] = 0x02
			report[1] = 0x07
			report[2] = UInt8( key )
			report[3] = last ? 1 : 0
			report.writeLE( UInt16( chunk.count ), at: 4 )
			report.writeLE( UInt16( page ), at: 6 )
			report.replaceSubrange( imageHeaderSize..<imageHeaderSize + chunk.count, with: chunk )
			return CoraFrame( flags: last ? [ .verbatim, .reqAck ] : .verbatim, operation: .write,
							  messageID: last ? messageID : 0, payload: report )
		}
	}

	/// Sets the backlight: feature report 03 08, then the percentage.
	static func brightness( _ percent: Int, messageID: UInt32 ) -> CoraFrame {
		var report = Data( count: featureSize )
		report[0] = 0x03
		report[1] = 0x08
		report[2] = UInt8( min( max( percent, 0 ), 100 ) )
		return CoraFrame( flags: [ .verbatim, .reqAck ], operation: .sendReport, messageID: messageID, payload: report )
	}

	/// Asks for a feature report (0x05 firmware, 0x06 serial number, 0x0B device info), as
	/// Elgato's app does when it connects.
	static func getReport( _ id: UInt8, messageID: UInt32 ) -> CoraFrame {
		var report = Data( count: featureSize )
		report[0] = id
		return CoraFrame( flags: [ .verbatim, .reqAck ], operation: .getReport, messageID: messageID, payload: report )
	}

	/// Which keys are down, if the payload is the input report that says: 01 00, the key
	/// count, 00, then one byte per key (1 down), in the deck's own key order.
	static func keyStates( _ payload: Data ) -> [Bool]? {
		guard payload.count >= 4, payload[payload.startIndex] == 0x01, payload[payload.startIndex + 1] == 0x00 else { return nil }
		let count = Int( payload[payload.startIndex + 2] )
		guard count > 0, payload.count >= 4 + count else { return nil }
		return ( 0..<count ).map { payload[payload.startIndex + 4 + $0] == 1 }
	}
}

// MARK: - Bytes

extension Data {
	/// A little-endian integer `offset` bytes in.
	func readLE<T: FixedWidthInteger>( _ type: T.Type, at offset: Int ) -> T {
		var value: T = 0
		for byte in 0..<MemoryLayout<T>.size {
			value |= T( self[startIndex + offset + byte] ) << ( 8 * byte )
		}
		return value
	}

	/// Writes a little-endian integer `offset` bytes in.
	mutating func writeLE<T: FixedWidthInteger>( _ value: T, at offset: Int ) {
		for byte in 0..<MemoryLayout<T>.size {
			self[startIndex + offset + byte] = UInt8( truncatingIfNeeded: value >> ( 8 * byte ) )
		}
	}

	/// Appends a little-endian integer.
	mutating func appendLE<T: FixedWidthInteger>( _ value: T ) {
		for byte in 0..<MemoryLayout<T>.size {
			append( UInt8( truncatingIfNeeded: value >> ( 8 * byte ) ) )
		}
	}

	/// Printable ASCII up to the first NUL, within `length` bytes from `offset`.
	func asciiString( at offset: Int, length: Int ) -> String {
		guard offset < count else { return "" }
		let field = self[( startIndex + offset )..<( startIndex + Swift.min( offset + length, count ) )]
		let text  = field.prefix { $0 != 0 }.filter { ( 0x20..<0x7F ).contains( $0 ) }
		return String( decoding: text, as: UTF8.self ).trimmingCharacters( in: .whitespaces )
	}
}
