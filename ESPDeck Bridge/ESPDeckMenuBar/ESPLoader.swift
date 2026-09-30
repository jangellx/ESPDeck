//
//  ESPLoader.swift
//  ESPDeckMenuBar
//
//  Talks to the serial bootloader in an ESP32-S3's ROM, as documented at
//  https://docs.espressif.com/projects/esptool/en/latest/esp32s3/advanced-topics/serial-protocol.html
//  It resets the chip into the bootloader, checks that it's an S3, and writes flash with
//  compressed writes, each region checked against the ROM's MD5 of what it wrote. It uses
//  the ROM directly, without esptool's flasher stub. Everything blocks; run it off the
//  main thread.
//

import CryptoKit
import Foundation

/// A connection to an ESP32-S3's ROM serial bootloader, for checking the chip and writing flash.
nonisolated final class ESPLoader {
	/// Bytes to write at a flash offset.
	struct Region: Sendable {
		var offset : Int
		var data   : Data
	}

	/// How the Mac reaches the chip, which decides how to reset it.
	enum Link: Sendable {
		/// A USB-to-serial chip wired to EN and IO0 through RTS and DTR (the COM/UART port).
		case uart
		/// The S3's own USB-Serial/JTAG, which turns DTR and RTS into IO0 and reset itself.
		case usbSerialJTAG
		/// The ROM bootloader on the USB-OTG peripheral, which has no reset lines.
		case usbOTG
	}

	/// Why an install failed, worded for the user.
	enum Failure: LocalizedError {
		case noBootloader
		case wrongChip( String )
		case rom( String, UInt8 )
		case noAnswer( String )
		case unsupported( String )
		case verifyFailed( Int )
		case message( String )

		var errorDescription: String? {
			switch self {
				case .noBootloader:
					"Couldn't put the board into flashing mode. Hold BOOT, press and release RST, release BOOT, then try again."
				case .wrongChip( let chip ):
					"This board has an \(chip), not an ESP32-S3, so ESPDeck can't run on it."
				case .rom( let what, let code ):
					"Couldn't \(what): the board reported \(Self.describe( code ))."
				case .noAnswer( let what ):
					"The board stopped answering while trying to \(what)."
				case .unsupported( let what ):
					"The board's bootloader doesn't support \(what)."
				case .verifyFailed( let offset ):
					"The flash didn't read back correctly at 0x\(String( offset, radix: 16 )). Try again, or try another cable or USB port."
				case .message( let text ):
					text
			}
		}

		/// The ROM loader's error codes.
		private static func describe( _ code: UInt8 ) -> String {
			switch code {
				case 0x05:       "a garbled message"
				case 0x07:       "a checksum error"
				case 0x08:       "a flash write error"
				case 0x09:       "a flash read error"
				case 0x0B, 0x0D: "a decompression error"
				case 0x0C:       "a decompression checksum error"
				default:         "error 0x\(String( code, radix: 16 ))"
			}
		}
	}

	/// The ROM loader's command codes used here.
	enum Op: UInt8 {
		case writeRegister   = 0x09
		case readRegister    = 0x0A
		case sync            = 0x08
		case spiSetParams    = 0x0B
		case spiAttach       = 0x0D
		case changeBaudRate  = 0x0F
		case flashDeflBegin  = 0x10
		case flashDeflData   = 0x11
		case spiFlashMD5     = 0x13
		case securityInfo    = 0x14
	}

	/// A command's answer: the value field (READ_REG's result) and the data after it.
	struct Response {
		var value : UInt32
		var data  : Data
	}

	/// Compressed data goes out in blocks of this size (the ROM loader's FLASH_WRITE_SIZE).
	static let blockSize     = 0x400
	/// GET_SECURITY_INFO's chip ID for an ESP32-S3.
	static let esp32S3ChipID : UInt32 = 9
	/// The speed a UART link moves to once connected (speedUp()).
	static let fastBaudRate  = 460_800

	// Registers (esptool's targets/esp32s3.py)
	private static let chipMagicRegister    : UInt32 = 0x4000_1000
	private static let efuseBlock1          : UInt32 = 0x6000_7044
	private static let spiBase              : UInt32 = 0x6000_2000   // SPI1, the flash's controller
	private static let uartDateRegister     : UInt32 = 0x6000_0080
	private static let macRegister          = efuseBlock1             // the MAC is eFuse block 1's first 6 bytes
	private static let rtcBase              : UInt32 = 0x6000_8000
	private static let wdtConfig0           = rtcBase + 0x98
	private static let wdtConfig1           = rtcBase + 0x9C
	private static let wdtProtect           = rtcBase + 0xB0
	private static let wdtKey               : UInt32 = 0x50D8_3AA1
	private static let swdConfig            = rtcBase + 0xB4
	private static let swdProtect           = rtcBase + 0xB8
	private static let swdKey               : UInt32 = 0x8F1D_312A
	private static let swdAutoFeed          : UInt32 = 1 << 31
	private static let option1Register      : UInt32 = 0x6000_812C
	private static let forceDownloadBoot    : UInt32 = 0x1

	private var port    : SerialPort
	private let link    : Link
	private var decoder = SLIPDecoder()

	/// Opens the port; nothing is sent until connect().
	init( path: String, link: Link ) throws {
		port      = try SerialPort( path: path )
		self.link = link
	}

	/// Closes the port without resetting the chip.
	func close() {
		port.close()
	}

	// MARK: - Connecting

	/// Resets into the bootloader and synchronizes. The last attempt skips the reset, for a
	/// board that's already waiting in its bootloader (BOOT held while pressing RST).
	func connect() throws {
		for attempt in 0..<3 {
			if attempt < 2 {
				try resetIntoBootloader( slow: attempt == 1 )
			}
			if try synchronize() { return }
		}
		throw Failure.noBootloader
	}

	/// esptool's reset sequences. `true` asserts a line, pulling its pin low.
	private func resetIntoBootloader( slow: Bool ) throws {
		do {
			switch link {
				case .uart:
					// RTS drives EN, DTR drives IO0; both asserted or neither leaves the chip alone.
					try port.setSignals( dtr: false, rts: false )
					try port.setSignals( dtr: true, rts: true )
					try port.setSignals( dtr: false, rts: true )   // in reset, IO0 high
					pause( 0.1 )
					try port.setSignals( dtr: true, rts: false )   // out of reset with IO0 low: bootloader
					pause( slow ? 0.5 : 0.05 )
					try port.setSignals( dtr: false, rts: false )
				case .usbSerialJTAG:
					try port.setSignals( dtr: false, rts: false )
					pause( 0.1 )
					try port.setSignals( dtr: true, rts: false )   // IO0 low
					pause( 0.1 )
					try port.setSignals( dtr: true, rts: true )    // through (1, 1), not (0, 0)
					try port.setSignals( dtr: false, rts: true )   // reset
					pause( slow ? 0.3 : 0.1 )
					try port.setSignals( dtr: false, rts: false )  // out of reset
				case .usbOTG:
					break
			}
		} catch SerialPort.Failure.disconnected {
			try reopen()
		}
	}

	/// SYNC carries 0x55 bytes that let the ROM measure the baud rate. It answers eight times.
	private func synchronize() throws -> Bool {
		var payload = Data( [ 0x07, 0x07, 0x12, 0x20 ] )
		payload.append( Data( repeating: 0x55, count: 32 ) )
		for _ in 0..<5 {
			discardInput()
			do {
				_ = try command( .sync, payload, timeout: 0.1 )
				pause( 0.1 )   // the other seven answers
				discardInput()
				return true
			} catch Failure.noAnswer {
				pause( 0.05 )
			} catch SerialPort.Failure.disconnected {
				try reopen()
			}
		}
		return false
	}

	/// Drops anything received so far, including a half-decoded frame.
	private func discardInput() {
		port.discardInput()
		decoder = SLIPDecoder()
	}

	/// Reopens the port by path, for up to 5 seconds: the USB-Serial/JTAG port disappears
	/// for a moment when the chip resets.
	private func reopen() throws {
		let path = port.path
		port.close()
		let deadline = Date( timeIntervalSinceNow: 5 )
		while true {
			pause( 0.25 )
			do {
				port = try SerialPort( path: path )
				return
			} catch SerialPort.Failure.disconnected where Date() < deadline {
				continue
			}
		}
	}

	// MARK: - Chip

	/// Refuses anything but an ESP32-S3. Returns a description like "ESP32-S3, MAC 24:0a:…".
	func checkChip() throws -> String {
		let info: Response
		do {
			info = try check( .securityInfo, responseLength: 20, "read the chip type" )
		} catch Failure.unsupported, Failure.rom {
			// Older chips have no GET_SECURITY_INFO (or, on the S2, no chip ID in it).
			throw Failure.wrongChip( try chipFromMagic() )
		}
		let flags  = info.data.uint32( at: 0 )
		let chipID = info.data.uint32( at: 12 )
		guard chipID == Self.esp32S3ChipID else {
			throw Failure.wrongChip( Self.chipName( id: chipID ) )
		}
		guard flags & 0x4 == 0 else {
			throw Failure.message( "This ESP32-S3 is in secure download mode, which doesn't allow installing firmware this way." )
		}
		return "ESP32-S3, MAC \(try macAddress())"
	}

	/// The factory MAC address from the eFuses, like "24:0a:c4:…".
	func macAddress() throws -> String {
		let low  = try readRegister( Self.macRegister )
		let high = try readRegister( Self.macRegister + 4 )
		let bytes = [ UInt8( high >> 8 & 0xFF ), UInt8( high & 0xFF ),
					  UInt8( low >> 24 ), UInt8( low >> 16 & 0xFF ), UInt8( low >> 8 & 0xFF ), UInt8( low & 0xFF ) ]
		return bytes.map { String( format: "%02x", $0 ) }.joined( separator: ":" )
	}

	/// Names a chip too old for GET_SECURITY_INFO from the magic value in its ROM.
	private func chipFromMagic() throws -> String {
		switch try readRegister( Self.chipMagicRegister ) {
			case 0x00F0_1D83: "ESP32"
			case 0x0000_07C6: "ESP32-S2"
			case 0xFFF0_C101: "ESP8266"
			default:          "unknown chip"
		}
	}

	/// Names a chip from GET_SECURITY_INFO's chip ID.
	private static func chipName( id: UInt32 ) -> String {
		switch id {
			case 0:  "ESP32"
			case 2:  "ESP32-S2"
			case 5:  "ESP32-C3"
			case 12: "ESP32-C2"
			case 13: "ESP32-C6"
			case 16: "ESP32-H2"
			case 18: "ESP32-P4"
			case 23: "ESP32-C5"
			default: "unknown chip (ID \(id))"
		}
	}

	/// The chip's built-in PSRAM from its eFuses (esptool's get_psram_cap): size in MB,
	/// 0 for none, nil for a value esptool doesn't know. 8 and 16 MB are octal PSRAM.
	func embeddedPSRAM() throws -> Int? {
		let word4 = try readRegister( Self.efuseBlock1 + 16 )
		let word5 = try readRegister( Self.efuseBlock1 + 20 )
		let code  = ( word5 >> 19 & 0x1 ) << 2 | word4 >> 3 & 0x3
		return [ 0: 0, 1: 8, 2: 2, 3: 16, 4: 4 ][code]
	}

	/// On USB-Serial/JTAG, the RTC watchdog and the super watchdog keep running in the
	/// bootloader and would reset the chip partway through.
	func disableWatchdogs() throws {
		guard link == .usbSerialJTAG else { return }
		try writeRegister( Self.wdtProtect, Self.wdtKey )
		try writeRegister( Self.wdtConfig0, 0 )
		try writeRegister( Self.wdtProtect, 0 )
		try writeRegister( Self.swdProtect, Self.swdKey )
		try writeRegister( Self.swdConfig, try readRegister( Self.swdConfig ) | Self.swdAutoFeed )
		try writeRegister( Self.swdProtect, 0 )
	}

	/// Over a UART, moves to 460800 baud. False if the board didn't follow; reconnect then.
	func speedUp() throws -> Bool {
		guard link == .uart else { return true }
		// Answered at the old speed. The second word is 0 for the ROM loader.
		_ = try command( .changeBaudRate, Self.words( UInt32( Self.fastBaudRate ), 0 ) )
		try port.setBaudRate( Self.fastBaudRate )
		pause( 0.05 )
		discardInput()
		do {
			_ = try readRegister( Self.uartDateRegister )
			return true
		} catch Failure.noAnswer {
			try port.setBaudRate( SerialPort.defaultBaudRate )
			return false
		}
	}

	/// READ_REG: a 32-bit word at `address`.
	func readRegister( _ address: UInt32 ) throws -> UInt32 {
		try check( .readRegister, Self.words( address ), "read a register" ).value
	}

	/// WRITE_REG: sets the bits of `mask` at `address` to those of `value`.
	func writeRegister( _ address: UInt32, _ value: UInt32, mask: UInt32 = 0xFFFF_FFFF ) throws {
		_ = try check( .writeRegister, Self.words( address, value, mask, 0 ), "write a register" )
	}

	// MARK: - Flash

	/// SPI_ATTACH (required by the ROM loader before any flash command), then the flash
	/// size, which the ROM otherwise assumes is smaller than it is.
	func attachFlash( size: Int? ) throws {
		_ = try check( .spiAttach, Data( count: 8 ), "start the flash chip" )
		if let size {
			_ = try check( .spiSetParams, Self.words( 0, UInt32( size ), 64 * 1024, 4 * 1024, 256, 0xFFFF ), "set the flash size" )
		}
	}

	/// The flash chip's JEDEC ID (manufacturer, memory type, capacity, low byte first):
	/// the RDID command (0x9F) run through the flash's SPI controller as a user command,
	/// as esptool's flash_id does. Needs attachFlash first.
	func flashID() throws -> UInt32 {
		let command    = Self.spiBase
		let user       = Self.spiBase + 0x18
		let user2      = Self.spiBase + 0x20
		let misoLength = Self.spiBase + 0x28
		let data       = Self.spiBase + 0x58
		let userStart  : UInt32 = 1 << 18

		let oldUser  = try readRegister( user )
		let oldUser2 = try readRegister( user2 )
		try writeRegister( misoLength, 24 - 1 )           // read 24 bits
		try writeRegister( user, 1 << 31 | 1 << 28 )       // a command phase, then a read phase
		try writeRegister( user2, 7 << 28 | 0x9F )         // 8-bit command: RDID
		try writeRegister( data, 0 )
		try writeRegister( command, userStart )
		var finished = false
		for _ in 0..<10 where !finished {
			finished = try readRegister( command ) & userStart == 0
		}
		guard finished else { throw Failure.message( "The flash chip didn't answer." ) }
		let id = try readRegister( data ) & 0xFF_FFFF
		try writeRegister( user, oldUser )
		try writeRegister( user2, oldUser2 )
		return id
	}

	/// The size a JEDEC ID's capacity byte stands for, with esptool's table (Adesto
	/// codes its size differently); nil when unknown.
	static func flashSize( jedecID: UInt32 ) -> Int? {
		if jedecID & 0xFF == 0x1F {
			let code = Int( jedecID >> 8 & 0x1F )
			return ( 0x04...0x09 ).contains( code ) ? 1 << ( code + 15 ) : nil
		}
		let code = Int( jedecID >> 16 & 0xFF )
		switch code {
			case 0x12...0x1C: return 1 << code
			case 0x20...0x22: return 1 << ( code - 6 )
			case 0x32...0x3A: return 1 << ( code - 0x20 )
			default:          return nil
		}
	}

	/// Writes each region, then checks it with the ROM's MD5 of the flash. Only the sectors
	/// the regions cover are erased. `progress` gets a stage and the fraction done.
	func write( _ regions: [Region], progress: ( String, Double ) -> Void ) throws {
		// Padded to a multiple of 4 bytes, as esptool does.
		let padded = regions.map { region in
			var data = region.data
			data.append( Data( repeating: 0xFF, count: ( 4 - data.count % 4 ) % 4 ) )
			return Region( offset: region.offset, data: data )
		}
		let compressed = try padded.map { region in
			guard let data = Zlib.compress( region.data ) else { throw Failure.message( "The firmware couldn't be compressed." ) }
			return data
		}
		let total = Double( max( compressed.reduce( 0 ) { $0 + $1.count }, 1 ) )
		var sent  = 0

		for ( region, packed ) in zip( padded, compressed ) {
			try Task.checkCancellation()
			let blocks    = ( packed.count + Self.blockSize - 1 ) / Self.blockSize
			// The ROM erases the whole area up front, rounded up to whole blocks.
			let eraseSize = ( region.data.count + Self.blockSize - 1 ) / Self.blockSize * Self.blockSize
			progress( "Erasing…", Double( sent ) / total )
			_ = try check( .flashDeflBegin, Self.words( UInt32( eraseSize ), UInt32( blocks ), UInt32( Self.blockSize ), UInt32( region.offset ), 0 ),
						   timeout: Self.timeout( secondsPerMB: 40, bytes: eraseSize ), "erase the flash" )

			for sequence in 0..<blocks {
				try Task.checkCancellation()
				let start = sequence * Self.blockSize
				let block = packed.subdata( in: start..<min( start + Self.blockSize, packed.count ) )
				var data  = Self.words( UInt32( block.count ), UInt32( sequence ), 0, 0 )
				data.append( block )
				// A block of compressed 0xFF padding can inflate to a lot of flash writing.
				_ = try check( .flashDeflData, data, checksum: Self.checksum( block ), timeout: 15, "write the flash" )
				sent += block.count
				progress( "Installing…", Double( sent ) / total )
			}

			progress( "Checking…", Double( sent ) / total )
			let expected = Insecure.MD5.hash( data: region.data ).map { String( format: "%02x", $0 ) }.joined()
			guard try flashMD5( offset: region.offset, size: region.data.count ) == expected else {
				throw Failure.verifyFailed( region.offset )
			}
		}
	}

	/// The ROM's MD5 of a flash region, as 32 hex digits.
	func flashMD5( offset: Int, size: Int ) throws -> String {
		let digest = try check( .spiFlashMD5, Self.words( UInt32( offset ), UInt32( size ), 0, 0 ), responseLength: 32,
								timeout: Self.timeout( secondsPerMB: 8, bytes: size ), "check the flash" )
		return String( decoding: digest.data, as: UTF8.self ).lowercased()
	}

	/// Leaves the bootloader and starts the firmware. First clears the "force download" flag
	/// a 1200 bps touch sets, which would bring it straight back. Over USB, the RTC watchdog
	/// does the reset: on an S3 put in the bootloader with BOOT and RST, a reset through RTS
	/// on USB-Serial/JTAG came back up in the bootloader.
	func restart() {
		try? writeRegister( Self.option1Register, 0, mask: Self.forceDownloadBoot )
		switch link {
			case .usbSerialJTAG, .usbOTG:
				try? writeRegister( Self.wdtProtect, Self.wdtKey )
				try? writeRegister( Self.wdtConfig1, 2000 )
				try? writeRegister( Self.wdtConfig0, 1 << 31 | 5 << 28 | 1 << 8 | 2 )
				try? writeRegister( Self.wdtProtect, 0 )
				pause( 0.5 )
			case .uart:
				try? port.setSignals( dtr: false, rts: true )
				pause( 0.1 )
				try? port.setSignals( dtr: false, rts: false )
		}
		port.close()
	}

	// MARK: - Commands

	/// Sends a command and waits for the answer to it, skipping anything else.
	func command( _ op: Op, _ data: Data = Data(), checksum: UInt32 = 0, timeout: TimeInterval = 3 ) throws -> Response {
		try port.write( Self.slipEncode( Self.packet( op, data, checksum: checksum ) ) )

		let deadline = Date( timeIntervalSinceNow: timeout )
		while true {
			let remaining = deadline.timeIntervalSinceNow
			guard remaining > 0 else { throw Failure.noAnswer( Self.describe( op ) ) }
			for frame in decoder.feed( try port.read( timeout: remaining ) ) {
				guard let response = Self.response( frame ) else { continue }
				if response.op == op.rawValue {
					return Response( value: response.value, data: response.data )
				}
				// The ROM answers a command it doesn't know with status 1, error 5.
				if response.data.count >= 2, response.data[response.data.startIndex] != 0, response.data[response.data.startIndex + 1] == 0x05 {
					throw Failure.unsupported( Self.describe( op ) )
				}
			}
		}
	}

	/// A command whose answer ends in status bytes: status (0 for success) and an error
	/// code, after `responseLength` bytes of data. The ROM adds two reserved bytes.
	func check( _ op: Op, _ data: Data = Data(), checksum: UInt32 = 0, responseLength: Int = 0,
				timeout: TimeInterval = 3, _ what: String ) throws -> Response {
		let response = try command( op, data, checksum: checksum, timeout: timeout )
		let body     = Data( response.data )
		guard body.count >= responseLength + 2 else {
			if body.count >= 2, body[0] != 0 { throw Failure.rom( what, body[1] ) }
			throw Failure.unsupported( what )
		}
		guard body[responseLength] == 0 else { throw Failure.rom( what, body[responseLength + 1] ) }
		return Response( value: response.value, data: body.prefix( responseLength ) )
	}

	/// What a command was doing, for noAnswer and unsupported.
	private static func describe( _ op: Op ) -> String {
		switch op {
			case .sync:                     "connect"
			case .flashDeflBegin:           "erase the flash"
			case .flashDeflData:            "write the flash"
			case .spiFlashMD5:              "check the flash"
			case .changeBaudRate:           "change speed"
			default:                        "set up the flash"
		}
	}

	// MARK: - Encoding

	/// Direction 0, the command, the data length and a checksum (all little-endian), then the data.
	static func packet( _ op: Op, _ data: Data, checksum: UInt32 = 0 ) -> Data {
		var packet = Data( [ 0x00, op.rawValue, UInt8( data.count & 0xFF ), UInt8( data.count >> 8 & 0xFF ) ] )
		packet.append( words( checksum ) )
		packet.append( data )
		return packet
	}

	/// Direction 1, the command it answers, the data length, a value (READ_REG's result),
	/// then the data.
	static func response( _ frame: Data ) -> ( op: UInt8, value: UInt32, data: Data )? {
		let bytes = Data( frame )
		guard bytes.count >= 8, bytes[0] == 0x01 else { return nil }
		let length = Int( bytes[2] ) | Int( bytes[3] ) << 8
		guard bytes.count >= 8 + length else { return nil }
		return ( bytes[1], bytes.uint32( at: 4 ), bytes.subdata( in: 8..<8 + length ) )
	}

	/// 0xEF, XORed with every byte of the data being written.
	static func checksum( _ data: Data ) -> UInt32 {
		UInt32( data.reduce( UInt8( 0xEF ) ) { $0 ^ $1 } )
	}

	/// 32-bit little-endian words, the form every command's parameters take.
	static func words( _ values: UInt32... ) -> Data {
		var data = Data( capacity: values.count * 4 )
		for value in values {
			withUnsafeBytes( of: value.littleEndian ) { data.append( contentsOf: $0 ) }
		}
		return data
	}

	/// Frames start and end with 0xC0; inside, 0xC0 is sent as DB DC and 0xDB as DB DD.
	static func slipEncode( _ packet: Data ) -> Data {
		var frame = Data( [ 0xC0 ] )
		frame.reserveCapacity( packet.count + 16 )
		for byte in packet {
			switch byte {
				case 0xC0: frame.append( contentsOf: [ 0xDB, 0xDC ] )
				case 0xDB: frame.append( contentsOf: [ 0xDB, 0xDD ] )
				default:   frame.append( byte )
			}
		}
		frame.append( 0xC0 )
		return frame
	}

	/// Collects frames across reads; bytes outside a frame (the ROM's boot messages) are dropped.
	struct SLIPDecoder {
		/// Longer than any response (8 bytes and at most 64 KB of data); past it, the bytes
		/// can't be a frame, so they're dropped until the next 0xC0.
		static let maximumFrame = 8 + 0xFFFF

		private var frame   = Data()
		private var inFrame = false
		private var escaped = false

		/// The frames that `bytes` completes, unescaped and without their 0xC0s.
		mutating func feed( _ bytes: Data ) -> [Data] {
			var frames: [Data] = []
			for byte in bytes {
				if byte == 0xC0 {
					if inFrame && !frame.isEmpty {
						frames.append( frame )
						inFrame = false
					} else {
						inFrame = true   // a start, or an empty frame between two
					}
					frame   = Data()
					escaped = false
				} else if inFrame {
					if frame.count >= Self.maximumFrame {
						frame   = Data()
						inFrame = false
						escaped = false
					} else if escaped {
						frame.append( byte == 0xDC ? 0xC0 : byte == 0xDD ? 0xDB : byte )
						escaped = false
					} else if byte == 0xDB {
						escaped = true
					} else {
						frame.append( byte )
					}
				}
			}
			return frames
		}
	}

	/// A timeout for an operation that scales with its size, at least 3 seconds.
	private static func timeout( secondsPerMB: Double, bytes: Int ) -> TimeInterval {
		max( 3, secondsPerMB * Double( bytes ) / 1_000_000 )
	}

	/// Blocks the calling thread.
	private func pause( _ seconds: TimeInterval ) {
		Thread.sleep( forTimeInterval: seconds )
	}
}

nonisolated extension Data {
	/// The little-endian 32-bit word at `offset` from the start, or 0 past the end.
	func uint32( at offset: Int ) -> UInt32 {
		guard count >= offset + 4 else { return 0 }
		let start = startIndex + offset
		return UInt32( self[start] ) | UInt32( self[start + 1] ) << 8 | UInt32( self[start + 2] ) << 16 | UInt32( self[start + 3] ) << 24
	}
}
