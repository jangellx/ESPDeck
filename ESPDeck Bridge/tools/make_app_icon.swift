// Draws the app icon's art as flat images: a Stream Deck Mini's 3 × 2 keys, with the
// bottom-center key lit amber and showing a house, light and dark, into the AppIconArt image
// set (the About page shows it; the Dock falls back to it). The app icon itself is
// AppIcon.icon, from make_app_icon_layers.swift. The house is drawn here rather than taken
// from SF Symbols, which can't be used in app icons.
//
//   swift tools/make_app_icon.swift

import AppKit

let size   : CGFloat = 1024
let output = URL( fileURLWithPath: CommandLine.arguments.first! ).deletingLastPathComponent()
	.appendingPathComponent( "../ESPDeck Bridge/Assets.xcassets/AppIconArt.imageset" ).standardized

struct Palette {
	var background : ( CGColor, CGColor )   // top, bottom
	var key        : ( CGColor, CGColor )
	var keyEdge    : CGColor
	var lit        : ( CGColor, CGColor )
	var glow       : CGColor
	var house      : CGColor
}

func rgb( _ hex: UInt32, _ alpha: CGFloat = 1 ) -> CGColor {
	CGColor( srgbRed: CGFloat( hex >> 16 & 0xff ) / 255, green: CGFloat( hex >> 8 & 0xff ) / 255, blue: CGFloat( hex & 0xff ) / 255, alpha: alpha )
}

func gray( _ white: CGFloat, _ alpha: CGFloat = 1 ) -> CGColor {
	CGColor( srgbRed: white, green: white, blue: white, alpha: alpha )
}

let light = Palette( background: ( rgb( 0x3a3a3e ), rgb( 0x1c1c1f ) ),
					 key: ( rgb( 0x55555a ), rgb( 0x3c3c40 ) ), keyEdge: gray( 1, 0.10 ),
					 lit: ( rgb( 0xffc247 ), rgb( 0xff9500 ) ), glow: rgb( 0xff9f0a, 0.55 ), house: rgb( 0x2a1a00 ) )

let dark = Palette( background: ( rgb( 0x1e1e21 ), rgb( 0x0a0a0b ) ),
					key: ( rgb( 0x3a3a3e ), rgb( 0x29292c ) ), keyEdge: gray( 1, 0.08 ),
					lit: ( rgb( 0xffc247 ), rgb( 0xff9500 ) ), glow: rgb( 0xff9f0a, 0.6 ), house: rgb( 0x2a1a00 ) )

func gradient( _ colors: ( CGColor, CGColor ) ) -> CGGradient {
	CGGradient( colorsSpace: CGColorSpace( name: CGColorSpace.sRGB ), colors: [ colors.0, colors.1 ] as CFArray, locations: [ 0, 1 ] )!
}

/// A house with a pitched roof and a door, fitted to `rect`, built from rounded strokes so it
/// matches the key's soft corners.
func house( in rect: CGRect ) -> CGPath {
	let path  = CGMutablePath()
	let w     = rect.width, h = rect.height
	let left  = rect.minX + w * 0.16, right = rect.maxX - w * 0.16
	let eaves = rect.minY + h * 0.47
	path.move( to: CGPoint( x: rect.minX, y: eaves + h * 0.06 ) )
	path.addLine( to: CGPoint( x: rect.midX, y: rect.minY ) )
	path.addLine( to: CGPoint( x: rect.maxX, y: eaves + h * 0.06 ) )
	let roof = path.copy( strokingWithWidth: w * 0.13, lineCap: .round, lineJoin: .round, miterLimit: 10 )

	let body = CGMutablePath()
	body.move( to: CGPoint( x: rect.midX, y: rect.minY + h * 0.14 ) )
	body.addLine( to: CGPoint( x: right, y: eaves ) )
	body.addLine( to: CGPoint( x: right, y: rect.maxY - w * 0.06 ) )
	body.addQuadCurve( to: CGPoint( x: right - w * 0.06, y: rect.maxY ), control: CGPoint( x: right, y: rect.maxY ) )
	body.addLine( to: CGPoint( x: left + w * 0.06, y: rect.maxY ) )
	body.addQuadCurve( to: CGPoint( x: left, y: rect.maxY - w * 0.06 ), control: CGPoint( x: left, y: rect.maxY ) )
	body.addLine( to: CGPoint( x: left, y: eaves ) )
	body.closeSubpath()

	let door = CGPath( roundedRect: CGRect( x: rect.midX - w * 0.10, y: rect.maxY - h * 0.34, width: w * 0.20, height: h * 0.34 + 1 ),
					   cornerWidth: w * 0.07, cornerHeight: w * 0.07, transform: nil )
	return roof.union( body ).subtracting( door )
}

func draw( _ palette: Palette, to name: String ) {
	let context = CGContext( data: nil, width: Int( size ), height: Int( size ), bitsPerComponent: 8, bytesPerRow: 0,
							 space: CGColorSpace( name: CGColorSpace.sRGB )!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue )!
	// Top-left origin, like the rest of the app's drawing code.
	context.translateBy( x: 0, y: size )
	context.scaleBy( x: 1, y: -1 )

	// Full-bleed square; the system applies the icon shape.
	context.drawLinearGradient( gradient( palette.background ), start: .zero, end: CGPoint( x: 0, y: size ), options: [] )

	// 3 × 2 keys, centered, the lit one bottom-center.
	let key: CGFloat = 236, gap: CGFloat = 58, radius: CGFloat = 52
	let originX = ( size - ( key * 3 + gap * 2 ) ) / 2
	let originY = ( size - ( key * 2 + gap ) ) / 2
	for row in 0..<2 {
		for col in 0..<3 {
			let rect   = CGRect( x: originX + CGFloat( col ) * ( key + gap ), y: originY + CGFloat( row ) * ( key + gap ), width: key, height: key )
			let shape  = CGPath( roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil )
			let isLit  = row == 1 && col == 1

			context.saveGState()
			if isLit {
				context.setShadow( offset: .zero, blur: 90, color: palette.glow )
				context.addPath( shape )
				context.setFillColor( palette.lit.1 )
				context.fillPath()
			}
			context.addPath( shape )
			context.clip()
			context.drawLinearGradient( gradient( isLit ? palette.lit : palette.key ), start: CGPoint( x: 0, y: rect.minY ), end: CGPoint( x: 0, y: rect.maxY ), options: [] )
			context.restoreGState()

			// A hairline highlight along the top edge.
			context.saveGState()
			context.addPath( CGPath( roundedRect: rect.insetBy( dx: 2, dy: 2 ), cornerWidth: radius - 2, cornerHeight: radius - 2, transform: nil ) )
			context.setStrokeColor( isLit ? gray( 1, 0.35 ) : palette.keyEdge )
			context.setLineWidth( 4 )
			context.strokePath()
			context.restoreGState()

			if isLit {
				context.addPath( house( in: rect.insetBy( dx: key * 0.24, dy: key * 0.25 ) ) )
				context.setFillColor( palette.house )
				context.fillPath()
			}
		}
	}

	let image = NSBitmapImageRep( cgImage: context.makeImage()! )
	try! image.representation( using: .png, properties: [:] )!.write( to: output.appendingPathComponent( name ) )
}

try! FileManager.default.createDirectory( at: output, withIntermediateDirectories: true )
draw( light, to: "AppIcon.png" )
draw( dark,  to: "AppIcon-Dark.png" )

let contents = """
{
  "images" : [
    { "filename" : "AppIcon.png", "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "AppIcon-Dark.png", "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try! contents.write( to: output.appendingPathComponent( "Contents.json" ), atomically: true, encoding: .utf8 )
print( "Wrote \(output.path)" )
