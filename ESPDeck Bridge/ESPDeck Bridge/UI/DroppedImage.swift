//
//  DroppedImage.swift
//  ESPDeck Bridge
//
//  Image data dragged in from Finder, browsers, or other apps. Only its bytes are read
//  here (and not at all past ConfigStore.iconFileLimit); decoding waits for iconPNG(),
//  which runs off the main thread.
//

import CoreTransferable
import UniformTypeIdentifiers

/// An image dropped on a key or an icon well, as bytes not yet decoded.
struct DroppedImage: Transferable {
	/// The image's bytes, or why they weren't read.
	let data: Result<Data, ConfigStore.IconProblem>

	static var transferRepresentation: some TransferRepresentation {
		// Browsers and most apps offer the image itself.
		DataRepresentation( importedContentType: .image ) { data in
			DroppedImage( data: data.count <= ConfigStore.iconFileLimit ? .success( data ) : .failure( .tooLarge ) )
		}
		// Finder offers a file.
		FileRepresentation( importedContentType: .image ) { received in
			try DroppedImage.read( received.file )
		}
		// Anything else that resolves to a local file URL.
		ProxyRepresentation { ( url: URL ) in
			guard url.isFileURL else { throw CocoaError( .fileReadUnsupportedScheme ) }
			return try DroppedImage.read( url )
		}
	}

	/// A local image file's bytes, unless it's larger than an icon file may be.
	private nonisolated static func read( _ url: URL ) throws -> DroppedImage {
		if let size = try url.resourceValues( forKeys: [ .fileSizeKey ] ).fileSize, size > ConfigStore.iconFileLimit {
			return DroppedImage( data: .failure( .tooLarge ) )
		}
		return DroppedImage( data: .success( try Data( contentsOf: url ) ) )
	}

	/// The icon to store: a PNG no larger than an icon, made off the main thread.
	@concurrent nonisolated func iconPNG() async -> Result<Data, ConfigStore.IconProblem> {
		data.flatMap { data in
			do {
				return .success( try ConfigStore.iconPNG( from: data ) )
			} catch let problem as ConfigStore.IconProblem {
				return .failure( problem )
			} catch {
				return .failure( .unreadable )
			}
		}
	}
}

extension DeckController {
	/// Sets a dropped image as one state's icon, once it has been made icon-sized.
	func setIcon( dropped: DroppedImage, device id: String, key: Int, state: KeyState ) {
		Task {
			switch await dropped.iconPNG() {
				case .success( let png ):     setIcon( data: png, device: id, key: key, state: state )
				case .failure( let problem ): lastError = BridgeProblem( "Image Not Added", problem.localizedDescription )
			}
		}
	}
}
