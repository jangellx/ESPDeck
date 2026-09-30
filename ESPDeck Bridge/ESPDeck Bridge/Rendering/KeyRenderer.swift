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
	var labelOnTop  = false
	var unreachable = false
	/// Its last action failed: an orange triangle in the corner, for a few seconds.
	var failed      = false
	/// Arrow drawn inside the opening of `door.garage.open` while the door moves.
	var doorArrow   : String?
	/// Base color of the background gradient; nil is plain black.
	var background  : Color?
	/// Shortcut whose own icon is the artwork when no icon was dropped.
	var shortcutID  : String?
	/// Show Page Number: a page (its corner folded at the lower right) with this number on it,
	/// instead of `symbol`.
	var pageNumber  : Int?
}

/// A key image ready to send in the deck's format, plus an upright preview for the UI.
struct RenderedKey {
	let hash    : String
	let data    : Data
	let preview : UIImage
}

/// A key face as SwiftUI draws it, at deckKeyPixels points square.
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
				if face.labelOnTop { labelText }
				artwork
					.frame( maxWidth: .infinity, maxHeight: .infinity )
				if !face.labelOnTop { labelText }
			}
			.padding( 6 )
			.opacity( face.unreachable || face.failed ? 0.45 : 1 )   // so the triangle stands out

			// Orange for a failed action, over yellow for an accessory that isn't responding.
			if face.failed || face.unreachable {
				Image( systemName: "exclamationmark.triangle.fill" )
					.font( .system( size: face.failed ? 18 : 14 ) )
					.foregroundStyle( .black, face.failed ? .orange : .yellow )
					.frame( maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing )
					.padding( 4 )
			}
		}
		.frame( width: CGFloat( deckKeyPixels ), height: CGFloat( deckKeyPixels ) )
		.environment( \.colorScheme, .dark )
	}

	/// The label, when there is one, shrinking to fit one line.
	@ViewBuilder private var labelText: some View {
		if let label = face.label, !label.isEmpty {
			Text( label )
				.font( .system( size: 12, weight: .semibold ) )
				.foregroundStyle( .white )
				.lineLimit( 1 )
				.minimumScaleFactor( 0.6 )
		}
	}

	/// The icon image, else the page number, else the symbol in the tint.
	@ViewBuilder private var artwork: some View {
		if let icon {
			Image( uiImage: icon )
				.resizable()
				.scaledToFit()
		} else if let number = face.pageNumber {
			PageNumber( number: number, tint: face.tint )
				.padding( 4 )
		} else if let symbol = face.symbol {
			// Multicolor draws warning badges in yellow; everything else takes the tint.
			Image( systemName: symbol )
				.resizable()
				.scaledToFit()
				.symbolRenderingMode( symbol.contains( "trianglebadge" ) ? .multicolor : .monochrome )
				.foregroundStyle( face.tint )
				// Some symbols (lamp.ceiling, for one) draw filled in dark mode; keep the shapes
				// the picker shows.
				.environment( \.colorScheme, .light )
				.overlay {
					if let arrow = face.doorArrow {
						DoorArrow( symbol: arrow, tint: face.tint )
					}
				}
				.padding( 4 )
		}
	}
}

/// The page's number cut out of a rounded square, its lower-right corner folded over.
private struct PageNumber: View {
	let number : Int
	let tint   : Color

	var body: some View {
		GeometryReader { geometry in
			let side = min( geometry.size.width, geometry.size.height ) * 0.86
			let fold = side * 0.3
			ZStack {
				FoldedSquare( radius: side * 0.2, fold: fold )
					.fill( tint )
				Text( "\(number)" )
					.font( .system( size: side * ( number > 9 ? 0.5 : 0.62 ), weight: .bold, design: .rounded ) )
					.offset( x: -side * 0.03, y: -side * 0.03 )   // clear of the fold
					.blendMode( .destinationOut )                 // the key shows through
				// The flap, folded over the corner.
				Path { path in
					let x = side - fold, y = side - fold
					path.move( to: CGPoint( x: x, y: side ) )
					path.addLine( to: CGPoint( x: x, y: y + side * 0.05 ) )
					path.addQuadCurve( to: CGPoint( x: x + side * 0.05, y: y ), control: CGPoint( x: x, y: y ) )
					path.addLine( to: CGPoint( x: side, y: y ) )
					path.closeSubpath()
				}
				.fill( Color.black.opacity( 0.3 ) )
			}
			.compositingGroup()
			.frame( width: side, height: side )
			.frame( width: geometry.size.width, height: geometry.size.height )
		}
	}
}

/// A rounded square whose lower-right corner is cut off diagonally, where it folds.
private nonisolated struct FoldedSquare: Shape {
	var radius : CGFloat
	var fold   : CGFloat

	func path( in rect: CGRect ) -> Path {
		var path = Path()
		path.move( to: CGPoint( x: rect.minX + radius, y: rect.minY ) )
		path.addLine( to: CGPoint( x: rect.maxX - radius, y: rect.minY ) )
		path.addQuadCurve( to: CGPoint( x: rect.maxX, y: rect.minY + radius ), control: CGPoint( x: rect.maxX, y: rect.minY ) )
		path.addLine( to: CGPoint( x: rect.maxX, y: rect.maxY - fold ) )
		path.addLine( to: CGPoint( x: rect.maxX - fold, y: rect.maxY ) )
		path.addLine( to: CGPoint( x: rect.minX + radius, y: rect.maxY ) )
		path.addQuadCurve( to: CGPoint( x: rect.minX, y: rect.maxY - radius ), control: CGPoint( x: rect.minX, y: rect.maxY ) )
		path.addLine( to: CGPoint( x: rect.minX, y: rect.minY + radius ) )
		path.addQuadCurve( to: CGPoint( x: rect.minX + radius, y: rect.minY ), control: CGPoint( x: rect.minX, y: rect.minY ) )
		return path
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

/// Turns key faces into the images the deck is sent.
enum KeyRenderer {
	/// A face drawn at the deck's key size and encoded in its format; nil if drawing fails.
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

/// Encodes key images as the deck's BMP or JPEG, with its transform applied.
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

	/// JPEG at 92% quality.
	static func jpeg( from image: CGImage, size: Int, transform: KeyTransform ) -> Data? {
		guard var rgba = pixels( of: image, size: size, transform: transform ) else { return nil }
		let transformed = rgba.withUnsafeMutableBytes { buffer -> CGImage? in
			bitmapContext( buffer.baseAddress, size: size )?.makeImage()
		}
		return transformed.flatMap { UIImage( cgImage: $0 ).jpegData( compressionQuality: 0.92 ) }
	}

	/// RGBX pixels, top row first, scaled to `size` and transformed for the panel.
	private static func pixels( of image: CGImage, size: Int, transform: KeyTransform ) -> [UInt8]? {
		var source = [UInt8]( repeating: 0, count: size * size * 4 )

		let drawn = source.withUnsafeMutableBytes { buffer -> Bool in
			guard let context = bitmapContext( buffer.baseAddress, size: size ) else { return false }
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

	/// An sRGB RGBX bitmap context, `size` pixels square, over `data`.
	private static func bitmapContext( _ data: UnsafeMutableRawPointer?, size: Int ) -> CGContext? {
		CGContext( data: data, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
				   space: CGColorSpace( name: CGColorSpace.sRGB )!,
				   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue )
	}
}
