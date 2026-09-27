// Uploads key images to the Stream Deck on its own task, so the main loop never waits on
// the deck (a Mini takes ~320 ms per key).
//
// The main loop says what each key should show; the task uploads the newest image for each
// key, skipping any a key already shows. If a key gets several images while the task is
// busy, only the last is uploaded. Finished uploads of cached images come back through
// nextShown(), so the main loop (which owns the WebSocket) can tell the Mac.
#pragma once

#include <cstdint>
#include <mutex>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "Config.h"
#include "Hash.h"
#include "ImageData.h"
#include "StreamDeck.h"

class KeyUploader {
public:
	struct Shown {
		uint8_t key;
		Hash    hash;
	};

	void begin( StreamDeck &deck );

	// What a key should show: a cached image with its hash, or (hash nullptr) one of our own.
	void show( uint8_t key, ImagePtr image, const Hash *hash );

	// The deck was plugged in or out: nothing is known to be on it, and nothing is pending.
	void reset();

	// A cached image that's now on a key (uploaded, or already there).
	bool nextShown( Shown &shown );

	// Waits until every pending image has been uploaded, up to timeoutMs.
	void waitIdle( uint32_t timeoutMs );

private:
	struct Slot {
		ImagePtr pending;          // newest image not yet uploaded
		bool     pendingHasHash = false;
		Hash     pendingHash    = {};
		uint32_t queuedAt       = 0;   // millis()
		bool     onDeckKnown    = false;   // onDeck is what the key shows
		Hash     onDeck         = {};
	};

	static void task( void *arg );
	void run();

	StreamDeck   *deck_       = nullptr;
	TaskHandle_t  task_       = nullptr;
	QueueHandle_t shown_      = nullptr;
	std::mutex    mutex_;
	Slot          slots_[kMaxKeys];
	uint32_t      pending_    = 0;       // one bit per key with an image waiting
	bool          busy_       = false;   // an upload is in progress
	uint32_t      generation_ = 0;       // bumped by reset(), so a stale upload isn't recorded
};
