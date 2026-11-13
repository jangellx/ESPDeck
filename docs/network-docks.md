# Network Docks (experimental)

An Elgato Stream Deck Network Dock puts a Stream Deck on your network over Ethernet. With Network Docks turned on, ESPDeck Bridge drives the Stream Deck plugged into a dock directly, with no ESP32. Its keys, pages, menus, presses, sleep timer and Shortcuts actions work as on any other deck.

This is experimental. It hasn't been tried with a real Network Dock yet: it follows what other projects have worked out about how docks work (see [How it works](#how-it-works)), and checks its messages against a packet capture of a real dock. If you have a dock, please [open an issue](https://github.com/jangellx/ESPDeck/issues) saying how it went.

## Turning it on

1. Open **Network Docks** in the sidebar's ESPDeck Bridge section, and turn on **Use Network Docks**.
2. Docks on the same network as the Mac appear under **On This Network**, each with its serial number and the Stream Deck plugged into it.
3. Click **Add** to connect to a dock. It's listed under Devices, and its Keys page works as any deck's does.

ESPDeck Bridge connects only to docks that were added. Turning Network Docks off disconnects from them and stops looking; their keys and settings are kept for when it's turned on again.

## Before you start

- **One app at a time.** A dock works with one app at a time. Add a dock only if Elgato's Stream Deck app isn't using it, and forget it in ESPDeck Bridge before using it with Elgato's app again.
- **No pairing or encryption.** A dock has neither, by Elgato's design: anything on the network can connect to it. Use one only on a network you trust. ESP32 decks, by contrast, are paired with one Mac and authenticate every message ([Setting up a deck](setup.md)).
- **The Mac does the work.** An ESP32 judges taps, double taps and holds, and runs the sleep timer, on the deck itself. For a dock, ESPDeck Bridge does these on the Mac, by the same rules, so they need the Mac to be awake and on the network.

## Which Stream Decks work

- The Stream Deck MK.2, XL, Neo, +, Pedal, Original V2, and the 15- and 32-key modules can be used through a dock.
- The Mini and the original Stream Deck can't yet. Their images go out in an older format that hasn't been written for docks.
- The Stream Deck + has its keys only. Its dials and touch strip aren't used, as on an ESP32.

## On the Device page

A dock's Device page has its name, status, the Stream Deck plugged into it, the dock's serial number and firmware, brightness, orientation, sleep, key presses, triggers, and On Sleep and On Wake.

What belongs to an ESP32 isn't shown: its firmware and updates, network name, setup mode, factory reset, security, developer settings and status light. **Forget Device** removes the dock and disconnects from it; it can be added again from the Network Docks page.

## When something goes wrong

- **The dock isn't listed.** Check that it's powered, plugged into the network, and on the same network as the Mac. Docks are found over Bonjour, which doesn't cross between networks.
- **"Didn't answer".** The dock was found but didn't say who it is. Click **Try Again**. If Elgato's app is using the dock, quit it first.
- **The dock is offline.** ESPDeck Bridge keeps trying, every few seconds at first and then every 30 seconds. The sidebar's ⓘ says what to check.
- **No Stream Deck.** The dock is connected but has no Stream Deck plugged in that can be used through a dock. The Log page says which model the dock reported.

## How it works

Elgato doesn't publish how its software talks to a dock. ESPDeck Bridge follows two MIT-licensed projects that worked it out:

- [Haukcode.StreamDeck](https://github.com/HakanL/Haukcode.StreamDeck) drives real docks, and publishes a packet capture of Elgato's app with a real dock.
- [DeckBridge](https://github.com/lukasMega/DeckBridge) stands in for a dock, so a USB Stream Deck can be used through Elgato's app.

In brief:

- A dock advertises itself over Bonjour as `_elg._tcp`, on port 5343.
- On that port, ESPDeck Bridge asks the dock for its serial number, its firmware, and what's plugged into it. The answer includes the port of a second connection, to the Stream Deck.
- That second connection carries the Stream Deck's own USB reports, each wrapped in a 16-byte header: key images out, in 1 KB pieces, and key states back.
- Both connections send keepalives every few seconds, which ESPDeck Bridge answers.

Inside ESPDeck Bridge, a dock is made to look like an ESPDeck device. It takes the same messages the Mac sends an ESP32 ([PROTOCOL.md](../PROTOCOL.md)) and answers with the ones an ESP32 sends, so the rest of the app needs to know very little about docks. The code is in `ESPDeck Bridge/ESPDeck Bridge/Docks/`.
