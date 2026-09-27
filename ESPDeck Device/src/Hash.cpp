#include "Hash.h"

#include <cstring>

#include "mbedtls/sha256.h"

void hashToHex( const Hash &hash, char *out ) {
	static const char digits[] = "0123456789abcdef";
	for( size_t i = 0; i < hash.size(); i++ ) {
		out[i * 2]     = digits[hash[i] >> 4];
		out[i * 2 + 1] = digits[hash[i] & 0x0F];
	}
	out[hash.size() * 2] = '\0';
}

static int hexValue( char c ) {
	if( c >= '0' && c <= '9' ) return c - '0';
	if( c >= 'a' && c <= 'f' ) return c - 'a' + 10;
	if( c >= 'A' && c <= 'F' ) return c - 'A' + 10;
	return -1;
}

bool hashFromHex( const char *hex, Hash &out ) {
	if( !hex || strlen( hex ) != kHashSize * 2 )
		return false;

	for( size_t i = 0; i < kHashSize; i++ ) {
		int high = hexValue( hex[i * 2] );
		int low  = hexValue( hex[i * 2 + 1] );
		if( high < 0 || low < 0 )
			return false;
		out[i] = (uint8_t)( ( high << 4 ) | low );
	}
	return true;
}

Hash hashOf( const uint8_t *data, size_t length ) {
	uint8_t digest[32];
	mbedtls_sha256( data, length, digest, 0 );

	Hash hash;
	memcpy( hash.data(), digest, hash.size() );
	return hash;
}
