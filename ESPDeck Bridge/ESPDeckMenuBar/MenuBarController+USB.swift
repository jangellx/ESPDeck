//
//  MenuBarController+USB.swift
//  ESPDeckMenuBar
//
//  Setting up a board over USB: the serial port list, installing firmware through the
//  ESP32-S3's ROM bootloader (ESPLoader), and Improv Wi-Fi (ImprovSession). The serial
//  work runs in detached tasks; results come back on the main thread.
//

import Foundation

extension MenuBarController {
	// MARK: - Ports

	func watchSerialPorts( changed: @escaping ( [[String]] ) -> Void ) {
		portWatcher?.stop()
		portWatcher = SerialPortWatcher { ports in
			changed( ports.map( \.fields ) )
		}
	}

	func stopWatchingSerialPorts() {
		portWatcher?.stop()
		portWatcher = nil
	}

	// MARK: - Installing firmware

	private enum InstallEvent: Sendable {
		case identified( String )
		case progress( String, Double )
		case finished( String?, String )
	}

	func installFirmware( port: String, offsets: [Int], images: [Data], minimumFlashSize: Int, identified: @escaping ( String ) -> Void,
						  progress: @escaping ( String, Double ) -> Void, completion: @escaping ( String?, String ) -> Void ) {
		stopImprov()   // one user of the port at a time
		installTask?.cancel()

		let regions = zip( offsets, images ).map { ESPLoader.Region( offset: $0, data: $1 ) }
		let ( events, continuation ) = AsyncStream.makeStream( of: InstallEvent.self )
		installTask = Task.detached( priority: .userInitiated ) {
			let ( error, finalPort ) = ESPLoader.install( port: port, regions: regions, minimumFlashSize: minimumFlashSize ) { board in
				continuation.yield( .identified( board ) )
			} progress: { stage, fraction in
				continuation.yield( .progress( stage, fraction ) )
			}
			continuation.yield( .finished( error, finalPort ) )
			continuation.finish()
		}
		Task {
			for await event in events {
				switch event {
					case .identified( let board ):             identified( board )
					case .progress( let stage, let fraction ): progress( stage, fraction )
					case .finished( let error, let port ):     completion( error, port )
				}
			}
		}
	}

	func cancelFirmwareInstall() {
		installTask?.cancel()
		installTask = nil
	}

	// MARK: - Improv

	func startImprov( port: String, received: @escaping ( Int, Int, [String] ) -> Void, log: @escaping ( String ) -> Void,
					  stopped: @escaping ( String? ) -> Void ) {
		stopImprov()

		let session: ImprovSession
		do {
			session = try ImprovSession( path: port )
		} catch {
			stopped( error.localizedDescription )
			return
		}
		improvSession = session

		let ( events, continuation ) = AsyncStream.makeStream( of: ImprovPacket.Event.self )
		let reader = Task.detached( priority: .userInitiated ) {
			let error = session.run { parsed in
				parsed.forEach { continuation.yield( $0 ) }
			}
			session.close()
			continuation.finish()
			return error?.localizedDescription
		}
		improvTask = Task {
			for await event in events {
				switch event {
					case .packet( let type, let data ):
						let bytes = [UInt8]( data )
						if type == ImprovPacket.typeResult {
							received( Int( type ), Int( bytes.first ?? 0 ), ImprovPacket.strings( inResult: data ) )
						} else {
							received( Int( type ), Int( bytes.first ?? 0 ), [] )
						}
					case .text( let line ):
						log( line )
				}
			}
			let error = await reader.value
			if improvSession === session {
				improvSession = nil
			}
			stopped( Task.isCancelled ? nil : error )
		}
		improvReader = reader
	}

	func sendImprov( command: Int, data: Data ) -> String? {
		guard let improvSession else { return "The board isn't connected." }
		do {
			try improvSession.send( command: UInt8( command ), data: data )
			return nil
		} catch {
			return error.localizedDescription
		}
	}

	func stopImprov() {
		improvReader?.cancel()
		improvTask?.cancel()
		improvReader  = nil
		improvTask    = nil
		improvSession = nil
	}
}
