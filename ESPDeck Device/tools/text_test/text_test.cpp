// Checks src/Text.cpp on the Mac: the JSON nesting pre-scan, device-name validation and log
// sanitizing. Run with run.sh; it prints each failure and exits non-zero if there are any.
#include <cstdio>
#include <cstring>
#include <string>

#include "Text.h"

namespace {
	int failures = 0;

	void check( bool condition, const char *what ) {
		if( !condition ) {
			printf( "FAIL: %s\n", what );
			failures++;
		}
	}

	bool depthOK( const std::string &json, int maxDepth = 8 ) {
		return Text::jsonDepthWithin( json.data(), json.size(), maxDepth );
	}

	std::string nested( int depth ) {
		return std::string( depth, '[' ) + std::string( depth, ']' );
	}
}

int main() {
	// JSON nesting
	check( depthOK( "{\"type\":\"show\",\"key\":0}" ), "flat object" );
	check( depthOK( "{\"type\":\"hello\",\"deck\":{\"connected\":true},\"cached\":[\"ab\"]}" ), "two levels" );
	check( depthOK( nested( 8 ) ), "depth 8 allowed" );
	check( !depthOK( nested( 9 ) ), "depth 9 refused" );
	check( !depthOK( nested( 300 ) ), "depth 300 refused" );
	check( !depthOK( "{\"a\":" + nested( 20 ) + "}" ), "deep value refused" );
	check( depthOK( "{\"a\":\"" + std::string( 50, '[' ) + "\"}" ), "brackets in a string ignored" );
	check( depthOK( "{\"a\":\"\\\"" + std::string( 50, '{' ) + "\"}" ), "escaped quote keeps the string open" );
	check( !depthOK( "{\"a\":\"\\\\\"" + nested( 20 ) + "}" ), "escaped backslash ends the string" );
	check( depthOK( "" ), "empty" );
	check( depthOK( "]]]]{}" ), "unbalanced closers are cJSON's problem" );
	check( !depthOK( "[[[[[", 4 ), "unterminated nesting refused" );

	// Names
	check( Text::isValidName( "Office Deck", 32 ), "plain name" );
	check( Text::isValidName( "Küche", 32 ), "accented name" );
	check( Text::isValidName( "Deck \xF0\x9F\x8E\x9B", 32 ), "emoji" );
	check( Text::isValidName( "12345678901234567890123456789012", 32 ), "32 bytes" );
	check( !Text::isValidName( "123456789012345678901234567890123", 32 ), "33 bytes" );
	check( !Text::isValidName( "", 32 ), "empty name" );
	check( !Text::isValidName( nullptr, 32 ), "null name" );
	check( !Text::isValidName( "   ", 32 ), "only spaces" );
	check( !Text::isValidName( "a\nb", 32 ), "newline" );
	check( !Text::isValidName( "a\x1b[31m", 32 ), "escape sequence" );
	check( !Text::isValidName( "a\x7f", 32 ), "DEL" );
	check( !Text::isValidName( "a\xC2\x85", 32 ), "C1 control (NEL)" );
	check( !Text::isValidName( "a\xE2\x80\xAE" "b", 32 ), "right-to-left override" );
	check( !Text::isValidName( "a\xE2\x81\xA6" "b", 32 ), "bidirectional isolate" );
	check( !Text::isValidName( "a\xE2\x80\xA8" "b", 32 ), "line separator" );
	check( !Text::isValidName( "\xEF\xBB\xBF" "a", 32 ), "byte-order mark" );
	check( !Text::isValidName( "a\xC3", 32 ), "truncated sequence" );
	check( !Text::isValidName( "a\xC0\xAF", 32 ), "overlong slash" );
	check( !Text::isValidName( "a\xE0\x80\xAF", 32 ), "overlong three-byte" );
	check( !Text::isValidName( "a\xED\xA0\x80", 32 ), "surrogate" );
	check( !Text::isValidName( "a\xF4\x90\x80\x80", 32 ), "past U+10FFFF" );
	check( !Text::isValidName( "a\xFF", 32 ), "invalid lead byte" );
	check( !Text::isValidName( "a\x80", 32 ), "stray continuation byte" );

	// Log text
	char out[16];
	check( strcmp( Text::printable( "hello", out, sizeof( out ) ), "hello" ) == 0, "short text unchanged" );
	check( strcmp( Text::printable( "a\nb\x1b" "c\xC3\xA9", out, sizeof( out ) ), "a?b?c??" ) == 0, "controls and non-ASCII replaced" );
	check( strcmp( Text::printable( "0123456789abcdefghij", out, sizeof( out ) ), "0123456789ab..." ) == 0, "long text truncated" );
	check( strcmp( Text::printable( "0123456789abcde", out, sizeof( out ) ), "0123456789abcde" ) == 0, "exactly fits" );
	check( strcmp( Text::printable( nullptr, out, sizeof( out ) ), "" ) == 0, "null text" );
	char tiny[3];
	check( strcmp( Text::printable( "abcdef", tiny, sizeof( tiny ) ), "ab" ) == 0, "tiny buffer" );

	if( failures == 0 )
		printf( "Text: all checks passed\n" );
	return failures == 0 ? 0 : 1;
}
