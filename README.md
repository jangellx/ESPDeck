# ESPDeck

A Stream Deck on an ESP32-S3, used as a HomeKit panel. The Mac app does all the work; the ESP32 only bridges Wi-Fi to USB HID and caches images.

- **ESPDeck Bridge/**: Mac Catalyst app (Xcode). HomeKit observation and control, key assignments, rendering, WebSocket server.
- **ESPDeck Device/**: ESP32-S3 firmware (PlatformIO, ESP-IDF 5.5 + Arduino 3.3 as a component).
- **PROTOCOL.md**: the wire format both sides implement.
- **web/**: the browser installer (ESP Web Tools), published with GitHub Pages; see `web/README.md`.

## Requirements

- A Mac on macOS 27 or later, signed in to an iCloud account that's a member of the Home. It has to stay on and logged in; for an always-on panel, turn on automatic login and the app's **Launch at Login**.
- An ESP32-S3 with 16 MB flash and 8 MB PSRAM (ESP32-S3-DevKitC-1 N16R8) running ESPDeck firmware.
- An Elgato Stream Deck (Mini, Original, MK.2, XL, Neo, +, Pedal, or a module).
- A **5 V USB power supply rated 2 A or more**, and its cable. It powers both the ESP32-S3 and the Stream Deck.
- A **passive USB-C OTG adapter with a power input**: a USB-C plug for the board's native **USB** port, a USB-A port for the Stream Deck, and a USB-C port for the power supply. It must be passive; adapters that need USB-PD negotiation may never switch on power to the Stream Deck.
- If the Stream Deck's cable ends in USB-C: a **USB-A (male) to USB-C (female) adapter** that includes the CC pull-up resistor, so the Stream Deck sees a power source. Choose one labeled for **charging and sync** (data), not charge-only; one whose listing mentions a **56 kΩ resistor** is the surest bet. To check an adapter before building, plug the Stream Deck through it into a Mac: if the deck lights up and appears in System Information → USB, it will work. If the deck's cable already ends in USB-A, you don't need this adapter.
- For installing firmware: a USB **data** cable (not a charge-only one) from the computer to the board's **USB** port.
- A 2.4 GHz Wi-Fi network that the Mac and the ESP32 share.

## Firmware

1. Install the firmware (below), with `pio run -t upload` or, without a build setup, the web installer.
2. Plug in a Stream Deck. Every model with keys works (Mini, Original, MK.2, XL, Neo, +, Pedal, and the modules); the firmware reports its layout and image format to the Mac.
3. Set up Wi-Fi in setup mode (below). There's nothing to configure at build time.

### Installing

**The board's two USB ports.** The ESP32-S3 dev kit has two USB-C ports:
- **USB**: the chip's own USB. ESPDeck uses it for the Stream Deck (through the OTG adapter), and it's also the easiest port to install through.
- **UART**, or **COM** on many clone boards (the "YD-ESP32-S3" style of N16R8 board is common): a USB-to-serial chip, for logs.

**Clone boards.** On some clones, the COM port doesn't power the board. If nothing shows up when the board is plugged in there, use the USB port. Otherwise they work the same as Espressif's board.

**Steps:**
1. Connect the board's **USB** port to the computer with a data cable.
2. **Put the board in flashing mode** if it's running other firmware; a new board's demo firmware usually is. Hold **BOOT** (also labeled B0 or IO0), press and release **RST** (also labeled EN or RESET), then release BOOT. A new serial port appears (`/dev/cu.usbmodem…` on a Mac).
3. Install with the web installer, or run `pio run -t upload --upload-port /dev/cu.usbmodem…`.
4. If the board doesn't start ESPDeck afterward (its serial port is still there), press **RST** or unplug and replug it.
5. With the web installer, stay on the page: once ESPDeck starts, the installer offers to **connect it to Wi-Fi** right there (over the serial port, with the [Improv](https://www.improv-wifi.com/serial/) protocol). Pick your network and enter its password. If you skip this, set up Wi-Fi later with the QR codes on the deck (setup mode, below).

**Computer or Stream Deck.** At startup ESPDeck looks at its USB port for about 1.5 seconds. If a computer is on the other end, the port stays a serial port: it shows up on the computer, logs appear there, Improv works, and reinstalling needs no BOOT/RST. Wi-Fi, setup mode and the bridge connection work as usual, but there's no Stream Deck. Only when there's no computer, as with the OTG adapter and a Stream Deck, does the port become the deck's USB host. The decision is made once per boot, so after switching cables, press **RST** or power-cycle the board.

**After installing:** updates normally come over Wi-Fi from ESPDeck Bridge. For logs while a deck is attached, connect the UART/COM port to the computer at 115200 baud (`pio device monitor`); it also accepts Improv and uploads with automatic reset.

### Setup mode

The device starts in setup mode when it has no Wi-Fi credentials. To enter it later, hold the top-left and bottom-right keys for 5 seconds, or turn it on from the Mac. After 2 seconds of holding, the other keys go dark and the middle column counts down (3, 2, 1) under "Entering Setup In"; letting go of either key cancels and the keys go back to normal. The deck then shows:
- top-left: a QR code that joins the device's access point, `ESPDeck-XXXX` (last four hex digits of its MAC address), with "1. Scan to join Wi-Fi" on the key below;
- top-right: a QR code for the setup page, `http://192.168.4.1/`, with "2. Scan to open setup" below;
- top centre: the network's name, `ESPDeck-XXXX`;
- bottom centre: **Exit setup**, once the device has credentials that work.

**Joining its network:**
1. Scan the left QR code with your phone's camera and join the network it offers.
2. If the phone doesn't stay connected (an iPhone may drop back to your usual Wi-Fi, because this network has no internet), open **Settings → Wi-Fi** on the phone and choose the name shown on the top-centre key. Scanning the QR code already saved its password.
3. Joining from Settings usually opens the setup page by itself. If it doesn't, scan the right QR code.

The access point's WPA2 password is random, generated on first boot and kept; the QR code carries it. On the page, set the device name and pick a Wi-Fi network (2.4 GHz only). After it joins the network, the page shows its new address, and the device leaves setup mode 8 seconds later. Settings live in NVS, so reflashing keeps them. The setup page also shows which bridge the device is paired with, and can unpair it.

### Pairing

A device only obeys the bridge it's paired with. When an unpaired device connects, the deck reads "Pair in / ESPDeck / Bridge". Click **Pair** on the Mac: the deck shows `Pair?` and a 6-digit code in its top row, with **Cancel** and **Confirm** in the bottom row. If the code matches the Mac's, press Confirm. On the Pedal, any key confirms. A pairing that isn't confirmed within 2 minutes is cancelled. Pairing again from another Mac moves the device there.

### Firmware updates and releases

ESPDeck Bridge updates the firmware over Wi-Fi from GitHub Releases. A new image has to reach its bridge and authenticate within 10 minutes of starting, or the device restarts into the previous one.

- **Partition change (3.0.0):** 3.0.0 switches to two 3 MB OTA app slots. Moving an older device to 3.0.0 needs one USB flash (`pio run -t upload`, or the web installer). It moves the image cache, so the cache starts empty and refills from the Mac. Wi-Fi settings survive a `pio run -t upload`; the web installer erases the whole flash, settings included.
- **Releasing:** set `PROJECT_VER` in `ESPDeck Device/CMakeLists.txt`, then run `ESPDeck Device/tools/release.sh X.Y.Z`. It builds `dist/espdeck-firmware-X.Y.Z.bin` (the OTA image) and `-merged.bin` (the full flash image), each with a `.sha256`, and points the web installer at the new version. Pushing the tag `firmware-vX.Y.Z` makes `.github/workflows/firmware.yml` do the same on GitHub, attach the files to a release, and deploy `web/` to Pages.
- **Crypto test vectors:** `ESPDeck Device/tools/crypto_test/run.sh` checks the pairing and session crypto against RFC 7748 and CryptoKit; `vectors.txt` there is the reference for the Mac side.

Notes:
- The platform is pinned to pioarduino `55.03.312-1` (Arduino 3.3.12, ESP-IDF 5.5.5), which needs PlatformIO Core 6.2, as installed by the pioarduino IDE extension. The previous pin, `55.03.30-2`, doesn't build on Core 6.2.
- ESP-IDF can't build in a path containing spaces, so `build_dir` is `~/.platformio/build/ESPDeck`, outside iCloud Drive.
- `custom_component_remove` drops RainMaker, Insights, Zigbee and other components that Arduino pulls in. Insights doesn't build under PlatformIO.
- If a PlatformIO tool download fails with `CERTIFICATE_VERIFY_FAILED`, run it with `SSL_CERT_FILE=$(~/.platformio/penv/bin/python -c "import certifi;print(certifi.where())")`.

## Mac app

1. Open `ESPDeck Bridge.xcodeproj`, choose the **My Mac (Mac Catalyst)** destination, and let automatic signing register the App ID. The app ID needs the HomeKit capability.
   - Team, bundle ID prefix, and the GitHub repository used for updates are in `ESPDeck Bridge/Config/Signing.xcconfig`. To build under your own team, create `Config/Signing.local.xcconfig` (git-ignored) and override `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` there.
2. Run it. It has no Dock icon; use the grid icon in the menu bar and choose **Configure…**. **Launch at Login** is in the same menu.
3. For unattended use: turn on auto-login for an account that's a member of the Home.

Every ESPDeck that connects appears in the window's sidebar, keyed by its MAC address. Each has:
- **Keys**: a simulated deck in the device's own layout, and the selected key's accessory, scene or shortcut, action, label, background color, and per-state icons (dropped images or SF Symbols). Drag keys onto each other to swap them.
- **Device**: name, brightness, image orientation, sleep timer, sleep/wake triggers from HomeKit accessories, commands to run on sleep and wake, setup mode, and Forget Device.

Key actions run when a key is released, and not when it was part of a multi-key press (so the setup-mode corner hold doesn't trigger keys).

Shortcuts run through Shortcuts Events. The first time the app lists or runs one, macOS asks to let it control Shortcuts Events. If you declined, turn it on in System Settings → Privacy & Security → Automation, or reset the decision with `tccutil reset AppleEvents com.tmproductions.ESPDeck-Bridge` and ask again.

New ESPDecks appear under **New Devices** until they're paired (see Pairing above). Pairing keys are stored in the Keychain.

**Updates** (in the sidebar) checks GitHub Releases for the app (tags `bridge-vX.Y.Z`) and the firmware (`firmware-vX.Y.Z`). Each can install automatically, ask first, or only check when you click Check Now. The app checks the download's SHA-256 and that it's signed by the same Team ID before replacing itself. The repository must be public for update checks to work.

**Releasing the app:** set the version (MARKETING_VERSION), then run `ESPDeck Bridge/tools/release-app.sh X.Y.Z`. It archives, exports with Developer ID, notarizes (one-time setup: `xcrun notarytool store-credentials ESPDeck …`, see the script), staples, and writes to `dist/` a disk image for first-time downloads (also signed, notarized and stapled) and a zip for the app's updater, each with a `.sha256`. Attach all four to a GitHub release tagged `bridge-vX.Y.Z`.

The app isn't sandboxed (it's distributed outside the App Store, and it has to replace itself when updating); it uses the hardened runtime and is notarized. Its data is in `~/Library/Application Support/ESPDeck Bridge`.

The app is a Catalyst target (iPad + Mac) with a small macOS bundle target, `ESPDeckMenuBar`, embedded in `Contents/PlugIns`. That bundle owns the `NSStatusItem` (which Catalyst can't create) and runs the AppleScript for Shortcuts (which Catalyst can't either). `Shared/DeckMenuBarProtocols.swift` is compiled into both targets.

## Check on first hardware run

- **Image uploads.** Output reports go to the deck's interrupt OUT endpoint, as the macOS and Linux HID stacks do; SET_REPORT on the control pipe is only a fallback for decks without one (ESP-IDF doesn't time out control transfers, so one the deck never finishes blocks the control pipe). **Verified** on a Stream Deck Mini (PID 0x0063, firmware 3.03.002). Support for the original Stream Deck (PID 0x0060) was written without one to test on.
- **Orientation.** Each model's default transform (Transpose for the Mini family, Rotate 180 for most others) matches python-elgato-streamdeck; **verified** for the Mini (0x0063). If images appear sideways or mirrored on another model, change **Image Orientation** on the device's **Device** page; the setting is stored on the ESP32, which uses it for its own setup-mode QR codes too. Every key re-renders when you change it.
- **Brightness and serial/firmware feature reports.** The Mini and Original use 17-byte feature reports; everything newer uses the 32-byte layout from python-elgato-streamdeck.
- **Current draw.** Measure the Stream Deck's current with a USB meter on the OTG adapter's power input.

## Credits

ESPDeck uses or includes:

- [python-elgato-streamdeck](https://github.com/abcminiuser/python-elgato-streamdeck) by Dean Camera (MIT license): the Stream Deck model layouts and USB report formats in the firmware are derived from it.
- [Elgato's Stream Deck HID documentation](https://docs.elgato.com/streamdeck/hid/).
- [ESP-IDF](https://github.com/espressif/esp-idf) (Apache 2.0) and the [Arduino core for ESP32](https://github.com/espressif/arduino-esp32) (LGPL 2.1).
- Espressif components: the [USB Host HID driver](https://github.com/espressif/esp-usb), [esp_websocket_client and mdns](https://github.com/espressif/esp-protocols), the [QR Code component](https://github.com/espressif/idf-extra-components) (all Apache 2.0), and [esp_new_jpeg](https://github.com/espressif/esp-adf-libs) (Espressif MIT).
- [esp_littlefs](https://github.com/joltwallet/esp_littlefs) by Brian Pugh (MIT).
- [Inter](https://github.com/rsms/inter) by Rasmus Andersson (SIL Open Font License 1.1): the typeface for text the firmware draws on keys, rendered into `src/Font.h` by `tools/make_font.swift`.
- [ESP Web Tools](https://github.com/esphome/esp-web-tools) (Apache 2.0): the browser installer.

The app's About page lists the same credits and shows the full license text where the license requires it. Keep the two in sync (`ESPDeck Bridge/UI/AboutView.swift`).

Elgato and Stream Deck are trademarks of Corsair Memory, Inc. HomeKit and Mac are trademarks of Apple Inc. ESPDeck isn't affiliated with, endorsed by, or sponsored by Elgato, Corsair, Apple, or Espressif.

## Before the first public release

- [ ] Choose a license for ESPDeck itself and add `LICENSE`.
- [ ] Check the Credits above against what's actually in the release, and that the About page matches.
- [ ] SF Symbols: Apple's license allows them in apps for Apple platforms. Here they're also rendered onto the Stream Deck's own screen; check that's acceptable, or limit the symbol picker to your own artwork.
- [ ] The Arduino core is LGPL 2.1. Publishing the full firmware source (this repository) satisfies it; keep the source available for every firmware release.
- [ ] Make the repository public, so update checks and the release downloads work, and turn on GitHub Pages (Settings → Pages → Source: GitHub Actions) for the web installer.
- [ ] Test on hardware: pairing, image uploads and orientation per model, firmware update and rollback, and the web installer.

