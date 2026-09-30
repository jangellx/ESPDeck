#include "KeyUploader.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "Timing.h"

static const char *TAG = "Upload";

namespace {
	constexpr uint32_t    kTaskStack    = 4096;   // bytes
	constexpr UBaseType_t kTaskPriority = 2;      // above the Arduino loop's 1, so uploads go on while it's busy
	constexpr uint32_t    kIdlePoll     = 10;     // ms between checks in waitIdle()

	using Timing::nowMillis;
}

void KeyUploader::begin( StreamDeck &deck ) {
	deck_  = &deck;
	shown_ = xQueueCreate( kMaxKeys * 2, sizeof( Shown ) );
	xTaskCreate( task, "upload", kTaskStack, this, kTaskPriority, &task_ );
}

void KeyUploader::show( uint8_t key, ImagePtr image, const Hash *hash ) {
	if( key >= kMaxKeys || !image || !task_ )
		return;
	{
		std::lock_guard<std::mutex> lock( mutex_ );
		Slot &slot = slots_[key];
		slot.pending        = image;   // replaces one that hasn't gone out yet
		slot.pendingHasHash = hash != nullptr;
		slot.pendingHash    = hash ? *hash : Hash{};
		slot.queuedAt       = nowMillis();
		pending_           |= 1u << key;
	}
	xTaskNotifyGive( task_ );
}

void KeyUploader::reset() {
	std::lock_guard<std::mutex> lock( mutex_ );
	for( Slot &slot : slots_ ) {
		slot.pending     = nullptr;
		slot.onDeckKnown = false;
	}
	pending_ = 0;
	generation_++;
}

bool KeyUploader::nextShown( Shown &shown ) {
	return shown_ && xQueueReceive( shown_, &shown, 0 ) == pdTRUE;
}

void KeyUploader::waitIdle( uint32_t timeoutMs ) {
	for( uint32_t waited = 0; waited < timeoutMs; waited += kIdlePoll ) {
		{
			std::lock_guard<std::mutex> lock( mutex_ );
			if( !pending_ && !busy_ )
				return;
		}
		vTaskDelay( pdMS_TO_TICKS( kIdlePoll ) );
	}
	ESP_LOGW( TAG, "Still uploading after %u ms", (unsigned)timeoutMs );
}

// MARK: - Task

void KeyUploader::task( void *arg ) {
	static_cast<KeyUploader *>( arg )->run();
}

void KeyUploader::run() {
	uint8_t next = 0;   // round-robin, so one busy key can't starve the others
	while( true ) {
		ImagePtr image;
		bool     hasHash    = false;
		Hash     hash       = {};
		uint32_t queuedAt   = 0;
		uint32_t generation = 0;
		uint8_t  key        = 0;
		{
			std::lock_guard<std::mutex> lock( mutex_ );
			if( !pending_ ) {
				busy_ = false;
			} else {
				uint32_t rotated = ( pending_ >> next ) | ( next ? pending_ << ( 32 - next ) : 0 );
				key      = ( next + __builtin_ctz( rotated ) ) % 32;
				next     = ( key + 1 ) % kMaxKeys;
				Slot &slot = slots_[key];
				image    = slot.pending;
				hasHash  = slot.pendingHasHash;
				hash     = slot.pendingHash;
				queuedAt = slot.queuedAt;
				slot.pending = nullptr;
				pending_    &= ~( 1u << key );

				// Already showing this cached image: nothing to upload.
				if( hasHash && slot.onDeckKnown && slot.onDeck == hash ) {
					reportShown( key, hash );
					continue;
				}
				slot.onDeckKnown = false;   // unknown while the upload runs
				busy_            = true;
				generation       = generation_;
			}
		}
		if( !image ) {
			ulTaskNotifyTake( pdTRUE, portMAX_DELAY );
			continue;
		}

		int64_t   started = esp_timer_get_time();
		esp_err_t err     = deck_->setKeyImage( key, image->data(), image->size() );
		uint32_t  took    = (uint32_t)( ( esp_timer_get_time() - started ) / 1000 );
		if( hasHash )
			ESP_LOGI( TAG, "Key %u: %02x%02x… uploaded in %u ms, %u ms after it was queued", key, hash[0], hash[1], (unsigned)took, (unsigned)( nowMillis() - queuedAt ) );
		else
			ESP_LOGI( TAG, "Key %u: our own image uploaded in %u ms", key, (unsigned)took );

		std::lock_guard<std::mutex> lock( mutex_ );
		Slot &slot = slots_[key];
		if( err == ESP_OK && hasHash && generation == generation_ ) {
			slot.onDeckKnown = true;
			slot.onDeck      = hash;
			reportShown( key, hash );
		}
	}
}

void KeyUploader::reportShown( uint8_t key, const Hash &hash ) {
	Shown shown = { key, hash };
	xQueueSend( shown_, &shown, 0 );
}
