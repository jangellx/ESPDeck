// Writes the Liquid Glass app icon as an Icon Composer package (AppIcon.icon): the same
// design as make_app_icon.swift (a Stream Deck Mini's 3 × 2 keys, the bottom-center one lit
// amber with a house), split into layers the system renders as glass: the five keys, the lit
// key, and the house. The background is the icon's fill. Open AppIcon.icon in Icon Composer
// to tune glass, specular, shadows and the dark and tinted looks.
//
// The icon has been tuned in Icon Composer, so an existing icon.json (those settings) is kept:
// running this again only redraws the layer images. Delete icon.json to start over.
//
//   swift tools/make_app_icon_layers.swift

import AppKit

let size: CGFloat = 1024
let output = URL( fileURLWithPath: CommandLine.arguments.first! ).deletingLastPathComponent()
	.appendingPathComponent( "../ESPDeck Bridge/AppIcon.icon" ).standardized
let assets = output.appendingPathComponent( "Assets" )

// The keys' layout, as in make_app_icon.swift.
let key: CGFloat = 236, gap: CGFloat = 58, radius: CGFloat = 52
let originX = ( size - ( key * 3 + gap * 2 ) ) / 2
let originY = ( size - ( key * 2 + gap ) ) / 2

/// A key's square, by row and column from the top left.
func keyRect( row: Int, col: Int ) -> CGRect {
	CGRect( x: originX + CGFloat( col ) * ( key + gap ), y: originY + CGFloat( row ) * ( key + gap ), width: key, height: key )
}

/// The house on the lit key, as in make_app_icon.swift.
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

/// A path as SVG path data (top-left origin, as drawn).
func svgPath( _ path: CGPath ) -> String {
	var data = ""
	func p( _ point: CGPoint ) -> String { String( format: "%.2f %.2f", point.x, point.y ) }
	path.applyWithBlock { element in
		let points = element.pointee.points
		switch element.pointee.type {
			case .moveToPoint:         data += "M\( p( points[0] ) ) "
			case .addLineToPoint:      data += "L\( p( points[0] ) ) "
			case .addQuadCurveToPoint: data += "Q\( p( points[0] ) ) \( p( points[1] ) ) "
			case .addCurveToPoint:     data += "C\( p( points[0] ) ) \( p( points[1] ) ) \( p( points[2] ) ) "
			case .closeSubpath:        data += "Z "
			@unknown default:          break
		}
	}
	return data
}

/// A 1024-point SVG with `body` inside, and a vertical gradient named "g" from `top` to `bottom`.
func svg( _ body: String, top: String, bottom: String ) -> String {
	"""
	<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
	<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(top)"/><stop offset="1" stop-color="\(bottom)"/></linearGradient></defs>
	\(body)
	</svg>

	"""
}

func roundedKey( _ rect: CGRect, fill: String ) -> String {
	String( format: "<rect x=\"%.0f\" y=\"%.0f\" width=\"%.0f\" height=\"%.0f\" rx=\"%.0f\" fill=\"%@\"/>", rect.minX, rect.minY, rect.width, rect.height, radius, fill )
}

try? FileManager.default.removeItem( at: assets )
try! FileManager.default.createDirectory( at: assets, withIntermediateDirectories: true )

// The five unlit keys; each has its own gradient top to bottom.
var keys = ""
for row in 0..<2 {
	for col in 0..<3 where !( row == 1 && col == 1 ) {
		keys += roundedKey( keyRect( row: row, col: col ), fill: "url(#g)" ) + "\n"
	}
}
try! svg( keys, top: "#55555A", bottom: "#3C3C40" ).write( to: assets.appendingPathComponent( "Keys.svg" ), atomically: true, encoding: .utf8 )

// The lit key.
let lit = keyRect( row: 1, col: 1 )
try! svg( roundedKey( lit, fill: "url(#g)" ), top: "#FFC247", bottom: "#FF9500" )
	.write( to: assets.appendingPathComponent( "Lit Key.svg" ), atomically: true, encoding: .utf8 )

// The house on it.
let houseData = svgPath( house( in: lit.insetBy( dx: key * 0.24, dy: key * 0.25 ) ) )
try! svg( "<path fill=\"#2A1A00\" fill-rule=\"evenodd\" d=\"\(houseData)\"/>", top: "#2A1A00", bottom: "#2A1A00" )
	.write( to: assets.appendingPathComponent( "House.svg" ), atomically: true, encoding: .utf8 )

// Front to back: the house, the lit key, the keys. The fill is the dark deck behind them.
let json = """
{
  "fill-specializations" : [
    {
      "value" : {
        "automatic-gradient" : "extended-srgb:0.22745,0.22745,0.24314,1.00000"
      }
    },
    {
      "appearance" : "dark",
      "value" : {
        "automatic-gradient" : "extended-srgb:0.11765,0.11765,0.12941,1.00000"
      }
    }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "House.svg",
          "name" : "House"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.3
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    },
    {
      "layers" : [
        {
          "glass" : true,
          "image-name" : "Lit Key.svg",
          "name" : "Lit Key"
        }
      ],
      "shadow" : {
        "kind" : "layer-color",
        "opacity" : 0.6
      },
      "specular" : true,
      "translucency" : {
        "enabled" : true,
        "value" : 0.2
      }
    },
    {
      "layers" : [
        {
          "glass" : true,
          "image-name" : "Keys.svg",
          "name" : "Keys"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "specular" : true,
      "translucency" : {
        "enabled" : true,
        "value" : 0.4
      }
    }
  ],
  "supported-platforms" : {
    "squares" : "shared"
  }
}

"""
let settings = output.appendingPathComponent( "icon.json" )
if FileManager.default.fileExists( atPath: settings.path ) {
	print( "Kept the tuned icon.json; redrew the layers in \(assets.path)" )
} else {
	try! json.write( to: settings, atomically: true, encoding: .utf8 )
	print( "Wrote \(output.path)" )
}
