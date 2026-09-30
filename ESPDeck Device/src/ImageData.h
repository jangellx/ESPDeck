// An image file (BMP or JPEG) in PSRAM, shared between the cache, the main loop and the
// upload task; it's freed when the last of them lets go.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>

#include "esp_heap_caps.h"

// One image file's bytes in PSRAM; empty (not valid()) if the allocation failed.
class ImageData {
public:
	// Allocates length bytes to be filled by the caller (reading a file).
	explicit ImageData( size_t length )
		: data_( (uint8_t *)heap_caps_malloc( length, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT ) ), size_( data_ ? length : 0 ) {}

	// A copy of length bytes from source.
	ImageData( const uint8_t *source, size_t length )
		: ImageData( length ) {
		if( data_ )
			memcpy( data_, source, length );
	}

	~ImageData() { heap_caps_free( data_ ); }

	ImageData( const ImageData & )            = delete;
	ImageData &operator=( const ImageData & ) = delete;

	// False if PSRAM was out.
	bool           valid() const { return data_ != nullptr; }
	const uint8_t *data() const  { return data_; }
	uint8_t       *data()        { return data_; }
	size_t         size() const  { return size_; }

private:
	uint8_t *data_;
	size_t   size_;
};

// An image shared between its holders; freed when the last lets go.
using ImagePtr = std::shared_ptr<const ImageData>;

// A copy of an image, or nullptr if PSRAM is out.
inline ImagePtr makeImage( const uint8_t *data, size_t length ) {
	auto image = std::make_shared<ImageData>( data, length );
	return image->valid() ? image : nullptr;
}
