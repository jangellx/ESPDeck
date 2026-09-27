// The cryptography of pairing and authenticated sessions (PROTOCOL.md, "Security"). Only
// mbedTLS, no ESP-IDF, so tools/crypto_test builds exactly this file on the Mac and checks
// it against RFC 7748 and CryptoKit.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>

namespace Crypto {
	constexpr size_t kKeySize   = 32;   // X25519 keys, shared secrets, K, S, proofs
	constexpr size_t kNonceSize = 16;
	constexpr size_t kMACSize   = 16;   // frame MACs are HMAC-SHA256 truncated to 16 bytes

	constexpr uint8_t kFromBridge = 0x01;   // frame MAC direction bytes
	constexpr uint8_t kFromDevice = 0x02;

	// An mbedTLS random number generator.
	using Random = int (*)( void *context, unsigned char *out, size_t length );

	// One byte string of a concatenation. Strings are their UTF-8 bytes, without a terminator.
	struct Part {
		Part( const void *bytes, size_t size ) : data( bytes ), length( size ) {}
		Part( const char *text ) : data( text ), length( strlen( text ) ) {}

		const void *data;
		size_t      length;
	};

	void sha256( const void *data, size_t length, uint8_t out[32] );
	void hmac( const uint8_t *key, size_t keyLength, std::initializer_list<Part> parts, uint8_t out[32] );

	// X25519 per RFC 7748: 32-byte little-endian strings, as CryptoKit's rawRepresentation.
	// makeKeyPair() fills privateKey with random bytes and derives the public key.
	bool makeKeyPair( uint8_t privateKey[32], uint8_t publicKey[32], Random random, void *context );
	bool publicKey( const uint8_t privateKey[32], uint8_t publicKey[32], Random random, void *context );
	bool sharedSecret( const uint8_t privateKey[32], const uint8_t peerPublicKey[32], uint8_t shared[32], Random random, void *context );

	// Pairing: the 6-digit code (plus terminator), K, and the pairConfirm proof.
	void pairingCode( const uint8_t shared[32], char code[7] );
	void pairingKey( const uint8_t shared[32], const char *bridgeID, const char *deviceID, uint8_t key[32] );
	void pairConfirmProof( const uint8_t key[32], uint8_t proof[32] );

	// Authentication handshake and session key.
	void bridgeProof( const uint8_t key[32], const uint8_t deviceNonce[16], const uint8_t bridgeNonce[16], uint8_t proof[32] );
	void deviceProof( const uint8_t key[32], const uint8_t bridgeNonce[16], const uint8_t deviceNonce[16], const uint8_t helloHash[32], uint8_t proof[32] );
	void sessionKey( const uint8_t key[32], const uint8_t deviceNonce[16], const uint8_t bridgeNonce[16], uint8_t session[32] );

	// First 16 bytes of HMAC( S, direction ‖ counter (64-bit big-endian) ‖ payload ).
	void frameMAC( const uint8_t session[32], uint8_t direction, uint64_t counter, const void *payload, size_t length, uint8_t mac[16] );

	// Constant-time comparison.
	bool equal( const uint8_t *a, const uint8_t *b, size_t length );

	// Lowercase hex; out holds 2 × length + 1 characters.
	void toHex( const uint8_t *data, size_t length, char *out );
	// Exactly 2 × length hex characters, either case.
	bool fromHex( const char *hex, uint8_t *out, size_t length );
}
