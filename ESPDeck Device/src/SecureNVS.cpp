// See SecureNVS.h.
#include "SecureNVS.h"

#include <cstring>
#include <vector>

#include "esp_efuse.h"
#include "esp_log.h"
#include "esp_partition.h"
#include "esp_random.h"
#include "esp_rom_crc.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "nvs_sec_provider.h"

#if CONFIG_EFUSE_VIRTUAL
#include "mbedtls/md.h"
#include "private/nvs_sec_provider_private.h"
#endif

static const char *TAG = "SecureNVS";

namespace {
	// Written first when entries go back into encrypted NVS, and removed once they all have and
	// read back correctly. Found at startup, it means the move was cut short.
	constexpr const char *kMarkerNamespace = "securenvs";
	constexpr const char *kMarkerKey       = "moving";

	bool             initialized = false;
	SecureNVS::State current     = SecureNVS::State::Plain;

	// One NVS entry, copied to RAM while NVS is erased and set up again encrypted.
	struct Entry {
		char                 space[NVS_NS_NAME_MAX_SIZE];
		char                 key[NVS_KEY_NAME_MAX_SIZE];
		nvs_type_t           type;
		uint64_t             number;   // integer types
		std::vector<uint8_t> bytes;    // strings (with their terminator) and blobs
	};

	// The copies hold the Wi-Fi password and the pairing key.
	void wipe( std::vector<Entry> &entries ) {
		for( Entry &entry : entries ) {
			if( !entry.bytes.empty() )
				memset( entry.bytes.data(), 0, entry.bytes.size() );
			entry.number = 0;
		}
		entries.clear();
	}

	// The key block holding an HMAC_UP key, if there is one.
	bool findKey( esp_efuse_block_t &block ) {
		return esp_efuse_find_purpose( ESP_EFUSE_KEY_PURPOSE_HMAC_UP, &block );
	}

#if CONFIG_EFUSE_VIRTUAL
	// Virtual eFuses (a test build only): the HMAC peripheral sees the real eFuses, not these,
	// so derive the keys in software from the virtual key block, as the peripheral would.
	bool deriveKeys( esp_efuse_block_t block, nvs_sec_cfg_t &cfg ) {
		uint8_t  key[32];
		uint32_t seeds[2][8];
		for( int i = 0; i < 8; i++ ) {
			seeds[0][i] = EKEY_SEED;
			seeds[1][i] = TKEY_SEED;
		}
		const mbedtls_md_info_t *sha256 = mbedtls_md_info_from_type( MBEDTLS_MD_SHA256 );
		bool ok = esp_efuse_read_block( block, key, 0, sizeof( key ) * 8 ) == ESP_OK
		          && mbedtls_md_hmac( sha256, key, sizeof( key ), (const uint8_t *)seeds[0], sizeof( seeds[0] ), cfg.eky ) == 0
		          && mbedtls_md_hmac( sha256, key, sizeof( key ), (const uint8_t *)seeds[1], sizeof( seeds[1] ), cfg.tky ) == 0;
		memset( key, 0, sizeof( key ) );
		ESP_LOGW( TAG, "Virtual eFuses: NVS keys derived in software (a test build)" );
		return ok;
	}
#else
	// ESP-IDF's HMAC scheme (nvs_sec_provider): the peripheral's HMAC of two fixed seeds with
	// the eFuse key. Reading never burns anything; only generating would.
	bool deriveKeys( esp_efuse_block_t block, nvs_sec_cfg_t &cfg ) {
		static nvs_sec_scheme_t *scheme = nullptr;
		if( !scheme ) {
			nvs_sec_config_hmac_t config = { .hmac_key_id = (hmac_key_id_t)( block - EFUSE_BLK_KEY0 ) };
			if( nvs_sec_provider_register_hmac( &config, &scheme ) != ESP_OK ) {
				scheme = nullptr;
				return false;
			}
		}
		return nvs_flash_read_security_cfg_v2( scheme, &cfg ) == ESP_OK;
	}
#endif

	// Whether NVS holds unencrypted entries, read from flash without setting NVS up (which
	// would change it). NVS's format: 4 KB pages, each a 32-byte header, a 32-byte bitmap of
	// entry states (2 bits each; 0b10 is written), then 126 entries of 32 bytes. Encryption
	// leaves the header and the bitmap as they are and encrypts the entries, so a written entry
	// whose CRC checks out as plain text is unencrypted (a false match is a 1 in 2^32 chance).
	bool holdsPlainEntries( const esp_partition_t *partition ) {
		constexpr size_t   kPageSize      = 4096;
		constexpr size_t   kEntryCount    = 126;
		constexpr size_t   kEntrySize     = 32;
		constexpr size_t   kBitmapOffset  = 32;
		constexpr size_t   kEntriesOffset = 64;
		constexpr uint32_t kActive        = 0xFFFFFFFE;
		constexpr uint32_t kFull          = 0xFFFFFFFC;
		constexpr uint32_t kFreeing       = 0xFFFFFFF8;
		constexpr uint8_t  kWritten       = 0b10;

		for( size_t page = 0; page + kPageSize <= partition->size; page += kPageSize ) {
			uint32_t state = 0;
			uint8_t  bitmap[32];
			if( esp_partition_read( partition, page, &state, sizeof( state ) ) != ESP_OK
			    || ( state != kActive && state != kFull && state != kFreeing )
			    || esp_partition_read( partition, page + kBitmapOffset, bitmap, sizeof( bitmap ) ) != ESP_OK )
				continue;

			for( size_t index = 0; index < kEntryCount; index++ ) {
				if( ( ( bitmap[index / 4] >> ( ( index % 4 ) * 2 ) ) & 0b11 ) != kWritten )
					continue;
				uint8_t item[kEntrySize];
				if( esp_partition_read( partition, page + kEntriesOffset + index * kEntrySize, item, sizeof( item ) ) != ESP_OK )
					continue;
				// Over the namespace, type, span and chunk bytes, then the key and the data.
				uint32_t stored = 0;
				memcpy( &stored, item + 4, sizeof( stored ) );
				uint32_t crc = esp_rom_crc32_le( 0xFFFFFFFF, item, 4 );
				crc = esp_rom_crc32_le( crc, item + 8, kEntrySize - 8 );
				if( crc == stored )
					return true;
			}
		}
		return false;
	}

	template <typename T>
	bool getNumber( esp_err_t ( *get )( nvs_handle_t, const char *, T * ), nvs_handle_t handle, Entry &entry ) {
		T value;
		if( get( handle, entry.key, &value ) != ESP_OK )
			return false;
		entry.number = (uint64_t)value;
		return true;
	}

	template <typename T>
	bool setNumber( esp_err_t ( *set )( nvs_handle_t, const char *, T ), nvs_handle_t handle, const Entry &entry ) {
		return set( handle, entry.key, (T)entry.number ) == ESP_OK;
	}

	bool readValue( nvs_handle_t handle, Entry &entry ) {
		size_t length = 0;
		switch( entry.type ) {
			case NVS_TYPE_U8:  return getNumber( nvs_get_u8, handle, entry );
			case NVS_TYPE_I8:  return getNumber( nvs_get_i8, handle, entry );
			case NVS_TYPE_U16: return getNumber( nvs_get_u16, handle, entry );
			case NVS_TYPE_I16: return getNumber( nvs_get_i16, handle, entry );
			case NVS_TYPE_U32: return getNumber( nvs_get_u32, handle, entry );
			case NVS_TYPE_I32: return getNumber( nvs_get_i32, handle, entry );
			case NVS_TYPE_U64: return getNumber( nvs_get_u64, handle, entry );
			case NVS_TYPE_I64: return getNumber( nvs_get_i64, handle, entry );
			case NVS_TYPE_STR:
				if( nvs_get_str( handle, entry.key, nullptr, &length ) != ESP_OK )
					return false;
				entry.bytes.resize( length );
				return nvs_get_str( handle, entry.key, (char *)entry.bytes.data(), &length ) == ESP_OK;
			case NVS_TYPE_BLOB:
				if( nvs_get_blob( handle, entry.key, nullptr, &length ) != ESP_OK )
					return false;
				entry.bytes.resize( length );
				return length == 0 || nvs_get_blob( handle, entry.key, entry.bytes.data(), &length ) == ESP_OK;
			default:
				return false;
		}
	}

	bool writeValue( nvs_handle_t handle, const Entry &entry ) {
		switch( entry.type ) {
			case NVS_TYPE_U8:   return setNumber( nvs_set_u8, handle, entry );
			case NVS_TYPE_I8:   return setNumber( nvs_set_i8, handle, entry );
			case NVS_TYPE_U16:  return setNumber( nvs_set_u16, handle, entry );
			case NVS_TYPE_I16:  return setNumber( nvs_set_i16, handle, entry );
			case NVS_TYPE_U32:  return setNumber( nvs_set_u32, handle, entry );
			case NVS_TYPE_I32:  return setNumber( nvs_set_i32, handle, entry );
			case NVS_TYPE_U64:  return setNumber( nvs_set_u64, handle, entry );
			case NVS_TYPE_I64:  return setNumber( nvs_set_i64, handle, entry );
			case NVS_TYPE_STR:  return !entry.bytes.empty() && nvs_set_str( handle, entry.key, (const char *)entry.bytes.data() ) == ESP_OK;
			case NVS_TYPE_BLOB: return nvs_set_blob( handle, entry.key, entry.bytes.data(), entry.bytes.size() ) == ESP_OK;
			default:            return false;
		}
	}

	// Every entry of every namespace (the marker's aside), from NVS as it's set up now.
	bool readAll( std::vector<Entry> &entries ) {
		nvs_iterator_t iterator = nullptr;
		esp_err_t      err      = nvs_entry_find( NVS_DEFAULT_PART_NAME, nullptr, NVS_TYPE_ANY, &iterator );
		bool           ok       = true;
		while( ok && err == ESP_OK ) {
			nvs_entry_info_t info;
			nvs_entry_info( iterator, &info );
			if( strcmp( info.namespace_name, kMarkerNamespace ) != 0 ) {
				Entry entry = {};
				strlcpy( entry.space, info.namespace_name, sizeof( entry.space ) );
				strlcpy( entry.key, info.key, sizeof( entry.key ) );
				entry.type = info.type;
				nvs_handle_t handle;
				ok = nvs_open( entry.space, NVS_READONLY, &handle ) == ESP_OK;
				if( ok ) {
					ok = readValue( handle, entry );
					nvs_close( handle );
				}
				if( ok )
					entries.push_back( std::move( entry ) );
				else
					ESP_LOGE( TAG, "Reading %s/%s (type 0x%02x) failed", entry.space, entry.key, entry.type );
			}
			err = nvs_entry_next( &iterator );
		}
		nvs_release_iterator( iterator );
		if( ok && err != ESP_ERR_NVS_NOT_FOUND ) {
			ESP_LOGE( TAG, "Listing NVS failed: %s", esp_err_to_name( err ) );
			ok = false;
		}
		return ok;
	}

	bool setMarker( bool on ) {
		nvs_handle_t handle;
		if( nvs_open( kMarkerNamespace, NVS_READWRITE, &handle ) != ESP_OK )
			return false;
		esp_err_t err = on ? nvs_set_u8( handle, kMarkerKey, 1 ) : nvs_erase_key( handle, kMarkerKey );
		bool      ok  = err == ESP_OK && nvs_commit( handle ) == ESP_OK;
		nvs_close( handle );
		return ok;
	}

	bool hasMarker() {
		nvs_handle_t handle;
		uint8_t      value = 0;
		if( nvs_open( kMarkerNamespace, NVS_READONLY, &handle ) != ESP_OK )
			return false;
		bool found = nvs_get_u8( handle, kMarkerKey, &value ) == ESP_OK;
		nvs_close( handle );
		return found;
	}

	// Writes the entries into the (encrypted, empty) NVS, commits, and reads each one back.
	bool writeAll( const std::vector<Entry> &entries ) {
		for( const Entry &entry : entries ) {
			nvs_handle_t handle;
			if( nvs_open( entry.space, NVS_READWRITE, &handle ) != ESP_OK )
				return false;
			bool ok = writeValue( handle, entry ) && nvs_commit( handle ) == ESP_OK;
			nvs_close( handle );
			if( !ok ) {
				ESP_LOGE( TAG, "Writing %s/%s failed", entry.space, entry.key );
				return false;
			}
		}

		for( const Entry &entry : entries ) {
			Entry check = {};
			memcpy( check.space, entry.space, sizeof( check.space ) );
			memcpy( check.key, entry.key, sizeof( check.key ) );
			check.type = entry.type;
			nvs_handle_t handle;
			bool ok = nvs_open( entry.space, NVS_READONLY, &handle ) == ESP_OK;
			if( ok ) {
				ok = readValue( handle, check ) && check.number == entry.number && check.bytes == entry.bytes;
				nvs_close( handle );
			}
			if( !check.bytes.empty() )
				memset( check.bytes.data(), 0, check.bytes.size() );
			if( !ok ) {
				ESP_LOGE( TAG, "%s/%s didn't read back as written", entry.space, entry.key );
				return false;
			}
		}
		return true;
	}

	// Steps 3 and 4 of encrypt(): NVS (plain, set up or not) becomes encrypted NVS holding
	// `entries`. False if that didn't finish; the marker then empties NVS at the next start.
	bool moveInto( const nvs_sec_cfg_t &keys, const std::vector<Entry> &entries ) {
		nvs_flash_deinit();   // fails harmlessly if NVS isn't set up
		esp_err_t err = nvs_flash_erase();
		if( err != ESP_OK ) {
			ESP_LOGE( TAG, "Erasing NVS failed: %s", esp_err_to_name( err ) );
			return false;
		}
		nvs_sec_cfg_t cfg = keys;
		err = nvs_flash_secure_init( &cfg );
		memset( &cfg, 0, sizeof( cfg ) );
		if( err != ESP_OK ) {
			ESP_LOGE( TAG, "Setting up encrypted NVS failed: %s", esp_err_to_name( err ) );
			return false;
		}
		if( !setMarker( true ) || !writeAll( entries ) || !setMarker( false ) )
			return false;
		ESP_LOGI( TAG, "NVS encrypted: %u entries moved", (unsigned)entries.size() );
		return true;
	}
}

// MARK: - Startup

esp_err_t SecureNVS::init() {
	if( initialized )
		return ESP_OK;

	esp_efuse_block_t block;
	if( !findKey( block ) ) {
		current = esp_efuse_find_unused_key_block() != EFUSE_BLK_KEY_MAX ? State::Plain : State::Unsupported;
		esp_err_t err = nvs_flash_init_partition( NVS_DEFAULT_PART_NAME );
		initialized   = err == ESP_OK;
		return err;
	}

	// Never set up plain from here on: that would erase every encrypted entry.
	current = State::Encrypted;
	nvs_sec_cfg_t keys = {};
	if( !deriveKeys( block, keys ) ) {
		ESP_LOGE( TAG, "Deriving the NVS keys from eFuse key block %d failed; settings are unavailable", (int)block );
		return ESP_ERR_NVS_SEC_HMAC_XTS_KEYS_DERIV_FAILED;
	}

	const esp_partition_t *partition = esp_partition_find_first( ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_NVS, NVS_DEFAULT_PART_NAME );
	if( partition && holdsPlainEntries( partition ) ) {
		// The key was burned but the move didn't finish (or firmware without encryption
		// support wrote here since): move what's there now.
		ESP_LOGW( TAG, "Unencrypted NVS entries found; encrypting them" );
		std::vector<Entry> entries;
		bool read = nvs_flash_init_partition( NVS_DEFAULT_PART_NAME ) == ESP_OK && readAll( entries );
		if( !read ) {
			ESP_LOGE( TAG, "Reading the unencrypted entries failed; starting empty" );
			wipe( entries );
		}
		bool moved = moveInto( keys, entries );
		wipe( entries );
		if( moved ) {
			memset( &keys, 0, sizeof( keys ) );
			initialized = true;
			return ESP_OK;
		}
		// Left with the marker (or nothing): the code below empties NVS.
		nvs_flash_deinit();
	}

	esp_err_t err = nvs_flash_secure_init( &keys );
	if( err == ESP_OK && hasMarker() ) {
		ESP_LOGE( TAG, "Encrypting NVS didn't finish; erasing it (the device starts over in setup mode)" );
		nvs_flash_deinit();
		err = nvs_flash_erase();
		if( err == ESP_OK )
			err = nvs_flash_secure_init( &keys );
	}
	memset( &keys, 0, sizeof( keys ) );
	// initArduino() erases NVS and calls again after ESP_ERR_NVS_NO_FREE_PAGES or
	// ESP_ERR_NVS_NEW_VERSION_FOUND, as for plain NVS.
	initialized = err == ESP_OK;
	if( initialized )
		ESP_LOGI( TAG, "NVS is encrypted (eFuse key block %d)", (int)block );
	return err;
}

bool SecureNVS::ready() {
	return initialized;
}

SecureNVS::State SecureNVS::state() {
	return current;
}

const char *SecureNVS::stateName() {
	switch( current ) {
		case State::Plain:     return "plain";
		case State::Encrypted: return "encrypted";
		default:               return "unsupported";
	}
}

// MARK: - Encrypting

SecureNVS::Outcome SecureNVS::encrypt( const char *&error ) {
	error = nullptr;
	if( current != State::Plain || !initialized ) {
		error = current == State::Encrypted ? "Storage is already encrypted."
		        : current == State::Unsupported ? "This chip has no free eFuse key block."
		        : "Storage isn't available.";
		return Outcome::Refused;
	}
	esp_efuse_block_t block = esp_efuse_find_unused_key_block();
	if( block == EFUSE_BLK_KEY_MAX ) {
		current = State::Unsupported;
		error   = "This chip has no free eFuse key block.";
		return Outcome::Refused;
	}

	// 1. Everything in NVS, in RAM.
	std::vector<Entry> entries;
	if( !readAll( entries ) ) {
		wipe( entries );
		error = "Reading the stored settings failed.";
		return Outcome::Refused;
	}

	// 2. The key. Wi-Fi is on (the request came over it), so esp_fill_random() is a true
	// random source.
	uint8_t key[32];
	esp_fill_random( key, sizeof( key ) );
	ESP_LOGW( TAG, "Burning the NVS key into eFuse key block %d (HMAC_UP, read- and write-protected)", (int)block );
	esp_err_t err = esp_efuse_write_key( block, ESP_EFUSE_KEY_PURPOSE_HMAC_UP, key, sizeof( key ) );
	memset( key, 0, sizeof( key ) );
	esp_efuse_block_t burned;
	if( !findKey( burned ) ) {
		ESP_LOGE( TAG, "Burning the key failed: %s", esp_err_to_name( err ) );
		wipe( entries );
		error = "Burning the eFuse key failed; nothing changed.";
		return Outcome::Refused;
	}
	current = State::Encrypted;
	if( err != ESP_OK || burned != block )
		ESP_LOGW( TAG, "Burning reported %s; using the key in block %d", esp_err_to_name( err ), (int)burned );

	nvs_sec_cfg_t keys = {};
	if( !deriveKeys( burned, keys ) ) {
		// NVS is untouched; after the restart it can't be read either.
		ESP_LOGE( TAG, "Deriving the NVS keys failed" );
		wipe( entries );
		error = "The key is burned, but deriving the storage keys from it failed.";
		return Outcome::Failed;
	}

	// 3 and 4.
	bool moved = moveInto( keys, entries );
	memset( &keys, 0, sizeof( keys ) );
	wipe( entries );
	if( !moved ) {
		error = "The key is burned, but moving the settings failed.";
		return Outcome::Failed;
	}
	return Outcome::Encrypted;
}

// MARK: - The wrapped nvs_flash_init()

extern "C" esp_err_t __wrap_nvs_flash_init( void ) {
	return SecureNVS::init();
}
