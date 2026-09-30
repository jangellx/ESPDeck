//
//  MainThreadWatchdog.swift
//  ESPDeck Bridge
//
//  Measures how long the main thread takes to respond, from a background thread. Everything
//  that talks to the ESP32s (including answering their heartbeat pings) runs on the main
//  thread, so a long stall drops their connections; this makes such stalls visible.
//

import Foundation

/// Pings the main thread once a second from a thread of its own; see the file comment.
enum MainThreadWatchdog {
	/// Calls `report` (on the main thread) after any stall longer than `threshold` seconds.
	nonisolated static func start( threshold: TimeInterval = 1.5, report: @escaping @Sendable ( TimeInterval ) -> Void ) {
		let thread = Thread {
			while true {
				let sent      = Date()
				let responded = DispatchSemaphore( value: 0 )
				DispatchQueue.main.async { responded.signal() }
				responded.wait()
				let lag = Date().timeIntervalSince( sent )
				if lag > threshold {
					DispatchQueue.main.async { report( lag ) }
				}
				Thread.sleep( forTimeInterval: 1 )
			}
		}
		thread.name = "ESPDeck main-thread watchdog"
		thread.start()
	}
}
