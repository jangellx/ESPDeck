#include "FirmwareUpdate.h"

#include <cstring>

#include "esp_log.h"

#include "Config.h"
#include "Crypto.h"

static const char *TAG = "Firmware";

namespace {
	constexpr size_t kHeader = 8;   // "FWU1" + offset (LE32)
}

FirmwareUpdate::Status FirmwareUpdate::fail( const char *message ) {
	ESP_LOGW( TAG, "Update failed: %s", message );
	abort();
	Status status;
	status.state   = Status::State::Error;
	status.message = message;
	return status;
}

void FirmwareUpdate::abort() {
	if( !active_ )
		return;
	esp_ota_abort( handle_ );
	mbedtls_sha256_free( &sha_ );
	active_ = false;
}

FirmwareUpdate::Status FirmwareUpdate::begin( const char *version, size_t size, const char *sha256Hex ) {
	Status status;
	status.state = Status::State::Error;
	if( active_ ) {
		status.message = "An update is already running.";
		return status;
	}
	if( !Crypto::fromHex( sha256Hex, expected_, sizeof( expected_ ) ) ) {
		status.message = "Bad SHA-256.";
		return status;
	}

	target_ = esp_ota_get_next_update_partition( nullptr );
	if( !target_ ) {
		status.message = "No OTA partition; reflash over USB once.";
		return status;
	}
	if( size == 0 || size > target_->size ) {
		status.message = "The image doesn't fit.";
		return status;
	}

	// Sequential writes erase as they go, so beginning doesn't block while a whole slot is erased.
	esp_err_t err = esp_ota_begin( target_, OTA_WITH_SEQUENTIAL_WRITES, &handle_ );
	if( err != ESP_OK ) {
		ESP_LOGW( TAG, "esp_ota_begin failed: %s", esp_err_to_name( err ) );
		status.message = "Couldn't start the update.";
		return status;
	}

	mbedtls_sha256_init( &sha_ );
	mbedtls_sha256_starts( &sha_, 0 );
	size_     = size;
	received_ = 0;
	active_   = true;
	ESP_LOGI( TAG, "Updating to %s (%u bytes) in %s", version ? version : "?", (unsigned)size, target_->label );

	status.state = Status::State::Ready;
	return status;
}

FirmwareUpdate::Status FirmwareUpdate::write( const uint8_t *frame, size_t length ) {
	if( !active_ ) {
		Status status;
		status.state   = Status::State::Error;
		status.message = "No update is running.";
		return status;
	}
	if( length <= kHeader || length - kHeader > kMaxFirmwareChunk )
		return fail( "Bad firmware frame." );

	uint32_t offset = frame[4] | ( frame[5] << 8 ) | ( frame[6] << 16 ) | ( (uint32_t)frame[7] << 24 );
	size_t   chunk  = length - kHeader;
	if( offset != received_ )
		return fail( "Chunk out of order." );
	if( received_ + chunk > size_ )
		return fail( "More data than announced." );

	esp_err_t err = esp_ota_write( handle_, frame + kHeader, chunk );
	if( err != ESP_OK ) {
		ESP_LOGW( TAG, "esp_ota_write failed: %s", esp_err_to_name( err ) );
		return fail( "Writing to flash failed." );
	}
	mbedtls_sha256_update( &sha_, frame + kHeader, chunk );
	received_ += chunk;

	Status status;
	status.state    = Status::State::Progress;
	status.received = received_;
	return status;
}

FirmwareUpdate::Status FirmwareUpdate::finish() {
	if( !active_ ) {
		Status status;
		status.state   = Status::State::Error;
		status.message = "No update is running.";
		return status;
	}
	if( received_ != size_ )
		return fail( "The image is incomplete." );

	uint8_t digest[32];
	mbedtls_sha256_finish( &sha_, digest );
	if( !Crypto::equal( digest, expected_, sizeof( digest ) ) )
		return fail( "SHA-256 mismatch." );

	// esp_ota_end() also checks the image's own format and checksum.
	mbedtls_sha256_free( &sha_ );
	active_ = false;
	esp_err_t err = esp_ota_end( handle_ );
	if( err == ESP_OK )
		err = esp_ota_set_boot_partition( target_ );
	if( err != ESP_OK ) {
		ESP_LOGW( TAG, "Installing failed: %s", esp_err_to_name( err ) );
		Status status;
		status.state   = Status::State::Error;
		status.message = err == ESP_ERR_OTA_VALIDATE_FAILED ? "The image isn't valid firmware." : "Installing failed.";
		return status;
	}

	ESP_LOGI( TAG, "Installed in %s", target_->label );
	Status status;
	status.state    = Status::State::Installed;
	status.received = received_;
	return status;
}

// MARK: - Rollback

bool FirmwareUpdate::pendingVerify() {
	esp_ota_img_states_t state;
	return esp_ota_get_state_partition( esp_ota_get_running_partition(), &state ) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY;
}

void FirmwareUpdate::markValid() {
	if( esp_ota_mark_app_valid_cancel_rollback() == ESP_OK )
		ESP_LOGI( TAG, "New firmware marked valid" );
}
