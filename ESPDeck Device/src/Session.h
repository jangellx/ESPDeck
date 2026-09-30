// One connection's security state (PROTOCOL.md, "Authentication handshake"): the device
// nonce and hello hash for the handshake, then the session key and the per-direction frame
// counters. Every connection starts unauthenticated; reset() starts over.
#pragma once

#include <cstddef>
#include <cstdint>

#include "Crypto.h"

class Session {
public:
	// A new connection: fresh nonce, unauthenticated.
	void reset();

	// This connection's device nonce, for the hello.
	const char *deviceNonceHex() const { return deviceNonceHex_; }

	// The exact bytes of the unauthenticated hello, for the device proof.
	bool recordHello( const char *text, size_t length );

	// Handshake step 3: checks the bridge's proof against K and, if it holds, fills in the
	// device proof and starts the session. False (and still unauthenticated) otherwise.
	bool authenticate( const uint8_t key[32], const uint8_t bridgeNonce[Crypto::kNonceSize], const uint8_t bridgeProof[32], uint8_t deviceProof[32] );

	// The handshake succeeded; frames carry MACs from here on.
	bool authenticated() const { return authenticated_; }

	// The MAC (32 hex characters) of the next outgoing text frame; the frame is this
	// followed by the JSON. Counts the frame as sent. False if it couldn't be computed.
	bool sealText( const char *json, size_t length, char mac[33] );

	// Verify and strip the MAC of an incoming frame: 32 hex characters before a text frame's
	// JSON, 16 bytes before a binary frame's payload. False means the connection must close.
	bool openText( const char *frame, size_t length, const char *&json );
	bool openBinary( const uint8_t *frame, size_t length, const uint8_t *&payload, size_t &payloadLength );

	// devOTA's sealed password hash, from the frame openText() opened last.
	bool openDevOTA( const uint8_t sealed[Crypto::kSealedHash], uint8_t hash[32] ) const;

private:
	bool     authenticated_                              = false;
	bool     haveHello_                                  = false;
	uint8_t  deviceNonce_[Crypto::kNonceSize]            = {};
	char     deviceNonceHex_[Crypto::kNonceSize * 2 + 1] = {};
	uint8_t  helloHash_[32]                              = {};
	uint8_t  sessionKey_[32]                             = {};
	uint64_t sent_                                       = 0;   // authenticated frames sent…
	uint64_t received_                                   = 0;   // …and received
};
