# The Mac app

[Overview](../README.md) · [Setting up a deck](setup.md) · [The Mac app](mac-app.md) · [FAQ](faq.md) · [Development](development.md)

**On this page**

- [Building and running](#building-and-running)
- [The menu bar](#the-menu-bar)
- [The sidebar](#the-sidebar)
- [The Keys page](#the-keys-page)
- [Setting up a key](#setting-up-a-key)
- [Shortcuts](#shortcuts)
- [The Device page](#the-device-page)
- [The Log page](#the-log-page)
- [Getting Started and USB Setup](#getting-started-and-usb-setup)
- [Updates](#updates)
- [Menus and keyboard shortcuts](#menus-and-keyboard-shortcuts)
- [Moving to another Mac](#moving-to-another-mac)
- [Sandbox and security](#sandbox-and-security)
- [Moving from an unsandboxed build](#moving-from-an-unsandboxed-build)
- [How it's built](#how-its-built)

## Building and running

1. Open `ESPDeck Bridge.xcodeproj`, choose the **My Mac (Mac Catalyst)** destination, and let automatic signing register the App ID. The app ID needs the HomeKit capability.
   - Team, bundle ID prefix, and the GitHub repository used for firmware updates are in `ESPDeck Bridge/Config/Signing.xcconfig`. To build under your own team, create `Config/Signing.local.xcconfig` (git-ignored) and override `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` there.
2. Run it. It has no Dock icon; use the grid icon in the menu bar and choose **Configure…**, or choose a deck listed at the top of that menu to open its keys. **Launch at Login** is in the same menu, in the app menu, and in the sidebar's Status section.
3. For unattended use: turn on auto-login for an account that's a member of the Home.

## The menu bar

ESPDeck Bridge has no Dock icon while its window is closed. It lives in the menu bar, under the grid icon:

- **Status lines** at the top: whether the bridge is waiting for a deck, HomeKit is connected, and anything that needs attention.
- **Decks**: each deck with its state. Choose one to open its Keys page.
- **Configure…** opens the configuration window.
- **Set Up a Device over USB…** opens the window on USB Setup.
- **Launch at Login**, and **Quit ESPDeck Bridge**.

The arrow keys move through the menu while the app is in front.

## The sidebar

The configuration window's sidebar has three parts.

**Devices**
- Every deck this Mac knows, keyed by its MAC address, with its state under its name (connected, asleep, waiting to be paired, and so on).
- **Not Connected**: the decks that aren't connected now, which can be hidden.
- **New Devices**: decks on the network that haven't been paired yet. Choose one to pair it (see [Pairing](setup.md#pairing)).
- **Add Demo Deck**: a deck with no hardware, in the model you pick. Lay out its keys, test their actions, and copy them to a real deck later.

**ESPDeck Bridge**
- **Getting Started**: the parts list and the setup steps. The window opens here while there are no decks.
- **USB Setup**: installs firmware on a board plugged into the Mac; the badge counts the boards it has found.
- **Updates**: firmware releases.
- **About**: the version, requirements, exporting and importing the bridge, the license and acknowledgments.

**Status**
- What the bridge is waiting for or connected to, **HomeKit**'s state, and **Launch at Login**.
- A problem that needs attention shows here too, with a notification.

Choosing a deck shows its three pages, **Keys**, **Device** and **Log**, picked at the top of the window (⌘1 to ⌘3).

## The Keys page

The Keys page has the deck preview and, for the selected key, its settings.

**The preview**
- A simulated deck in the device's own layout, showing what each key shows now.
- Click a key to select it. The arrow keys move the selection after a click in the preview.
- **Shift-click** a key to press it as on the deck: shift-double-click for its Double Tap, shift-hold for its Hold.
- Drag a key onto another to swap them.
- Drop an image on a key to make it the key's icon, or a color (from the Colors panel or a color well) to make it the key's background.
- Right-click a key for Copy, Paste and Clear.

**Pages**
- **Page ① ② ③ +** above the preview shows the deck's pages of keys; click one to edit it, and **+** to add one. Right-click a page to delete it.
- The deck itself shows whichever page it's on. Keys with a Page action move between them.

**Size and arrangement**
- The slider and **Size to Fit** under the page bar zoom the preview; so do pinching on a trackpad and View ▸ Zoom In and Zoom Out.
- The control at the far right of the page bar puts the preview **beside** the key's settings or **above** them, which suits a wide deck. Drag the divider between the two to resize them.
- **Labels** under the preview puts every key's label at the top or the bottom.

## Setting up a key

Select a key, then work down its settings.

**1. Which press**

A key can do three different things. **Tap**, **Double Tap** and **Hold**, at the top, choose which one you're setting up. The key's look (icon, label, color) belongs to its tap.

**2. What it controls**

Under **Controlling**, three tabs:

- **Home**: accessories and scenes, in a sheet arranged like the Home app, by room, with a search field.
  - Pick one accessory, or several to control together. The starred one is the key accessory: the key shows its state.
  - Scenes can be mixed in with accessories. **Scenes Run** then says when: every press, only when turning on, or only when turning off.
  - With more than one Home, accessories and scenes are grouped by Home, and one key can use several Homes.
- **Shortcut**: one of your Shortcuts. See [Shortcuts](#shortcuts), below.
- **Page**: Next Page, Previous Page, First Page, Last Page, Go to Page, or Show Page Number.

**3. What the press does**

- **On Press** lists the actions that fit: Toggle, Turn On, Turn Off, Open, Close, Lock, Unlock, Run Scene, or Nothing (the key only shows state).
- A light with brightness or a fan with speeds can be **Toggle** or **Level**. Level makes a pair of keys that step the level up and down:
  - **Other Key** is the second key of the pair; **Swap** exchanges which one raises.
  - **Step** is how far each press goes, and holding a key keeps stepping.
  - **Double-Tap Goes All the Way** jumps to full or to off.
  - The two keys share their background color.
- **Test Action** (⌘T) does it now, without the deck.

**4. How it looks**

- **Label**, **Show Label** and **Background** under Appearance.
- **Icons**: one for each state the key can show (Default, plus On and Off, or Open, Opening, Closed and so on). Drop an image on a state, or choose an SF Symbol. A state without its own icon uses Default.

**Copy Key**, **Paste Key** and **Clear Key** are at the bottom, and in the Edit menu.

When keys run: a key acts when it's released, and not when it was part of pressing several keys at once, so the two-corner hold for setup mode doesn't set anything off.

## Shortcuts

A key on the **Shortcut** tab runs one of your Shortcuts on the Mac.

- **One-Shot** runs it once per press.
- **On/Off** makes a key with two states. Each press runs the shortcut with "on" or "off" as its Shortcut Input: the state the key is switching to. If the shortcut ends with Stop and Output of "on" or "off", the key shows that state instead.
- **Reload Shortcuts** rereads the list after you add or rename one.

How they run:

- Through Shortcuts Events, in the background. The app sends Apple Events itself (it launches no helper tools) and starts Shortcuts Events when it isn't running.
- One at a time. Pressing a key again while its shortcut is still running doesn't start it again.
- The first time the app lists or runs one, macOS asks to let it control Shortcuts Events. If you declined, turn it on in System Settings → Privacy & Security → Automation, or reset the decision with `tccutil reset AppleEvents com.tmproductions.ESPDeck-Bridge` and ask again.

When one fails, the key shows a warning triangle and the Log page says why. See [Why do my Shortcuts fail?](faq.md#why-do-my-shortcuts-fail) in the FAQ.

## The Device page

- **Device**: the deck's name and its **Network Name** (its name on the network, for `ping` and PlatformIO), with its status, Stream Deck model, MAC and IP addresses, and the Wi-Fi network it's set up for (firmware 4.1.0 and later).
- **ESPDeck Firmware**: the version it runs, and installing an update or a file.
- **Display**: **Brightness** and **Image Orientation**.
- **Sleep**: **Sleep After** (a timer), **Sleep Now** and **Wake Now**, and a command to run as it sleeps and as it wakes (an accessory, a scene or a shortcut).
- **Triggers**: sleep or wake the deck when a HomeKit accessory changes, like a door locking or a light going off.
- **Key Presses**: **Double-Tap Speed** and **Hold Time** (how long counts as each), and **Repeat Delay** and **Repeat Speed** for keys that repeat while held.
- **Setup**:
  - **Enter Setup Mode**, to change its Wi-Fi from a phone.
  - **Copy From Deck…**: another deck's keys and settings.
  - **Clear All Keys…**
  - **Factory Reset Device…**: erases the device. It can get its own settings, or another deck's, back once it's paired again.
  - **Forget Device…**: removes it from this Mac and unpairs it.
- **Security**: whether its stored secrets are encrypted, and **Encrypt Stored Secrets Now…** (see [Encrypting stored secrets](setup.md#encrypting-stored-secrets)).
- **Developer**: **Allow uploads through PlatformIO** and the developer password (see [Development](development.md#firmware-updates-and-releases)).
- **Status Light**: what the colors of the dev kit's light mean.

A demo deck's Device page has only its name and model.

## The Log page

- Every message to and from the deck as it happens, newest first: key presses, images sent, state changes, and why something failed.
- **Filter** narrows it to entries containing some text (pressed, image, keyDown).
- Click to select entries, with ⌘ and Shift for several. **Copy Selected** or ⌘C copies them; **Copy All** copies everything shown.
- **Clear** empties it.

## Getting Started and USB Setup

**Getting Started** lists the parts for one ESPDeck (What You Need), then follows the way you choose to set up the dev kit:

- **Over USB from the Mac:** Connect to This Mac, USB Setup, Putting It Together, then Find Your Device.
- **Over Wi-Fi with the setup codes on the deck:** Putting It Together, Set Up over Wi-Fi, then Find Your Device. Set Up over Wi-Fi shows a deck in setup mode, the steps for a phone or tablet, and what to do when the phone leaves the deck's network or the deck isn't in setup mode.

**Find Your Device** lists the decks on the network that aren't working with this Mac yet (new ones, and ones it knows that are waiting to be paired again or need attention), and boards plugged in over USB that still need setting up.

**USB Setup** installs firmware on a board plugged into the Mac and sets up its Wi-Fi and name; see [Installing](setup.md#installing). The end of the page says what comes next, with a button for Putting It Together.

## Updates

- **Updates** checks GitHub Releases for firmware (tags `firmware-vX.Y.Z`).
- It can **Install Automatically**, **Check Automatically, Ask to Install**, or **Check Manually** (only when you click **Check Now**).
- It offers only signed releases (see [Release signing](development.md#release-signing)).
- The repository must be public for update checks to work.
- The app itself is distributed and updated through the Mac App Store.

## Menus and keyboard shortcuts

**ESPDeck Bridge**

| Command | Keys | |
|---|---|---|
| Check for Updates… | | Looks for firmware releases |
| Launch at Login | | |

**File**

| Command | Keys | |
|---|---|---|
| New Demo Deck | ⌘N | A submenu of models; ⌘N makes the first |
| Find Your Device | ⇧⌘F | |
| Set Up Device over USB… | ⇧⌘U | |
| Export Bridge…, Import Bridge… | | See [Moving to another Mac](#moving-to-another-mac) |
| Reset Bridge… | | Forgets every device and starts over as a new bridge |

**Edit**

| Command | Keys | |
|---|---|---|
| Cut, Copy, Paste | ⌘X, ⌘C, ⌘V | The selected key. Copy also copies selected Log entries. In a text field they act on the text |
| Clear Key… | Delete | After the same confirmation as the button |
| Undo, Redo | ⌘Z, ⇧⌘Z | Changes to keys |

**View**

| Command | Keys | |
|---|---|---|
| Keys, Device, Log | ⌘1, ⌘2, ⌘3 | The selected deck's pages |
| Getting Started, USB Setup, Updates, About | | The sidebar's pages |
| Zoom In, Zoom Out | ⌘=, ⌘- | The deck preview |
| Size to Fit | ⌘0 | |

**Device**

| Command | Keys | |
|---|---|---|
| Next Device, Previous Device | ⌘], ⌘[ | |
| A device by name | ⌃⌘1 to ⌃⌘9 | |
| Sleep Now or Wake Now | | |
| Enter or Exit Setup Mode | | |
| Install Firmware Update | | |
| Forget Device… | | |

**Key**

| Command | Keys | |
|---|---|---|
| Select Key to the Left, Right, Above, Below | ⌥ and an arrow | Plain arrows too, after a click in the deck preview |
| Test Action | ⌘T | |
| Assign Home…, Shortcut…, Page… | ⌥⌘1, ⌥⌘2, ⌥⌘3 | Opens the key's picker on that tab |

**Help**

| Command | Keys | |
|---|---|---|
| ESPDeck Help | | Opens this documentation |
| Getting Started | | A submenu with each of its sheets |

## Moving to another Mac

A deck only talks to the bridge it's paired with: the bridge's ID and the deck's pairing key. ESPDeck Bridge can move both to another Mac, with everything else, so the decks connect there without pairing again.
1. On the old Mac, choose **File ▸ Export Bridge…** (or **Export Bridge…** on the About page). Enter a passphrase twice (at least 10 characters; a few random words work well) and save the file, `ESPDeck Bridge.espdeckbridge`. It holds the bridge ID, every device's pairing key, the settings (devices, key layouts, sleep/wake triggers and commands), the icons and shortcut icons, and the developer password, with the app version, the date and the Mac's name.
2. On the new Mac, choose **File ▸ Import Bridge…** (also on the About page, and in the empty window before any device is set up). Choose the file and enter the passphrase. The app shows what's in it (how many devices and their names, when and on which Mac it was exported). If this Mac already has devices or pairings, importing replaces them, and it asks first. The new identity takes effect at once: the app drops its connections and advertises the imported bridge, and the decks reconnect to it within a few seconds. No relaunch is needed.
3. Only one Mac can be the bridge at a time. Quit ESPDeck Bridge on the old Mac or remove the bridge there, or the decks switch between them. **Also remove this bridge from this Mac after exporting** (off by default) does that for you: once the file is saved, the old Mac deletes the pairing keys, settings, icons and developer password, and starts over as a new bridge with no devices. It doesn't tell the decks anything; they stay paired with the bridge in the file.

The file is encrypted with AES-256-GCM, under a key derived from the passphrase with PBKDF2-HMAC-SHA256 (calibrated to take about 0.75 s on the exporting Mac, and at least a million rounds), and its header is authenticated too, so a wrong passphrase or a changed file is refused before anything on the Mac changes. Still, the file and its passphrase together are as sensitive as the decks themselves: anyone with both can control them. Keep it somewhere private and delete it once you've imported it; a forgotten passphrase can't be recovered. Decks whose stored secrets are encrypted aren't affected: their keys stay on the chip, and only the Mac side moves.

## Sandbox and security

The Mac app runs in the App Sandbox (`Support/ESPDeck Bridge Catalyst.entitlements`), with: network client and server (the WebSocket server on port 48620, Bonjour `_deckbridge._tcp`, GitHub downloads), HomeKit, USB serial ports (`com.apple.security.device.serial`, for USB Setup), read and write access to files you pick (Install Firmware from File…, Save as ota_password.txt…), and Apple Events to Shortcuts Events (`com.apple.security.scripting-targets` for `com.apple.shortcuts.events`, access group `com.apple.shortcuts.run`, plus the hardened runtime's `com.apple.security.automation.apple-events`). Pairing keys stay in the Keychain, and Launch at Login uses `SMAppService`, both of which work sandboxed. It's also built with Xcode's Enhanced Security: pointer authentication, the hardened-process entitlements, and hardware memory tagging in soft mode (`xcode-security-settings.md` in the `ESPDeck Bridge` folder records the settings).

## Moving from an unsandboxed build

Earlier builds kept their data in `~/Library/Application Support/ESPDeck Bridge`, which the sandboxed app can't read. To keep your key layouts and icons: quit ESPDeck Bridge, then in Finder move that `ESPDeck Bridge` folder into `~/Library/Containers/com.tmproductions.ESPDeck-Bridge/Data/Library/Application Support/` (the container exists once the sandboxed app has run; replace the `ESPDeck Bridge` folder it made), and open the app again. Pairings are in the Keychain and carry over.

## How it's built

The app is a Mac Catalyst target (Mac only) with a small macOS bundle target, `ESPDeckMenuBar`, embedded in `Contents/PlugIns`. That bundle owns the `NSStatusItem` (which Catalyst can't create), sends the Apple Events for Shortcuts (which Catalyst can't either), and does USB Setup's serial work: the port list (IOKit), the ROM bootloader protocol (`ESPLoader`), and Improv. `Shared/DeckMenuBarProtocols.swift` is compiled into both targets.
