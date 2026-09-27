// Key images keyed by content hash, in two tiers.
//
// PSRAM: every image arrives here, and is usable at once. Images assigned to keys always
// stay; up to kRamImages others are kept in least-recently-used order, so quick state flips
// (a door's open and closed images) don't need a resend.
//
// LittleFS: a background task saves images that are still assigned to a key once the Mac
// has gone quiet for a moment (images that were only briefly on a key, like each step of a
// label being typed, are never written), and persists the key assignments, brightness, and
// the LRU index. The deck shows its last images at boot before the Mac connects. Flash
// images are evicted least recently used first when the filesystem fills.
//
// All public methods are safe from any task; none of them touch the flash except begin()
// and persistNow().
#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <vector>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "Hash.h"
#include "ImageData.h"

class ImageCache {
public:
	enum class Lookup : uint8_t {
		Ready,     // in PSRAM now
		Loading,   // on flash; takeReady() reports the key when it's in PSRAM
		Missing,   // neither; ask the Mac for it
	};

	// Mounts the filesystem, loads the images assigned to keys, and starts the writer task.
	bool begin();

	// Stops the writer task after its current operation (before erasing the filesystem).
	void stop();

	bool has( const Hash &hash ) const;

	// Keeps a copy of an image the caller has verified. Returns false if PSRAM is out.
	bool store( const Hash &hash, const uint8_t *data, size_t size );

	// Records what a key should show.
	Lookup assign( uint8_t key, const Hash &hash );

	// Keys whose assigned image has become available since the last call (after store() or
	// a flash read), one bit per key.
	uint32_t takeReady();

	// Flash images that turned out to be unreadable while a key waited for them; the Mac
	// has to send them again.
	std::vector<Hash> takeMissing();

	// A key's assigned image, if it's in PSRAM.
	ImagePtr keyImage( uint8_t key, Hash *hash = nullptr ) const;

	// Every image the Mac needn't send again, in either tier.
	std::vector<Hash> hashes() const;

	uint8_t brightness() const;
	void    setBrightness( uint8_t percent );

	// Saves everything pending now and waits for it (before a restart).
	void persistNow();

private:
	struct FlashEntry {
		uint32_t size;
		uint32_t lastUse;
	};

	struct RamEntry {
		ImagePtr image;
		uint32_t lastUse;
		bool     onFlash;
		bool     saveFailed = false;   // the filesystem was full; stays in PSRAM only
	};

	struct Key {
		bool assigned = false;
		Hash hash     = {};
	};

	// Writer task: the only one touching the flash after begin().
	static void writerTask( void *arg );
	void runWriter();
	void loadPending();
	void saveAssigned( bool force );
	void saveMetadata( bool force );
	bool makeRoom( size_t size );
	ImagePtr readImage( const Hash &hash, size_t size );

	// Callers hold mutex_.
	bool isAssigned( const Hash &hash ) const;
	uint32_t keysShowing( const Hash &hash ) const;
	void touch( const Hash &hash );
	void trimRam();
	void markDirty( bool &flag );

	// Boot only (before the writer starts).
	void scanImages();
	void loadIndex();
	void loadState();

	mutable std::mutex         mutex_;
	std::map<Hash, FlashEntry> flash_;
	std::map<Hash, RamEntry>   ram_;
	Key                        keys_[kMaxKeys];
	std::deque<Hash>           toLoad_;             // flash images a key is waiting for
	std::vector<Hash>          missing_;            // for takeMissing()
	uint32_t                   ready_       = 0;    // for takeReady()
	uint8_t                    brightness_  = 80;
	uint32_t                   useCounter_  = 1;

	bool                       indexDirty_  = false;
	bool                       stateDirty_  = false;
	uint32_t                   dirtySince_  = 0;
	uint32_t                   lastChange_  = 0;    // millis() of the last store() or assign()

	TaskHandle_t               writer_      = nullptr;
	volatile bool              stopping_    = false;
	volatile bool              stopped_     = false;
	volatile bool              flushNow_    = false;
};
