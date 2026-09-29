#include "KeyImage.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "esp_heap_caps.h"
#include "esp_jpeg_enc.h"
#include "esp_log.h"
#include "qrcode.h"

#include "Font.h"

static const char *TAG = "KeyImage";

namespace {
	using Transform = StreamDeck::Transform;

	constexpr int     kMaxQRVersion = 10;   // 57 modules; plenty for a Wi-Fi QR payload
	constexpr int     kMaxModules   = 17 + 4 * kMaxQRVersion;
	constexpr int     kQuietZone    = 2;    // modules of white on each side, at least
	constexpr uint8_t kJPEGQuality  = 90;

	// esp_qrcode_generate() hands the code to a callback without a context pointer, so the
	// modules are copied out through these.
	uint8_t qrModules[kMaxModules * kMaxModules];
	int     qrSize = 0;

	void copyModules( esp_qrcode_handle_t qrcode ) {
		qrSize = std::min( esp_qrcode_get_size( qrcode ), kMaxModules );
		for( int y = 0; y < qrSize; y++ ) {
			for( int x = 0; x < qrSize; x++ )
				qrModules[y * qrSize + x] = esp_qrcode_get_module( qrcode, x, y ) ? 1 : 0;
		}
	}

	void writeLE16( uint8_t *out, uint16_t value ) {
		out[0] = value & 0xFF;
		out[1] = value >> 8;
	}

	void writeLE32( uint8_t *out, uint32_t value ) {
		for( int i = 0; i < 4; i++ )
			out[i] = ( value >> ( 8 * i ) ) & 0xFF;
	}
}

KeyImage::~KeyImage() {
	release();
}

void KeyImage::release() {
	heap_caps_free( canvas_ );
	heap_caps_free( scratch_ );
	heap_caps_free( output_ );
	canvas_  = nullptr;
	scratch_ = nullptr;
	output_  = nullptr;
	size_    = 0;
}

bool KeyImage::begin( uint16_t size ) {
	if( size == size_ && canvas_ )
		return true;

	release();
	size_t bytes = (size_t)size * size * 3;
	canvas_  = (uint8_t *)heap_caps_malloc( bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT );
	scratch_ = (uint8_t *)heap_caps_aligned_alloc( 16, bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT );
	output_  = (uint8_t *)heap_caps_malloc( kMaxImageSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT );
	if( !size || !canvas_ || !scratch_ || !output_ ) {
		release();
		return false;
	}
	size_ = size;
	return true;
}

// MARK: - Drawing

void KeyImage::fill( uint8_t red, uint8_t green, uint8_t blue ) {
	for( size_t i = 0; i < (size_t)size_ * size_; i++ ) {
		canvas_[i * 3]     = red;
		canvas_[i * 3 + 1] = green;
		canvas_[i * 3 + 2] = blue;
	}
}

void KeyImage::drawDot( uint32_t color, float diameter ) {
	fill( 0, 0, 0 );
	float   center = size_ / 2.0f;
	float   radius = size_ * diameter / 2.0f;
	uint8_t rgb[3] = { (uint8_t)( color >> 16 ), (uint8_t)( color >> 8 ), (uint8_t)color };
	for( int y = 0; y < size_; y++ ) {
		for( int x = 0; x < size_; x++ ) {
			float dx = x + 0.5f - center, dy = y + 0.5f - center;
			// Coverage from the distance to the edge: 1 inside, 0 outside, a ramp across one pixel.
			float coverage = std::min( 1.0f, std::max( 0.0f, radius + 0.5f - sqrtf( dx * dx + dy * dy ) ) );
			if( coverage <= 0 )
				continue;
			uint8_t *pixel = canvas_ + ( (size_t)y * size_ + x ) * 3;
			for( int c = 0; c < 3; c++ )
				pixel[c] = (uint8_t)( rgb[c] * coverage + 0.5f );
		}
	}
}

void KeyImage::setPixel( int x, int y, uint8_t value ) {
	if( x < 0 || y < 0 || x >= size_ || y >= size_ )
		return;
	memset( canvas_ + ( (size_t)y * size_ + x ) * 3, value, 3 );
}

bool KeyImage::drawQR( const char *text ) {
	fill( 255, 255, 255 );

	esp_qrcode_config_t config = {};
	config.display_func       = copyModules;
	config.max_qrcode_version = kMaxQRVersion;
	config.qrcode_ecc_level   = ESP_QRCODE_ECC_LOW;   // keeps the modules as large as possible
	qrSize = 0;
	if( esp_qrcode_generate( &config, text ) != ESP_OK || qrSize == 0 ) {
		ESP_LOGW( TAG, "Couldn't encode a %u-character QR code", (unsigned)strlen( text ) );   // the text may be a password
		return false;
	}

	int scale = size_ / ( qrSize + 2 * kQuietZone );
	if( scale < 1 ) {
		ESP_LOGW( TAG, "A %d-module QR code doesn't fit on a %u px key", qrSize, size_ );
		return false;
	}

	int origin = ( size_ - qrSize * scale ) / 2;
	for( int y = 0; y < qrSize; y++ ) {
		for( int x = 0; x < qrSize; x++ ) {
			if( !qrModules[y * qrSize + x] )
				continue;
			for( int dy = 0; dy < scale; dy++ ) {
				for( int dx = 0; dx < scale; dx++ )
					setPixel( origin + x * scale + dx, origin + y * scale + dy, 0 );
			}
		}
	}
	return true;
}

namespace {
	const FontGlyph *glyphFor( const Font &font, char c ) {
		return c >= font.first && c <= font.last ? &font.glyphs[c - font.first] : nullptr;
	}

	int lineWidth( const Font &font, const char *line ) {
		int width = 0;
		for( ; *line; line++ ) {
			const FontGlyph *glyph = glyphFor( font, *line );
			width += glyph ? glyph->advance : 0;
		}
		return width;
	}

	// Every character is in the font, and the block fits in room × room.
	bool fits( const Font &font, const char *const *lines, size_t count, int room ) {
		if( font.capHeight + (int)( count - 1 ) * font.lineHeight > room )
			return false;
		for( size_t i = 0; i < count; i++ ) {
			for( const char *c = lines[i]; *c; c++ ) {
				if( !glyphFor( font, *c ) )
					return false;
			}
			if( lineWidth( font, lines[i] ) > room )
				return false;
		}
		return true;
	}
}

void KeyImage::blendWhite( int x, int y, uint8_t level ) {
	if( level == 0 || x < 0 || y < 0 || x >= size_ || y >= size_ )
		return;
	uint8_t *pixel = canvas_ + ( (size_t)y * size_ + x ) * 3;
	for( int i = 0; i < 3; i++ )
		pixel[i] = (uint8_t)( pixel[i] + ( 255 - pixel[i] ) * level / 15 );
}

void KeyImage::drawText( const char *const *lines, size_t count, uint32_t background, TextStyle style ) {
	fill( background >> 16, ( background >> 8 ) & 0xFF, background & 0xFF );
	if( count == 0 )
		return;

	// Largest first; the last one is used even if it doesn't fit. LabelSmall is for labels
	// like "Connecting" on 72 px keys (the MK.2) and 80 px ones (the Mini).
	constexpr int kMargin = 3;
	int           room    = size_ - 2 * kMargin;
	const Font   *choices[4];
	size_t        options = 0;
	if( style == TextStyle::Big )
		choices[options++] = &kBigFont;
	if( size_ >= 96 )
		choices[options++] = &kLabelLargeFont;
	choices[options++] = &kLabelFont;
	choices[options++] = &kLabelSmallFont;

	const Font *font = choices[options - 1];
	for( size_t i = 0; i < options; i++ ) {
		if( fits( *choices[i], lines, count, room ) ) {
			font = choices[i];
			break;
		}
	}

	// Centre the block from the first line's cap height to the last line's baseline.
	int block = font->capHeight + (int)( count - 1 ) * font->lineHeight;
	int top   = ( size_ - block ) / 2;
	for( size_t i = 0; i < count; i++ ) {
		int baseline = top + font->capHeight + (int)i * font->lineHeight;
		int x        = ( size_ - lineWidth( *font, lines[i] ) ) / 2;
		for( const char *c = lines[i]; *c; c++ ) {
			const FontGlyph *glyph = glyphFor( *font, *c );
			if( !glyph )
				glyph = glyphFor( *font, '?' );
			if( !glyph )
				continue;

			const uint8_t *bits = font->bitmap + glyph->offset;
			for( int row = 0; row < glyph->height; row++ ) {
				for( int col = 0; col < glyph->width; col++ ) {
					int     index = row * glyph->width + col;
					uint8_t level = index % 2 == 0 ? bits[index / 2] >> 4 : bits[index / 2] & 0x0F;
					blendWhite( x + glyph->left + col, baseline - glyph->top + row, level );
				}
			}
			x += glyph->advance;
		}
	}
}

// MARK: - Encoding

// Output pixel (x, y) comes from the source pixel given in PROTOCOL.md's transform table.
void KeyImage::applyTransform( Transform transform ) {
	int last = size_ - 1;
	for( int y = 0; y < size_; y++ ) {
		for( int x = 0; x < size_; x++ ) {
			int sx = x, sy = y;
			switch( transform ) {
				case Transform::None:      break;
				case Transform::Transpose: sx = y;        sy = x;        break;
				case Transform::Rotate90:  sx = y;        sy = last - x; break;
				case Transform::Rotate270: sx = last - y; sy = x;        break;
				case Transform::Rotate180: sx = last - x; sy = last - y; break;
			}
			memcpy( scratch_ + ( (size_t)y * size_ + x ) * 3, canvas_ + ( (size_t)sy * size_ + sx ) * 3, 3 );
		}
	}
}

const uint8_t *KeyImage::encode( StreamDeck::Format format, Transform transform, size_t &length ) {
	length = 0;
	if( !canvas_ )
		return nullptr;

	applyTransform( transform );
	if( format == StreamDeck::Format::BMP )
		length = encodeBMP();
	else if( format == StreamDeck::Format::JPEG )
		length = encodeJPEG();
	return length ? output_ : nullptr;
}

// 24-bit BMP: 14-byte file header, 40-byte BITMAPINFOHEADER, then rows bottom-up in BGR,
// each padded to four bytes.
size_t KeyImage::encodeBMP() {
	constexpr size_t kHeader = 54;
	size_t rowSize = ( (size_t)size_ * 3 + 3 ) & ~(size_t)3;
	size_t length  = kHeader + rowSize * size_;
	if( length > kMaxImageSize )
		return 0;

	memset( output_, 0, kHeader );
	output_[0] = 'B';
	output_[1] = 'M';
	writeLE32( output_ + 2, length );
	writeLE32( output_ + 10, kHeader );
	writeLE32( output_ + 14, 40 );
	writeLE32( output_ + 18, size_ );
	writeLE32( output_ + 22, size_ );             // positive height: bottom-up
	writeLE16( output_ + 26, 1 );                 // planes
	writeLE16( output_ + 28, 24 );                // bits per pixel
	writeLE32( output_ + 34, rowSize * size_ );
	writeLE32( output_ + 38, 2835 );              // 72 dpi
	writeLE32( output_ + 42, 2835 );

	for( int y = 0; y < size_; y++ ) {
		const uint8_t *source = scratch_ + (size_t)( size_ - 1 - y ) * size_ * 3;
		uint8_t       *row    = output_ + kHeader + (size_t)y * rowSize;
		for( int x = 0; x < size_; x++ ) {
			row[x * 3]     = source[x * 3 + 2];
			row[x * 3 + 1] = source[x * 3 + 1];
			row[x * 3 + 2] = source[x * 3];
		}
		memset( row + size_ * 3, 0, rowSize - size_ * 3 );
	}
	return length;
}

size_t KeyImage::encodeJPEG() {
	jpeg_enc_config_t config = {};
	config.width       = size_;
	config.height      = size_;
	config.src_type    = JPEG_PIXEL_FORMAT_RGB888;
	config.subsampling = JPEG_SUBSAMPLE_420;
	config.quality     = kJPEGQuality;
	config.rotate      = JPEG_ROTATE_0D;
	config.task_enable = false;

	jpeg_enc_handle_t encoder = nullptr;
	jpeg_error_t      err     = jpeg_enc_open( &config, &encoder );
	if( err != JPEG_ERR_OK ) {
		ESP_LOGW( TAG, "jpeg_enc_open failed: %d", (int)err );
		return 0;
	}

	int length = 0;
	err = jpeg_enc_process( encoder, scratch_, size_ * size_ * 3, output_, kMaxImageSize, &length );
	jpeg_enc_close( encoder );
	if( err != JPEG_ERR_OK ) {
		ESP_LOGW( TAG, "jpeg_enc_process failed: %d", (int)err );
		return 0;
	}
	return (size_t)length;
}
