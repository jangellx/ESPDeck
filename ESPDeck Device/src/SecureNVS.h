// Optional encryption of NVS (the Wi-Fi password, the pairing key, the upload password hash
// and the other settings), with ESP-IDF's HMAC-based NVS encryption: the XTS keys that encrypt
// NVS are derived by the chip's HMAC peripheral from a 256-bit key in an eFuse key block
// (purpose HMAC_UP, read- and write-protected), which no software can read back. It doesn't
// need flash encryption. Burning that key can't be undone, so it only happens when the paired
// bridge asks (encryptStorage), never by itself: a device without the key keeps plain NVS.
//
// Arduino's initArduino() sets up NVS before setup() with nvs_flash_init(). The build wraps
// that call (-Wl,--wrap=nvs_flash_init, in src/CMakeLists.txt) so it comes here instead, which
// opens NVS plain without the key and encrypted with it. CONFIG_NVS_ENCRYPTION stays off: with
// it, nvs_flash_init() burns a key on every device that doesn't have one. A plain
// nvs_flash_init() on encrypted NVS would erase every entry (they fail their CRC), which is
// also why firmware before 4.1.0 starts an encrypted device over from scratch.
#pragma once

#include <cstdint>

#include "esp_err.h"

namespace SecureNVS {
	enum class State : uint8_t {
		Plain,         // not encrypted, and encrypt() can
		Encrypted,
		Unsupported,   // not encrypted, and there's no free eFuse key block to do it with
	};

	// In place of nvs_flash_init(), from initArduino(). With the key, it also finishes a move
	// to encryption that a power cut interrupted (see encrypt()).
	esp_err_t init();

	// NVS was set up here (the wrap is in effect).
	bool ready();

	State       state();
	// The status object's `storage`: "plain", "encrypted" or "unsupported".
	const char *stateName();

	enum class Outcome : uint8_t {
		Refused,     // nothing changed; `error` says why
		Encrypted,   // restart now
		Failed,      // the key is burned but the move didn't finish; restart now (init() sorts it out)
	};

	// Burns a new key and moves every NVS entry over to encrypted NVS. The steps, and what a
	// power cut during each one leaves at the next start:
	//   1. Copy every entry to RAM.        Nothing has changed.
	//   2. Burn the key.                   Plain NVS with a key: init() finds the unencrypted
	//                                      entries and finishes the move (encrypted, all kept).
	//   3. Erase NVS (~0.2 s).             As 2, with the entries not yet erased; those already
	//                                      erased are lost (all of them, at worst).
	//   4. Write the entries back          init() finds the move's marker and erases NVS: empty,
	//      encrypted, verify (~0.1 s).     so the device starts in setup mode, unpaired.
	// NVS is unusable afterwards until the restart.
	Outcome encrypt( const char *&error );
}
