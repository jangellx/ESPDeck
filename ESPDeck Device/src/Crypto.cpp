#include "Crypto.h"

#include <cstdio>

#include "mbedtls/ecp.h"
#include "mbedtls/gcm.h"
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

	// counter as 8 bytes, big-endian.
	void putBigEndian64( uint64_t counter, uint8_t out[8] ) {
		for( int i = 0; i < 8; i++ )
			out[i] = (uint8_t)( counter >> ( 56 - 8 * i ) );
	}

	// One hex digit's value, or -1 if it isn't one.
	int hexValue( char c ) {
		if( c >= '0' && c <= '9' ) return c - '0';
		if( c >= 'a' && c <= 'f' ) return c - 'a' + 10;
		if( c >= 'A' && c <= 'F' ) return c - 'A' + 10;
		return -1;
	}
}

namespace Crypto {

// MARK: - Hashes

bool sha256( const void *data, size_t length, uint8_t out[32] ) {
	return mbedtls_sha256( (const unsigned char *)data, length, out, 0 ) == 0;
}

bool hmac( const uint8_t *key, size_t keyLength, std::initializer_list<Part> parts, uint8_t out[32] ) {
	mbedtls_md_context_t context;
	mbedtls_md_init( &context );
	bool ok = mbedtls_md_setup( &context, mbedtls_md_info_from_type( MBEDTLS_MD_SHA256 ), 1 ) == 0
	          && mbedtls_md_hmac_starts( &context, key, keyLength ) == 0;
	for( const Part &part : parts )
		ok = ok && mbedtls_md_hmac_update( &context, (const unsigned char *)part.data, part.length ) == 0;
	ok = ok && mbedtls_md_hmac_finish( &context, out ) == 0;
	mbedtls_md_free( &context );
	if( !ok )
		memset( out, 0, 32 );
	return ok;
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

// MARK: - Pairing

bool pairCommitment( const uint8_t deviceNonce[16], const uint8_t devicePublic[32], const uint8_t macPublic[32], uint8_t commitment[32] ) {
	return hmac( deviceNonce, 16, { "espdeck-pair-commit", Part( devicePublic, 32 ), Part( macPublic, 32 ) }, commitment );
}

bool pairingCode( const uint8_t macPublic[32], const uint8_t devicePublic[32], const uint8_t macNonce[16], const uint8_t deviceNonce[16], char code[7] ) {
	constexpr size_t kLabel = 20;   // "espdeck-pair-code-v4"
	uint8_t input[kLabel + 32 + 32 + 16 + 16];
	uint8_t digest[32];
	memcpy( input, "espdeck-pair-code-v4", kLabel );
	memcpy( input + kLabel, macPublic, 32 );
	memcpy( input + kLabel + 32, devicePublic, 32 );
	memcpy( input + kLabel + 64, macNonce, 16 );
	memcpy( input + kLabel + 80, deviceNonce, 16 );
	if( !sha256( input, sizeof( input ), digest ) ) {
		code[0] = '\0';
		return false;
	}

	uint32_t value = ( (uint32_t)digest[0] << 24 ) | ( (uint32_t)digest[1] << 16 ) | ( (uint32_t)digest[2] << 8 ) | digest[3];
	snprintf( code, 7, "%06u", (unsigned)( value % 1000000 ) );
	return true;
}

bool pairingKey( const uint8_t shared[32], const uint8_t macPublic[32], const uint8_t devicePublic[32], const uint8_t macNonce[16],
                 const uint8_t deviceNonce[16], const char *bridgeID, const char *deviceID, uint8_t key[32] ) {
	return hmac( shared, 32, { "espdeck-pairing-key-v4", Part( macPublic, 32 ), Part( devicePublic, 32 ), Part( macNonce, 16 ),
	                           Part( deviceNonce, 16 ), bridgeID, deviceID }, key );
}

bool pairConfirmProof( const uint8_t key[32], uint8_t proof[32] ) {
	return hmac( key, 32, { "espdeck-pair-confirm" }, proof );
}

// MARK: - Sessions

bool bridgeProof( const uint8_t key[32], const uint8_t deviceNonce[16], const uint8_t bridgeNonce[16], uint8_t proof[32] ) {
	return hmac( key, 32, { "espdeck-bridge", Part( deviceNonce, 16 ), Part( bridgeNonce, 16 ) }, proof );
}

bool deviceProof( const uint8_t key[32], const uint8_t bridgeNonce[16], const uint8_t deviceNonce[16], const uint8_t helloHash[32], uint8_t proof[32] ) {
	return hmac( key, 32, { "espdeck-device", Part( bridgeNonce, 16 ), Part( deviceNonce, 16 ), Part( helloHash, 32 ) }, proof );
}

bool sessionKey( const uint8_t key[32], const uint8_t deviceNonce[16], const uint8_t bridgeNonce[16], uint8_t session[32] ) {
	return hmac( key, 32, { "espdeck-session", Part( deviceNonce, 16 ), Part( bridgeNonce, 16 ) }, session );
}

bool frameMAC( const uint8_t session[32], uint8_t direction, uint64_t counter, const void *payload, size_t length, uint8_t mac[16] ) {
	uint8_t header[9] = { direction };
	putBigEndian64( counter, header + 1 );

	uint8_t full[32];
	bool    ok = hmac( session, 32, { Part( header, sizeof( header ) ), Part( payload, length ) }, full );
	memcpy( mac, full, 16 );
	return ok;
}

// MARK: - devOTA

namespace {
	// Key and nonce for devOTA's password hash: the nonce is the Mac → ESP32 direction byte,
	// three zero bytes, and the frame counter, big-endian.
	bool devOTAParameters( const uint8_t session[32], uint64_t counter, uint8_t key[32], uint8_t nonce[12] ) {
		memset( nonce, 0, 12 );
		nonce[0] = kFromBridge;
		putBigEndian64( counter, nonce + 4 );
		return hmac( session, 32, { "espdeck-devota" }, key );
	}
}

bool sealDevOTA( const uint8_t session[32], uint64_t counter, const uint8_t hash[32], uint8_t sealed[kSealedHash] ) {
	uint8_t key[32], nonce[12];
	bool    ok = devOTAParameters( session, counter, key, nonce );

	mbedtls_gcm_context gcm;
	mbedtls_gcm_init( &gcm );
	ok = ok && mbedtls_gcm_setkey( &gcm, MBEDTLS_CIPHER_ID_AES, key, 256 ) == 0
	     && mbedtls_gcm_crypt_and_tag( &gcm, MBEDTLS_GCM_ENCRYPT, 32, nonce, sizeof( nonce ), nullptr, 0, hash, sealed, kTagSize, sealed + 32 ) == 0;
	mbedtls_gcm_free( &gcm );
	memset( key, 0, sizeof( key ) );
	return ok;
}

bool openDevOTA( const uint8_t session[32], uint64_t counter, const uint8_t sealed[kSealedHash], uint8_t hash[32] ) {
	uint8_t key[32], nonce[12];
	bool    ok = devOTAParameters( session, counter, key, nonce );

	mbedtls_gcm_context gcm;
	mbedtls_gcm_init( &gcm );
	ok = ok && mbedtls_gcm_setkey( &gcm, MBEDTLS_CIPHER_ID_AES, key, 256 ) == 0
	     && mbedtls_gcm_auth_decrypt( &gcm, 32, nonce, sizeof( nonce ), nullptr, 0, sealed + 32, kTagSize, sealed, hash ) == 0;
	mbedtls_gcm_free( &gcm );
	memset( key, 0, sizeof( key ) );
	if( !ok )
		memset( hash, 0, 32 );
	return ok;
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
