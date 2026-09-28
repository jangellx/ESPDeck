//
//  SerialPort.swift
//  ESPDeckMenuBar
//
//  A serial port through the POSIX calls: open, termios for 8N1 and the speed, and ioctl
//  for the DTR and RTS lines that reset an ESP32. Everything blocks, so use it off the
//  main thread. A sandboxed build needs com.apple.security.device.serial for this.
//

import Darwin
import Foundation

nonisolated final class SerialPort {
	enum Failure: LocalizedError {
		/// The port went away: the board was unplugged, or it restarted and re-enumerated.
		case disconnected
		case system( String, Int32 )

		var errorDescription: String? {
			switch self {
				case .disconnected:               "The board was disconnected."
				case .system( let call, let err ): "\(call) failed: \(String( cString: strerror( err ) ))"
			}
		}
	}

	/// `_IOW( 'T', 2, speed_t )` from IOKit/serial/ioss.h: any speed, not only the B* ones.
	private static let setSpeed: UInt = 0x8008_5402

	let path: String
	private(set) var baudRate: Int
	private var descriptor: Int32

	init( path: String, baudRate: Int = 115_200 ) throws {
		self.path     = path
		self.baudRate = baudRate
		// Non-blocking, so opening doesn't wait for carrier detect; reads go through poll().
		// Busy for a moment while an earlier user of the port finishes closing it.
		descriptor = open( path, O_RDWR | O_NOCTTY | O_NONBLOCK )
		for _ in 0..<10 where descriptor < 0 && errno == EBUSY {
			Thread.sleep( forTimeInterval: 0.1 )
			descriptor = open( path, O_RDWR | O_NOCTTY | O_NONBLOCK )
		}
		guard descriptor >= 0 else {
			throw errno == ENOENT || errno == ENXIO ? Failure.disconnected : Failure.system( "open", errno )
		}
		do {
			guard ioctl( descriptor, TIOCEXCL ) == 0 else { throw Failure.system( "TIOCEXCL", errno ) }
			var options = termios()
			guard tcgetattr( descriptor, &options ) == 0 else { throw Failure.system( "tcgetattr", errno ) }
			cfmakeraw( &options )
			options.c_cflag |= tcflag_t( CLOCAL | CREAD )
			options.c_cflag &= ~tcflag_t( CRTSCTS | HUPCL )
			options.c_iflag &= ~tcflag_t( IXON | IXOFF | IXANY )
			guard tcsetattr( descriptor, TCSANOW, &options ) == 0 else { throw Failure.system( "tcsetattr", errno ) }
			try setBaudRate( baudRate )
		} catch {
			Darwin.close( descriptor )
			throw error
		}
	}

	deinit {
		close()
	}

	func close() {
		guard descriptor >= 0 else { return }
		Darwin.close( descriptor )
		descriptor = -1
	}

	/// Also what the 1200 bps "touch" uses: the new speed reaches a USB CDC device as a
	/// SET_LINE_CODING request.
	func setBaudRate( _ rate: Int ) throws {
		var speed = speed_t( rate )
		guard ioctl( descriptor, Self.setSpeed, &speed ) == 0 else { throw failure( "IOSSIOSPEED" ) }
		baudRate = rate
	}

	/// Sets both lines in one call, so a reset sequence never passes through a combination
	/// it didn't ask for. `true` asserts a line, which pulls the pin it drives low.
	func setSignals( dtr: Bool, rts: Bool ) throws {
		var bits: Int32 = 0
		guard ioctl( descriptor, TIOCMGET, &bits ) == 0 else { throw failure( "TIOCMGET" ) }
		bits = dtr ? bits | TIOCM_DTR : bits & ~TIOCM_DTR
		bits = rts ? bits | TIOCM_RTS : bits & ~TIOCM_RTS
		guard ioctl( descriptor, TIOCMSET, &bits ) == 0 else { throw failure( "TIOCMSET" ) }
	}

	func write( _ data: Data, timeout: TimeInterval = 10 ) throws {
		let deadline = Date( timeIntervalSinceNow: timeout )
		try data.withUnsafeBytes { buffer in
			var offset = 0
			while offset < buffer.count {
				let written = Darwin.write( descriptor, buffer.baseAddress! + offset, buffer.count - offset )
				if written > 0 {
					offset += written
				} else if written < 0 && errno != EAGAIN && errno != EINTR {
					throw failure( "write" )
				} else {
					guard Date() < deadline else { throw Failure.system( "write", ETIMEDOUT ) }
					try wait( for: Int16( POLLOUT ), until: deadline )
				}
			}
		}
	}

	/// Whatever arrives within `timeout` (at least one byte), or empty data if nothing does.
	func read( timeout: TimeInterval ) throws -> Data {
		guard try wait( for: Int16( POLLIN ), until: Date( timeIntervalSinceNow: timeout ) ) else { return Data() }
		var buffer = [UInt8]( repeating: 0, count: 4096 )
		let count  = Darwin.read( descriptor, &buffer, buffer.count )
		if count > 0 { return Data( buffer[0..<count] ) }
		if count == 0 { throw Failure.disconnected }
		if errno == EAGAIN || errno == EINTR { return Data() }
		throw failure( "read" )
	}

	/// Drops anything received and not yet read.
	func discardInput() {
		tcflush( descriptor, TCIFLUSH )
	}

	/// True when the port is ready before the deadline; false when time ran out.
	@discardableResult
	private func wait( for events: Int16, until deadline: Date ) throws -> Bool {
		while true {
			var entry     = pollfd( fd: descriptor, events: events, revents: 0 )
			let remaining = max( 0, Int32( deadline.timeIntervalSinceNow * 1000 ) )
			let result    = poll( &entry, 1, remaining )
			if result > 0 {
				if entry.revents & Int16( POLLHUP | POLLNVAL ) != 0 { throw Failure.disconnected }
				return true
			}
			if result == 0 { return false }
			if errno != EINTR { throw failure( "poll" ) }
		}
	}

	private func failure( _ call: String ) -> Failure {
		switch errno {
			case ENXIO, ENODEV, EIO, EBADF: .disconnected
			default:                        .system( call, errno )
		}
	}
}
