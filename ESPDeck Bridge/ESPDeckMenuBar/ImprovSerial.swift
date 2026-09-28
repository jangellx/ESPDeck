//
//  ImprovSerial.swift
//  ESPDeckMenuBar
//
//  Improv Wi-Fi over serial (https://www.improv-wifi.com/serial/): the packet format, and
//  a session that reads a port in the background. The firmware's log lines share the
//  port; they're passed on separately, and the parser finds packets among them.
//

import Foundation

nonisolated enum ImprovPacket {
	static let header      = Array( "IMPROV".utf8 )
	static let version     : UInt8 = 1

	static let typeState   : UInt8 = 0x01
	static let typeError   : UInt8 = 0x02
	static let typeRPC     : UInt8 = 0x03
	static let typeResult  : UInt8 = 0x04

	/// A packet's data, and an RPC command's, has a one-byte length.
	enum Failure: LocalizedError {
		case tooLong( Int )

		var errorDescription: String? {
			switch self {
				case .tooLong( let count ): "That's too much to send to the board (\(count) bytes; Improv allows 255)."
			}
		}
	}

	/// "IMPROV", version, type, length, data, and a checksum: the low byte of the sum of
	/// every byte before it.
	static func encode( type: UInt8, data: Data ) throws -> Data {
		guard let length = UInt8( exactly: data.count ) else { throw Failure.tooLong( data.count ) }
		var packet = Data( header )
		packet.append( contentsOf: [ version, type, length ] )
		packet.append( data )
		packet.append( packet.reduce( UInt8( 0 ) ) { $0 &+ $1 } )
		return packet
	}

	/// An RPC command packet: the command, the length of its data, the data. The whole
	/// body has a one-byte length too, so the data can be at most 253 bytes.
	static func command( _ command: UInt8, data: Data ) throws -> Data {
		guard let length = UInt8( exactly: data.count ) else { throw Failure.tooLong( data.count ) }
		var body = Data( [ command, length ] )
		body.append( data )
		return try encode( type: typeRPC, data: body )
	}

	/// An RPC result's strings, each a length byte and its bytes, after the command and
	/// the length of the rest.
	static func strings( inResult data: Data ) -> [String] {
		let bytes = [UInt8]( data )
		guard bytes.count >= 2 else { return [] }
		var strings: [String] = []
		var index = 2
		let end   = min( bytes.count, 2 + Int( bytes[1] ) )
		while index < end {
			let length = Int( bytes[index] )
			index += 1
			guard index + length <= end else { break }
			strings.append( String( decoding: bytes[index..<index + length], as: UTF8.self ) )
			index += length
		}
		return strings
	}

	enum Event: Equatable {
		case packet( type: UInt8, data: Data )
		/// A line of the device's log output (without the line ending).
		case text( String )
	}

	/// Splits incoming bytes into packets and log lines.
	struct Parser {
		private var pending = [UInt8]()   // a packet in progress, starting with the header
		private var line    = [UInt8]()

		mutating func feed( _ bytes: Data ) -> [Event] {
			var events: [Event] = []
			for byte in bytes {
				if !pending.isEmpty || byte == header[0] {
					pending.append( byte )
					consumePending( &events )
				} else {
					appendText( byte, &events )
				}
			}
			return events
		}

		private mutating func consumePending( _ events: inout [Event] ) {
			let headerCount = header.count
			let index       = pending.count - 1
			// Still matching the header, then a known version and packet type? Otherwise
			// it was text; its last byte may start a real header.
			let matches = switch index {
				case ..<headerCount:    pending[index] == header[index]
				case headerCount:       pending[index] == version
				case headerCount + 1:   ( typeState...typeResult ).contains( pending[index] )
				default:                true
			}
			guard matches else {
				let last = pending.removeLast()
				pending.forEach { appendText( $0, &events ) }
				pending = []
				if last == header[0] {
					pending = [ last ]
				} else {
					appendText( last, &events )
				}
				return
			}
			guard pending.count >= headerCount + 3 else { return }
			let length = Int( pending[headerCount + 2] )
			guard pending.count >= headerCount + 3 + length + 1 else { return }

			let sum = pending.dropLast().reduce( UInt8( 0 ) ) { $0 &+ $1 }
			if sum == pending[pending.count - 1] {
				events.append( .packet( type: pending[headerCount + 1], data: Data( pending[( headerCount + 3 )..<( headerCount + 3 + length )] ) ) )
			}
			pending = []
		}

		private mutating func appendText( _ byte: UInt8, _ events: inout [Event] ) {
			if byte == 0x0A {
				let text = String( decoding: line, as: UTF8.self ).trimmingCharacters( in: .whitespacesAndNewlines )
				if !text.isEmpty { events.append( .text( text ) ) }
				line = []
			} else if line.count < 1024 {
				line.append( byte )
			}
		}
	}
}

/// An open port that's read in the background, with packets and log lines passed to the
/// caller as they arrive. Writes come from any thread.
nonisolated final class ImprovSession: @unchecked Sendable {
	private let port   : SerialPort
	private let lock   = NSLock()
	private var closed = false

	/// Leaves DTR and RTS as opening left them, both asserted: that resets neither a board
	/// with the auto-reset circuit nor the S3's USB-Serial/JTAG, and changing them could
	/// pass through a combination that does.
	init( path: String ) throws {
		port = try SerialPort( path: path )
	}

	func send( command: UInt8, data: Data ) throws {
		lock.lock()
		defer { lock.unlock() }
		guard !closed else { throw SerialPort.Failure.disconnected }
		try port.write( ImprovPacket.command( command, data: data ), timeout: 2 )
	}

	/// Reads until cancelled or the port goes away; returns why it stopped.
	func run( events: ( [ImprovPacket.Event] ) -> Void ) -> Error? {
		var parser = ImprovPacket.Parser()
		while !Task.isCancelled {
			do {
				let data = try port.read( timeout: 0.2 )
				let parsed = parser.feed( data )
				if !parsed.isEmpty { events( parsed ) }
			} catch {
				return error
			}
		}
		return nil
	}

	func close() {
		lock.lock()
		closed = true
		port.close()
		lock.unlock()
	}
}
