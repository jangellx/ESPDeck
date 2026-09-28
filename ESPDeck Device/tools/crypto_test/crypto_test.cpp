// Prints the pairing and session test vectors computed by src/Crypto.cpp (built against the
// mbedTLS sources that ship with ESP-IDF). crypto_test.swift computes the same values with
// ESPDeck Bridge's own DeckCrypto (CryptoKit), and run.sh checks that both match
// vectors.txt. See run.sh.
#include <cstdio>
#include <cstring>

#include "Crypto.h"

namespace {
	// RFC 7748 §6.1
	const char *kAlicePrivate = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a";
	const char *kBobPrivate   = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb";

	// The rest are made up. Alice is the Mac, Bob the ESP32.
	const char *kBridgeID     = "0c6e0a52-1f6b-4b8e-9f1a-2b3c4d5e6f70";
	const char *kDeviceID     = "f4:12:fa:00:00:01";
	const char *kMacPairNonce = "202122232425262728292a2b2c2d2e2f";
	const char *kDevPairNonce = "303132333435363738393a3b3c3d3e3f";
	const char *kDeviceNonce  = "000102030405060708090a0b0c0d0e0f";
	const char *kBridgeNonce  = "101112131415161718191a1b1c1d1e1f";
	const char *kHello        = "{\"type\":\"hello\",\"protocol\":4,\"id\":\"f4:12:fa:00:00:01\"}";
	const char *kFrame        = "{\"type\":\"show\",\"key\":0,\"hash\":\"9f86d081884c7d659a2feaa0c55ad015\"}";
	const char *kOTAPassword  = "correct-horse-battery";
	const uint64_t kOTACounter = 5;

	// Deterministic "random" bytes: the RNG only blinds the scalar multiplication.
	int fakeRandom( void *, unsigned char *out, size_t length ) {
		for( size_t i = 0; i < length; i++ )
			out[i] = (unsigned char)( i * 37 + 11 );
		return 0;
	}

	void print( const char *name, const uint8_t *data, size_t length ) {
		char hex[129];
		Crypto::toHex( data, length, hex );
		printf( "%s=%s\n", name, hex );
	}

	// Hex parsing takes exactly two hex digits per byte and nothing else.
	bool strictHex() {
		const char *bad[] = { "+f", "-1", " f", "f ", "0x", "g0", "f", "" };
		uint8_t     byte  = 0;
		for( const char *text : bad ) {
			if( Crypto::fromHex( text, &byte, 1 ) )
				return false;
		}
		uint8_t two[2];
		return Crypto::fromHex( "0aFf", two, 2 ) && two[0] == 0x0A && two[1] == 0xFF;
	}
}

int main() {
	uint8_t alice[32], bob[32], alicePublic[32], bobPublic[32], sharedA[32], sharedB[32];
	Crypto::fromHex( kAlicePrivate, alice, 32 );
	Crypto::fromHex( kBobPrivate, bob, 32 );
	if( !Crypto::publicKey( alice, alicePublic, fakeRandom, nullptr ) || !Crypto::publicKey( bob, bobPublic, fakeRandom, nullptr )
	    || !Crypto::sharedSecret( bob, alicePublic, sharedB, fakeRandom, nullptr ) || !Crypto::sharedSecret( alice, bobPublic, sharedA, fakeRandom, nullptr ) ) {
		printf( "X25519 failed\n" );
		return 1;
	}
	if( memcmp( sharedA, sharedB, 32 ) != 0 ) {
		printf( "shared secrets differ\n" );
		return 1;
	}

	uint8_t macPairNonce[16], devicePairNonce[16], deviceNonce[16], bridgeNonce[16], helloHash[32];
	Crypto::fromHex( kMacPairNonce, macPairNonce, 16 );
	Crypto::fromHex( kDevPairNonce, devicePairNonce, 16 );
	Crypto::fromHex( kDeviceNonce, deviceNonce, 16 );
	Crypto::fromHex( kBridgeNonce, bridgeNonce, 16 );

	char    code[7];
	uint8_t commitment[32], key[32], confirm[32], bridgeProof[32], deviceProof[32], session[32], mac[16];
	bool    ok = Crypto::sha256( kHello, strlen( kHello ), helloHash )
	             && Crypto::pairCommitment( devicePairNonce, bobPublic, alicePublic, commitment )
	             && Crypto::pairingCode( alicePublic, bobPublic, macPairNonce, devicePairNonce, code )
	             && Crypto::pairingKey( sharedB, alicePublic, bobPublic, macPairNonce, devicePairNonce, kBridgeID, kDeviceID, key )
	             && Crypto::pairConfirmProof( key, confirm )
	             && Crypto::bridgeProof( key, deviceNonce, bridgeNonce, bridgeProof )
	             && Crypto::deviceProof( key, bridgeNonce, deviceNonce, helloHash, deviceProof )
	             && Crypto::sessionKey( key, deviceNonce, bridgeNonce, session );
	if( !ok ) {
		printf( "a derivation failed\n" );
		return 1;
	}

	print( "macPublicKey", alicePublic, 32 );
	print( "devicePublicKey", bobPublic, 32 );
	print( "sharedSecret", sharedB, 32 );
	print( "pairCommitment", commitment, 32 );
	printf( "code=%s\n", code );
	print( "K", key, 32 );
	print( "pairConfirmProof", confirm, 32 );
	print( "helloSHA256", helloHash, 32 );
	print( "bridgeProof", bridgeProof, 32 );
	print( "deviceProof", deviceProof, 32 );
	print( "S", session, 32 );
	Crypto::frameMAC( session, Crypto::kFromBridge, 0, kFrame, strlen( kFrame ), mac );
	print( "macFromBridgeCounter0", mac, 16 );
	Crypto::frameMAC( session, Crypto::kFromBridge, 1, kFrame, strlen( kFrame ), mac );
	print( "macFromBridgeCounter1", mac, 16 );
	Crypto::frameMAC( session, Crypto::kFromDevice, 0, kFrame, strlen( kFrame ), mac );
	print( "macFromDeviceCounter0", mac, 16 );
	Crypto::frameMAC( session, Crypto::kFromDevice, 0x0102030405060708ull, kFrame, strlen( kFrame ), mac );
	print( "macFromDeviceCounter0102030405060708", mac, 16 );

	// devOTA: the password's SHA-256, sealed for Mac → ESP32 frame 5 of the session.
	uint8_t passwordHash[32], sealed[Crypto::kSealedHash], opened[32];
	if( !Crypto::sha256( kOTAPassword, strlen( kOTAPassword ), passwordHash ) || !Crypto::sealDevOTA( session, kOTACounter, passwordHash, sealed ) ) {
		printf( "sealing failed\n" );
		return 1;
	}
	print( "devOTAPasswordHash", passwordHash, 32 );
	print( "devOTASealedCounter5", sealed, sizeof( sealed ) );
	bool opens    = Crypto::openDevOTA( session, kOTACounter, sealed, opened ) && memcmp( opened, passwordHash, 32 ) == 0;
	bool wrongCtr = Crypto::openDevOTA( session, kOTACounter + 1, sealed, opened );
	sealed[3] ^= 0x01;
	bool tampered = Crypto::openDevOTA( session, kOTACounter, sealed, opened );
	printf( "devOTAOpens=%s\n", opens ? "yes" : "no" );
	printf( "devOTARejectsOtherCounter=%s\n", wrongCtr ? "no" : "yes" );
	printf( "devOTARejectsTampering=%s\n", tampered ? "no" : "yes" );
	printf( "strictHex=%s\n", strictHex() ? "yes" : "no" );
	return 0;
}
