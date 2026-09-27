//
//  DroppedImage.swift
//  ESPDeck Bridge
//
//  Image data dragged in from Finder, browsers, or other apps.
//

import CoreTransferable
import UniformTypeIdentifiers

struct DroppedImage: Transferable {
	let data: Data

	static var transferRepresentation: some TransferRepresentation {
		// Browsers and most apps offer the image itself.
		DataRepresentation( importedContentType: .image ) { data in
			DroppedImage( data: data )
		}
		// Finder offers a file.
		FileRepresentation( importedContentType: .image ) { received in
			DroppedImage( data: try Data( contentsOf: received.file ) )
		}
		// Anything else that resolves to a local file URL.
		ProxyRepresentation { ( url: URL ) in
			guard url.isFileURL else { throw CocoaError( .fileReadUnsupportedScheme ) }
			return DroppedImage( data: try Data( contentsOf: url ) )
		}
	}
}
