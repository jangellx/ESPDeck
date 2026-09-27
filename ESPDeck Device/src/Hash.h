// Image hashes: the first 16 bytes of the SHA-256 of the image file, 32 hex characters on the wire.
#pragma once

#include <array>
#include <cstdint>
#include <cstddef>

#include "Config.h"

using Hash = std::array<uint8_t, kHashSize>;

// Writes 32 hex characters plus a terminator into out (33 bytes).
void hashToHex( const Hash &hash, char *out );

// Parses exactly 32 hex characters.
bool hashFromHex( const char *hex, Hash &out );

Hash hashOf( const uint8_t *data, size_t length );
