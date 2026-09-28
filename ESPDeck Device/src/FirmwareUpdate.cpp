#include "FirmwareUpdate.h"

#include <cstdio>
#include <cstring>

#include "esp_app_desc.h"
#include "esp_app_format.h"
#include "esp_log.h"

#include "Config.h"
#include "Crypto.h"
#include "Text.h"

static const char *TAG = "Firmware";

namespace {
	constexpr size_t kHeader = 8;   // "FWU1" + offset (LE32)

	// The app description follows the image header and the first segment's header.
	constexpr size_t kAppDescOffset = sizeof( esp_image_header_t ) + sizeof( esp_image_segment_header_t );

	// "X.Y.Z" (anything after Z is ignored). False if it isn't one.
	bool parseVersion( const char *text, unsigned parts[3] ) {
		return sscanf( text, "%u.%u.%u", &parts[0], &parts[1], &parts[2] ) == 3;
	}

	bool olderThan( const unsigned a[3], const unsigned b[3] ) {
		for( int i = 0; i < 3; i++ ) {
			if( a[i] != b[i] )
				return a[i] < b[i];
		}
		return false;
	}
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

FirmwareUpdate::Status FirmwareUpdate::begin( const char *version, size_t size, const char *sha256Hex, bool allowDowngrade ) {
	Status status;
	status.state = Status::State::Error;
	// Only the authenticated bridge sends updates, so a new begin means it started over (say,
	// after losing track of the last one): drop the old transfer rather than refuse.
	if( active_ ) {
		ESP_LOGW( TAG, "A new update replaces the one in progress" );
		abort();
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
	if( mbedtls_sha256_starts( &sha_, 0 ) != 0 ) {
		mbedtls_sha256_free( &sha_ );
		esp_ota_abort( handle_ );
		status.message = "Couldn't start the update.";
		return status;
	}
	size_      = size;
	received_  = 0;
	downgrade_ = allowDowngrade;
	active_    = true;
	char safe[24];
	ESP_LOGI( TAG, "Updating to %s (%u bytes) in %s%s", Text::printable( version, safe, sizeof( safe ) ), (unsigned)size, target_->label,
			  allowDowngrade ? ", older versions allowed" : "" );

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
	if( offset == 0 ) {
		Status check = checkImage( frame + kHeader, chunk );
		if( check.state == Status::State::Error )
			return check;
	}

	esp_err_t err = esp_ota_write( handle_, frame + kHeader, chunk );
	if( err != ESP_OK ) {
		ESP_LOGW( TAG, "esp_ota_write failed: %s", esp_err_to_name( err ) );
		return fail( "Writing to flash failed." );
	}
	if( mbedtls_sha256_update( &sha_, frame + kHeader, chunk ) != 0 )
		return fail( "Couldn't check the image." );
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
	if( mbedtls_sha256_finish( &sha_, digest ) != 0 )
		return fail( "Couldn't check the image." );
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

// The image's app description (esp_app_desc_t), before anything reaches the flash: it has to
// be ESPDeck's, and not older than what runs unless the bridge allowed that.
FirmwareUpdate::Status FirmwareUpdate::checkImage( const uint8_t *chunk, size_t length ) {
	esp_app_desc_t description;
	if( length < kAppDescOffset + sizeof( description ) )
		return fail( "The image is too short." );
	memcpy( &description, chunk + kAppDescOffset, sizeof( description ) );
	description.version[sizeof( description.version ) - 1]           = '\0';
	description.project_name[sizeof( description.project_name ) - 1] = '\0';

	const esp_app_desc_t *running = esp_app_get_description();
	if( description.magic_word != ESP_APP_DESC_MAGIC_WORD || strcmp( description.project_name, running->project_name ) != 0 )
		return fail( "The image isn't ESPDeck firmware." );

	unsigned incoming[3], current[3];
	bool     older = !parseVersion( description.version, incoming ) || ( parseVersion( running->version, current ) && olderThan( incoming, current ) );
	if( older && !downgrade_ ) {
		char safe[24];
		snprintf( message_, sizeof( message_ ), "Firmware %s is older than the running %s.", Text::printable( description.version, safe, sizeof( safe ) ),
		          running->version );
		ESP_LOGW( TAG, "%s", message_ );
		abort();
		Status status;
		status.state   = Status::State::Error;
		status.message = message_;
		return status;
	}
	return Status();
}

// MARK: - Rollback

// Arduino's initArduino() asks this before setup(); its default (false) marks a new image
// valid right there, before it has proven anything. main marks it valid itself.
extern "C" bool verifyRollbackLater() {
	return true;
}

bool FirmwareUpdate::pendingVerify() {
	esp_ota_img_states_t state;
	return esp_ota_get_state_partition( esp_ota_get_running_partition(), &state ) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY;
}

void FirmwareUpdate::markValid() {
	if( esp_ota_mark_app_valid_cancel_rollback() == ESP_OK )
		ESP_LOGI( TAG, "New firmware marked valid" );
}
