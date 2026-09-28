#include "Text.h"

#include <cstdint>
#include <cstring>

namespace Text {

bool jsonDepthWithin( const char *json, size_t length, int maxDepth ) {
	int  depth    = 0;
	bool inString = false;
	for( size_t i = 0; i < length; i++ ) {
		char c = json[i];
		if( inString ) {
			if( c == '\\' )
				i++;   // skips the escaped character, so \" doesn't end the string
			else if( c == '"' )
				inString = false;
		} else if( c == '"' ) {
			inString = true;
		} else if( c == '[' || c == '{' ) {
			if( ++depth > maxDepth )
				return false;
		} else if( c == ']' || c == '}' ) {
			depth--;
		}
	}
	return true;
}

namespace {
	// Decodes one UTF-8 sequence at text[0…], rejecting overlong forms, surrogates and
	// anything past U+10FFFF. Returns its length, or 0 if it's invalid.
	size_t decode( const uint8_t *text, size_t available, uint32_t &codePoint ) {
		uint8_t lead = text[0];
		size_t  length;
		uint32_t minimum;
		if( lead < 0x80 ) {
			codePoint = lead;
			return 1;
		} else if( ( lead & 0xE0 ) == 0xC0 ) {
			length = 2, minimum = 0x80, codePoint = lead & 0x1F;
		} else if( ( lead & 0xF0 ) == 0xE0 ) {
			length = 3, minimum = 0x800, codePoint = lead & 0x0F;
		} else if( ( lead & 0xF8 ) == 0xF0 ) {
			length = 4, minimum = 0x10000, codePoint = lead & 0x07;
		} else {
			return 0;
		}
		if( length > available )
			return 0;
		for( size_t i = 1; i < length; i++ ) {
			if( ( text[i] & 0xC0 ) != 0x80 )
				return 0;
			codePoint = ( codePoint << 6 ) | ( text[i] & 0x3F );
		}
		if( codePoint < minimum || codePoint > 0x10FFFF || ( codePoint >= 0xD800 && codePoint <= 0xDFFF ) )
			return 0;
		return length;
	}

	bool isControl( uint32_t c ) {
		return c < 0x20 || ( c >= 0x7F && c <= 0x9F )
		       || c == 0x2028 || c == 0x2029                  // line and paragraph separators
		       || ( c >= 0x202A && c <= 0x202E )              // bidirectional embeddings and overrides
		       || ( c >= 0x2066 && c <= 0x2069 )              // bidirectional isolates
		       || c == 0xFEFF;                                // byte-order mark
	}
}

bool isValidName( const char *name, size_t maxBytes ) {
	if( !name )
		return false;
	size_t length = strlen( name );
	if( length == 0 || length > maxBytes )
		return false;

	const uint8_t *bytes      = (const uint8_t *)name;
	bool           hasVisible = false;
	for( size_t i = 0; i < length; ) {
		uint32_t codePoint;
		size_t   size = decode( bytes + i, length - i, codePoint );
		if( size == 0 || isControl( codePoint ) )
			return false;
		if( codePoint != ' ' )
			hasVisible = true;
		i += size;
	}
	return hasVisible;
}

const char *printable( const char *text, char *out, size_t size ) {
	if( size == 0 )
		return out;
	out[0] = '\0';
	if( !text )
		return out;

	size_t length = strlen( text );
	size_t fits   = length < size ? length : size - 1;
	bool   cut    = fits < length && size > 4;
	if( cut )
		fits = size - 4;
	for( size_t i = 0; i < fits; i++ ) {
		unsigned char c = (unsigned char)text[i];
		out[i] = c >= 0x20 && c < 0x7F ? (char)c : '?';
	}
	if( cut ) {
		memcpy( out + fits, "...", 3 );
		fits += 3;
	}
	out[fits] = '\0';
	return out;
}

const char *displayable( const char *text, char *out, size_t size ) {
	if( size == 0 )
		return out;
	out[0] = '\0';
	if( !text )
		return out;

	const uint8_t *bytes  = (const uint8_t *)text;
	size_t         length = strlen( text );
	size_t         used   = 0;
	for( size_t i = 0; i < length; ) {
		uint32_t codePoint;
		size_t   bytesIn  = decode( bytes + i, length - i, codePoint );
		bool     keep     = bytesIn != 0 && !isControl( codePoint );
		size_t   bytesOut = keep ? bytesIn : 1;
		if( used + bytesOut > size - 1 )
			break;
		if( keep )
			memcpy( out + used, text + i, bytesIn );
		else
			out[used] = '?';
		used += bytesOut;
		i    += bytesIn != 0 ? bytesIn : 1;
	}
	out[used] = '\0';
	return out;
}

}
