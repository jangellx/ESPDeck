#include "Crypto.h"

#include <cstdio>

#include "mbedtls/ecp.h"
#include "mbedtls/md.h"
#include "mbedtls/sha256.h"

namespace {
	// X25519's base point, u = 9.
	constexpr uint8_t kBasePoint[32] = { 9 };

	// scalar × point on Curve25519. The scalar is clamped as RFC 7748 specifies (mbedTLS
	// insists on a clamped private key; X25519 clamps anyway, so the result is the same).
	bool x25519( const uint8_t scalar[32], const uint8_t point[32], uint8_t out[32], Crypto::Random random, void *context ) {
		uint8_t clamped[32];
		memcpy( clamped, scalar, sizeof( clamped ) );
		clamped[0]  &= 248;
		clamped[31] &= 127;
		clamped[31] |= 64;

		mbedtls_ecp_group group;
		mbedtls_ecp_point input, result;
		mbedtls_mpi       d;
		mbedtls_ecp_group_init( &group );
		mbedtls_ecp_point_init( &input );
		mbedtls_ecp_point_init( &result );
		mbedtls_mpi_init( &d );

		size_t written = 0;
		bool   ok      = mbedtls_ecp_group_load( &group, MBEDTLS_ECP_DP_CURVE25519 ) == 0
		                 && mbedtls_mpi_read_binary_le( &d, clamped, sizeof( clamped ) ) == 0
		                 && mbedtls_ecp_point_read_binary( &group, &input, point, 32 ) == 0
		                 && mbedtls_ecp_mul( &group, &result, &d, &input, random, context ) == 0
		                 && mbedtls_ecp_point_write_binary( &group, &result, MBEDTLS_ECP_PF_UNCOMPRESSED, &written, out, 32 ) == 0
		                 && written == 32;

		mbedtls_mpi_free( &d );
		mbedtls_ecp_point_free( &result );
		mbedtls_ecp_point_free( &input );
		mbedtls_ecp_group_free( &group );
		memset( clamped, 0, sizeof( clamped ) );

		// An all-zero result means a low-order peer key; CryptoKit rejects those too.
		uint8_t any = 0;
		for( int i = 0; ok && i < 32; i++ )
			any |= out[i];
		return ok && any;
	}
}

namespace Crypto {

// MARK: - Hashes

void sha256( const void *data, size_t length, uint8_t out[32] ) {
	mbedtls_sha256( (const unsigned char *)data, length, out, 0 );
}

void hmac( const uint8_t *key, size_t keyLength, std::initializer_list<Part> parts, uint8_t out[32] ) {
	mbedtls_md_context_t context;
	mbedtls_md_init( &context );
	mbedtls_md_setup( &context, mbedtls_md_info_from_type( MBEDTLS_MD_SHA256 ), 1 );
	mbedtls_md_hmac_starts( &context, key, keyLength );
	for( const Part &part : parts )
		mbedtls_md_hmac_update( &context, (const unsigned char *)part.data, part.length );
	mbedtls_md_hmac_finish( &context, out );
	mbedtls_md_free( &context );
}

// MARK: - X25519

bool makeKeyPair( uint8_t privateKey[32], uint8_t publicKey[32], Random random, void *context ) {
	return random( context, privateKey, 32 ) == 0 && Crypto::publicKey( privateKey, publicKey, random, context );
}

bool publicKey( const uint8_t privateKey[32], uint8_t publicKey[32], Random random, void *context ) {
	return x25519( privateKey, kBasePoint, publicKey, random, context );
}

bool sharedSecret( const uint8_t privateKey[32], const uint8_t peerPublicKey[32], uint8_t shared[32], Random random, void *context ) {
	return x25519( privateKey, peerPublicKey, shared, random, context );
}

// MARK: - Pairing and sessions

void pairingCode( const uint8_t shared[32], char code[7] ) {
	uint8_t digest[32];
	uint8_t input[17 + 32];
	memcpy( input, "espdeck-pair-code", 17 );
	memcpy( input + 17, shared, 32 );
	sha256( input, sizeof( input ), digest );

	uint32_t value = ( (uint32_t)digest[0] << 24 ) | ( (uint32_t)digest[1] << 16 ) | ( (uint32_t)digest[2] << 8 ) | digest[3];
	snprintf( code, 7, "%06u", (unsigned)( value % 1000000 ) );
}

void pairingKey( const uint8_t shared[32], const char *bridgeID, const char *deviceID, uint8_t key[32] ) {
	hmac( shared, 32, { "espdeck-pairing-key", bridgeID, deviceID }, key );
}

void pairConfirmProof( const uint8_t key[32], uint8_t proof[32] ) {
	hmac( key, 32, { "espdeck-pair-confirm" }, proof );
}

void bridgeProof( const uint8_t key[32], const uint8_t deviceNonce[16], const uint8_t bridgeNonce[16], uint8_t proof[32] ) {
	hmac( key, 32, { "espdeck-bridge", Part( deviceNonce, 16 ), Part( bridgeNonce, 16 ) }, proof );
}

void deviceProof( const uint8_t key[32], const uint8_t bridgeNonce[16], const uint8_t deviceNonce[16], const uint8_t helloHash[32], uint8_t proof[32] ) {
	hmac( key, 32, { "espdeck-device", Part( bridgeNonce, 16 ), Part( deviceNonce, 16 ), Part( helloHash, 32 ) }, proof );
}

void sessionKey( const uint8_t key[32], const uint8_t deviceNonce[16], const uint8_t bridgeNonce[16], uint8_t session[32] ) {
	hmac( key, 32, { "espdeck-session", Part( deviceNonce, 16 ), Part( bridgeNonce, 16 ) }, session );
}

void frameMAC( const uint8_t session[32], uint8_t direction, uint64_t counter, const void *payload, size_t length, uint8_t mac[16] ) {
	uint8_t header[9] = { direction };
	for( int i = 0; i < 8; i++ )
		header[1 + i] = (uint8_t)( counter >> ( 56 - 8 * i ) );

	uint8_t full[32];
	hmac( session, 32, { Part( header, sizeof( header ) ), Part( payload, length ) }, full );
	memcpy( mac, full, 16 );
}

// MARK: - Utilities

bool equal( const uint8_t *a, const uint8_t *b, size_t length ) {
	uint8_t difference = 0;
	for( size_t i = 0; i < length; i++ )
		difference |= a[i] ^ b[i];
	return difference == 0;
}

void toHex( const uint8_t *data, size_t length, char *out ) {
	static const char digits[] = "0123456789abcdef";
	for( size_t i = 0; i < length; i++ ) {
		out[i * 2]     = digits[data[i] >> 4];
		out[i * 2 + 1] = digits[data[i] & 0x0F];
	}
	out[length * 2] = '\0';
}

static int hexValue( char c ) {
	if( c >= '0' && c <= '9' ) return c - '0';
	if( c >= 'a' && c <= 'f' ) return c - 'a' + 10;
	if( c >= 'A' && c <= 'F' ) return c - 'A' + 10;
	return -1;
}

bool fromHex( const char *hex, uint8_t *out, size_t length ) {
	if( !hex || strlen( hex ) != length * 2 )
		return false;
	for( size_t i = 0; i < length; i++ ) {
		int high = hexValue( hex[i * 2] );
		int low  = hexValue( hex[i * 2 + 1] );
		if( high < 0 || low < 0 )
			return false;
		out[i] = (uint8_t)( ( high << 4 ) | low );
	}
	return true;
}

}
