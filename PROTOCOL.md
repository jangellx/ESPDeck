# ESPDeck wire protocol (version 3)

The Mac app (ESPDeck Bridge) runs a WebSocket server. Any number of ESP32s (ESPDeck Device) connect to it as clients; each is identified by its Wi-Fi MAC address.

## Discovery

- Bonjour service type `_deckbridge._tcp`, fixed port **48620**. TXT record: `id` (the bridge ID, a lowercase UUID the Mac generates once) and `proto` (`3`).
- Each ESP32 resolves the service with mDNS. A paired ESP32 connects to the bridge whose `id` matches the one it paired with, if it finds one; otherwise (or if it's unpaired) it connects to the first bridge found, where it can only offer pairing. It connects to `ws://<host>:<port>/`.
- If a device reconnects, its new connection replaces its old one on the Mac.
- Liveness: the ESP32 sends a WebSocket ping every 5 s and closes the connection if no pong arrives within 10 s, so the Mac must answer pings promptly (its Network framework does, on the queue its app logic runs on, so that queue must not stall). The Mac also enables TCP keepalive.
- While a paired device has no authenticated session (Wi-Fi or the bridge unreachable, for 3 s after a drop and from boot until the first session), its deck shows "Connecting / to Wi-Fi" or "Connecting / to Mac" on the top-centre key with a row of blue dots below that fill in left to right and then empty left to right, instead of keys that wouldn't do anything.

## Security

Every ESP32 is paired with one bridge. Pairing uses an X25519 key agreement confirmed by a 6-digit code shown on both the Mac and the deck, and needs a key press on the deck, so it requires physical access. The result is a 32-byte pairing key `K` that both sides store: the ESP32 in NVS, the Mac in the Keychain.

Every connection starts **unauthenticated**. Until the handshake below succeeds:
- The ESP32 sends only `hello`, `auth`, `pairResponse`, `pairConfirm` and `pairCancel`, and accepts only `auth`, `pairRequest` and `pairCancel`. It forwards no key presses and obeys no commands.
- The Mac acts on nothing from the device, and shows it as a new device that can be paired.

Notation:
- `HMAC(k, …)` is HMAC-SHA256 over the concatenation of the listed byte strings.
- Strings are their UTF-8 bytes, without a terminator.
- Nonces and keys are raw bytes; on the wire they're lowercase hex.
- X25519 keys and shared secrets are the 32-byte strings of RFC 7748, the same as CryptoKit's `rawRepresentation`. They're little-endian, so use mbedTLS's `_le` functions.

### Pairing

1. The user clicks Pair on the Mac, which sends `pairRequest` with `bridgeID`, `bridgeName`, and `publicKey`: a fresh X25519 public key.
2. The ESP32 generates its own fresh X25519 key pair and answers `pairResponse` with `publicKey`. Both sides compute the shared secret `Z` and the code:
   - `code` = the first 4 bytes of `SHA256( "espdeck-pair-code" ‖ Z )` as a big-endian unsigned integer, mod 1,000,000, written as 6 digits with leading zeros.
3. The Mac shows the code. The ESP32 shows it on the deck:
   - top row: `Pair?`, the first 3 digits, the last 3 digits;
   - bottom row: **Cancel** at the left, **Confirm** at the right; other keys are black;
   - decks without displays (the Pedal) show nothing, and any key confirms.
4. The user compares the codes and presses Confirm on the deck. The ESP32 then:
   - derives `K = HMAC( Z, "espdeck-pairing-key" ‖ bridgeID ‖ deviceID )`, where `deviceID` is the device's `id` as sent in `hello`;
   - stores `K` and `bridgeID`, replacing any earlier pairing;
   - sends `pairConfirm` with `proof` = `HMAC( K, "espdeck-pair-confirm" )`.
5. The Mac checks `proof`, stores `K`, and continues with the authentication handshake using the nonce from the device's original `hello`.
   - Either side can send `pairCancel` at any time before this.
   - The ESP32 cancels by itself after 120 seconds.
   - The ESP32 also answers a `pairRequest` with `pairCancel` to refuse it, e.g. in setup mode or when key agreement fails.

A pairing request arriving while the ESP32 is already paired can still complete, because it needs the Confirm press. That's how a device moves to a new Mac. But a paired device connects to its own bridge whenever that bridge is online, so the new Mac never gets a chance to pair. Forget the device on the old Mac first (which sends `unpair`), or use Unpair on the device's setup page.

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

Every frame after that, in both directions, carries a MAC:
- **Text frames:** 32 hex characters, then the JSON: `9f86d081884c7d659a2feaa0c55ad015{"type":"show",…}`.
- **Binary frames:** 16 raw MAC bytes, then the payload.
- **MAC value:** the first 16 bytes of `HMAC( S, direction ‖ counter ‖ payload )`.
  - `direction` is the byte `0x01` for Mac → ESP32 and `0x02` for ESP32 → Mac.
  - `counter` is a 64-bit big-endian count of authenticated frames already sent in that direction, starting at 0.
  - `payload` is the JSON bytes or the binary payload.
- A frame whose MAC doesn't verify closes the connection.
- WebSocket ping/pong frames aren't covered.

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
| `hello` | `protocol` (3), `id` (MAC), `name`, `firmware`, `nonce`, `pairedBridge`, `cached` (hashes), `deck` (deck object), `settings` (settings object), `status` (status object) | **Unauthenticated.** Sent right after connecting, and again (inside the session, with a MAC) after leaving setup mode, since the setup page may have renamed the device. The Mac treats every authenticated `hello` as a full resync; one sent inside the session needs no new handshake, and carries the session's original `nonce`. |
| `auth` | `proof` | **Unauthenticated.** Handshake step 3 |
| `pairResponse` | `publicKey` | **Unauthenticated.** Pairing step 2 |
| `pairConfirm` | `proof` | **Unauthenticated.** Pairing step 4 |
| `pairCancel` | | **Unauthenticated.** Pairing cancelled on the deck, or timed out |
| `firmwareStatus` | `state` (`ready`, `progress`, `installed`, `error`), `received` (bytes, for `progress`), `message` (for `error`) | answers to a firmware update |
| `deck` | `deck` | the Stream Deck is plugged in or unplugged, or its transform changed |
| `status` | `status`, `reason` | sleep or setup mode changed. `reason` sits beside `status`, not inside it: `timer` (sleep timeout), `key` (woken by a key press), `bridge` (commanded by the Mac), `chord` (setup mode from the corner hold), `boot` (setup mode at boot, no Wi-Fi credentials), `setupPage`, `exitKey`, `improv` (left setup mode), `pairing` (woken for a pairing request) |
| `need` | `hash` | told to `show` a hash it doesn't have |
| `shown` | `key`, `hash` | the key now shows that cached image on the deck: just uploaded, or it already did. Drives the Mac's progress bar; firmware without it is handled by a timeout. |
| `keyDown`, `keyUp` | `key` | key pressed or released (not sent while asleep or in setup mode, nor for the key press that wakes the deck) |

**Deck object:** `connected` (bool). When connected, it also has:
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

```json
{"type":"hello","protocol":3,"id":"f4:12:fa:00:00:00","name":"Office Deck","firmware":"3.0.0","nonce":"5f1c…","pairedBridge":"0c6e0a52-…","cached":["9f86d081884c7d659a2feaa0c55ad015"],
 "deck":{"connected":true,"model":"Stream Deck Mini","pid":99,"serial":"BL12H1A12345","firmware":"1.00.004","rows":2,"cols":3,"keySize":80,"format":"bmp","transform":"transpose"},
 "settings":{"orientation":"auto","sleepTimeout":600,"brightness":80,"ip":"192.168.1.44"},
 "status":{"asleep":false,"setupMode":false}}
```

### Mac → ESP32

| type | fields | effect (all settings are persisted on the ESP32) |
|---|---|---|
| `show` | `key`, `hash` | display a cached image on a key; it's also the key's boot image |
| `brightness` | `value` (0–100) | backlight brightness while awake |
| `setName` | `name` | device name |
| `orientation` | `value` (`"auto"` or a transform) | the ESP32 answers with a `deck` message |
| `sleepTimeout` | `seconds` (0 = never, at most 30 days) | sleep after this long without a key press |
| `sleep`, `wake` | | sleep or wake the deck now |
| `setupMode` | `enabled` (bool) | enter or leave setup mode |
| `unpair` | | delete the pairing key; the connection then closes |
| `factoryReset` | | erase NVS (Wi-Fi, name, pairing, settings, the setup network's password) and the image cache, then restart; the device comes back in setup mode. The firmware stays. The setup page offers the same reset. |
| `firmwareBegin` | `version`, `size` (bytes), `sha256` (hex of the whole image) | start a firmware update; answered with `firmwareStatus` `ready` or `error`. A `firmwareBegin` during an update abandons that update and starts over (firmware 3.0.3 and later; earlier firmware answers `error`) |
| `firmwareEnd` | | all data sent; the ESP32 verifies the SHA-256, answers `installed` or `error`, and on success restarts about 1 second later |

These are the unauthenticated messages from the Mac:

| type | fields | when |
|---|---|---|
| `auth` | `nonce`, `proof` | handshake step 2 |
| `pairRequest` | `bridgeID`, `bridgeName`, `publicKey` | pairing step 1 |
| `pairCancel` | | pairing cancelled on the Mac |

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

The ESP32 writes the image to its inactive OTA slot. After the restart it runs the new image in pending-verify mode, and marks it valid once it has completed an authenticated handshake with its bridge. If that hasn't happened within 10 minutes of boot, it restarts, and the bootloader rolls back to the previous image. `hello`'s `firmware` then reports the version actually running.

The Mac downloads firmware from GitHub Releases:
- tags `firmware-vX.Y.Z`;
- asset `espdeck-firmware-X.Y.Z.bin` is the OTA app image;
- asset `espdeck-firmware-X.Y.Z-merged.bin` is the full flash image for USB installs.

The Mac checks the image against the asset's published SHA-256 before sending it.

## Sleep

Sleep turns the deck's backlight off. The ESP32 manages the timer from key activity, so sleep works without the Mac. Any key press wakes the deck, and that press is not forwarded. The Mac sends `sleep` and `wake` for HomeKit-driven rules, and runs its on-sleep and on-wake commands when a `status` message reports a change.

## Setup mode

The ESP32 enters setup mode:
- at boot if it has no Wi-Fi credentials,
- when the top-left and bottom-right keys are held together for 5 seconds,
- or when the Mac sends `setupMode`.

In setup mode it:
- runs a WPA2 access point named `ESPDeck-XXXX`, with a random password generated once and stored;
- runs a captive-portal web page at `http://192.168.4.1/` for the device name and Wi-Fi network;
- shows these on the deck, each QR code above a key describing it: a Wi-Fi-join QR code in the left column, a setup-page QR code in the right column, and an Exit key at the bottom center if the device was already set up.

It leaves setup mode when:
- it joins a network saved on the setup page (8 seconds later, so the page can show the result),
- Exit is pressed on the deck or on the web page,
- or the Mac sends `setupMode` with `enabled: false`.
