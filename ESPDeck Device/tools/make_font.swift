// Generates src/Font.h: anti-aliased, proportional bitmap fonts for the text the firmware
// draws on keys itself (setup mode, pairing, the countdown), rendered from Inter by Rasmus
// Andersson (SIL Open Font License 1.1), a typeface in the spirit of San Francisco.
//
//   Label       Inter SemiBold 15 px, printable ASCII: labels on keys up to 80 px
//   LabelLarge  Inter SemiBold 19 px, printable ASCII: labels on 96 px and larger keys
//   LabelSmall  Inter SemiBold 12 px, printable ASCII: labels too wide for Label (72 px keys)
//   Big         Inter Display SemiBold 34 px, digits: the pairing code and the countdown
//
// Glyphs are 4 bits per pixel (16 levels of coverage), packed two to a byte, row-major,
// high nibble first. The script downloads the pinned Inter release, checks its SHA-256, and
// renders the glyphs with Core Text; the font files aren't kept in this repository.
//
//   swift tools/make_font.swift > src/Font.h
//   swift tools/make_font.swift --preview     (prints the glyphs as ASCII art instead)

import CoreGraphics
import CoreText
import CryptoKit
import Foundation

let version  = "4.1"
let archive  = URL( string: "https://github.com/rsms/inter/releases/download/v\(version)/Inter-\(version).zip" )!
let checksum = "9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e"
let preview  = CommandLine.arguments.contains( "--preview" )

struct Spec {
	let name  : String
	let file  : String
	let size  : CGFloat
	let first : Character
	let last  : Character
}

let specs = [
	Spec( name: "Label",      file: "extras/ttf/Inter-SemiBold.ttf",        size: 15, first: " ", last: "~" ),
	Spec( name: "LabelLarge", file: "extras/ttf/Inter-SemiBold.ttf",        size: 19, first: " ", last: "~" ),
	Spec( name: "LabelSmall", file: "extras/ttf/Inter-SemiBold.ttf",        size: 12, first: " ", last: "~" ),
	Spec( name: "Big",        file: "extras/ttf/InterDisplay-SemiBold.ttf", size: 34, first: "0", last: "9" ),
]

func fail( _ message: String ) -> Never {
	FileHandle.standardError.write( Data( "make_font: \(message)\n".utf8 ) )
	exit( 1 )
}

func run( _ tool: String, _ arguments: [String] ) {
	let process = Process()
	process.executableURL = URL( fileURLWithPath: tool )
	process.arguments     = arguments
	do { try process.run() } catch { fail( "\(tool): \(error)" ) }
	process.waitUntilExit()
	if process.terminationStatus != 0 { fail( "\(tool) failed" ) }
}

// Download, verify, unpack.
let work = FileManager.default.temporaryDirectory.appendingPathComponent( "inter-\(UUID().uuidString)" )
try? FileManager.default.createDirectory( at: work, withIntermediateDirectories: true )
defer { try? FileManager.default.removeItem( at: work ) }

let zip = work.appendingPathComponent( "inter.zip" )
run( "/usr/bin/curl", [ "-sSfL", "-o", zip.path, archive.absoluteString ] )
guard let data = try? Data( contentsOf: zip ) else { fail( "download failed" ) }
let digest = SHA256.hash( data: data ).map { String( format: "%02x", $0 ) }.joined()
if digest != checksum { fail( "unexpected SHA-256 \(digest)" ) }
run( "/usr/bin/unzip", [ "-q", zip.path, "-d", work.path ] )

guard let license = try? String( contentsOf: work.appendingPathComponent( "LICENSE.txt" ), encoding: .utf8 ) else { fail( "no LICENSE.txt" ) }
let copyright = license.split( separator: "\n" ).first.map( String.init ) ?? ""

struct Glyph {
	var width   = 0
	var height  = 0
	var left    = 0     // pixels from the pen position to the bitmap's left edge
	var top     = 0     // pixels from the baseline up to the bitmap's top row
	var advance = 0
	var levels  : [UInt8] = []   // 0–15, row-major
}

struct Rendered {
	let spec       : Spec
	let glyphs     : [Glyph]
	let ascent     : Int
	let lineHeight : Int
	let capHeight  : Int
}

func render( _ spec: Spec ) -> Rendered {
	let url = work.appendingPathComponent( spec.file )
	guard let provider = CGDataProvider( url: url as CFURL ), let graphicsFont = CGFont( provider ) else { fail( "can't load \(spec.file)" ) }
	let font = CTFontCreateWithGraphicsFont( graphicsFont, spec.size, nil, nil )

	var glyphs: [Glyph] = []
	let firstCode = spec.first.unicodeScalars.first!.value
	let lastCode  = spec.last.unicodeScalars.first!.value
	for code in firstCode...lastCode {
		var character = UniChar( code )
		var cgGlyph   = CGGlyph( 0 )
		guard CTFontGetGlyphsForCharacters( font, &character, &cgGlyph, 1 ) else { fail( "no glyph for \(code) in \(spec.file)" ) }

		var advance = CGSize.zero
		CTFontGetAdvancesForGlyphs( font, .horizontal, &cgGlyph, &advance, 1 )
		var bounds = CGRect.zero
		CTFontGetBoundingRectsForGlyphs( font, .horizontal, &cgGlyph, &bounds, 1 )

		var glyph     = Glyph()
		glyph.advance = Int( advance.width.rounded() )
		guard !bounds.isEmpty else {   // the space
			glyphs.append( glyph )
			continue
		}

		let minX = Int( floor( bounds.minX ) ), maxX = Int( ceil( bounds.maxX ) )
		let minY = Int( floor( bounds.minY ) ), maxY = Int( ceil( bounds.maxY ) )
		glyph.width  = maxX - minX
		glyph.height = maxY - minY
		glyph.left   = minX
		glyph.top    = maxY

		// White on black in an 8-bit gray context; memory row 0 is the top row.
		var pixels = [UInt8]( repeating: 0, count: glyph.width * glyph.height )
		pixels.withUnsafeMutableBytes { buffer in
			guard let context = CGContext( data: buffer.baseAddress, width: glyph.width, height: glyph.height, bitsPerComponent: 8,
										   bytesPerRow: glyph.width, space: CGColorSpaceCreateDeviceGray(),
										   bitmapInfo: CGImageAlphaInfo.none.rawValue ) else { fail( "no context" ) }
			context.setAllowsAntialiasing( true )
			context.setShouldAntialias( true )
			context.setAllowsFontSmoothing( false )
			context.setFillColor( gray: 1, alpha: 1 )
			var position = CGPoint( x: -CGFloat( minX ), y: -CGFloat( minY ) )
			CTFontDrawGlyphs( font, &cgGlyph, &position, 1, context )
		}
		glyph.levels = pixels.map { UInt8( ( Int( $0 ) * 15 + 127 ) / 255 ) }
		glyphs.append( glyph )
	}

	let ascent  = CTFontGetAscent( font ), descent = CTFontGetDescent( font )
	return Rendered( spec: spec, glyphs: glyphs, ascent: Int( ascent.rounded() ),
					 lineHeight: Int( ( ascent + descent ).rounded() ), capHeight: Int( CTFontGetCapHeight( font ).rounded() ) )
}

let fonts = specs.map( render )

if preview {
	let shades = Array( " .:-=+*#%@" )
	for font in fonts {
		print( "== \(font.spec.name) (\(font.spec.size) px): line \(font.lineHeight), ascent \(font.ascent), cap \(font.capHeight)" )
		for ( index, glyph ) in font.glyphs.enumerated() where glyph.width > 0 {
			let character = Character( UnicodeScalar( font.spec.first.unicodeScalars.first!.value + UInt32( index ) )! )
			print( "'\(character)' \(glyph.width)×\(glyph.height) left \(glyph.left) top \(glyph.top) advance \(glyph.advance)" )
			for row in 0..<glyph.height {
				print( String( ( 0..<glyph.width ).map { shades[Int( glyph.levels[row * glyph.width + $0] ) * ( shades.count - 1 ) / 15] } ) )
			}
		}
	}
	exit( 0 )
}

// Header.
var out = """
// Generated by tools/make_font.swift from Inter \(version); don't edit.
// Regenerate with: swift tools/make_font.swift > src/Font.h
//
// Inter by Rasmus Andersson. \(copyright)
// Licensed under the SIL Open Font License, Version 1.1 (https://openfontlicense.org).
//
// Glyph bitmaps are 4 bits per pixel, packed two per byte, row-major, high nibble first.
#pragma once

#include <cstdint>

struct FontGlyph {
	uint16_t offset;    // into the font's bitmap, in bytes
	uint8_t  width;
	uint8_t  height;
	int8_t   left;      // from the pen position to the bitmap's left edge
	int8_t   top;       // from the baseline up to the bitmap's top row
	uint8_t  advance;
};

struct Font {
	char             first;
	char             last;
	uint8_t          ascent;
	uint8_t          lineHeight;
	uint8_t          capHeight;
	const FontGlyph *glyphs;
	const uint8_t   *bitmap;
};


"""

for font in fonts {
	var bitmap: [UInt8] = []
	var entries: [String] = []
	for glyph in font.glyphs {
		let offset = bitmap.count
		var nibbles = glyph.levels
		if nibbles.count % 2 == 1 { nibbles.append( 0 ) }
		for index in stride( from: 0, to: nibbles.count, by: 2 ) {
			bitmap.append( nibbles[index] << 4 | nibbles[index + 1] )
		}
		entries.append( "\t{ \(offset), \(glyph.width), \(glyph.height), \(glyph.left), \(glyph.top), \(glyph.advance) }," )
	}
	let name = font.spec.name
	out += "// \(name): \(font.spec.file.split( separator: "/" ).last!) at \(Int( font.spec.size )) px\n"
	out += "constexpr uint8_t k\(name)Bitmap[] = {\n"
	for chunkStart in stride( from: 0, to: bitmap.count, by: 24 ) {
		let chunk = bitmap[chunkStart..<min( chunkStart + 24, bitmap.count )]
		out += "\t" + chunk.map { String( format: "0x%02x,", $0 ) }.joined( separator: " " ) + "\n"
	}
	out += "};\n\nconstexpr FontGlyph k\(name)Glyphs[] = {\n" + entries.joined( separator: "\n" ) + "\n};\n\n"
	let first = font.spec.first == "'" ? "\\'" : String( font.spec.first )
	let last  = font.spec.last == "'" ? "\\'" : String( font.spec.last )
	out += "constexpr Font k\(name)Font = { '\(first)', '\(last)', \(font.ascent), \(font.lineHeight), \(font.capHeight), k\(name)Glyphs, k\(name)Bitmap };\n\n"
}

print( out, terminator: "" )
