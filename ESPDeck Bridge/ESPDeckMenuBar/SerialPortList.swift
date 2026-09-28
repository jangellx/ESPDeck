//
//  SerialPortList.swift
//  ESPDeckMenuBar
//
//  The Mac's serial ports and the USB device behind each, from the I/O Registry, and a
//  watcher that reports the list again whenever a port appears or disappears.
//

import Foundation
import IOKit
import IOKit.serial

nonisolated struct SerialPortInfo: Equatable, Sendable {
	var path      : String
	/// The USB device's product and vendor names, when it's a USB device and has them.
	var product   : String?
	var vendor    : String?
	var vendorID  : Int?
	var productID : Int?
	/// Where the device is plugged in (locationID): the same socket keeps the same value
	/// when a board restarts as a different USB device, e.g. into its ROM bootloader.
	var location  : Int?
	/// The USB serial number. On the ESP32-S3's own USB port, it's the chip's MAC address
	/// ("7C:4F:AD:BB:D9:78"), which the app matches to the device's ID.
	var serial    : String?

	static let espressifVendorID = 0x303A
	/// The ESP32-S3's own USB-Serial/JTAG port: the ROM bootloader's and ESPDeck's.
	static let usbSerialJTAGProductID = 0x1001
	/// The ROM bootloader on the USB-OTG peripheral (the chip ID as product ID).
	static let romOTGProductID = 0x0009

	var isEspressif: Bool { vendorID == Self.espressifVendorID }

	/// [path, product, vendor, vendor ID, product ID, location, serial], with "" for
	/// anything missing; the form DeckMenuBarPlugin reports ports in.
	var fields: [String] {
		[ path, product ?? "", vendor ?? "", vendorID.map( String.init ) ?? "", productID.map( String.init ) ?? "",
		  location.map( String.init ) ?? "", serial ?? "" ]
	}

	/// The call-out devices (/dev/cu.*), without Bluetooth and the debug console.
	static func current() -> [SerialPortInfo] {
		guard let matching = IOServiceMatching( kIOSerialBSDServiceValue ) as NSMutableDictionary? else { return [] }
		matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

		var iterator: io_iterator_t = 0
		guard IOServiceGetMatchingServices( kIOMainPortDefault, matching, &iterator ) == KERN_SUCCESS else { return [] }
		defer { IOObjectRelease( iterator ) }

		var ports: [SerialPortInfo] = []
		while case let service = IOIteratorNext( iterator ), service != 0 {
			defer { IOObjectRelease( service ) }
			guard let path = property( service, kIOCalloutDeviceKey, searchParents: false ) as? String,
				  !path.contains( "Bluetooth" ), !path.contains( "debug-console" ), !path.contains( "wlan-debug" ) else { continue }
			ports.append( SerialPortInfo( path: path,
										  product: property( service, "USB Product Name" ) as? String,
										  vendor: property( service, "USB Vendor Name" ) as? String,
										  vendorID: ( property( service, "idVendor" ) as? NSNumber )?.intValue,
										  productID: ( property( service, "idProduct" ) as? NSNumber )?.intValue,
										  location: ( property( service, "locationID" ) as? NSNumber )?.intValue,
										  serial: ( property( service, "USB Serial Number" ) ?? property( service, "kUSBSerialNumberString" ) ) as? String ) )
		}
		return ports.sorted { $0.path < $1.path }
	}

	static func named( _ path: String ) -> SerialPortInfo? {
		current().first { $0.path == path }
	}

	/// The USB device's properties live on its ancestors in the service plane.
	private static func property( _ service: io_object_t, _ key: String, searchParents: Bool = true ) -> Any? {
		let options = searchParents ? IOOptionBits( kIORegistryIterateRecursively | kIORegistryIterateParents ) : 0
		return IORegistryEntrySearchCFProperty( service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options )
	}
}

/// Calls `changed` on the main thread with the full list, now and after every change.
final class SerialPortWatcher {
	private let changed      : ( [SerialPortInfo] ) -> Void
	private let notifications = Notifications()
	private var pendingList  : Task<Void, Never>?

	/// What IOKit holds on to, apart from the watcher: its callbacks get a retained Relay
	/// that only points weakly at the watcher, so a late callback can't reach a freed one.
	/// Torn down by stop(), or when the watcher goes away.
	private nonisolated final class Notifications: @unchecked Sendable {
		var port      : IONotificationPortRef?
		var iterators : [io_iterator_t] = []
		var relay     : Unmanaged<Relay>?

		func tearDown() {
			iterators.forEach { IOObjectRelease( $0 ) }
			iterators = []
			if let port {
				IONotificationPortDestroy( port )
			}
			port = nil
			relay?.release()
			relay = nil
		}

		deinit {
			tearDown()
		}
	}

	private nonisolated final class Relay: @unchecked Sendable {
		weak var watcher: SerialPortWatcher?

		init( _ watcher: SerialPortWatcher ) {
			self.watcher = watcher
		}
	}

	init( changed: @escaping ( [SerialPortInfo] ) -> Void ) {
		self.changed = changed
		start()
		changed( SerialPortInfo.current() )
	}

	func stop() {
		pendingList?.cancel()
		pendingList = nil
		notifications.tearDown()
	}

	private func start() {
		guard let port = IONotificationPortCreate( kIOMainPortDefault ) else { return }
		let relay = Unmanaged.passRetained( Relay( self ) )
		notifications.port  = port
		notifications.relay = relay
		CFRunLoopAddSource( CFRunLoopGetMain(), IONotificationPortGetRunLoopSource( port ).takeUnretainedValue(), .defaultMode )

		// Delivered on the main run loop, which the port's source was added to.
		let callback: IOServiceMatchingCallback = { refcon, iterator in
			// Drain the iterator to re-arm the notification.
			while case let service = IOIteratorNext( iterator ), service != 0 {
				IOObjectRelease( service )
			}
			guard let refcon else { return }
			let relay = Unmanaged<Relay>.fromOpaque( refcon ).takeUnretainedValue()
			MainActor.assumeIsolated { relay.watcher?.scheduleList() }
		}
		for type in [ kIOFirstMatchNotification, kIOTerminatedNotification ] {
			var iterator: io_iterator_t = 0
			guard let matching = IOServiceMatching( kIOSerialBSDServiceValue ),
				  IOServiceAddMatchingNotification( port, type, matching, callback, relay.toOpaque(), &iterator ) == KERN_SUCCESS else { continue }
			while case let service = IOIteratorNext( iterator ), service != 0 {
				IOObjectRelease( service )
			}
			notifications.iterators.append( iterator )
		}
	}

	/// A board that restarts removes one port and adds another within moments; report once.
	private func scheduleList() {
		pendingList?.cancel()
		pendingList = Task { [weak self] in
			try? await Task.sleep( for: .milliseconds( 250 ) )
			guard !Task.isCancelled, let self else { return }
			changed( SerialPortInfo.current() )
		}
	}
}
