// Image hashes: the first 16 bytes of the SHA-256 of the image file, 32 hex characters on the wire.
#pragma once

#include <array>
#include <cstdint>
#include <cstddef>

#include "Config.h"

// An image's hash, as raw bytes.
using Hash = std::array<uint8_t, kHashSize>;

// hashToHex()'s output: 32 hex characters and a terminator.
constexpr size_t kHashHexSize = kHashSize * 2 + 1;

// Writes 32 hex characters plus a terminator into out (kHashHexSize bytes).
void hashToHex( const Hash &hash, char *out );

// Parses exactly 32 hex characters.
bool hashFromHex( const char *hex, Hash &out );

// The hash of an image file; false if it couldn't be computed.
bool hashOf( const uint8_t *data, size_t length, Hash &out );
