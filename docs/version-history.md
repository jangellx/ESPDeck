# Version history

What changed in each version of ESPDeck Bridge, the Mac app. The firmware has its own versions, listed with each [release](https://github.com/jangellx/ESPDeck/releases).

## 1.1.1

### Fixes

- HomeKit now keeps working while ESPDeck Bridge runs only in the menu bar. After Launch at Login, HomeKit refused the app until its window was opened, so keys showed out-of-date states and couldn't operate anything. If HomeKit does refuse it, Status now says so.

### Other changes

- ESPDeck Bridge now needs macOS 15 Sequoia or later. Every Mac with Apple silicon can run it.
- The Wi-Fi network menu in USB Setup and the Deck tab's Command menu say "Choose…" without listing it as a choice.

## 1.1.0

### Menus

- A key can open a menu: another set of keys that takes the place of the page while the menu is open. The menu can open on the key's tap, double tap or hold.
- Every menu has a Close key, either a back key at the top left or a close key at the top right, with a choice of icons for each.
- **Dismiss on Action** closes a menu after one of its keys is pressed.
- **Edit Menu** shows a menu in the Keys page, where its keys are set up like a page's. The settings beside the preview then have a **Menu** tab for the menu and a **Key** tab for the selected key.
- Double-clicking a Page or Menu key in the preview goes where the key goes.

### Keys

- **Copy Action** and **Paste Action** (⇧⌘C, ⇧⌘V) copy what one press of a key does (its Tap, Double Tap or Hold) to another press or another key.
- A copied key or action includes the menus it opens.
- **Sleep the Deck Afterward** puts the deck to sleep once a Home or Shortcut press has run, and **Sleep the Deck** on the Deck tab makes a press that does only that.
- **One Icon** makes a key show the same icon whatever state its accessory is in.
- Choosing something on another tab of **Controlling** asks before it replaces what the press already does.
- The **Action** section is shown only where there is an action to choose.
- The **Page** tab of **Controlling** is now **Deck**, since it controls the deck itself: its pages, and sleeping it.

### Other changes

- When HomeKit refuses to operate a garage door or a lock because the Mac is locked, the app says so and links to an explanation.
- The app listens on another port when port 48620 is already in use on the Mac.
- A **What's New** window shows the main changes the first time the configuration window is opened after an update.
- The Updates page is now called **Firmware Updates**, and the app menu no longer has Check for Updates…: the page only ever updated the decks' firmware, and the app itself is updated by the Mac App Store.

## 1.0.0

The first version: HomeKit accessories, scenes and Shortcuts on a Stream Deck's keys, with pages, Level keys, double taps and holds, per-state icons, sleep triggers, setup over USB, and firmware updates.
