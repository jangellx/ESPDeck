#include "Session.h"

#include <cstring>

#include "esp_random.h"

void Session::reset() {
	authenticated_ = false;
	haveHello_     = false;
	sent_          = 0;
	received_      = 0;
	memset( sessionKey_, 0, sizeof( sessionKey_ ) );
	esp_fill_random( deviceNonce_, sizeof( deviceNonce_ ) );
	Crypto::toHex( deviceNonce_, sizeof( deviceNonce_ ), deviceNonceHex_ );
}

bool Session::recordHello( const char *text, size_t length ) {
	haveHello_ = Crypto::sha256( text, length, helloHash_ );
	return haveHello_;
}

bool Session::authenticate( const uint8_t key[32], const uint8_t bridgeNonce[16], const uint8_t bridgeProof[32], uint8_t deviceProof[32] ) {
	if( authenticated_ || !haveHello_ )
		return false;

	uint8_t expected[32];
	if( !Crypto::bridgeProof( key, deviceNonce_, bridgeNonce, expected ) || !Crypto::equal( expected, bridgeProof, sizeof( expected ) ) )
		return false;

	if( !Crypto::deviceProof( key, bridgeNonce, deviceNonce_, helloHash_, deviceProof )
	    || !Crypto::sessionKey( key, deviceNonce_, bridgeNonce, sessionKey_ ) ) {
		memset( sessionKey_, 0, sizeof( sessionKey_ ) );
		return false;
	}
	sent_          = 0;
	received_      = 0;
	authenticated_ = true;
	return true;
}

bool Session::sealText( const char *json, size_t length, char mac[33] ) {
	uint8_t bytes[Crypto::kMACSize];
	if( !authenticated_ || !Crypto::frameMAC( sessionKey_, Crypto::kFromDevice, sent_, json, length, bytes ) )
		return false;
	sent_++;
	Crypto::toHex( bytes, sizeof( bytes ), mac );
	return true;
}

bool Session::openText( const char *frame, size_t length, const char *&json ) {
	constexpr size_t kHexMAC = Crypto::kMACSize * 2;
	char    hex[kHexMAC + 1];
	uint8_t claimed[Crypto::kMACSize];
	if( !authenticated_ || length < kHexMAC )
		return false;
	memcpy( hex, frame, kHexMAC );
	hex[kHexMAC] = '\0';
	if( !Crypto::fromHex( hex, claimed, sizeof( claimed ) ) )
		return false;

	uint8_t expected[Crypto::kMACSize];
	if( !Crypto::frameMAC( sessionKey_, Crypto::kFromBridge, received_, frame + kHexMAC, length - kHexMAC, expected )
	    || !Crypto::equal( expected, claimed, sizeof( expected ) ) )
		return false;
	received_++;
	json = frame + kHexMAC;
	return true;
}

bool Session::openBinary( const uint8_t *frame, size_t length, const uint8_t *&payload, size_t &payloadLength ) {
	if( !authenticated_ || length < Crypto::kMACSize )
		return false;

	uint8_t expected[Crypto::kMACSize];
	if( !Crypto::frameMAC( sessionKey_, Crypto::kFromBridge, received_, frame + Crypto::kMACSize, length - Crypto::kMACSize, expected )
	    || !Crypto::equal( expected, frame, sizeof( expected ) ) )
		return false;
	received_++;
	payload       = frame + Crypto::kMACSize;
	payloadLength = length - Crypto::kMACSize;
	return true;
}

bool Session::openDevOTA( const uint8_t sealed[Crypto::kSealedHash], uint8_t hash[32] ) const {
	return authenticated_ && received_ > 0 && Crypto::openDevOTA( sessionKey_, received_ - 1, sealed, hash );
}
