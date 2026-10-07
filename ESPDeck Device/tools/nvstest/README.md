# ESPDeck virtual-eFuse test kit

Tests firmware 4.1.0's storage encryption on the spare board **without burning anything**:
a test build with ESP-IDF's virtual eFuses (`CONFIG_EFUSE_VIRTUAL` +
`CONFIG_EFUSE_VIRTUAL_KEEP_IN_FLASH`), which keeps its "eFuses" in an `efuse_em` flash
partition (carved from the unused coredump area) instead of the chip. `SecureNVS` already
derives the NVS keys in software in such a build, since the HMAC peripheral only sees the
real eFuses.

The scenarios run the real firmware paths, driven over the board's COM port with Improv:

| Scenario | What it does | Expected |
|---|---|---|
| `first-setup` | new device, rename, join Wi-Fi (default) | encrypted before the network is saved; name and network read back after a restart; no plain entries |
| `opt-out` | new device, Improv `0xFD 0`, join Wi-Fi | stays plain; Standard remembered; `0xFD 1`/`0` switch it; a factory reset clears it |
| `migrate` | plain device set up + made-up pairing, then `encryptStorage` | restarts encrypted, network, name and pairing key unchanged |
| `cut-migrate-1` | power cut right after the burn | the next start finishes the move: everything kept |
| `cut-migrate-2` | power cut after the erase | encrypted and empty: new, setup mode |
| `cut-migrate-3` | power cut halfway through writing back | marker found, erased: encrypted, new |
| `cut-setup-1` | first setup, cut after the burn | encrypted, new (network not saved), name kept |
| `cut-setup-2` / `-3` | first setup, cut after the erase / mid-write | encrypted, new |
| `cut-setup-4` | first setup, cut after the move, before the network is saved | encrypted, new, name kept |
| `cut-setup-5` | first setup, the write fails (no cut) | setup goes on in plain storage; restarts after setup mode; next start encrypts it with the network |

After each cut, the cut-setup and cut-migrate scenarios also set the device up again and check
the network is stored encrypted. Every scenario starts from a new, keyless device (NVS and
`efuse_em` erased). A "power cut" is a restart at that step (`esp_restart()`, armed over Improv
in RTC memory), so flash is left exactly as a cut between two flash operations would leave it;
a cut in the middle of a single flash write isn't simulated (NVS itself handles those).

Test hooks exist only in `~/.platformio/build/ESPDeck-nvstest/work`, a copy of `ESPDeck Device` made by `prepare.py` (anchored
edits that stop the build if the source moved on). The real project isn't changed.

## Before you start

- The spare board ("ESPDeck D978"), **both** ports plugged into this Mac: **USB** for power,
  **COM** for everything else (esptool, logs, Improv). No Stream Deck needed.
- In ESPDeck Bridge, turn off **USB Setup ▸ Look for boards plugged in over USB** (or quit it)
  so it doesn't open the ports mid-test. Close any serial monitor.
- A 2.4 GHz Wi-Fi network the board can join. The scripts ask for its password (never stored);
  or set `NVSTEST_SSID` and `NVSTEST_PASSWORD` for the session.
- `cd "ESPDeck Device/tools/nvstest"` (from the repository root).

## Steps (one command each)

1. **Find the port:** `./nvstest.sh ports`. The COM port is the WCH one
   (`/dev/cu.wchusbserial…`); it's picked automatically when it's the only one, or set
   `export PORT=/dev/cu.wchusbserial…`.
2. **Back up:** `./nvstest.sh backup` (about 3 minutes). Saves the real eFuse summary and the
   whole 16 MB flash (firmware, settings, image cache, partition table) to
   `~/ESPDeck-nvstest-backup/` with its SHA-256 and the board's MAC. It refuses to overwrite an
   existing backup.
3. **Build:** `./nvstest.sh build` (about a minute; no board needed). Refuses to call it ready
   unless the build has virtual eFuses kept in flash and the test hooks.
4. **Flash:** `./nvstest.sh flash`. Checks the build again and that it's the backed-up board,
   erases otadata, NVS and `efuse_em`, writes bootloader, partition table and app, then boots it
   and checks the log says `eFuse virtual mode is enabled`.
5. **Run:** `./nvstest.sh run all` (about 10 minutes), or single scenarios, e.g.
   `./nvstest.sh run first-setup`. Each check prints PASS or FAIL. Every boot must log
   `eFuse virtual mode is enabled`; if one doesn't, it stops at once (go to step 7).
   `NVSTEST_ECHO=1` also shows the board's log live.
6. **Read the log:** the path is printed at the end (`logs/run-….log`): the board's whole log
   plus `===` lines for each step. Look for `FAIL` above it first; the `TEST:` and `SecureNVS`
   lines show each step (burns show as `[Virtual]` eFuse writes).
7. **Restore:** `./nvstest.sh restore` (about 3 minutes). Writes the backed-up 16 MB image
   back (checked against its SHA-256; refuses a different board), then reads the real eFuse
   summary again and compares it with the one from step 2: it must say
   `The chip's real eFuses are unchanged.` The board is then exactly as before, running its
   previous firmware with its settings.
8. **Normal firmware (optional):** to have 4.1.0 on it afterwards, install
   `ESPDeck Device/dist/test-4.1.0/espdeck-4.1.0-usb.bin` from USB Setup (keeps the settings).
   Careful: if its storage is ever empty (no network, not paired) and you then set up Wi-Fi with
   the **Encrypt stored secrets** box checked, that burns the real key. If the backed-up
   settings include a network, restoring doesn't make it new.

`./nvstest.sh efuses` prints the real eFuse summary (read-only) at any time.

## Safety

- Nothing in this kit burns a real eFuse: the only firmware it flashes is checked for
  `CONFIG_EFUSE_VIRTUAL=y` and `CONFIG_EFUSE_VIRTUAL_KEEP_IN_FLASH=y` in its sdkconfig and for
  the virtual-mode message in the binary (the bootloader is built with the same sdkconfig), and
  every boot during the run must print that message. `espefuse summary` is read-only.
- `restore` and `flash` refuse a board whose MAC differs from the backup's.
- If anything goes wrong midway, `./nvstest.sh restore` is always the way back.
