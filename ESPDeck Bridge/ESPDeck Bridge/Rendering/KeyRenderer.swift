//
//  KeyRenderer.swift
//  ESPDeck Bridge
//
//  Draws a key face in SwiftUI and converts it to the image the deck expects: any key
//  size, BMP or JPEG, with the deck's transform applied.
//

import CryptoKit
import SwiftUI

/// Key faces are laid out at this size in points and rendered at the deck's own key
/// size in pixels, so every model gets the same design.
let deckKeyPixels = 80

/// Everything that determines how one key looks.
struct KeyFace: Equatable {
	var iconName    : String?
	var symbol      : String?
	var tint        : Color = .white
	var label       : String?
	var unreachable = false
	/// Arrow drawn inside the opening of `door.garage.open` while the door moves.
	var doorArrow   : String?
	/// Base color of the background gradient; nil is plain black.
	var background  : Color?
	/// Shortcut whose own icon is the artwork when no icon was dropped.
	var shortcutID  : String?
}

/// A key image ready to send in the deck's format, plus an upright preview for the UI.
struct RenderedKey {
	let hash    : String
	let data    : Data
	let preview : UIImage
}

struct KeyFaceView: View {
	let face : KeyFace
	let icon : UIImage?

	var body: some View {
		ZStack {
			if let background = face.background {
				LinearGradient( colors: [ background.adjusted( brightness: 1.25 ), background.adjusted( brightness: 0.55 ) ],
								startPoint: .top, endPoint: .bottom )
			} else {
				Color.black
			}

			VStack( spacing: 2 ) {
				artwork
					.frame( maxWidth: .infinity, maxHeight: .infinity )

				if let label = face.label, !label.isEmpty {
					Text( label )
						.font( .system( size: 12, weight: .semibold ) )
						.foregroundStyle( .white )
						.lineLimit( 1 )
						.minimumScaleFactor( 0.6 )
				}
			}
			.padding( 6 )
			.opacity( face.unreachable ? 0.45 : 1 )

			if face.unreachable {
				Image( systemName: "exclamationmark.triangle.fill" )
					.font( .system( size: 14 ) )
					.foregroundStyle( .yellow )
					.frame( maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing )
					.padding( 4 )
			}
		}
		.frame( width: CGFloat( deckKeyPixels ), height: CGFloat( deckKeyPixels ) )
		.environment( \.colorScheme, .dark )
	}

	@ViewBuilder private var artwork: some View {
		if let icon {
			Image( uiImage: icon )
				.resizable()
				.scaledToFit()
		} else if let symbol = face.symbol {
			// Multicolor draws warning badges in yellow; everything else takes the tint.
			Image( systemName: symbol )
				.resizable()
				.scaledToFit()
				.symbolRenderingMode( symbol.contains( "trianglebadge" ) ? .multicolor : .monochrome )
				.foregroundStyle( face.tint )
				.overlay {
					if let arrow = face.doorArrow {
						DoorArrow( symbol: arrow, tint: face.tint )
					}
				}
				.padding( 4 )
		}
	}
}

/// Places an arrow in the open part of `door.garage.open`: horizontally centered,
/// bottom-aligned, and 80% of the opening's height. The opening spans 32%–96% of the
/// symbol's height as SwiftUI lays it out (measured from a render).
private struct DoorArrow: View {
	let symbol : String
	let tint   : Color

	private static let openingTop    = 0.32
	private static let openingBottom = 0.96
	private static let scale         = 0.8

	var body: some View {
		GeometryReader { geometry in
			let height = geometry.size.height * ( Self.openingBottom - Self.openingTop ) * Self.scale
			Image( systemName: symbol )
				.resizable()
				.scaledToFit()
				.fontWeight( .bold )
				.foregroundStyle( tint )
				.frame( width: geometry.size.width, height: height )
				.offset( y: geometry.size.height * Self.openingBottom - height )
		}
	}
}

enum KeyRenderer {
	static func render( _ face: KeyFace, icon: UIImage?, layout: DeckLayout ) -> RenderedKey? {
		let renderer = ImageRenderer( content: KeyFaceView( face: face, icon: icon ) )
		renderer.scale        = CGFloat( layout.keySize ) / CGFloat( deckKeyPixels )
		renderer.proposedSize = ProposedViewSize( width: CGFloat( deckKeyPixels ), height: CGFloat( deckKeyPixels ) )
		guard let image = renderer.cgImage else { return nil }

		// A deck without displays (the Pedal) still gets a preview for the UI.
		let data: Data?
		switch layout.format {
			case .bmp:  data = KeyImageEncoder.bmp( from: image, size: layout.keySize, transform: layout.transform )
			case .jpeg: data = KeyImageEncoder.jpeg( from: image, size: layout.keySize, transform: layout.transform )
			case .none: data = Data()
		}
		guard let data else { return nil }

		return RenderedKey( hash: hash( of: data ), data: data, preview: UIImage( cgImage: image ) )
	}

	/// First 16 bytes of the SHA-256, as lowercase hex. See PROTOCOL.md.
	static func hash( of data: Data ) -> String {
		SHA256.hash( data: data ).prefix( 16 ).map { String( format: "%02x", $0 ) }.joined()
	}
}

enum KeyImageEncoder {
	/// 24-bit bottom-up BMP.
	static func bmp( from image: CGImage, size: Int, transform: KeyTransform ) -> Data? {
		guard let rgba = pixels( of: image, size: size, transform: transform ) else { return nil }

		let rowBytes   = ( size * 3 + 3 ) & ~3
		let pixelBytes = rowBytes * size
		let headerSize = 54
		var bmp        = Data( capacity: headerSize + pixelBytes )

		func append16( _ value: UInt16 ) { withUnsafeBytes( of: value.littleEndian ) { bmp.append( contentsOf: $0 ) } }
		func append32( _ value: UInt32 ) { withUnsafeBytes( of: value.littleEndian ) { bmp.append( contentsOf: $0 ) } }

		// BITMAPFILEHEADER
		bmp.append( contentsOf: [ 0x42, 0x4D ] )          // "BM"
		append32( UInt32( headerSize + pixelBytes ) )
		append32( 0 )
		append32( UInt32( headerSize ) )
		// BITMAPINFOHEADER
		append32( 40 )
		append32( UInt32( size ) )
		append32( UInt32( size ) )                        // positive height: bottom-up rows
		append16( 1 )
		append16( 24 )
		append32( 0 )                                     // BI_RGB
		append32( UInt32( pixelBytes ) )
		append32( 2835 )                                  // 72 dpi
		append32( 2835 )
		append32( 0 )
		append32( 0 )

		let padding = [UInt8]( repeating: 0, count: rowBytes - size * 3 )
		for y in stride( from: size - 1, through: 0, by: -1 ) {
			for x in 0..<size {
				let offset = ( y * size + x ) * 4
				bmp.append( contentsOf: [ rgba[offset + 2], rgba[offset + 1], rgba[offset] ] )   // BGR
			}
			bmp.append( contentsOf: padding )
		}
		return bmp
	}

	static func jpeg( from image: CGImage, size: Int, transform: KeyTransform ) -> Data? {
		guard var rgba = pixels( of: image, size: size, transform: transform ) else { return nil }
		let transformed = rgba.withUnsafeMutableBytes { buffer -> CGImage? in
			CGContext( data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
					   space: CGColorSpace( name: CGColorSpace.sRGB )!,
					   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue )?.makeImage()
		}
		return transformed.flatMap { UIImage( cgImage: $0 ).jpegData( compressionQuality: 0.92 ) }
	}

	/// RGBX pixels, top row first, scaled to `size` and transformed for the panel.
	private static func pixels( of image: CGImage, size: Int, transform: KeyTransform ) -> [UInt8]? {
		let bytesPerRow = size * 4
		var source      = [UInt8]( repeating: 0, count: bytesPerRow * size )

		let drawn = source.withUnsafeMutableBytes { buffer -> Bool in
			guard let context = CGContext( data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
										   space: CGColorSpace( name: CGColorSpace.sRGB )!,
										   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue ) else { return false }
			context.setFillColor( CGColor( gray: 0, alpha: 1 ) )
			context.fill( CGRect( x: 0, y: 0, width: size, height: size ) )
			context.interpolationQuality = .high
			context.draw( image, in: CGRect( x: 0, y: 0, width: size, height: size ) )
			return true
		}
		guard drawn else { return nil }
		guard transform != .none else { return source }

		var output = [UInt8]( repeating: 0, count: source.count )
		let last   = size - 1
		for y in 0..<size {
			for x in 0..<size {
				// Source pixel for output pixel (x, y); see PROTOCOL.md.
				let ( sx, sy ): ( Int, Int ) = switch transform {
					case .none:      ( x, y )
					case .transpose: ( y, x )
					case .rotate90:  ( y, last - x )
					case .rotate270: ( last - y, x )
					case .rotate180: ( last - x, last - y )
				}
				let from = ( sy * size + sx ) * 4
				let to   = ( y * size + x ) * 4
				output[to]     = source[from]
				output[to + 1] = source[from + 1]
				output[to + 2] = source[from + 2]
				output[to + 3] = 255
			}
		}
		return output
	}
}
