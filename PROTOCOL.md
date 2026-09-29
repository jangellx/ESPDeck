# ESPDeck wire protocol (version 4)

The Mac app (ESPDeck Bridge) runs a WebSocket server. Any number of ESP32s (ESPDeck Device) connect to it as clients; each is identified by its Wi-Fi MAC address.

## Discovery

- Bonjour service type `_deckbridge._tcp`, fixed port **48620**. TXT record: `id` (the bridge ID, a lowercase UUID the Mac generates once) and `proto` (`4`).
- Each ESP32 resolves the service with mDNS and connects to `ws://<host>:<port>/`.
  - A paired ESP32 only connects to a bridge whose `id` is the one it paired with. Of its addresses it prefers the one where it last authenticated, then one on its own subnet.
  - An unpaired ESP32 connects to the first bridge found, where it can only offer pairing.
  - An address where a paired ESP32's handshake failed (the bridge's `auth` didn't verify, or didn't come within 10 seconds of connecting) is skipped for 10 minutes, unless it's the address where it last authenticated. So something else on the network advertising the bridge's `id` can't keep the device from its real bridge.
- If a device reconnects, its new connection replaces its old one on the Mac.
- Liveness: the ESP32 sends a WebSocket ping every 5 s and closes the connection if no pong arrives within 10 s, so the Mac must answer pings promptly (its Network framework does, on the queue its app logic runs on, so that queue must not stall). The Mac also enables TCP keepalive.
- While a paired device has no authenticated session (Wi-Fi or the bridge unreachable, for 3 s after a drop and from boot until the first session), its deck shows "Connecting / to Wi-Fi" or "Connecting / to Mac" on the top-centre key with a row of blue dots below that fill in left to right and then empty left to right, instead of keys that wouldn't do anything.

## Security

Every ESP32 is paired with one bridge. Pairing uses an X25519 key agreement confirmed by comparing a 6-digit code shown on both the Mac and the deck (numeric comparison with a commitment, as in Bluetooth LE Secure Connections). The user confirms on the Mac and holds a key on the deck, so pairing requires physical access. The result is a 32-byte pairing key `K` that both sides store: the ESP32 in NVS, the Mac in the Keychain.

Every connection starts **unauthenticated**. Until the handshake below succeeds:
- The ESP32 sends only `hello`, `auth`, `pairResponse`, `pairReveal`, `pairConfirm` and `pairCancel`, and accepts only `auth`, `pairRequest`, `pairNonce`, `pairCancel` and `noKey`. It forwards no key presses and obeys no commands.
- The Mac acts on nothing from the device, and shows it as a new device that can be paired (or, for a device that says it's paired with this bridge but whose key the Mac doesn't have, explains how to unpair it). What an unauthenticated connection sends doesn't go into any device's log until it authenticates, and nothing about the device ID it claims is remembered.

Limits before authentication:
- ESP32: text frames longer than 2 KB are ignored, binary frames are ignored, and a paired ESP32 closes the connection if the bridge's `auth` hasn't verified within 10 seconds of connecting (and avoids that address; see Discovery). A bridge with the ESP32's `pairedBridge` ID but no key for it (lost from its Keychain, say) sends `noKey` instead: the ESP32 then stays connected and idle, so the bridge can show it as present and needing unpairing, and the bridge can still send `auth` if it finds the key again (it re-reads it every minute). `noKey` is unauthenticated, so a stand-in could send it too; but while idle the ESP32 looks for another bridge with its `pairedBridge` ID every 30 seconds, and if one turns up it moves to that one (and a stand-in that then fails there is avoided as usual). Firmware 4.1.0 and later; older firmware ignores it.
- ESP32, always: JSON nested deeper than 8 arrays or objects is ignored before it's parsed.
- Mac: at most 8 unauthenticated connections, and 2 from any one address; beyond 8, the oldest one that isn't pairing is closed. A connection that hasn't sent `hello` within 15 seconds, or doesn't finish the handshake within 15 seconds of `auth`, is closed (one listed as a new device waits for the user without a limit; one pairing has about 2 minutes). Before authentication, a binary frame, a frame over 4 KB (32 KB for the `hello`, which lists cached images), more than 12 frames in 10 seconds, or a second `hello` closes the connection.

Notation:
- `HMAC(k, …)` is HMAC-SHA256 over the concatenation of the listed byte strings.
- Strings are their UTF-8 bytes, without a terminator.
- Nonces and keys are raw bytes; on the wire they're lowercase hex.
- X25519 keys and shared secrets are the 32-byte strings of RFC 7748, the same as CryptoKit's `rawRepresentation`. They're little-endian, so use mbedTLS's `_le` functions.

### Pairing

Pairing needs protocol 4 on both sides. `PKm`, `PKd` are the Mac's and the ESP32's fresh X25519 public keys, `Nm`, `Nd` their fresh 16-byte nonces, and `Z` the X25519 shared secret.

1. The user clicks Pair on the Mac. If the Mac already has a pairing key or settings for this device ID, it first asks "Replace the existing pairing for <name>?", and pairs only if the user agrees. The Mac sends `pairRequest` with `bridgeID`, `bridgeName` and `publicKey` (`PKm`).
2. The ESP32 accepts it only if it isn't paired, isn't in setup mode, and isn't installing firmware; otherwise it answers `pairCancel` with a `reason`. It generates its key pair and `Nd`, and answers `pairResponse` with:
   - `publicKey`: `PKd`;
   - `commitment`: `C = HMAC( Nd, "espdeck-pair-commit" ‖ PKd ‖ PKm )`.
3. The Mac sends `pairNonce` with `nonce`: `Nm`. It sends it only after it has `C`.
4. The ESP32 answers `pairReveal` with `nonce`: `Nd`. It reveals it only after it has `Nm`.
5. The Mac checks `C` against `Nd`, `PKd` and `PKm`; if it doesn't match, it stops (and sends `pairCancel`). Both sides compute:
   - `code` = the first 4 bytes of `SHA256( "espdeck-pair-code-v4" ‖ PKm ‖ PKd ‖ Nm ‖ Nd )` as a big-endian unsigned integer, mod 1,000,000, written as 6 digits with leading zeros;
   - `K = HMAC( Z, "espdeck-pairing-key-v4" ‖ PKm ‖ PKd ‖ Nm ‖ Nd ‖ bridgeID ‖ deviceID )`, where `deviceID` is the device's `id` as sent in `hello`.
6. Both show the code. The ESP32 shows it on the deck:
   - top row: `Pair?`, the first 3 digits, the last 3 digits;
   - bottom row: **Cancel** at the left, **Hold to Confirm** at the right; other keys are black;
   - key presses are ignored for 1 second after the code appears;
   - decks without displays (the Pedal) show nothing: the status LED blinks magenta, and holding any key confirms.
7. The user compares the codes:
   - On the deck, holding Confirm for 1.5 seconds confirms (Cancel cancels at a press). The ESP32 then sends `pairConfirm` with `proof` = `HMAC( K, "espdeck-pair-confirm" )`, shows "Waiting for Mac" on the Confirm key (the Pedal's LED stays magenta), and keeps `K` in memory, not yet stored.
   - On the Mac, the user answers "The deck shows this code" or "It doesn't match" (which sends `pairCancel`).
   - These can happen in either order. The Mac checks `proof` when it arrives.
8. Once both have confirmed, the Mac runs the authentication handshake below with the new `K`, using the nonce from the device's original `hello`. The ESP32 checks the Mac's proof against the new `K`, and only then stores `K` and `bridgeID` (and turns uploads from PlatformIO off). The Mac stores `K` when the ESP32's `auth` verifies.

Either side can send `pairCancel` at any time before that. The ESP32 cancels by itself 120 seconds after the `pairRequest`, the Mac about 5 seconds later. The ESP32's `pairCancel` carries `reason`: `deck` (Cancel pressed), `timeout`, `setupMode`, `paired` (it's paired; see below), `busy` (installing firmware), or `failed` (a malformed message or a failed computation). The Mac's `pairCancel` has no fields. A repeated `pairRequest` starts over with new keys and nonces.

A paired ESP32 refuses pairing, and only connects to its own bridge. To move it to another Mac, forget it on the old Mac (which sends `unpair`), or use Unpair on the device's setup page; it's then unpaired and connects to whichever bridge it finds.

Test vectors for all of this, and for the handshake, session and `devOTA` below, are in `ESPDeck Device/tools/crypto_test/vectors.txt`; `run.sh` there checks the firmware's mbedTLS code and the app's CryptoKit code against them.

### Authentication handshake

1. The ESP32's `hello` includes:
   - `nonce`: 16 random bytes;
   - `pairedBridge`: the bridge ID it's paired with, or `""` if it isn't paired.
2. If the Mac has a key `K` for this device ID, it sends `auth` with:
   - `nonce`: 16 random bytes of its own;
   - `proof` = `HMAC( K, "espdeck-bridge" ‖ deviceNonce ‖ bridgeNonce )`.
3. The ESP32 checks `proof`; on a mismatch it closes the connection. It then sends `auth` with:
   - `proof` = `HMAC( K, "espdeck-device" ‖ bridgeNonce ‖ deviceNonce ‖ SHA256( hello ) )`, where `hello` is the exact bytes of the `hello` frame it sent.
   - That binds the `hello` contents to the key.
4. The Mac checks `proof`; on a mismatch it closes the connection. Both sides derive the session key `S = HMAC( K, "espdeck-session" ‖ deviceNonce ‖ bridgeNonce )`, and the session is authenticated.

A `hello` inside the session whose `id` isn't the session's device closes the connection.

Every frame after that, in both directions, carries a MAC:
- **Text frames:** 32 hex characters, then the JSON: `9f86d081884c7d659a2feaa0c55ad015{"type":"show",…}`.
- **Binary frames:** 16 raw MAC bytes, then the payload.
- **MAC value:** the first 16 bytes of `HMAC( S, direction ‖ counter ‖ payload )`.
  - `direction` is the byte `0x01` for Mac → ESP32 and `0x02` for ESP32 → Mac.
  - `counter` is a 64-bit big-endian count of authenticated frames already sent in that direction, starting at 0.
  - `payload` is the JSON bytes or the binary payload.
- A frame whose MAC doesn't verify closes the connection.
- WebSocket ping/pong frames aren't covered.
- Any cryptographic operation that fails (an mbedTLS error) counts as a mismatch: the ESP32 fails closed.

When the Mac forgets a device, it sends `unpair`, and the ESP32 deletes its key. The ESP32's setup page can also delete it.

## Image hashes

- A hash is the first 16 bytes of the SHA-256 of the image file, as 32 lowercase hex characters.
- The ESP32 verifies the hash of every image it receives and drops mismatches.

## Key indices

Row-major from the top-left, as seen from the front of the deck: on a 3 × 2 Mini, `0 1 2` on top and `3 4 5` below. The firmware maps these to each model's own wire order.

## Deck layout and transforms

The ESP32 knows each model's layout from a table keyed by USB product ID, and reports it in the deck object. The Mac renders images to that layout: `keySize` × `keySize` pixels in `format`, with `transform` applied. The ESP32 draws its own images (setup QR codes) with the same values.

| transform | output pixel (x, y) comes from source pixel |
|---|---|
| `none` | (x, y) |
| `transpose` | (y, x) |
| `rotate90` (clockwise) | (y, size−1−x) |
| `rotate270` (counterclockwise) | (size−1−y, x) |
| `rotate180` | (size−1−x, size−1−y) |

## Messages

Control messages are JSON text frames with a `type` field. Image data is a binary frame.

### ESP32 → Mac

| type | fields | when |
|---|---|---|
| `hello` | `protocol` (4), `id` (MAC), `name`, `firmware`, `elfSHA256` (firmware 3.1.0 and later), `nonce`, `pairedBridge`, `cached` (hashes), `deck` (deck object), `settings` (settings object), `status` (status object) | **Unauthenticated.** Sent right after connecting, and again (inside the session, with a MAC) after leaving setup mode. Also resent inside the session as soon as the device is renamed over Improv or on the setup page (see Renaming below). The Mac treats every authenticated `hello` as a full resync; one sent inside the session needs no new handshake, carries the session's original `nonce`, and must have the session's `id`. |
| `auth` | `proof` | **Unauthenticated.** Handshake step 3 |
| `pairResponse` | `publicKey`, `commitment` | **Unauthenticated.** Pairing step 2 |
| `pairReveal` | `nonce` | **Unauthenticated.** Pairing step 4 |
| `pairConfirm` | `proof` | **Unauthenticated.** Pairing step 7: confirmed on the deck |
| `pairCancel` | `reason` | **Unauthenticated.** Pairing cancelled on the deck, timed out, or refused; see Pairing |
| `firmwareStatus` | `state` (`ready`, `progress`, `installed`, `error`), `received` (bytes, for `progress`), `message` (for `error`) | answers to a firmware update |
| `storageStatus` | `state` (`encrypting`, `error`), `message` (for `error`) | the answer to `encryptStorage` (firmware 4.1.0 and later): `encrypting` just before it starts (the device restarts when it's done), or `error` if it refused and nothing changed. See Storage encryption. |
| `deck` | `deck` | the Stream Deck is plugged in or unplugged, or its transform changed; also right after `status` `session` (firmware 4.1.0 and later), since a deck plugged in before the session couldn't be reported |
| `status` | `status`, `reason` | sleep or setup mode changed. `reason` sits beside `status`, not inside it: `timer` (sleep timeout), `key` (woken by a key press), `bridge` (commanded by the Mac), `chord` (setup mode from the corner hold), `boot` (setup mode at boot, no Wi-Fi credentials), `setupPage`, `exitKey`, `improv` (left setup mode), `timeout` (left setup mode after 15 minutes without a phone on its network), `pairing` (woken to show a pairing code), `deck` (woken because a Stream Deck was plugged in), `session` (firmware 4.1.0 and later: sent right after the device's `auth`, as the session's first frame, so the Mac gets `wifi`, which the unauthenticated `hello` leaves out) |
| `usbDevice` | `vid`, `pid`, `class` (the device descriptor's `bDeviceClass`; all three left out if it couldn't be read) | Firmware 4.1.0 and later: something was plugged into the USB port, Stream Deck or not, for the Mac's log. A deck that never shows up can then be told apart from nothing attached; class 9 is a hub, which isn't supported. Also sent after `status` `session` when something is plugged in but no deck is connected (it was plugged in before the Mac connected). |
| `need` | `hash` | told to `show` a hash it doesn't have |
| `shown` | `key`, `hash` | the key now shows that cached image on the deck: just uploaded, or it already did. Drives the Mac's progress bar; firmware without it is handled by a timeout. |
| `keyDown`, `keyUp` | `key` | key pressed or released (not sent while asleep or in setup mode, nor for the key press that wakes the deck) |
| `keyRepeat` | `key` | Firmware 4.1.0 and later: a key in the `repeatKeys` list is still held: sent after the delay, then every interval, until its `keyUp`. The device repeats rather than the Mac, so a late `keyUp` can't cause extra steps. |
| `keyTap`, `keyDoubleTap`, `keyHold` | `key` | Firmware 4.1.0 and later: what kind of press it was (see `keyModes`); `keyDown`/`keyUp` still come too. |

`elfSHA256` is the running app's `app_elf_sha256` from its app description (`esp_app_desc_t`), as 64 lowercase hex digits: the SHA-256 of the ELF file it was built from. Two builds with the same `firmware` version have different values.

**Deck object:** `connected` (bool). When connected, it also has (the Mac ignores a layout outside 1–8 rows, 1–8 columns and 16–256 px keys):
- `model` (string) and `pid` (int)
- `serial` and `firmware` (strings)
- `rows` and `cols` (int)
- `keySize` (pixels)
- `format`: `"bmp"`, `"jpeg"`, or `"none"` for decks without displays
- `transform`: the transform in effect, taken from the setting or the model's default

**Settings object:**
- `orientation`: `"auto"` or a transform name
- `sleepTimeout`: seconds, where 0 means never
- `brightness`: 0–100
- `ip` (string)

**Status object:**
- `asleep` (bool)
- `setupMode` (bool)
- `devOTA` (bool, firmware 3.2.0 and later): uploads from PlatformIO (ArduinoOTA) are allowed, i.e. the device has a password for them
- `storage` (string, firmware 4.1.0 and later): how NVS is stored. `plain`: not encrypted, and `encryptStorage` can encrypt it; `encrypted`; `unsupported`: not encrypted, and the chip has no free eFuse key block to do it with. See Storage encryption.
- `wifi` (object, firmware 4.1.0 and later, **only inside the session**): the Wi-Fi network the device is set up for.
  - `ssid`: the network name in its settings (what it's set up for, even while it isn't on it), `""` if it has none. At most 32 bytes: valid UTF-8, with each invalid byte and each control character (as for `setName`) replaced by `?`. The password is never sent.
  - `connected` (bool): it's on that network now.
  - The first `hello` goes out before authentication, to whichever bridge an unpaired device finds, so it has no `wifi`; the `status` (reason `session`) after the handshake brings it. A `hello` resent inside the session, and every `status`, include it. No signal strength: `status` only goes out when something changes, so it would be stale.

```json
{"type":"hello","protocol":4,"id":"f4:12:fa:00:00:00","name":"Office Deck","firmware":"4.1.0","elfSHA256":"29b53312…","nonce":"5f1c…","pairedBridge":"0c6e0a52-…","cached":["9f86d081884c7d659a2feaa0c55ad015"],
 "deck":{"connected":true,"model":"Stream Deck Mini","pid":99,"serial":"BL12H1A12345","firmware":"1.00.004","rows":2,"cols":3,"keySize":80,"format":"bmp","transform":"transpose"},
 "settings":{"orientation":"auto","sleepTimeout":600,"brightness":80,"ip":"192.168.1.44"},
 "status":{"asleep":false,"setupMode":false,"devOTA":false,"storage":"plain"}}
```

### Mac → ESP32

| type | fields | effect (all settings are persisted on the ESP32) |
|---|---|---|
| `show` | `key`, `hash` | display a cached image on a key; it's also the key's boot image |
| `brightness` | `value` (0–100) | backlight brightness while awake |
| `setName` | `name` | device name: 1 to 32 bytes of UTF-8 without control characters (including line separators, bidirectional overrides and the byte-order mark), not only spaces; anything else is ignored |
| `orientation` | `value` (`"auto"` or a transform) | the ESP32 answers with a `deck` message |
| `sleepTimeout` | `seconds` (0 = never, at most 30 days) | sleep after this long without a key press |
| `sleep`, `wake` | | sleep or wake the deck now |
| `setupMode` | `enabled` (bool) | enter or leave setup mode |
| `setHostname` | `hostname` (1–32 lowercase letters, digits and hyphens, not starting or ending with one; `""` for the original `espdeck-eeff`) | Firmware 4.1.0 and later: its name on the network (DHCP, mDNS as `<hostname>.local`, and so PlatformIO uploads). Taken at startup, so a change restarts the device. `status` reports the current one as `hostname`. |
| `keyModes` | `repeat`, `doubleTap`, `hold` (key indexes; each optional), `delay`, `interval`, `doubleTapWindow`, `holdTime` (milliseconds; clamped to 100–3000, 30–2000, 150–1000, 200–3000) | Firmware 4.1.0 and later: how the keys on the page the Mac shows report presses, judged on the device so network delays can't change them. `repeat` keys send `keyRepeat` while held; `hold` keys send `keyHold` once held for `holdTime` (that press is then no tap); `doubleTap` keys send `keyDoubleTap` for a second press within the window, else `keyTap` once it has passed; other keys send `keyTap` as they come up. A new session starts with none. (`repeatKeys` { `keys`, `delay`, `interval` } from an earlier bridge sets only the repeating keys.) |
| `unpair` | | delete the pairing key; the connection then closes |
| `devOTA` | `sealedHash` (to allow), or `passwordHash`: `""` (to turn off) | Allows uploads from PlatformIO over Wi-Fi (ArduinoOTA, UDP port 3232), or turns them off; the listener starts or stops at once. See **devOTA** below. The device answers with `status` (reason `bridge`), whose `devOTA` shows the result. While allowed, a new image is marked valid once it's on Wi-Fi instead of after the first authenticated session. Pairing again, unpairing, and a factory reset turn uploads off. |
| `factoryReset` | | erase NVS (Wi-Fi, name, pairing, settings) first, then the image cache (once its writer has stopped), then restart; the device comes back in setup mode. The firmware stays, and so does storage encryption (NVS starts over empty and encrypted). The setup page offers the same reset. |
| `encryptStorage` | | Firmware 4.1.0 and later: permanently encrypt NVS with a new key burned into the chip's eFuses, then restart. Answered with `storageStatus`. The Mac sends it only after the user confirmed. See Storage encryption. |
| `firmwareBegin` | `version`, `size` (bytes), `sha256` (hex of the whole image), `allowDowngrade` (bool, optional) | start a firmware update; answered with `firmwareStatus` `ready` or `error`. A `firmwareBegin` during an update abandons that update and starts over (firmware 3.0.3 and later; earlier firmware answers `error`). Refused while an installed update waits to restart, or during an upload from PlatformIO. Firmware 4.0.0 and later refuses an image older than the running version unless `allowDowngrade` is `true`; see Firmware frame. |
| `firmwareEnd` | | all data sent; the ESP32 verifies the SHA-256, answers `installed` or `error`, and on success restarts about 1 second later |

These are the unauthenticated messages from the Mac:

| type | fields | when |
|---|---|---|
| `auth` | `nonce`, `proof` | handshake step 2 |
| `pairRequest` | `bridgeID`, `bridgeName`, `publicKey` | pairing step 1 |
| `pairNonce` | `nonce` | pairing step 3 |
| `pairCancel` | | pairing cancelled on the Mac (or the codes didn't match) |
| `noKey` | | **Unauthenticated.** This Mac knows the deck but has no key for it; the deck waits, idle, while looking for another bridge with its ID (see Limits). Firmware 4.1.0 and later |

### devOTA

The password's SHA-256 works as the password (espota derives its response from it, and it's what ArduinoOTA's `setPasswordHash()` takes), so it never travels in the clear:
- `sealedHash` = hex of the 32-byte SHA-256 of the password's UTF-8 bytes, encrypted with AES-256-GCM, then the 16-byte tag: 96 hex digits.
- Key: `HMAC( S, "espdeck-devota" )`.
- Nonce (12 bytes): `0x01`, three zero bytes, then the 64-bit big-endian counter of the Mac → ESP32 frame that carries the message (the same counter as its MAC). Counters never repeat within a session, and each session has its own `S`.
- No additional data.

The ESP32 stores the hash (as 64 hex digits) only if the tag verifies. It refuses a non-empty `passwordHash` (the unencrypted form of firmware 3.2.x). Each Mac has one developer password for all its devices, which the developer keeps in `ota_password.txt` for PlatformIO.

Once the session is authenticated, the Mac sends `show` for every key, preceded by any images the ESP32 doesn't have.

### Image frame (binary, Mac → ESP32)

| offset | size | content |
|---|---|---|
| 0 | 4 | ASCII `IMG1` |
| 4 | 16 | raw hash bytes |
| 20 | n | image file in the deck's `format`, `keySize` square, transform already applied |

BMP images are 24-bit uncompressed: a 54-byte header (BITMAPFILEHEADER + BITMAPINFOHEADER, 2835 pixels per metre), rows bottom-up, BGR, each row padded to 4 bytes. JPEG images are baseline.

The image is added to the cache. It isn't displayed until a `show` names its hash.

### Firmware frame (binary, Mac → ESP32)

| offset | size | content |
|---|---|---|
| 0 | 4 | ASCII `FWU1` |
| 4 | 4 | offset of this chunk in the image, little-endian |
| 8 | n | up to 16 KB of the app image (the `.bin` that goes into an OTA partition) |

Chunks are sent in order, one at a time: the Mac waits for a `firmwareStatus` `progress` covering each chunk before sending the next.

Before writing the first chunk, the ESP32 (firmware 4.0.0 and later) reads the image's app description (`esp_app_desc_t`, right after the image header and the first segment header): its project name must be the running one's (`ESPDeck`), and its version (`X.Y.Z`) must not be older than the running one unless `firmwareBegin` had `allowDowngrade: true`. The Mac sets that only for an image the user chose from a file and confirmed; release updates only go forward. Otherwise it answers `error` ("Firmware X is older than the running Y.").

The Mac requires each `progress` to report exactly the end of the chunk it sent last, and stops the update otherwise.

The ESP32 writes the image to its inactive OTA slot. After the restart it runs the new image in pending-verify mode, and marks it valid once it has completed an authenticated handshake with its bridge. If that hasn't happened within 10 minutes of boot, it restarts, and the bootloader rolls back to the previous image. `hello`'s `firmware` then reports the version actually running.

After the restart, the Mac decides whether the new image is running by comparing `hello`'s `elfSHA256` with the `app_elf_sha256` in the image it sent, since a development build can carry the same version as the one it replaces. Firmware without `elfSHA256` is compared by version.

The Mac downloads firmware from GitHub Releases:
- tags `firmware-vX.Y.Z`;
- asset `espdeck-firmware-X.Y.Z.bin` is the OTA app image;
- asset `espdeck-firmware-X.Y.Z-merged.bin` is the full flash image for USB installs;
- each has a `.sha256` (`<hash>  <file>`) and a `.sig`: the raw 64-byte Ed25519 signature over the file's exact bytes, made with the release signing key (README, Release signing).

The Mac checks the image against the asset's published SHA-256 and its signature before sending it or writing it over USB. It doesn't offer releases without a `.sig` (everything before 4.1.0), and refuses a download whose signature is missing or doesn't verify.

## USB (Improv serial)

Over USB, a device speaks [Improv Wi-Fi serial](https://www.improv-wifi.com/serial/) (version 1) at 115200 baud: on the UART/COM port always, and on the native USB port's USB-Serial/JTAG when a computer is on it at boot. ESP Web Tools and ESPDeck Bridge's USB Setup page use it.

- The firmware's log lines share the port. A lock keeps each log line and each packet whole, and every packet the device sends ends with a newline, so a client reads lines of text and finds packets by their `IMPROV` header, version 1 and a packet type from 1 to 4, then checks the checksum.
- Commands: `0x01` send Wi-Fi settings, `0x02` request current state, `0x03` request device information, `0x04` request scanned Wi-Fi networks, `0x06` get or set the device name, and ESPDeck's own `0xFE` and `0xFD` (below). Others answer error `0x02` (unknown command); ESPDeck has no hostname command (`0x05`), since its hostname is fixed.
- Device information is `ESPDeck`, the firmware version, `ESP32-S3`, and the device name.
- Send Wi-Fi settings saves the credentials only once they work (within 20 s): the answer is state Provisioned and a result with no URL, since the device's only web page is its setup page. Otherwise it's error `0x03` (unable to connect), and the device goes back to its previous network. In setup mode, joining leaves setup mode (`status` reason `improv`). On a new device (firmware 4.1.0 and later), saving them first encrypts storage, unless Standard was chosen with `0xFD` (see Storage encryption, first setup); the result follows once that's done, within a second, and the log line `Joined <network> as <address> (storage <state>)` says how it went.
- `0x06`, the spec's standard device name command (firmware 3.1.0 and later): with no data it answers the name; with data, the data is the new name itself (UTF-8, 1 to 32 bytes, no NUL, and valid as for `setName`), not a length-prefixed string. The name is stored as `setName` stores it, and the result carries the name in effect. A name that isn't allowed gets error `0x01`. The bridge then learns the new name (see Renaming): firmware 3.1.0 to 4.0.x only told a bridge it had an authenticated session with.
- `0xFE`, ESPDeck's own **Wi-Fi network** command (firmware 4.1.0 and later), with no data. The result (command `0xFE`) has two strings: the network name in the device's settings (the one it's set up for, `""` if none; sanitized as for the status object's `wifi`), and `YES` or `NO` for whether it's on that network now. The password is never sent. The spec numbers its commands up from `0x01` and reserves no vendor range, so ESPDeck takes its own from the top of the range down; a client that sends `0xFE` to anything else gets error `0x02`, as from firmware before 4.1.0. Anyone at the USB port can read the whole flash anyway (unless storage is encrypted, which still doesn't hide the network name from someone who can see which network the device joins), so the name isn't a secret there. ESPDeck Bridge asks for it right after device information, in the same brief session, and treats an error or no answer within 0.7 s as "not reported".
- `0xFD`, ESPDeck's own **storage** command (firmware 4.1.0 and later). With no data it only answers; with one byte it first chooses how a new device's setup stores its settings: `0x00` Standard (plain NVS: joining its first network doesn't burn the eFuse key), `0x01` encrypted (the default: it does). The choice is only taken while storage is `plain`; Standard is remembered in NVS (plain), so a later Wi-Fi change doesn't ask again, until a factory reset clears it, and `0x01` clears it. Anything else as data gets error `0x01`. The result (command `0xFD`) has two strings: the storage, as the status object's `storage` (`plain`, `encrypted`, `unsupported`), and what saving the first network will do: `encrypt`, `standard`, or `none` when there's nothing to choose (the device isn't new, or storage isn't `plain`). ESPDeck Bridge asks after `0xFE`, shows the choice only for `encrypt` or `standard`, and when the user picks Standard, sends `0x00` right before the Wi-Fi settings, in the same session, and doesn't send them unless the answer confirms it (anything but `encrypt`). It asks again after joining, to show the result. Numbered down from `0xFE`, as above; a client that sends it to firmware before 4.1.0 gets error `0x02`.

## Renaming

The name is in `hello`, which the Mac shows. When the device is renamed over Improv or on the setup page (not by the Mac's `setName`, which the Mac already knows), the firmware (4.1.0 and later) tells the Mac at once:
- with an authenticated session, by resending `hello` inside it;
- connected but not authenticated (unpaired and listed under New Devices, say), by closing the connection and reconnecting without the backoff, so the new connection's `hello` has the new name. A pairing in progress isn't interrupted: the device waits for it to end, and once it succeeds, resends `hello` inside the new session.

## Storage encryption

Firmware 4.1.0 and later can encrypt NVS, where the device keeps the Wi-Fi password, the pairing key `K`, the devOTA password hash, the name and settings. Without it, anyone who takes the device can read them from its flash over USB. It uses ESP-IDF's HMAC-based NVS encryption (not flash encryption): the XTS-AES keys that encrypt NVS entries are the ESP32-S3's HMAC peripheral's HMAC-SHA256 of two fixed seeds with a 256-bit key in an eFuse key block whose purpose is `HMAC_UP`. That block is read- and write-protected, so no software can read the key back, and the peripheral only computes with it. Burning it is permanent, so it only happens at two moments: by default when a new device is first set up, and when the Mac asks a device that was set up with plain storage.

- Without a key, NVS stays plain (`storage` is `plain`, or `unsupported` when all six eFuse key blocks are taken). The firmware sets NVS up itself at startup (it takes over Arduino's `nvs_flash_init()` call): encrypted if a key block has the `HMAC_UP` purpose, plain otherwise. ESP-IDF's own `CONFIG_NVS_ENCRYPTION` stays off, since with it `nvs_flash_init()` would burn a key on every device at startup, before anyone could choose.
- **First setup (the default):** a device is *new* when it has no Wi-Fi network saved and isn't paired (a new board, or one after a factory reset), so nothing secret is stored yet. When a new device with `plain` storage saves its first network, over Improv (Send Wi-Fi settings) or from the setup page, it encrypts storage first, unless Standard was chosen for its setup (Improv `0xFD` `0x00`, or the setup page's checkbox). As always, the network is saved only once the device has joined it, so the key is only burned for a network that works; at that point the device:
  1. copies the NVS entries to RAM (only non-secret ones exist: the name, orientation and sleep timer, and the Wi-Fi driver's and PHY calibration data);
  2. burns the key, and erases and sets NVS up encrypted with those entries, as steps 2 to 4 below (about 0.3 s in all);
  3. saves the network's name and password into the encrypted NVS, and carries on without a restart: the Improv result or the setup page's "Connected" follows, and `storage` is `encrypted` from then on (in `hello`, `status`, `0xFD`, and the setup page).
  If it can't encrypt, setup carries on with plain storage and says why in the log: with no free key block or a failed burn nothing has changed; if the key was burned but the move to encrypted NVS failed, NVS is set up plain again with the same entries, the network is saved there, and the device restarts once setup mode ends, so the startup check below encrypts them (reporting `encrypted` meanwhile, since the key is there). A power cut during it is covered as for the move below: the device is new either way, so at worst it starts in setup mode again, with nothing of value lost. A device that isn't new never encrypts by itself; ESP Web Tools (which knows no `0xFD`) gets the default.
- `encryptStorage` (authenticated, sent after the user confirmed on the Mac) is refused with `storageStatus` `error` when storage isn't `plain`, in setup mode, or during a firmware update. Otherwise the device answers `storageStatus` `encrypting`, shows "Encrypting storage" on the deck, and:
  1. copies every NVS entry (all namespaces) to RAM;
  2. burns a new random 256-bit key into the first free key block with purpose `HMAC_UP`, read- and write-protected;
  3. erases the NVS partition (about 0.2 s);
  4. sets NVS up encrypted, writes a marker, writes every entry back, reads each one back to check it, and removes the marker (about 0.1 s);
  5. restarts. Its next `hello` reports `storage` `encrypted`.
- **Power loss** during the move leaves, at the next start:
  - before step 2: plain NVS, all settings kept;
  - after step 2, before step 3: a key and plain NVS. At startup the device looks at NVS's raw pages for entries that are valid as plain text; finding some, it finishes the move itself (steps 3 and 4). Encrypted, all settings kept.
  - during step 3: the same, with only the entries that weren't erased yet (at worst none);
  - during step 4: encrypted NVS with the marker. The device erases it: encrypted and empty, so it starts in setup mode, unpaired.
- **Factory reset** and the **web installer** (which erases the whole flash) leave the key: NVS starts over empty, and encrypted. On a device with plain storage they make it new again, with no Standard choice remembered, so its next setup encrypts by default.
- **Older firmware** (before 4.1.0) on an encrypted device reads NVS as plain; every entry fails its CRC and NVS erases it, so the device starts over in setup mode, unpaired, and stores its new settings unencrypted. Installing 4.1.0 or later again finds those plain entries and encrypts them (as after step 2 above). So the Mac refuses to send an encrypted device (`storage` `encrypted`) firmware older than 4.1.0, even from a file. USB installs and uploads from PlatformIO aren't checked.
- The key can't be erased or replaced, so an encrypted device can't go back to plain NVS.

## Sleep

Sleep turns the deck's backlight off. The ESP32 manages the timer from key activity, so sleep works without the Mac. Any key press wakes the deck, and that press is not forwarded. The Mac sends `sleep` and `wake` for HomeKit-driven rules, and runs its on-sleep and on-wake commands when a `status` message reports a change.

## Setup mode

The ESP32 enters setup mode:
- at boot if it has no Wi-Fi credentials,
- when the top-left and bottom-right keys are held together for 5 seconds,
- or when the Mac sends `setupMode`.

In setup mode it:
- runs a WPA2/WPA3 (transition mode) access point named `ESPDeck-XXXX`, with a new random 12-character password each time setup mode starts (kept only in RAM; the Wi-Fi QR code carries it);
- runs a captive-portal web page at `http://192.168.4.1/` for the device name and Wi-Fi network, and a DNS server that answers every name with 192.168.4.1. On a new device with plain storage (see Storage encryption), the page also has an **Encrypt stored secrets (recommended)** checkbox, on unless Standard was chosen before; its `/status` reports `storage`, `encryptOffered` and `standardStorage`, and `/save` takes `encrypt` (`1` or `0`), which is stored as the Standard choice before the network is tried;
- shows these on the deck, each QR code above a key describing it: a Wi-Fi-join QR code in the left column, a setup-page QR code in the right column, and an Exit key at the bottom center if the device was already set up.

The page and the DNS server only answer phones on the access point: requests arriving from the home network are refused. The page's own requests must carry `Host: 192.168.4.1` (others are redirected to the page, so a web page elsewhere can't reach it by DNS tricks), and a `POST` whose `Origin` isn't `http://192.168.4.1` is refused. A network saved on the page is only stored once the device has joined it (within 30 seconds); otherwise the page shows why, and the previous network stays.

It leaves setup mode when:
- it joins a network saved on the setup page (8 seconds later, so the page can show the result),
- Exit is pressed on the deck or on the web page,
- no phone has been on its network for 15 minutes, if it has a network that works (`status` reason `timeout`),
- or the Mac sends `setupMode` with `enabled: false`.

## Compatibility

- **Protocol 3 devices (firmware 3.x)** still authenticate with the pairing key they have: the handshake, session MACs, images, firmware frames and every other message are unchanged, so they keep working and can be updated to 4.0.0 from the bridge (`firmwareBegin`'s `allowDowngrade` is ignored by them). They can't pair with a protocol 4 bridge (the Mac shows them as needing a firmware update over USB), and the Mac only ever sends them `devOTA` to turn uploads off.
- **Firmware 4.0.0** drops an upload password stored by earlier firmware (which received it in the clear), so uploads from PlatformIO are off after the update until they're allowed again. It also removes the setup network's stored password.
- A protocol 3 bridge can't pair with firmware 4.0.0: the device waits for `pairNonce`, which an older bridge never sends, and times out. A device it paired earlier keeps authenticating with it.
- **Firmware 4.1.0** adds `storage` and `wifi` to the status object, the `status` reason `session`, `encryptStorage` and `storageStatus`, the Improv commands `0xFE` and `0xFD`, and encryption at first setup (a new device encrypts its storage when it saves its first network, unless Standard was chosen); the protocol version stays 4, a Mac that doesn't know them never sends `encryptStorage`, and one that doesn't know `wifi` ignores it (the extra `status` changes nothing it tracks). An encrypted device can't run firmware before 4.1.0 without losing its settings (see Storage encryption).
- **Rollback before 4.1.0:** Arduino's startup marked a new image valid before the firmware ran, so firmware before 4.1.0 never rolled back an update, whatever happened after it. 4.1.0 and later keep it pending until the first authenticated session, as described under Firmware frame (so an update from 4.0.x to 4.1.0 is the first that can roll back, to 4.0.x).
