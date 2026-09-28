//
//  Zlib.swift
//  ESPDeckMenuBar
//
//  zlib-format compression (RFC 1950) for the ROM bootloader's compressed flash writes.
//  Apple's COMPRESSION_ZLIB is raw deflate (RFC 1951), so the two-byte header and the
//  Adler-32 trailer, which the ROM checks, are added here.
//

import Compression
import Foundation

nonisolated enum Zlib {
	static func compress( _ data: Data ) -> Data? {
		guard !data.isEmpty else { return nil }
		// Incompressible data grows a little; leave room for that.
		let capacity = data.count + data.count / 16 + 1024
		var deflated = Data( count: capacity )
		let size = deflated.withUnsafeMutableBytes { output in
			data.withUnsafeBytes { input in
				compression_encode_buffer( output.bindMemory( to: UInt8.self ).baseAddress!, capacity,
										   input.bindMemory( to: UInt8.self ).baseAddress!, data.count, nil, COMPRESSION_ZLIB )
			}
		}
		guard size > 0 else { return nil }

		var result = Data( [ 0x78, 0x9C ] )   // deflate, 32 KB window, default level; a multiple of 31
		result.append( deflated.prefix( size ) )
		var adler = adler32( data ).bigEndian
		withUnsafeBytes( of: &adler ) { result.append( contentsOf: $0 ) }
		return result
	}

	static func adler32( _ data: Data ) -> UInt32 {
		var a: UInt32 = 1
		var b: UInt32 = 0
		data.withUnsafeBytes { buffer in
			var bytes = buffer.bindMemory( to: UInt8.self )[...]
			// 5552 bytes is the most that can be summed before the 32-bit sums could overflow.
			while !bytes.isEmpty {
				for byte in bytes.prefix( 5552 ) {
					a += UInt32( byte )
					b += a
				}
				bytes = bytes.dropFirst( 5552 )
				a %= 65521
				b %= 65521
			}
		}
		return b << 16 | a
	}
}
