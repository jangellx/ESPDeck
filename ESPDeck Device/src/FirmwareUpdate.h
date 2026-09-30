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
		// The firmwareStatus `state`.
		enum class State : uint8_t {
			None,        // nothing to send
			Ready,       // begun; send the chunks
			Progress,
			Installed,   // verified and set to boot; restart to run it
			Error,
		};

		State       state    = State::None;
		size_t      received = 0;    // bytes so far (Progress, Installed)
		const char *message  = "";   // why (Error)
	};

	// A transfer is under way.
	bool active() const { return active_; }

	// Starts a transfer into the inactive slot, dropping any in progress.
	Status begin( const char *version, size_t size, const char *sha256Hex, bool allowDowngrade );
	// An FWU1 frame, MAC already removed.
	Status write( const uint8_t *frame, size_t length );
	// Checks the SHA-256 and makes the slot the boot partition.
	Status finish();
	// Drops the transfer in progress, if any.
	void   abort();

	// MARK: Rollback

	// Whether the running image is a new one that hasn't proven itself yet.
	static bool pendingVerify();
	// Cancels the rollback: the running image stays.
	static void markValid();

private:
	// Aborts the transfer and answers message as an Error.
	Status fail( const char *message );
	// Checks the first chunk's app description; an Error (transfer aborted) if it won't do.
	Status checkImage( const uint8_t *chunk, size_t length );

	bool                   active_       = false;
	const esp_partition_t *target_       = nullptr;
	esp_ota_handle_t       handle_       = 0;
	size_t                 size_         = 0;
	size_t                 received_     = 0;
	bool                   downgrade_    = false;   // allowDowngrade
	char                   message_[96]  = {};      // for a Status that needs formatting
	uint8_t                expected_[32] = {};      // the announced SHA-256
	mbedtls_sha256_context sha_;                    // of what's been written so far
};
