// An image file (BMP or JPEG) in PSRAM, shared between the cache, the main loop and the
// upload task; it's freed when the last of them lets go.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>

#include "esp_heap_caps.h"

class ImageData {
public:
	ImageData( const uint8_t *source, size_t length )
		: data_( (uint8_t *)heap_caps_malloc( length, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT ) ), size_( data_ ? length : 0 ) {
		if( data_ )
			memcpy( data_, source, length );
	}

	// Allocates length bytes to be filled by the caller (reading a file).
	explicit ImageData( size_t length )
		: data_( (uint8_t *)heap_caps_malloc( length, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT ) ), size_( data_ ? length : 0 ) {}

	~ImageData() { heap_caps_free( data_ ); }

	ImageData( const ImageData & )            = delete;
	ImageData &operator=( const ImageData & ) = delete;

	bool           valid() const { return data_ != nullptr; }
	const uint8_t *data() const  { return data_; }
	uint8_t       *data()        { return data_; }
	size_t         size() const  { return size_; }

private:
	uint8_t *data_;
	size_t   size_;
};

using ImagePtr = std::shared_ptr<const ImageData>;

// A copy of an image, or nullptr if PSRAM is out.
inline ImagePtr makeImage( const uint8_t *data, size_t length ) {
	auto image = std::make_shared<ImageData>( data, length );
	return image->valid() ? image : nullptr;
}
