// Firmware updates over the WebSocket (PROTOCOL.md, "Firmware frame"): the image is written
// to the inactive OTA slot chunk by chunk, its SHA-256 checked, and the slot made the boot
// partition. A new image boots pending verification; main marks it valid after its first
// authenticated handshake, or restarts after kRollbackDeadline so the bootloader rolls back.
//
// The first chunk's app description must be ESPDeck's, and unless the bridge said
// allowDowngrade, of the running version or a newer one.
#pragma once

#include <cstddef>
#include <cstdint>

#include "esp_ota_ops.h"
#include "mbedtls/sha256.h"

class FirmwareUpdate {
public:
	// What to answer with, as a firmwareStatus.
	struct Status {
		enum class State : uint8_t {
			None,        // nothing to send
			Ready,
			Progress,
			Installed,
			Error,
		};

		State       state    = State::None;
		size_t      received = 0;
		const char *message  = "";
	};

	bool active() const { return active_; }

	Status begin( const char *version, size_t size, const char *sha256Hex, bool allowDowngrade );
	// An FWU1 frame, MAC already removed.
	Status write( const uint8_t *frame, size_t length );
	Status finish();
	void   abort();

	// MARK: Rollback

	// Whether the running image is a new one that hasn't proven itself yet.
	static bool pendingVerify();
	static void markValid();

private:
	Status fail( const char *message );
	Status checkImage( const uint8_t *chunk, size_t length );

	bool                   active_       = false;
	const esp_partition_t *target_       = nullptr;
	esp_ota_handle_t       handle_       = 0;
	size_t                 size_         = 0;
	size_t                 received_     = 0;
	bool                   downgrade_    = false;   // allowDowngrade
	char                   message_[96]  = {};      // for a Status that needs formatting
	uint8_t                expected_[32] = {};
	mbedtls_sha256_context sha_;
};
