//
//  ESPLoader+Install.swift
//  ESPDeckMenuBar
//
//  The whole USB install: getting the board into its ROM bootloader (from ESPDeck's own
//  USB-Serial/JTAG port, a USB-to-serial chip, or firmware with its own USB serial port),
//  checking the chip, writing and checking the flash, and restarting it.
//

import Foundation

nonisolated extension ESPLoader {
	/// Installs `regions` on the board at `path`, getting it into its bootloader first.
	/// Before writing anything it checks the chip, that the flash holds `minimumFlashSize`
	/// bytes, and that there's the octal PSRAM ESPDeck needs, reporting what it found
	/// through `identified` ("ESP32-S3, 16 MB flash, 8 MB PSRAM"). Returns an error message
	/// (nil on success) and the port the board ended up on.
	static func install( port path: String, regions: [Region], minimumFlashSize: Int, identified: @escaping @Sendable ( String ) -> Void,
						 progress: @escaping @Sendable ( String, Double ) -> Void ) -> ( String?, String ) {
		var path = path
		do {
			guard var info = SerialPortInfo.named( path ) else {
				throw Failure.message( "The board isn't connected anymore." )
			}
			if info.isEspressif && !info.isBootloaderCapable {
				// Firmware with its own USB serial port (TinyUSB, like Arduino's USB CDC):
				// the 1200 bps touch restarts it into the ROM bootloader, as a new port.
				progress( "Restarting the board into flashing mode…", 0 )
				info = try touch( info )
				path = info.path
			}
			let link: Link = switch ( info.isEspressif, info.productID ) {
				case ( true, SerialPortInfo.romOTGProductID ): .usbOTG
				case ( true, _ ):                              .usbSerialJTAG
				default:                                       .uart
			}

			progress( "Connecting to the board…", 0 )
			let loader = try ESPLoader( path: path, link: link )
			defer { loader.close() }
			try loader.connect()
			let chip = try loader.checkChip()
			print( "[MenuBar] Installing firmware on \(chip) at \(path)" )
			try loader.disableWatchdogs()
			if try !loader.speedUp() {
				try loader.connect()
				_ = try loader.checkChip()
			}
			try loader.attachFlash( size: nil )
			let flash = flashSize( jedecID: try loader.flashID() )
			let psram = try loader.embeddedPSRAM()
			identified( describe( flash: flash, psram: psram ) )
			if let problem = compatibilityProblem( flash: flash, psram: psram, minimumFlashSize: minimumFlashSize ) {
				loader.restart()   // back to what it was running; nothing was written
				throw Failure.message( problem )
			}
			try loader.attachFlash( size: flash ?? flashSize( regions ) )
			try loader.write( regions, progress: progress )
			progress( "Restarting…", 1 )
			loader.restart()
			return ( nil, path )
		} catch is CancellationError {
			return ( "Installing stopped partway. Install again before using the board.", path )
		} catch {
			return ( error.localizedDescription, path )
		}
	}

	/// The speed that, set on firmware's own USB serial port, asks it to restart into the bootloader.
	private static let touchBaudRate = 1200

	/// Asks firmware with its own USB serial port to restart into the ROM bootloader, then
	/// waits for the bootloader's port in the same USB socket. Two conventions: switching
	/// to 1200 baud (Arduino's "1200 bps touch"), and the DTR/RTS pattern of esptool's
	/// reset, which Arduino's USB CDC also watches for. Firmware that knows neither (like
	/// ESP-IDF's TinyUSB examples) needs the BOOT and RST buttons.
	static func touch( _ info: SerialPortInfo ) throws -> SerialPortInfo {
		let before = Set( SerialPortInfo.current().map( \.path ) )
		do {
			let port = try SerialPort( path: info.path )
			defer { port.close() }
			try port.setBaudRate( Self.touchBaudRate )
			Thread.sleep( forTimeInterval: 0.1 )
			for ( dtr, rts ) in [ ( false, true ), ( true, true ), ( true, false ), ( false, false ) ] {
				try port.setSignals( dtr: dtr, rts: rts )
				Thread.sleep( forTimeInterval: 0.05 )
			}
		} catch SerialPort.Failure.disconnected {
			// Already restarting.
		}

		let deadline = Date( timeIntervalSinceNow: 10 )
		while Date() < deadline {
			try Task.checkCancellation()
			Thread.sleep( forTimeInterval: 0.25 )
			let bootloader = SerialPortInfo.current().first { port in
				guard port.isBootloaderCapable else { return false }
				return info.location != nil ? port.location == info.location : !before.contains( port.path )
			}
			if let bootloader {
				Thread.sleep( forTimeInterval: 0.5 )   // let it finish enumerating
				return bootloader
			}
		}
		throw Failure.noBootloader
	}

	/// What the bootloader found, like "ESP32-S3, 16 MB flash, 8 MB PSRAM".
	static func describe( flash: Int?, psram: Int? ) -> String {
		var parts = [ "ESP32-S3" ]
		if let flash { parts.append( "\(flash >> 20) MB flash" ) }
		switch psram {
			case 0?:          parts.append( "no PSRAM" )
			case let size?:   parts.append( "\(size) MB PSRAM" )
			case nil:         break
		}
		return parts.joined( separator: ", " )
	}

	/// Why ESPDeck can't run on this board, if it can't. Its partition table decides the
	/// flash it needs. The firmware uses 8 MB of octal PSRAM (an N16R8 board) and stops at
	/// startup without it; the eFuses list only built-in PSRAM, which S3 boards use.
	static func compatibilityProblem( flash: Int?, psram: Int?, minimumFlashSize: Int ) -> String? {
		if let flash, flash < minimumFlashSize {
			return "This board has \(flash >> 20) MB of flash, and ESPDeck needs \(minimumFlashSize >> 20) MB. \(Self.useSupportedBoard)"
		}
		if let psram, psram != 8 && psram != 16 {
			let has = psram == 0 ? "no PSRAM" : "\(psram) MB of quad PSRAM"
			return "This board has \(has), and ESPDeck needs 8 MB of octal PSRAM. \(Self.useSupportedBoard)"
		}
		return nil
	}

	/// How compatibilityProblem's messages end.
	private static let useSupportedBoard = "Use an ESP32-S3 board with 16 MB of flash and 8 MB of PSRAM (N16R8). Nothing was installed."

	/// From the image header of the bootloader at offset 0: the high nibble of its fourth
	/// byte is the flash size, 0 for 1 MB up to 7 for 128 MB.
	static func flashSize( _ regions: [Region] ) -> Int? {
		guard let bootloader = regions.first( where: { $0.offset == 0 } ), bootloader.data.count > 4,
			  bootloader.data[bootloader.data.startIndex] == 0xE9 else { return nil }
		let code = Int( bootloader.data[bootloader.data.startIndex + 3] >> 4 )
		return code <= 7 ? ( 1 << code ) * 1024 * 1024 : nil
	}
}
