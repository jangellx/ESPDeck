// Optional encryption of NVS (the Wi-Fi password, the pairing key, the upload password hash
// and the other settings), with ESP-IDF's HMAC-based NVS encryption: the XTS keys that encrypt
// NVS are derived by the chip's HMAC peripheral from a 256-bit key in an eFuse key block
// (purpose HMAC_UP, read- and write-protected), which no software can read back. It doesn't
// need flash encryption. Burning that key can't be undone, so it only happens at two moments:
// when a new device (nothing secret stored yet) saves its first Wi-Fi network, unless Standard
// storage was chosen for its setup (encryptForSetup(), from Settings), and when the paired
// bridge asks (encryptStorage, encrypt()). A device without the key keeps plain NVS.
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
	// How NVS is kept.
	enum class State : uint8_t {
		Plain,         // not encrypted, and encrypt() can
		Encrypted,     // with the eFuse key (burned, whether or not NVS has moved over yet)
		Unsupported,   // not encrypted, and there's no free eFuse key block to do it with
	};

	// In place of nvs_flash_init(), from initArduino(). With the key, it also finishes a move
	// to encryption that a power cut interrupted (see encrypt()).
	esp_err_t init();

	// NVS was set up here (the wrap is in effect).
	bool ready();

	// How NVS is kept now.
	State       state();
	// The status object's `storage`: "plain", "encrypted" or "unsupported".
	const char *stateName();

	// What encrypt() and encryptForSetup() did.
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

	// The same for a new device saving its first Wi-Fi network (Settings::setCredentials()),
	// before the credentials are stored, so they never touch plain flash. The entries so far
	// (its name, say) move across. There's no restart: once it returns Encrypted, NVS is
	// encrypted and in use, though every handle opened before is invalid (open it again).
	// If the move fails after the burn (Failed), NVS is set up plain again with the entries,
	// so the setup can go on; the next start encrypts them (init()), and restartWanted() asks
	// for that start. Refused leaves NVS plain and as it was.
	Outcome encryptForSetup( const char *&error );

	// The key is burned but NVS is still plain until the next start (encryptForSetup() fell
	// back); restart once nothing is in the middle of something.
	bool restartWanted();
}
