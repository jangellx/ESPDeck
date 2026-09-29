// Key images the ESP32 draws itself (the setup-mode QR codes and labels), rendered into an
// RGB888 canvas and encoded the way the Mac encodes its images: the deck's transform applied,
// then a 24-bit bottom-up BMP or a JPEG.
#pragma once

#include <cstddef>
#include <cstdint>

#include "StreamDeck.h"

struct Font;

class KeyImage {
public:
	enum class TextStyle : uint8_t {
		Label,   // Inter SemiBold, sized for the key
		Big,     // large Inter Display digits (pairing code, countdown); falls back to Label
	};

	~KeyImage();

	// Allocates a size × size canvas (and the encoder's buffers). Safe to call again with a
	// different size.
	bool begin( uint16_t size ) { return begin( size, size ); }
	// A width × height canvas, for a deck's extra screen (the Neo's info bar, the +'s touch
	// strip). Only None and Rotate180 transforms suit one that isn't square.
	bool begin( uint16_t width, uint16_t height );

	void fill( uint8_t red, uint8_t green, uint8_t blue );

	// Black modules on white, centred, with a quiet zone of at least two modules and the
	// largest integer scale that fits. False if the text doesn't fit on the key.
	bool drawQR( const char *text );

	// White, anti-aliased lines of text centred on a background (0xRRGGBB, black by
	// default). Uses the largest of the style's fonts in which every line fits.
	void drawText( const char *const *lines, size_t count, uint32_t background = 0x000000, TextStyle style = TextStyle::Label );

	// A square RGB888 icon (iconSize × iconSize) and one line of white text beside it, the
	// pair centred on black.
	void drawIconAndText( const uint8_t *icon, int iconSize, const char *text );

	// A filled, anti-aliased circle (0xRRGGBB) centred on black, diameter a fraction of the key.
	void drawDot( uint32_t color, float diameter );

	// Encodes the canvas. Returns the encoded data (valid until the next encode() or
	// begin()), or nullptr.
	const uint8_t *encode( StreamDeck::Format format, StreamDeck::Transform transform, size_t &length );

private:
	void release();
	void setPixel( int x, int y, uint8_t value );
	void blendWhite( int x, int y, uint8_t level );   // level 0–15
	void drawLine( const Font &font, const char *line, int x, int baseline );
	void applyTransform( StreamDeck::Transform transform );
	size_t encodeBMP();
	size_t encodeJPEG();

	uint16_t width_    = 0;
	uint16_t height_   = 0;
	uint8_t *canvas_   = nullptr;   // RGB888, top row first
	uint8_t *scratch_  = nullptr;   // the canvas after the transform, 16-byte aligned for the JPEG encoder
	uint8_t *output_   = nullptr;   // kMaxImageSize
};
