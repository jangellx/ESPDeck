# The Mac app

[Overview](../README.md) · [Setting up a deck](setup.md) · [The Mac app](mac-app.md) · [FAQ](faq.md) · [Development](development.md)

## Building and running

1. Open `ESPDeck Bridge.xcodeproj`, choose the **My Mac (Mac Catalyst)** destination, and let automatic signing register the App ID. The app ID needs the HomeKit capability.
   - Team, bundle ID prefix, and the GitHub repository used for firmware updates are in `ESPDeck Bridge/Config/Signing.xcconfig`. To build under your own team, create `Config/Signing.local.xcconfig` (git-ignored) and override `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` there.
2. Run it. It has no Dock icon; use the grid icon in the menu bar and choose **Configure…**, or choose a deck listed at the top of that menu to open its keys. **Launch at Login** is in the same menu, in the app menu, and in the sidebar's Status section.
3. For unattended use: turn on auto-login for an account that's a member of the Home.

## The window

Every ESPDeck that connects appears in the window's sidebar, keyed by its MAC address. Each has:
- **Keys**: a simulated deck in the device's own layout and its pages of keys. For the selected key: its accessory (or several), scene or shortcut; what a tap, a double tap and a hold do; its label, background color, and per-state icons (dropped images or SF Symbols). A pair of keys can step a light's brightness or a fan's speed, and keys can move between pages. Drag keys onto each other to swap them, and drop a color or an image on a key to set its background or icon; copy and paste work on keys.
- **Device**: name, network name, the Wi-Fi network it's set up for (firmware 4.1.0 and later), brightness, image orientation, sleep timer, sleep/wake triggers from HomeKit accessories, commands to run on sleep and wake, and firmware. Under Setup: **Setup Mode**, **Copy From Deck…** (another deck's keys and settings), **Clear All Keys…**, **Factory Reset Device…** (erases the device; it can get its own settings or another deck's back once it's paired again) and **Forget Device…**. Then Security (encrypting stored secrets), Developer (uploads through PlatformIO), and what the board's status light means.
- **Log**: the messages to and from the device as they happen, with a filter; select entries to copy them.

A **demo deck** (File ▸ New Demo Deck) has no hardware: lay out its keys, test their actions, and copy them to a real deck later.

Keys can use accessories and scenes from every Home the account belongs to, even several Homes on one key. With more than one Home, the pickers group accessories and scenes by Home first.

## Menus

The menus cover the window: File ▸ New Demo Deck (⌘N), Find Your Device (⇧⌘F), Set Up Device over USB (⇧⌘U), Export Bridge… and Import Bridge… (Moving to another Mac, below) and Reset Bridge…; Edit ▸ Cut, Copy and Paste for the selected key (Copy also copies selected Log entries); View ▸ Keys, Device and Log (⌘1–⌘3), the sidebar's pages, and Zoom In, Zoom Out and Size to Fit for the deck preview; the Device menu (⌘] and ⌘[ step through devices, ⌃⌘1–9 pick one, plus sleep, wake, setup mode, firmware update and Forget); and the Key menu (⌥-arrows move the selected key, or plain arrows after clicking the deck preview; ⌘T tests its action; Assign Accessory, Scene or Shortcut). Delete clears the selected key, after the same confirmation as the button. The app menu has Check for Updates… (firmware) and Launch at Login, and Help ▸ Getting Started opens each of its sheets.

## Getting Started and USB Setup

**Getting Started** in the sidebar (where the window opens while there are no decks) lists the parts for one ESPDeck (What You Need), then follows the way you choose to set up the dev kit: over USB from the Mac (Connect to This Mac, then USB Setup, Putting It Together and Find Your Device), or over Wi-Fi with the setup codes on the deck (Putting It Together, Set Up over Wi-Fi, then Find Your Device). Set Up over Wi-Fi shows a Stream Deck Mini in setup mode, the steps for a phone or tablet, and what to do when the phone leaves the deck's network or the deck isn't in setup mode. Find Your Device lists the decks on the network that aren't working with this Mac yet (new ones, and ones it knows that are waiting to be paired again or need attention), and boards plugged in over USB that still need setting up.

**USB Setup** installs firmware on a board plugged into the Mac and sets up its Wi-Fi and name; see [Installing](setup.md#installing). The end of the page says what comes next, with a button for Getting Started's Putting It Together.

## Keys and Shortcuts

Key actions run when a key is released, and not when it was part of a multi-key press (so the setup-mode corner hold doesn't trigger keys).

Shortcuts run through Shortcuts Events, with Apple Events sent from within the app (it launches no helper tools, so it works sandboxed; it starts Shortcuts Events itself when that isn't running). Shortcuts run one at a time, and pressing a key again while its shortcut is still running doesn't start it again. The first time the app lists or runs one, macOS asks to let it control Shortcuts Events. If you declined, turn it on in System Settings → Privacy & Security → Automation, or reset the decision with `tccutil reset AppleEvents com.tmproductions.ESPDeck-Bridge` and ask again.

New ESPDecks appear under **New Devices** until they're paired (see [Pairing](setup.md#pairing)). Pairing keys are stored in the Keychain.

## Updates

**Updates** (in the sidebar) checks GitHub Releases for firmware (tags `firmware-vX.Y.Z`). It offers only signed releases (see [Release signing](development.md#release-signing)), and can install automatically, ask first, or only check when you click Check Now. The repository must be public for update checks to work. The app itself is distributed and updated through the Mac App Store.

## Sandbox and security

The Mac app runs in the App Sandbox (`Support/ESPDeck Bridge Catalyst.entitlements`), with: network client and server (the WebSocket server on port 48620, Bonjour `_deckbridge._tcp`, GitHub downloads), HomeKit, USB serial ports (`com.apple.security.device.serial`, for USB Setup), read and write access to files you pick (Install Firmware from File…, Save as ota_password.txt…), and Apple Events to Shortcuts Events (`com.apple.security.scripting-targets` for `com.apple.shortcuts.events`, access group `com.apple.shortcuts.run`, plus the hardened runtime's `com.apple.security.automation.apple-events`). Pairing keys stay in the Keychain, and Launch at Login uses `SMAppService`, both of which work sandboxed. It's also built with Xcode's Enhanced Security: pointer authentication, the hardened-process entitlements, and hardware memory tagging in soft mode (`xcode-security-settings.md` in the `ESPDeck Bridge` folder records the settings).

## Moving from an unsandboxed build

Earlier builds kept their data in `~/Library/Application Support/ESPDeck Bridge`, which the sandboxed app can't read. To keep your key layouts and icons: quit ESPDeck Bridge, then in Finder move that `ESPDeck Bridge` folder into `~/Library/Containers/com.tmproductions.ESPDeck-Bridge/Data/Library/Application Support/` (the container exists once the sandboxed app has run; replace the `ESPDeck Bridge` folder it made), and open the app again. Pairings are in the Keychain and carry over.

## Moving to another Mac

A deck only talks to the bridge it's paired with: the bridge's ID and the deck's pairing key. ESPDeck Bridge can move both to another Mac, with everything else, so the decks connect there without pairing again.
1. On the old Mac, choose **File ▸ Export Bridge…** (or **Export Bridge…** on the About page). Enter a passphrase twice (at least 10 characters; a few random words work well) and save the file, `ESPDeck Bridge.espdeckbridge`. It holds the bridge ID, every device's pairing key, the settings (devices, key layouts, sleep/wake triggers and commands), the icons and shortcut icons, and the developer password, with the app version, the date and the Mac's name.
2. On the new Mac, choose **File ▸ Import Bridge…** (also on the About page, and in the empty window before any device is set up). Choose the file and enter the passphrase. The app shows what's in it (how many devices and their names, when and on which Mac it was exported). If this Mac already has devices or pairings, importing replaces them, and it asks first. The new identity takes effect at once: the app drops its connections and advertises the imported bridge, and the decks reconnect to it within a few seconds. No relaunch is needed.
3. Only one Mac can be the bridge at a time. Quit ESPDeck Bridge on the old Mac or remove the bridge there, or the decks switch between them. **Also remove this bridge from this Mac after exporting** (off by default) does that for you: once the file is saved, the old Mac deletes the pairing keys, settings, icons and developer password, and starts over as a new bridge with no devices. It doesn't tell the decks anything; they stay paired with the bridge in the file.

The file is encrypted with AES-256-GCM, under a key derived from the passphrase with PBKDF2-HMAC-SHA256 (calibrated to take about 0.75 s on the exporting Mac, and at least a million rounds), and its header is authenticated too, so a wrong passphrase or a changed file is refused before anything on the Mac changes. Still, the file and its passphrase together are as sensitive as the decks themselves: anyone with both can control them. Keep it somewhere private and delete it once you've imported it; a forgotten passphrase can't be recovered. Decks whose stored secrets are encrypted aren't affected: their keys stay on the chip, and only the Mac side moves.

## How it's built

The app is a Mac Catalyst target (Mac only) with a small macOS bundle target, `ESPDeckMenuBar`, embedded in `Contents/PlugIns`. That bundle owns the `NSStatusItem` (which Catalyst can't create), sends the Apple Events for Shortcuts (which Catalyst can't either), and does USB Setup's serial work: the port list (IOKit), the ROM bootloader protocol (`ESPLoader`), and Improv. `Shared/DeckMenuBarProtocols.swift` is compiled into both targets.
