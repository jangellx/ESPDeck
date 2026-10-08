# ESPDeck

Turn an Elgato Stream Deck into a HomeKit control deck that sits anywhere in the house, with no computer attached to it. An ESP32-S3 dev kit plugs into the Stream Deck and connects it over Wi-Fi to **ESPDeck Bridge**, a Mac app that watches your Home and runs what the keys do.

- **Keys that show what's happening.** A key shows its accessory's state (on or off, open, opening, closed, locked) with the icon, label and color you choose for each state, and follows changes made anywhere else.
- **Accessories, scenes and Shortcuts.** A key toggles an accessory or a group of them, runs a scene, or runs one of your Shortcuts. A tap, a double tap and a hold can each do something different.
- **Brightness and fan speed.** A pair of keys steps a light's brightness or a fan's speed up and down; holding repeats.
- **Pages.** A deck has as many pages of keys as you like, with keys that move between them.
- **Every Stream Deck with keys.** Mini, Original, MK.2, XL, Neo, +, Pedal and the modules, each in its own layout; several decks can share one Mac.
- **Sleep and wake.** The deck's screen sleeps on a timer or when a HomeKit accessory changes (a door locks, a light goes off), and can run a scene or a shortcut as it sleeps and wakes.
- **Set up from the Mac.** The app installs the firmware over USB, joins the dev kit to Wi-Fi and names it; firmware updates then arrive over Wi-Fi.
- **Paired and private.** A deck only obeys the Mac it's paired with, over an authenticated connection on your own network. There's no account and no cloud service; the secrets a deck stores can be encrypted on its chip.
- **Try it without hardware.** A demo deck lays out keys and tests their actions before anything is built.

The Mac app does all the work; the ESP32 only bridges Wi-Fi to USB HID and caches images.

- **ESPDeck Bridge/**: Mac Catalyst app (Xcode). HomeKit observation and control, key assignments, rendering, WebSocket server.
- **ESPDeck Device/**: ESP32-S3 firmware (PlatformIO, ESP-IDF 5.5 + Arduino 3.3 as a component).
- **PROTOCOL.md**: the wire format both sides implement.
- **web/**: the browser installer (ESP Web Tools), published with GitHub Pages; see `web/README.md`.

## Requirements

- A Mac on **macOS 14 (Sonoma) or later**, signed in to an iCloud account that's a **member of the Home**. It has to **stay on and logged in**; for an always-on deck, turn on automatic login and the app's **Launch at Login**.
- An **ESP32-S3 dev kit with 16 MB flash and 8 MB PSRAM** (ESP32-S3-DevKitC-1 **N16R8**) running ESPDeck firmware.
- An **Elgato Stream Deck** (Mini, Original, MK.2, XL, Neo, +, Pedal, or a module).
- A **5 V USB-C power supply rated 2 A or more**. Through the OTG adapter, it powers both the ESP32-S3 and the Stream Deck.
- A **passive USB-C OTG adapter with a power input**: a USB-C plug for the board's native **USB** port, a USB-A port for the Stream Deck, and a USB-C port for the power supply. It must be passive; adapters that need USB-PD negotiation may never switch on power to the Stream Deck.
- If the Stream Deck's cable ends in USB-C: a **USB-A (male) to USB-C (female) adapter** that includes the CC pull-up resistor, so the Stream Deck sees a power source. Choose one labeled for **charging and data** (sometimes "sync"), not charge-only; one whose listing mentions a **56 kΩ resistor** is the surest bet. To check an adapter before building, plug the Stream Deck through it into a Mac: if the deck lights up and appears in System Information → USB, it will work. If the deck's cable already ends in USB-A, you don't need this adapter.
- A **USB-C cable that carries data** (not a charge-only one). It connects the power supply to the OTG adapter, and the board's **USB** port to the Mac when installing firmware.
- A **2.4 GHz Wi-Fi network** that the Mac and the ESP32 share.

## Firmware

1. Install the firmware (below): from ESPDeck Bridge's **USB Setup** page, with the web installer, or with `pio run -t upload`.
2. Plug in a Stream Deck. Every model with keys works (Mini, Original, MK.2, XL, Neo, +, Pedal, and the modules); the firmware reports its layout and image format to the Mac.
3. Set up Wi-Fi in setup mode (below). There's nothing to configure at build time.

### Installing

**The board's two USB ports.** The ESP32-S3 dev kit has two USB-C ports:
- **USB**: the chip's own USB. ESPDeck uses it for the Stream Deck (through the OTG adapter), and it's also the easiest port to install through.
- **UART**, or **COM** on many clone boards (the "YD-ESP32-S3" style of N16R8 board is common): a USB-to-serial chip, for logs.

**Clone boards.** On some clones, the COM port doesn't power the board. Use the USB port for setup in any case: ESPDeck Bridge's USB Setup works there. Otherwise they work the same as Espressif's board.

**Steps:**
1. Connect the board's **USB** port to the computer with a data cable.
2. **Put the board in flashing mode** if it's running other firmware; a new board's demo firmware usually is. Hold **BOOT** (also labeled B0 or IO0), press and release **RST** (also labeled EN or RESET), then release BOOT. A new serial port appears (`/dev/cu.usbmodem…` on a Mac).
3. Install with ESPDeck Bridge (next paragraph), the web installer, or `pio run -t upload --upload-port /dev/cu.usbmodem…`.
4. If the board doesn't start ESPDeck afterward (its serial port is still there), press **RST** or unplug and replug it.
5. With ESPDeck Bridge or the web installer, stay there: once ESPDeck starts, you can **connect it to Wi-Fi** over the same cable (with the [Improv](https://www.improv-wifi.com/serial/) protocol). Pick your network and enter its password. If you skip this, set up Wi-Fi later with the QR codes on the deck (setup mode, below).

**With ESPDeck Bridge (Mac):** open **USB Setup** in the configuration window's sidebar, or choose **Set Up a Device over USB…** in the menu bar menu.

*Finding the board*
- With **Look for boards plugged in over USB** on (the default; turn it off if you use this Mac for other ESP32 work), the page lists the boards plugged in, and the sidebar entry shows how many. With several boards, click the one to set up.
- When an ESP32 appears on its own USB port, the app opens that port once and asks what it's running (Improv device information), which Wi-Fi network it's set up for (firmware 4.1.0 and later; the name only, never the password) and whether its stored secrets are encrypted. Then it closes the port again. Opening it doesn't restart the board.
- A board on a USB serial chip (a COM or UART port) is asked only when you click **Check**, since opening such a port can restart the board.
- Setup itself is done on the board's **USB** port. On a COM port the page only shows the board, with a note to move the cable; the steps (installing firmware, Wi-Fi, the name) appear once it's on the USB port.

*What Board Info shows for an ESPDeck board*
- Its version against the latest release: up to date, an update available, or newer (a development build).
- Its Wi-Fi network: "Wi-Fi: <name>", marked "not connected" when it isn't on it, or "No Wi-Fi set up".
- Whether its stored secrets are encrypted: "Stored secrets: encrypted" or "not encrypted".

*1. Install Firmware*
- Choose the firmware in the Firmware menu: the latest release from GitHub (checked against its SHA-256 and signature), or a file from **Choose File…** at the end of the menu. The refresh button next to it looks for new releases.
- Click **Install Firmware**. Installing an older version than the board runs asks first.
- The app puts the board into flashing mode itself: through the reset lines of the USB-Serial/JTAG port, or, for firmware with its own USB serial port, the 1200 bps signal that Arduino sketches honor. Other firmware (ESP-IDF's USB examples, say) ignores that, and then the page asks you to hold BOOT and press RST. The board comes back as a new port in the same USB socket, which the page follows.
- Before writing anything, in the bootloader, it checks the chip (ESP32-S3), the flash size (the flash chip's JEDEC ID, against what the image's partition table needs: 16 MB) and the built-in PSRAM (from the eFuses: 8 or 16 MB of octal PSRAM, without which the firmware stops at startup). It shows what it found, like "ESP32-S3, 16 MB flash, 8 MB PSRAM".
- It writes the bootloader, partition table and app, but not the data partitions, so a reinstall keeps the Wi-Fi settings, name and pairing. (The web installer erases everything.)
- After the board restarts, the page asks it again what it runs.

*2. Set Up Wi-Fi, and the name*
- The page looks for Wi-Fi networks the first time it shows an ESPDeck board; the refresh button next to the Network menu looks again.
- The Network menu starts on the network the board is already set up for (listed as the current setting when the board can't see it); otherwise on **Choose…**, and **Join Network** waits until you pick one or type one under **Other Network…**.
- A new board has **Encrypt stored secrets (recommended)** checked; see Encrypting stored secrets, below.
- Looking for networks, **Join Network** and **Rename** each open the port for that one action.

*Afterward*
- Once on Wi-Fi the board finds the bridge by itself, and appears under **New Devices** for pairing, which needs the Stream Deck attached to hold Confirm.
- The page recognizes it there by its ID (the MAC address, which is the USB serial number of the ESP32-S3's own USB port), so a board renamed after it first connected is still found.
- The end of the page says what comes next: unplugging the board and putting the deck together.

The app writes the flash through the ESP32-S3's ROM bootloader protocol itself (no esptool), so it works in the App Sandbox with only the `com.apple.security.device.serial` entitlement.

**Computer or Stream Deck.** At startup ESPDeck looks at its USB port for about 1.5 seconds. If a computer is on the other end, the port stays a serial port: it shows up on the computer, logs appear there, Improv works, and reinstalling needs no BOOT/RST. Wi-Fi, setup mode and the bridge connection work as usual, but there's no Stream Deck. Only when there's no computer, as with the OTG adapter and a Stream Deck, does the port become the deck's USB host. The decision is made once per boot, so after switching cables, press **RST** or power-cycle the board.

**After installing:** updates normally come over Wi-Fi from ESPDeck Bridge. For logs while a deck is attached, connect the UART/COM port to the computer at 115200 baud (`pio device monitor`); it also accepts Improv and uploads with automatic reset.

### Setup mode

The device starts in setup mode when it has no Wi-Fi credentials. To enter it later, hold the top-left and bottom-right keys for 5 seconds, or turn it on from the Mac. After 2 seconds of holding, the other keys go dark and the middle column counts down (3, 2, 1) under "Entering Setup In"; letting go of either key cancels and the keys go back to normal. The deck then shows:
- top-left: a QR code that joins the device's access point, `ESPDeck-XXXX` (last four hex digits of its MAC address), with "1. Scan to join Wi-Fi" on the key below;
- top-right: a QR code for the setup page, `http://192.168.4.1/`, with "2. Scan to open setup" below;
- top center: the network's name, `ESPDeck-XXXX`;
- bottom center: **Exit setup**, once the device has credentials that work.

**Joining its network:**
1. Scan the left QR code with your phone's camera and join the network it offers.
2. If the phone doesn't stay connected (it may drop back to your usual Wi-Fi, because this network has no internet), open the phone's Wi-Fi settings and choose the name shown on the top-center key. Scanning the QR code already saved its password.
3. Joining from Settings usually opens the setup page by itself. If it doesn't, scan the right QR code.

The access point (WPA2/WPA3) gets a new random password each time setup mode starts, and the QR code carries it, so scan the QR code again each time. The setup page only answers phones joined to the deck's own network. On the page, set the device name and pick a Wi-Fi network (2.4 GHz only). The network is saved only once the device has joined it (within 30 seconds); if it can't, the page says why and the previous network stays. After it joins, the page shows its new address, and the device leaves setup mode 8 seconds later. With a working network, setup mode also ends after 15 minutes with no phone connected. Settings live in NVS, so reflashing keeps them. The setup page also shows which bridge the device is paired with, and can unpair it.

### Pairing

A device only obeys the bridge it's paired with. When an unpaired device connects, the deck reads "Pair in / ESPDeck / Bridge". Click **Pair with This Mac** (available once a Stream Deck is plugged into the dev kit, since confirming needs its keys): the deck shows `Pair?` and a 6-digit code in its top row, with **Cancel** and **Hold to Confirm** in the bottom row, and the Mac shows the same code. If they match, click **The Deck Shows This Code** on the Mac and hold Confirm on the deck for 1.5 seconds, in either order. The Pedal has no display: its status LED blinks magenta, and holding any pedal confirms. A pairing that isn't confirmed within 2 minutes is canceled.

A paired device refuses pairing and only connects to its own bridge. To move it to another Mac, first **Forget** it on the Mac it's paired with, or use **Unpair** on the deck's setup page. A deck that's paired with another Mac, or whose pairing key this Mac no longer has, shows a page that says so, with **Unpair Over USB** (for the board plugged into this Mac) and the steps to unpair on the deck's setup page. To move every deck to a new Mac at once, without pairing again, move the bridge instead (see Moving to another Mac, under Mac app). Pairing needs firmware 4.0.0 or later; a device on older firmware shows under New Devices as needing an update over USB.

Renaming a device over USB or on its setup page updates its name under New Devices right away (firmware 4.1.0 and later).

### Encrypting stored secrets

The dev kit keeps its Wi-Fi password, pairing key and developer password in its flash, where anyone who takes it can read them over USB. Firmware 4.1.0 and later can encrypt them with a key burned into the ESP32-S3's eFuses that no software can read (ESP-IDF's HMAC-based NVS encryption; no flash encryption needed).

**New devices are encrypted by default, at first setup.** When a new dev kit (nothing saved yet: no Wi-Fi network, not paired; also one after a factory reset) joins its first Wi-Fi network, it burns its key and encrypts its storage just before saving that network, so the password is never stored unencrypted. It takes under a second and needs nothing else from you; the key is only burned once the network has actually worked. If the chip can't do it, setup carries on unencrypted and the log says why.

**Opting out (Standard storage).** To keep plain flash on a new device, uncheck **Encrypt stored secrets (recommended)** before joining:
- in ESPDeck Bridge's **USB Setup**, step **2. Set Up Wi-Fi** (shown for boards on firmware 4.1.0 or later that aren't set up yet), or
- on the setup page (setup mode), next to the Wi-Fi settings.

The device remembers that choice (until a factory reset), so it doesn't ask again. Board Info in USB Setup and the device's **Device** page (under **Security**) show which way it stores its secrets. The web installer's Wi-Fi step always uses the default, encrypted.

**Devices set up before, or set up as Standard,** keep their settings unencrypted until you choose otherwise: their **Device** page, under **Security**, recommends encrypting and has **Encrypt Stored Secrets Now…**, which moves every setting across (Wi-Fi, name, pairing: nothing needs setting up again) and restarts the deck. Keep it powered for the few seconds that takes; a power cut in the middle can reset its settings, and it then starts in setup mode. ESPDeck Bridge never does this by itself.

Either way it's one-way: the eFuse key is permanent, so that dev kit always encrypts what it stores. Only the encryption is permanent, not the settings: the Wi-Fi network, name and pairing can still be changed as usual. The deck works as before, updates still work, and a factory reset or the web installer start over with empty storage that's still encrypted.

Firmware older than 4.1.0 can't read encrypted storage. ESPDeck Bridge won't install it on an encrypted device, over Wi-Fi or from a file. Installed anyway over USB or with PlatformIO, it erases the settings and starts over unencrypted; installing 4.1.0 or later again encrypts them again.

### Firmware updates and releases

ESPDeck Bridge updates the firmware over Wi-Fi from GitHub Releases, and installs only releases signed with ESPDeck's release key (see Release signing, below). A new image has to reach its bridge and authenticate within 10 minutes of starting, or the device restarts into the previous one. Firmware before 4.1.0 marked a new image valid as soon as it started (an Arduino default), so it never rolled back; 4.1.0 is the first that does. Release updates only go forward: the device (firmware 4.0.0 and later) refuses an older version, unless it's installed from a file, which asks you to confirm first.

- **Partition change (3.0.0):** 3.0.0 switches to two 3 MB OTA app slots. Moving an older device to 3.0.0 needs one USB flash (`pio run -t upload`, or the web installer). It moves the image cache, so the cache starts empty and refills from the Mac. Wi-Fi settings survive a `pio run -t upload`; the web installer erases the whole flash, settings included.
- **Releasing:** set `PROJECT_VER` in `ESPDeck Device/CMakeLists.txt`, then run `ESPDeck Device/tools/release.sh X.Y.Z`. It builds `dist/espdeck-firmware-X.Y.Z.bin` (the OTA image) and `-merged.bin` (the full flash image), each with a `.sha256`, and points the web installer at the new version. Pushing the tag `firmware-vX.Y.Z` makes `.github/workflows/firmware.yml` do the same on GitHub, sign both images, attach the files and their `.sha256` and `.sig` files to a release, and deploy `web/` to Pages.
- **Development builds:** on a device's **Device** page (or under **Updates**), the **…** menu next to its firmware has **Install Firmware from File…** (choose `firmware.bin` in `~/.platformio/build/ESPDeck/espdeck/`). It sends the app image over Wi-Fi like a release update, after checking that it's ESPDeck's (the project name in its app description) and showing its version and build time. A development build can carry the version the device already runs, so the Mac tells the new image apart by its ELF SHA-256, which the device reports in `hello`. For USB, choose a full image with **Choose File…** in the USB Setup page's Firmware menu: PlatformIO's `firmware.factory.bin` in that build folder is one (bootloader, partition table, otadata and app from offset 0).
- **Uploading over Wi-Fi from PlatformIO (ArduinoOTA), firmware 4.0.0 and later:** every build can take uploads from `pio run -t upload` over Wi-Fi, but only once you allow it for that device; until then nothing listens. Updating to 4.0.0 turns uploads off once (earlier firmware received the password unencrypted), so turn them on again afterward.
  1. In ESPDeck Bridge, open the device's **Device** page and, under **Developer**, turn on **Allow uploads through PlatformIO**. The first time, the Mac makes a developer password (20 random letters, digits, `-` and `_`) and keeps it in the Keychain; every device you allow uses the same one. Devices get only its SHA-256, sent encrypted over the paired connection. Turning uploads off, or a factory reset, removes it from the device. Wrong passwords are rate-limited.
  2. Under the switch, **Save as ota_password.txt…** and save it into the `ESPDeck Device` folder of your checkout (it's git-ignored), or **Copy** it into `ESPDECK_OTA_PASSWORD` (Copy keeps it on this Mac's clipboard only, for 2 minutes). `tools/dev_ota.py` passes it to espota; builds and USB uploads don't need it, and an upload over Wi-Fi without it stops with an explanation.
  - **More ▸ Use My Own Password…** replaces the generated password with one you choose (8 or more characters, no spaces or quotes). **More ▸ Regenerate Password…** makes a new one. Either way, connected devices that allow uploads get the new password at once; offline ones keep the old one until you turn uploads off and on again for them. Save ota_password.txt again afterward.
  3. Upload with `pio run -t upload --upload-port espdeck-eeff.local` (the device's mDNS name: its Network Name on the Device page, by default `espdeck-` and the last four hex digits of its MAC address) or its IP address; a `.local` name or an IP address makes PlatformIO use espota. To skip typing it, set `upload_port` under `[env:espdeck]` in `ESPDeck Device/platformio.local.ini` (git-ignored).
  - The deck shows "Updating firmware" during the upload. Uploads are ignored while an update from ESPDeck Bridge is running or waiting to restart.
  - Rollback: a new image normally stays pending until its first authenticated session with the bridge, and rolls back after 10 minutes without one. With uploads allowed, a new image (from espota or from the bridge) is kept as soon as it's on Wi-Fi, where the next upload comes from, so testing without the bridge doesn't roll back. An image that crashes before reaching Wi-Fi still rolls back.
  - It's for development: anyone on the network with the password can replace the firmware.
- **Security tests:** `ESPDeck Bridge/tools/security_test/run.sh` signs a file with a throwaway key through `tools/sign_release.sh` and checks it with the app's own signature check (and that changed files, changed signatures and other keys fail); it also round-trips a made-up bridge through the export file's encryption, and checks that a wrong passphrase, a changed byte anywhere in the file, and a newer format all fail. Needs OpenSSL 3.
- **Crypto test vectors:** `ESPDeck Device/tools/crypto_test/run.sh` checks the firmware's pairing, session and devOTA crypto (mbedTLS) and the app's own `DeckCrypto.swift` (CryptoKit) against RFC 7748 and `vectors.txt`, the shared reference.
- **Text tests:** `ESPDeck Device/tools/text_test/run.sh` builds the firmware's `src/Text.cpp` (the JSON nesting check, device-name validation and log sanitizing) on the Mac with the address and undefined-behavior sanitizers, and runs its tests.

Notes:
- The platform is pinned to pioarduino `55.03.312-1` (Arduino 3.3.12, ESP-IDF 5.5.5), which needs PlatformIO Core 6.2, as installed by the pioarduino IDE extension. The previous pin, `55.03.30-2`, doesn't build on Core 6.2.
- ESP-IDF can't build in a path containing spaces, so `build_dir` is `~/.platformio/build/ESPDeck`, outside iCloud Drive.
- `custom_component_remove` drops RainMaker, Insights, Zigbee and other components that Arduino pulls in. Insights doesn't build under PlatformIO.
- If a PlatformIO tool download fails with `CERTIFICATE_VERIFY_FAILED`, run it with `SSL_CERT_FILE=$(~/.platformio/penv/bin/python -c "import certifi;print(certifi.where())")`.

### Release signing

Firmware releases are signed with an Ed25519 key, so ESPDeck Bridge only installs firmware built by this repository's release workflow, even if someone replaced a release's files and their `.sha256`.

- **Signing:** after building, the release workflow's Sign step runs `ESPDeck Device/tools/sign_release.sh` on the OTA image and the `-merged.bin`. The private key (PEM, from `openssl genpkey -algorithm ed25519`) is the repository secret `FIRMWARE_SIGNING_KEY`. The script writes it to a file only it can read in a temporary folder, removed when it's done; checks that it matches `ESPDeck Device/tools/firmware_signing_public_key.pem`; and writes `<file>.sig` next to each file: the raw 64-byte signature over the file's exact bytes (`openssl pkeyutl -sign -rawin`), checked again with the public key. Without the secret, or with the wrong key, the job fails before anything is published. Ed25519 is deterministic, so a second run for the same tag uploads the same signatures.
- **Checking:** the public key is built into the app, in `ESPDeck Bridge/ESPDeck Bridge/Updates/FirmwareSignature.swift` (`FirmwareSignature.publicKey`: the raw 32 bytes, the last 32 of the PEM's DER). Every firmware downloaded from GitHub Releases, for an update over Wi-Fi or USB Setup's latest release, is checked with CryptoKit against its `.sig` before it's installed; a missing or invalid signature stops the install with an explanation. Releases without signatures (3.2.0 and earlier; 4.1.0 is the first signed release, `FirmwareSignature.firstSignedRelease`) aren't offered, and the Updates page says why. Files you choose yourself (**Install Firmware from File…**, USB Setup's **Choose File…**) aren't checked, since you picked them and confirm first; the web installer doesn't check signatures either.
- **Signing by hand** (OpenSSL 3; macOS's own `openssl` is LibreSSL and can't): `FIRMWARE_SIGNING_KEY="$(cat key.pem)" "ESPDeck Device/tools/sign_release.sh" dist/espdeck-firmware-X.Y.Z.bin dist/espdeck-firmware-X.Y.Z-merged.bin`.
- **Rotating the key:** make a new pair (`openssl genpkey -algorithm ed25519 -out key.pem`, then `openssl pkey -in key.pem -pubout`), put the public key in `firmware_signing_public_key.pem` and its raw bytes in `FirmwareSignature.publicKey` (the security test checks they match), and release the app. Only then replace the `FIRMWARE_SIGNING_KEY` secret: app versions with the old key refuse releases signed with the new one, so users need the new app first. If the private key leaks, rotate it the same way.
- **The private key must never be committed**, to this repository or anywhere else. Keep it only in the secret and an offline backup (a password manager, say). `.gitignore` leaves out the usual names for a copy of it (`*.key`, `*private*.pem`, `firmware_signing_key.pem`), but don't rely on that.

## Mac app

1. Open `ESPDeck Bridge.xcodeproj`, choose the **My Mac (Mac Catalyst)** destination, and let automatic signing register the App ID. The app ID needs the HomeKit capability.
   - Team, bundle ID prefix, and the GitHub repository used for firmware updates are in `ESPDeck Bridge/Config/Signing.xcconfig`. To build under your own team, create `Config/Signing.local.xcconfig` (git-ignored) and override `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` there.
2. Run it. It has no Dock icon; use the grid icon in the menu bar and choose **Configure…**, or choose a deck listed at the top of that menu to open its keys. **Launch at Login** is in the same menu, in the app menu, and in the sidebar's Status section.
3. For unattended use: turn on auto-login for an account that's a member of the Home.

Every ESPDeck that connects appears in the window's sidebar, keyed by its MAC address. Each has:
- **Keys**: a simulated deck in the device's own layout and its pages of keys. For the selected key: its accessory (or several), scene or shortcut; what a tap, a double tap and a hold do; its label, background color, and per-state icons (dropped images or SF Symbols). A pair of keys can step a light's brightness or a fan's speed, and keys can move between pages. Drag keys onto each other to swap them; copy and paste work on keys.
- **Device**: name, network name, the Wi-Fi network it's set up for (firmware 4.1.0 and later), brightness, image orientation, sleep timer, sleep/wake triggers from HomeKit accessories, commands to run on sleep and wake, and firmware. Under Setup: **Setup Mode**, **Copy From Deck…** (another deck's keys and settings), **Clear All Keys…**, **Factory Reset Device…** (erases the device; it can get its own settings or another deck's back once it's paired again) and **Forget Device…**. Then Security (encrypting stored secrets), Developer (uploads through PlatformIO), and what the board's status light means.
- **Log**: the messages to and from the device as they happen, with a filter; select entries to copy them.

A **demo deck** (File ▸ New Demo Deck) has no hardware: lay out its keys, test their actions, and copy them to a real deck later.

Keys can use accessories and scenes from every Home the account belongs to, even several Homes on one key. With more than one Home, the pickers group accessories and scenes by Home first.

The menus cover the window: File ▸ New Demo Deck (⌘N), Find Your Device (⇧⌘F), Set Up Device over USB (⇧⌘U), Export Bridge… and Import Bridge… (Moving to another Mac, below) and Reset Bridge…; Edit ▸ Cut, Copy and Paste for the selected key (Copy also copies selected Log entries); View ▸ Keys, Device and Log (⌘1–⌘3), the sidebar's pages, and Zoom In, Zoom Out and Size to Fit for the deck preview; the Device menu (⌘] and ⌘[ step through devices, ⌃⌘1–9 pick one, plus sleep, wake, setup mode, firmware update and Forget); and the Key menu (⌥-arrows move the selected key, or plain arrows after clicking the deck preview; ⌘T tests its action; Assign Accessory, Scene or Shortcut). Delete clears the selected key, after the same confirmation as the button. The app menu has Check for Updates… (firmware) and Launch at Login, and Help ▸ Getting Started opens each of its sheets.

**Getting Started** in the sidebar (where the window opens while there are no decks) lists the parts for one ESPDeck (What You Need), then follows the way you choose to set up the dev kit: over USB from the Mac (Connect to This Mac, then USB Setup, Putting It Together and Find Your Device), or over Wi-Fi with the setup codes on the deck (Putting It Together, Set Up over Wi-Fi, then Find Your Device). Set Up over Wi-Fi shows a Stream Deck Mini in setup mode, the steps for a phone or tablet, and what to do when the phone leaves the deck's network or the deck isn't in setup mode. Find Your Device lists the decks on the network that aren't working with this Mac yet (new ones, and ones it knows that are waiting to be paired again or need attention), and boards plugged in over USB that still need setting up.

**USB Setup** installs firmware on a board plugged into the Mac and sets up its Wi-Fi and name; see Installing above. The end of the page says what comes next, with a button for Getting Started's Putting It Together.

Key actions run when a key is released, and not when it was part of a multi-key press (so the setup-mode corner hold doesn't trigger keys).

Shortcuts run through Shortcuts Events, with Apple Events sent from within the app (it launches no helper tools, so it works sandboxed; it starts Shortcuts Events itself when that isn't running). Shortcuts run one at a time, and pressing a key again while its shortcut is still running doesn't start it again. The first time the app lists or runs one, macOS asks to let it control Shortcuts Events. If you declined, turn it on in System Settings → Privacy & Security → Automation, or reset the decision with `tccutil reset AppleEvents com.tmproductions.ESPDeck-Bridge` and ask again.

New ESPDecks appear under **New Devices** until they're paired (see Pairing above). Pairing keys are stored in the Keychain.

**Updates** (in the sidebar) checks GitHub Releases for firmware (tags `firmware-vX.Y.Z`). It offers only signed releases (see Release signing), and can install automatically, ask first, or only check when you click Check Now. The repository must be public for update checks to work. The app itself is distributed and updated through the Mac App Store.

**Sandbox.** The Mac app runs in the App Sandbox (`Support/ESPDeck Bridge Catalyst.entitlements`), with: network client and server (the WebSocket server on port 48620, Bonjour `_deckbridge._tcp`, GitHub downloads), HomeKit, USB serial ports (`com.apple.security.device.serial`, for USB Setup), read and write access to files you pick (Install Firmware from File…, Save as ota_password.txt…), and Apple Events to Shortcuts Events (`com.apple.security.scripting-targets` for `com.apple.shortcuts.events`, access group `com.apple.shortcuts.run`, plus the hardened runtime's `com.apple.security.automation.apple-events`). Pairing keys stay in the Keychain, and Launch at Login uses `SMAppService`, both of which work sandboxed. It's also built with Xcode's Enhanced Security: pointer authentication, the hardened-process entitlements, and hardware memory tagging in soft mode (`xcode-security-settings.md` in the `ESPDeck Bridge` folder records the settings).

**Moving from an unsandboxed build.** Earlier builds kept their data in `~/Library/Application Support/ESPDeck Bridge`, which the sandboxed app can't read. To keep your key layouts and icons: quit ESPDeck Bridge, then in Finder move that `ESPDeck Bridge` folder into `~/Library/Containers/com.tmproductions.ESPDeck-Bridge/Data/Library/Application Support/` (the container exists once the sandboxed app has run; replace the `ESPDeck Bridge` folder it made), and open the app again. Pairings are in the Keychain and carry over.

**Moving to another Mac.** A deck only talks to the bridge it's paired with: the bridge's ID and the deck's pairing key. ESPDeck Bridge can move both to another Mac, with everything else, so the decks connect there without pairing again.
1. On the old Mac, choose **File ▸ Export Bridge…** (or **Export Bridge…** on the About page). Enter a passphrase twice (at least 10 characters; a few random words work well) and save the file, `ESPDeck Bridge.espdeckbridge`. It holds the bridge ID, every device's pairing key, the settings (devices, key layouts, sleep/wake triggers and commands), the icons and shortcut icons, and the developer password, with the app version, the date and the Mac's name.
2. On the new Mac, choose **File ▸ Import Bridge…** (also on the About page, and in the empty window before any device is set up). Choose the file and enter the passphrase. The app shows what's in it (how many devices and their names, when and on which Mac it was exported). If this Mac already has devices or pairings, importing replaces them, and it asks first. The new identity takes effect at once: the app drops its connections and advertises the imported bridge, and the decks reconnect to it within a few seconds. No relaunch is needed.
3. Only one Mac can be the bridge at a time. Quit ESPDeck Bridge on the old Mac or remove the bridge there, or the decks switch between them. **Also remove this bridge from this Mac after exporting** (off by default) does that for you: once the file is saved, the old Mac deletes the pairing keys, settings, icons and developer password, and starts over as a new bridge with no devices. It doesn't tell the decks anything; they stay paired with the bridge in the file.

The file is encrypted with AES-256-GCM, under a key derived from the passphrase with PBKDF2-HMAC-SHA256 (calibrated to take about 0.75 s on the exporting Mac, and at least a million rounds), and its header is authenticated too, so a wrong passphrase or a changed file is refused before anything on the Mac changes. Still, the file and its passphrase together are as sensitive as the decks themselves: anyone with both can control them. Keep it somewhere private and delete it once you've imported it; a forgotten passphrase can't be recovered. Decks whose stored secrets are encrypted aren't affected: their keys stay on the chip, and only the Mac side moves.

The app is a Mac Catalyst target (Mac only) with a small macOS bundle target, `ESPDeckMenuBar`, embedded in `Contents/PlugIns`. That bundle owns the `NSStatusItem` (which Catalyst can't create), sends the Apple Events for Shortcuts (which Catalyst can't either), and does USB Setup's serial work: the port list (IOKit), the ROM bootloader protocol (`ESPLoader`), and Improv. `Shared/DeckMenuBarProtocols.swift` is compiled into both targets.

## Check on first hardware run

- **Image uploads.** Output reports go to the deck's interrupt OUT endpoint, as the macOS and Linux HID stacks do; SET_REPORT on the control pipe is only a fallback for decks without one (ESP-IDF doesn't time out control transfers, so one the deck never finishes blocks the control pipe). **Verified** on a Stream Deck Mini (PID 0x0063, firmware 3.03.002). Support for the original Stream Deck (PID 0x0060) was written without one to test on.
- **Orientation.** Each model's default transform (Transpose for the Mini family, Rotate 180 for most others) matches python-elgato-streamdeck; **verified** for the Mini (0x0063). If images appear sideways or mirrored on another model, change **Image Orientation** on the device's **Device** page; the setting is stored on the ESP32, which uses it for its own setup-mode QR codes too. Every key re-renders when you change it.
- **Brightness and serial/firmware feature reports.** The Mini and Original use 17-byte feature reports; everything newer uses the 32-byte layout from python-elgato-streamdeck.
- **Current draw.** Measure the Stream Deck's current with a USB meter on the OTG adapter's power input.
- **Storage encryption.** **Verified** on two ESP32-S3 dev kits with firmware 4.1.0: a new device encrypting at first setup, and an existing one moved with **Encrypt Stored Secrets Now…**; both kept working through renaming, changing Wi-Fi, pairing again, a firmware update and a factory reset. `ESPDeck Device/tools/nvstest` repeats the same paths, and power cuts in the middle, with virtual eFuses (nothing burned).

## Credits

ESPDeck uses or includes the following; [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) has the full notices and license details.

- [python-elgato-streamdeck](https://github.com/abcminiuser/python-elgato-streamdeck) by Dean Camera (MIT license): the Stream Deck model layouts and USB report formats in the firmware are derived from it.
- [Elgato's Stream Deck HID documentation](https://docs.elgato.com/streamdeck/hid/).
- [ESP-IDF](https://github.com/espressif/esp-idf) (Apache 2.0) and the [Arduino core for ESP32](https://github.com/espressif/arduino-esp32) (LGPL 2.1).
- Espressif components: the [USB Host HID driver](https://github.com/espressif/esp-usb), [esp_websocket_client and mdns](https://github.com/espressif/esp-protocols), the [QR Code component](https://github.com/espressif/idf-extra-components) (all Apache 2.0), and [esp_new_jpeg](https://github.com/espressif/esp-adf-libs) (Espressif MIT).
- [esp_littlefs](https://github.com/joltwallet/esp_littlefs) by Brian Pugh (MIT).
- [Inter](https://github.com/rsms/inter) by Rasmus Andersson (SIL Open Font License 1.1): the typeface for text the firmware draws on keys, rendered into `src/Font.h` by `tools/make_font.swift`.
- [ESP Web Tools](https://github.com/esphome/esp-web-tools) (Apache 2.0): the browser installer.

The app's About page lists the same credits and shows the full license text where the license requires it. Keep the two in sync (`ESPDeck Bridge/UI/AboutView.swift`).

Elgato and Stream Deck are trademarks of Corsair Memory, Inc. HomeKit and Mac are trademarks of Apple Inc. ESPDeck isn't affiliated with, endorsed by, or sponsored by Elgato, Corsair, Apple, or Espressif.

## License

ESPDeck is released under the [MIT License](LICENSE). The firmware and the web installer include other people's work under their own licenses; see Credits above and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Before the first public release

- [x] Choose a license for ESPDeck itself and add `LICENSE` (MIT).
- [x] Check the Credits above against what's actually in the release, and that the About page matches (checked for firmware 4.1.0, against the build's fetched components and the firmware's includes).
- [x] SF Symbols: Apple's license (Xcode and Apple SDKs Agreement, 2.10) allows them for developing apps for Apple products. Here the Mac app also renders them into the key images it sends to the Stream Deck. Decided 2026-10-08 to ship with them: the deck shows nothing but "Connecting" without the app, so the symbols are only ever the app's output. If Apple objects, replace the symbol picker's and the accessory icons' artwork with an openly licensed set.
- [ ] The Arduino core is LGPL 2.1. Publishing the full firmware source (this repository) satisfies it; keep the source available for every firmware release.
- [x] Make the repository public, so update checks and the release downloads work, and turn on GitHub Pages (Settings → Pages → Source: GitHub Actions) for the web installer.
- [x] Test on hardware (4.1.0; the Neo's and the +'s screens are untested, for want of one): pairing, image uploads and orientation per model, firmware update and rollback, and the web installer.

