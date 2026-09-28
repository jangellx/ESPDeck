// Checks on text that comes from outside: JSON from the network, device names, Wi-Fi network
// names, and strings headed for the log (which Improv clients read on the serial port). No ESP-IDF, so
// tools/text_test builds exactly this file on the Mac.
#pragma once

#include <cstddef>

namespace Text {
	// Whether the JSON's arrays and objects nest no deeper than maxDepth, so cJSON's
	// recursive parser can't run out of stack. Brackets inside strings don't count.
	bool jsonDepthWithin( const char *json, size_t length, int maxDepth );

	// A device name: 1 to maxBytes bytes of valid UTF-8 without control characters (C0, DEL,
	// C1, line and paragraph separators, bidirectional overrides, the byte-order mark), and
	// not only spaces.
	bool isValidName( const char *name, size_t maxBytes );

	// A copy for the log: printable ASCII only (anything else becomes '?'), truncated to fit
	// out with "..." at the end. Returns out; a null text gives "".
	const char *printable( const char *text, char *out, size_t size );

	// A copy to show someone (a Wi-Fi network name, say): valid UTF-8, with each invalid
	// byte and each control character (as isValidName() defines them) replaced by '?',
	// cut at a character boundary to fit out. Returns out; a null text gives "".
	const char *displayable( const char *text, char *out, size_t size );
}
