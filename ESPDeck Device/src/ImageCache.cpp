#include "ImageCache.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_littlefs.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "Timing.h"

static const char *TAG = "ImageCache";

namespace {
	constexpr const char *kPartition      = "littlefs";
	constexpr const char *kMount          = "/deck";
	constexpr const char *kImageDir       = "/deck/img";
	constexpr const char *kIndexPath      = "/deck/index.bin";
	constexpr const char *kStatePath      = "/deck/state.bin";
	constexpr uint8_t     kStateMagic[4]  = { 'E', 'D', 'K', '2' };
	constexpr uint8_t     kLegacyMagic[4] = { 'E', 'D', 'K', '1' };   // firmware 1.x: Mini only, 6 keys
	constexpr uint8_t     kLegacyKeys     = 6;

	// File layouts (see saveMetadata()).
	constexpr size_t      kIndexRecord    = kHashSize + 4;       // hash, lastUse
	constexpr size_t      kStateHeader    = 4 + 2;               // magic, brightness, key count
	constexpr size_t      kKeyRecord      = 1 + kHashSize;       // assigned, hash

	// Free space kept for LittleFS metadata, the index, and the state file.
	constexpr size_t      kReserve        = 64 * 1024;
	constexpr size_t      kMaxEntries     = 450;

	// PSRAM tier: images not on any key, kept for quick flips back.
	constexpr size_t      kRamImages      = 32;
	constexpr size_t      kRamBytes       = 640 * 1024;

	constexpr uint32_t    kQuietTime      = 3000;   // ms without changes before images are saved
	constexpr uint32_t    kFlushDelay     = 3000;   // ms of debouncing for the index and state
	constexpr uint32_t    kWriterPoll     = 500;    // ms
	constexpr uint32_t    kWaitLimit      = 5000;   // ms persistNow() and stop() wait at most
	constexpr uint32_t    kWaitStep       = 10;     // ms between checks while waiting
	constexpr uint32_t    kWriterStack    = 6144;   // bytes

	// Images are stored as "<32 hex>.img"; firmware 1.x called them ".bmp".
	constexpr const char *kImageExtension  = ".img";
	constexpr const char *kLegacyExtension = ".bmp";
	constexpr size_t      kHexLength       = kHashSize * 2;
	constexpr size_t      kPathSize        = 64;   // any image path, with ".tmp" added

	using Timing::nowMillis;

	// Waits until done() or kWaitLimit, whichever comes first.
	template <typename Done>
	void waitUntil( Done done ) {
		for( uint32_t waited = 0; !done() && waited < kWaitLimit; waited += kWaitStep )
			vTaskDelay( pdMS_TO_TICKS( kWaitStep ) );
	}

	// The file an image is stored in.
	void imagePath( const Hash &hash, char *out, size_t size, const char *extension = kImageExtension ) {
		char hex[kHexLength + 1];
		hashToHex( hash, hex );
		snprintf( out, size, "%s/%s%s", kImageDir, hex, extension );
	}

	// Writes a whole file through a temporary one, so an interrupted write leaves the old file.
	bool writeFile( const char *path, const uint8_t *data, size_t size ) {
		char temp[kPathSize];
		snprintf( temp, sizeof( temp ), "%s.tmp", path );

		FILE *file = fopen( temp, "wb" );
		if( !file )
			return false;
		bool ok = fwrite( data, 1, size, file ) == size;
		ok      = fclose( file ) == 0 && ok;
		if( ok ) {
			unlink( path );
			ok = rename( temp, path ) == 0;
		}
		if( !ok )
			unlink( temp );
		return ok;
	}
}

bool ImageCache::begin() {
	esp_vfs_littlefs_conf_t conf = {};
	conf.base_path              = kMount;
	conf.partition_label        = kPartition;
	conf.format_if_mount_failed = true;
	esp_err_t err = esp_vfs_littlefs_register( &conf );
	if( err != ESP_OK ) {
		ESP_LOGE( TAG, "Mounting LittleFS failed: %s", esp_err_to_name( err ) );
		return false;
	}
	mkdir( kImageDir, 0775 );

	scanImages();
	loadIndex();
	loadState();

	size_t total = 0, used = 0;
	esp_littlefs_info( kPartition, &total, &used );
	ESP_LOGI( TAG, "%u images cached, %u/%u KB used", (unsigned)flash_.size(), (unsigned)( used / 1024 ), (unsigned)( total / 1024 ) );

	xTaskCreate( writerTask, "cache", kWriterStack, this, 1, &writer_ );
	return true;
}

bool ImageCache::stop() {
	if( !writer_ || stopped_ )
		return true;
	stopping_ = true;
	xTaskNotifyGive( writer_ );
	waitUntil( [this] { return stopped_; } );
	return stopped_;
}

void ImageCache::persistNow() {
	if( !writer_ || stopped_ )
		return;
	flushNow_ = true;
	xTaskNotifyGive( writer_ );
	waitUntil( [this] { return !flushNow_; } );
}

// MARK: - Images

bool ImageCache::has( const Hash &hash ) const {
	std::lock_guard<std::mutex> lock( mutex_ );
	return ram_.count( hash ) != 0 || flash_.count( hash ) != 0;
}

bool ImageCache::store( const Hash &hash, const uint8_t *data, size_t size ) {
	{
		std::lock_guard<std::mutex> lock( mutex_ );
		lastChange_ = nowMillis();
		if( ram_.count( hash ) ) {
			touch( hash );
			return true;
		}
	}

	ImagePtr image = makeImage( data, size );   // the copy happens outside the lock
	if( !image ) {
		ESP_LOGE( TAG, "Out of PSRAM for a %u byte image", (unsigned)size );
		return false;
	}

	std::lock_guard<std::mutex> lock( mutex_ );
	ram_[hash] = { image, useCounter_++, flash_.count( hash ) != 0 };
	ready_    |= keysShowing( hash );
	trimRam();
	return true;
}

std::vector<Hash> ImageCache::hashes() const {
	std::lock_guard<std::mutex> lock( mutex_ );
	std::vector<Hash> result;
	result.reserve( flash_.size() + ram_.size() );
	for( const auto &entry : flash_ )
		result.push_back( entry.first );
	for( const auto &entry : ram_ ) {
		if( !entry.second.onFlash )
			result.push_back( entry.first );
	}
	return result;
}

// Marks an image as the most recently used, in both tiers.
void ImageCache::touch( const Hash &hash ) {
	auto inRam = ram_.find( hash );
	if( inRam != ram_.end() )
		inRam->second.lastUse = useCounter_;
	auto onFlash = flash_.find( hash );
	if( onFlash != flash_.end() ) {
		onFlash->second.lastUse = useCounter_;
		markDirty( indexDirty_ );
	}
	useCounter_++;
}

bool ImageCache::isAssigned( const Hash &hash ) const {
	return keysShowing( hash ) != 0;
}

// The keys assigned this image, one bit per key.
uint32_t ImageCache::keysShowing( const Hash &hash ) const {
	uint32_t keys = 0;
	for( uint8_t key = 0; key < kMaxKeys; key++ ) {
		if( keys_[key].assigned && keys_[key].hash == hash )
			keys |= 1u << key;
	}
	return keys;
}

// Drops the least recently used PSRAM images that aren't on a key, beyond kRamImages or
// kRamBytes. One that never made it to flash is simply gone; the Mac sends it again if needed.
void ImageCache::trimRam() {
	while( true ) {
		size_t count = 0, bytes = 0;
		auto   victim = ram_.end();
		for( auto it = ram_.begin(); it != ram_.end(); ++it ) {
			if( isAssigned( it->first ) )
				continue;
			count++;
			bytes += it->second.image->size();
			if( victim == ram_.end() || it->second.lastUse < victim->second.lastUse )
				victim = it;
		}
		if( victim == ram_.end() || ( count <= kRamImages && bytes <= kRamBytes ) )
			return;
		ram_.erase( victim );
	}
}

// MARK: - Keys

ImageCache::Lookup ImageCache::assign( uint8_t key, const Hash &hash ) {
	if( key >= kMaxKeys )
		return Lookup::Missing;

	Lookup lookup;
	{
		std::lock_guard<std::mutex> lock( mutex_ );
		Key &slot = keys_[key];
		if( !slot.assigned || slot.hash != hash ) {
			slot.assigned = true;
			slot.hash     = hash;
			markDirty( stateDirty_ );
		}
		lastChange_ = nowMillis();
		touch( hash );
		trimRam();   // the key's previous image may no longer be on any key

		if( ram_.count( hash ) ) {
			lookup = Lookup::Ready;
		} else if( flash_.count( hash ) ) {
			if( std::find( toLoad_.begin(), toLoad_.end(), hash ) == toLoad_.end() )
				toLoad_.push_back( hash );
			lookup = Lookup::Loading;
		} else {
			lookup = Lookup::Missing;
		}
	}
	if( lookup == Lookup::Loading && writer_ )
		xTaskNotifyGive( writer_ );
	return lookup;
}

uint32_t ImageCache::takeReady() {
	std::lock_guard<std::mutex> lock( mutex_ );
	uint32_t ready = ready_;
	ready_ = 0;
	return ready;
}

std::vector<Hash> ImageCache::takeMissing() {
	std::lock_guard<std::mutex> lock( mutex_ );
	std::vector<Hash> missing;
	missing.swap( missing_ );
	return missing;
}

ImagePtr ImageCache::keyImage( uint8_t key, Hash *hash ) const {
	std::lock_guard<std::mutex> lock( mutex_ );
	if( key >= kMaxKeys || !keys_[key].assigned )
		return nullptr;
	auto found = ram_.find( keys_[key].hash );
	if( found == ram_.end() )
		return nullptr;
	if( hash )
		*hash = keys_[key].hash;
	return found->second.image;
}

uint8_t ImageCache::brightness() const {
	std::lock_guard<std::mutex> lock( mutex_ );
	return brightness_;
}

void ImageCache::setBrightness( uint8_t percent ) {
	std::lock_guard<std::mutex> lock( mutex_ );
	if( percent == brightness_ )
		return;
	brightness_ = percent;
	markDirty( stateDirty_ );
}

// Sets indexDirty_ or stateDirty_, starting the debounce if neither was set.
void ImageCache::markDirty( bool &flag ) {
	if( !indexDirty_ && !stateDirty_ )
		dirtySince_ = nowMillis();
	flag = true;
}

// MARK: - Writer task

void ImageCache::writerTask( void *arg ) {
	static_cast<ImageCache *>( arg )->runWriter();
}

// Loads, saves and flushes on each wake-up (a notification or kWriterPoll) until stop().
void ImageCache::runWriter() {
	while( !stopping_ ) {
		ulTaskNotifyTake( pdTRUE, pdMS_TO_TICKS( kWriterPoll ) );
		if( stopping_ )
			break;
		bool force = flushNow_;
		loadPending();
		saveAssigned( force );
		saveMetadata( force );
		if( force )
			flushNow_ = false;
	}
	stopped_ = true;
	vTaskDelete( nullptr );
}

// Reads the flash images keys are waiting for into PSRAM.
void ImageCache::loadPending() {
	while( !stopping_ ) {
		Hash   hash;
		size_t size;
		{
			std::lock_guard<std::mutex> lock( mutex_ );
			if( toLoad_.empty() )
				return;
			hash = toLoad_.front();
			toLoad_.pop_front();
			auto found = flash_.find( hash );
			if( ram_.count( hash ) || found == flash_.end() )
				continue;
			size = found->second.size;
		}

		ImagePtr image = readImage( hash, size );

		std::lock_guard<std::mutex> lock( mutex_ );
		if( image ) {
			ram_[hash] = { image, useCounter_++, true };
			ready_    |= keysShowing( hash );
			trimRam();
		} else {
			ESP_LOGW( TAG, "Cached image %02x%02x… is unreadable", hash[0], hash[1] );
			flash_.erase( hash );
			markDirty( indexDirty_ );
			if( isAssigned( hash ) )
				missing_.push_back( hash );
		}
	}
}

// An image file, read into PSRAM; null if it can't be read in full.
ImagePtr ImageCache::readImage( const Hash &hash, size_t size ) {
	char path[kPathSize];
	imagePath( hash, path, sizeof( path ) );
	FILE *file = fopen( path, "rb" );
	if( !file )
		return nullptr;

	auto image = std::make_shared<ImageData>( size );
	bool ok    = image->valid() && fread( image->data(), 1, size, file ) == size;
	fclose( file );
	return ok ? image : nullptr;
}

// Writes the images on keys that aren't on flash yet, once the Mac has been quiet for
// kQuietTime. The lock is only held to pick the next image and to record the result.
void ImageCache::saveAssigned( bool force ) {
	while( !stopping_ ) {
		Hash     hash;
		ImagePtr image;
		{
			std::lock_guard<std::mutex> lock( mutex_ );
			if( !force && nowMillis() - lastChange_ < kQuietTime )
				return;
			auto next = std::find_if( ram_.begin(), ram_.end(), [&]( const auto &entry ) {
				return !entry.second.onFlash && !entry.second.saveFailed && isAssigned( entry.first );
			} );
			if( next == ram_.end() )
				return;
			hash  = next->first;
			image = next->second.image;
		}

		int64_t started = esp_timer_get_time();
		char    path[kPathSize];
		imagePath( hash, path, sizeof( path ) );
		bool ok = makeRoom( image->size() ) && writeFile( path, image->data(), image->size() );

		std::lock_guard<std::mutex> lock( mutex_ );
		auto inRam = ram_.find( hash );
		if( ok ) {
			flash_[hash] = { (uint32_t)image->size(), inRam != ram_.end() ? inRam->second.lastUse : useCounter_++ };
			markDirty( indexDirty_ );
			ESP_LOGI( TAG, "Saved %02x%02x… (%u bytes) to flash in %lld ms", hash[0], hash[1], (unsigned)image->size(), ( esp_timer_get_time() - started ) / 1000 );
		} else {
			ESP_LOGE( TAG, "Couldn't save %02x%02x… (%u bytes) to flash", hash[0], hash[1], (unsigned)image->size() );
		}
		if( inRam != ram_.end() ) {
			inRam->second.onFlash    = ok;
			inRam->second.saveFailed = !ok;   // not retried over and over; it stays in PSRAM
		}
	}
}

// Deletes least recently used flash images that aren't on a key until size bytes fit.
bool ImageCache::makeRoom( size_t size ) {
	while( true ) {
		size_t total = 0, used = 0;
		if( esp_littlefs_info( kPartition, &total, &used ) != ESP_OK )
			return false;

		Hash victim;
		{
			std::lock_guard<std::mutex> lock( mutex_ );
			if( used + size + kReserve <= total && flash_.size() < kMaxEntries )
				return true;

			auto oldest = flash_.end();
			for( auto it = flash_.begin(); it != flash_.end(); ++it ) {
				if( isAssigned( it->first ) )
					continue;
				if( oldest == flash_.end() || it->second.lastUse < oldest->second.lastUse )
					oldest = it;
			}
			if( oldest == flash_.end() )
				return false;
			victim = oldest->first;
			flash_.erase( oldest );
			auto inRam = ram_.find( victim );
			if( inRam != ram_.end() )
				inRam->second.onFlash = false;
			markDirty( indexDirty_ );
		}

		char path[kPathSize];
		imagePath( victim, path, sizeof( path ) );
		unlink( path );
	}
}

// The index and key state, debounced; snapshots are taken under the lock and written without it.
void ImageCache::saveMetadata( bool force ) {
	std::vector<uint8_t> index, state;
	{
		std::lock_guard<std::mutex> lock( mutex_ );
		if( !indexDirty_ && !stateDirty_ )
			return;
		if( !force && nowMillis() - dirtySince_ < kFlushDelay )
			return;

		// Index: repeated { hash[16], lastUse u32 }.
		if( indexDirty_ ) {
			index.reserve( flash_.size() * kIndexRecord );
			for( const auto &entry : flash_ ) {
				index.insert( index.end(), entry.first.begin(), entry.first.end() );
				const uint8_t *lastUse = (const uint8_t *)&entry.second.lastUse;
				index.insert( index.end(), lastUse, lastUse + 4 );
			}
		}

		// State: magic[4], brightness, key count, then per key { assigned, hash[16] }.
		if( stateDirty_ ) {
			state.resize( kStateHeader + kMaxKeys * kKeyRecord );
			memcpy( state.data(), kStateMagic, 4 );
			state[4] = brightness_;
			state[5] = kMaxKeys;
			uint8_t *cursor = state.data() + kStateHeader;
			for( uint8_t key = 0; key < kMaxKeys; key++, cursor += kKeyRecord ) {
				cursor[0] = keys_[key].assigned ? 1 : 0;
				memcpy( cursor + 1, keys_[key].hash.data(), kHashSize );
			}
		}
		indexDirty_ = false;
		stateDirty_ = false;
	}

	if( !index.empty() && !writeFile( kIndexPath, index.data(), index.size() ) )
		ESP_LOGW( TAG, "Saving the index failed" );
	if( !state.empty() && !writeFile( kStatePath, state.data(), state.size() ) )
		ESP_LOGW( TAG, "Saving key state failed" );
}

// MARK: - Boot

// Lists the image files into flash_, removing anything else and renaming 1.x files.
void ImageCache::scanImages() {
	DIR *dir = opendir( kImageDir );
	if( !dir )
		return;

	std::vector<Hash> legacy;   // renamed after the scan, so the directory doesn't change under readdir
	struct dirent    *item;
	while( ( item = readdir( dir ) ) != nullptr ) {
		char path[16 + sizeof( item->d_name )];   // the directory, a slash, and any name readdir() can return
		snprintf( path, sizeof( path ), "%s/%s", kImageDir, item->d_name );

		// "<32 hex>.img" (or a 1.x ".bmp"); anything else, including interrupted .tmp writes,
		// is removed.
		char hex[kHexLength + 1] = {};
		Hash hash;
		bool valid    = strlen( item->d_name ) == kHexLength + 4;
		bool isLegacy = valid && strcmp( item->d_name + kHexLength, kLegacyExtension ) == 0;
		valid         = valid && ( isLegacy || strcmp( item->d_name + kHexLength, kImageExtension ) == 0 );
		if( valid ) {
			memcpy( hex, item->d_name, kHexLength );
			valid = hashFromHex( hex, hash );
		}

		struct stat info;
		if( valid && stat( path, &info ) == 0 && info.st_size > 0 ) {
			flash_[hash] = { (uint32_t)info.st_size, 0 };
			if( isLegacy )
				legacy.push_back( hash );
		} else {
			unlink( path );
		}
	}
	closedir( dir );

	for( const Hash &hash : legacy ) {
		char from[kPathSize], to[kPathSize];
		imagePath( hash, from, sizeof( from ), kLegacyExtension );
		imagePath( hash, to, sizeof( to ) );
		if( rename( from, to ) != 0 ) {
			unlink( from );
			flash_.erase( hash );
		}
	}
}

// Each flash image's last use, from the index.
void ImageCache::loadIndex() {
	FILE *file = fopen( kIndexPath, "rb" );
	if( !file )
		return;

	uint8_t record[kIndexRecord];
	while( fread( record, 1, sizeof( record ), file ) == sizeof( record ) ) {
		Hash hash;
		memcpy( hash.data(), record, kHashSize );
		uint32_t lastUse;
		memcpy( &lastUse, record + kHashSize, 4 );

		auto found = flash_.find( hash );
		if( found != flash_.end() ) {
			found->second.lastUse = lastUse;
			useCounter_ = std::max( useCounter_, lastUse + 1 );
		}
	}
	fclose( file );
}

// Firmware 1.x wrote magic "EDK1", brightness and exactly six keys; those assignments are kept.
// The images on keys are read into PSRAM now, so the deck can show them at once.
void ImageCache::loadState() {
	FILE *file = fopen( kStatePath, "rb" );
	if( !file )
		return;

	uint8_t data[kStateHeader + kMaxKeys * kKeyRecord];
	size_t  size = fread( data, 1, sizeof( data ), file );
	fclose( file );

	size_t         count  = 0;
	const uint8_t *cursor = nullptr;
	if( size >= kStateHeader && memcmp( data, kStateMagic, 4 ) == 0 ) {
		count  = std::min<size_t>( data[5], kMaxKeys );
		cursor = data + kStateHeader;
	} else if( size >= 5 && memcmp( data, kLegacyMagic, 4 ) == 0 ) {
		count  = kLegacyKeys;
		cursor = data + 5;
	}
	if( !cursor || size < (size_t)( cursor - data ) + count * kKeyRecord ) {
		ESP_LOGW( TAG, "Ignoring unreadable state file" );
		return;
	}

	brightness_ = std::min<uint8_t>( data[4], 100 );
	for( uint8_t key = 0; key < count; key++, cursor += kKeyRecord ) {
		keys_[key].assigned = cursor[0] != 0;
		memcpy( keys_[key].hash.data(), cursor + 1, kHashSize );
		const Hash &hash  = keys_[key].hash;
		auto        found = flash_.find( hash );
		if( !keys_[key].assigned || ram_.count( hash ) || found == flash_.end() )
			continue;
		if( ImagePtr image = readImage( hash, found->second.size ) )
			ram_[hash] = { image, found->second.lastUse, true };
	}
}
