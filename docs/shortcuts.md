# ESPDeck actions in Shortcuts

ESPDeck Bridge 1.2.0 and later add actions to the Shortcuts app, so a shortcut or an automation can control the decks themselves: a page of morning keys at 7 AM, the decks asleep when a Focus starts, or the brightness down at night.

This page covers the actions ESPDeck Bridge gives Shortcuts. Keys that run a shortcut when they're pressed are a different thing, set up on the Keys page (see [The Mac app](mac-app.md)).

To find the actions, search for "ESPDeck" in the Shortcuts app's action list, or open ESPDeck Bridge in its list of apps.

## How the actions run

- The actions run in ESPDeck Bridge. If it isn't running, Shortcuts opens it in the background first.
- A deck that's still connecting, as decks are just after ESPDeck Bridge opens, gets up to 15 seconds. After that the action fails and says which deck isn't connected.
- Demo decks aren't listed and can't be chosen.
- Decks and menus are remembered by their IDs, so a shortcut keeps working when a deck or a menu's key is renamed. A shortcut whose menu has been deleted fails with "The menu … no longer exists."

## The actions

### Go to Page

Shows one of a deck's pages, as a Go to Page key does. A menu that's open on the deck closes.

- **Deck**: the deck to change.
- **Page**: the page's number, counting from 1, as the Keys page shows them. A page the deck doesn't have makes the action fail, saying the deck has no such page.

In the shortcut editor it reads "Show page 1 on Deck".

### Open Menu

Opens one of a deck's menus over the page it's on, as the key that opens it does.

- **Menu**: each menu is named for the key that opens it, with its deck below. There's no separate Deck setting, since a menu belongs to one deck.

### Close Menu

Closes the menu open on a deck, as its Close key does, going back to the page under it. Nothing happens if no menu is open.

- **Deck**: the deck whose menu to close.

### Sleep Deck

Turns a deck's screen off, as Sleep Now on the Device page does. Pressing any of its keys wakes it.

- **Deck**: the deck to put to sleep. Leave it empty to put every deck to sleep.

### Wake Deck

Turns a sleeping deck's screen back on, as Wake Now on the Device page does.

- **Deck**: the deck to wake. Leave it empty to wake every deck.

### Set Deck Brightness

Sets how bright a deck's screen is. It's the same setting as Brightness on the Device page, and it stays until it's changed again.

- **Deck**: the deck to change. Leave it empty to change every deck.
- **Brightness**: from 0 to 100 percent. It starts at 80.

When Deck is empty, Sleep Deck, Wake Deck and Set Deck Brightness act on every deck that's connected. They fail only if no deck connects at all.

### Find Decks and Find Menus

Shortcuts makes these two actions itself from the lists of decks and menus. They find decks or menus, which can then be passed to the other actions, like every deck to Sleep Deck in a Repeat with Each.

- **Find Decks** can filter by a deck's name.
- **Find Menus** can filter by a menu's name or its deck's name.
- Both can sort what they find and limit how many they return.

## Ready-made shortcuts and Siri

Two shortcuts are ready-made in the Shortcuts app under ESPDeck Bridge, with no setting up:

- **Sleep Decks** puts every deck to sleep. Siri knows it as "Sleep my decks with ESPDeck Bridge" or "Put my decks to sleep with ESPDeck Bridge".
- **Wake Decks** wakes every deck. Siri knows it as "Wake my decks with ESPDeck Bridge".

## Examples

- **Morning page**: an automation at 7 AM runs **Wake Deck**, then **Go to Page** with the page of morning keys.
- **Sleep with a Focus**: an automation when the Sleep Focus starts runs **Sleep Deck** with Deck left empty.
- **Dim at night**: an automation at sunset runs **Set Deck Brightness** at 30 percent, and another at sunrise sets it back to 80.

## Errors

When an action can't run, Shortcuts shows why:

| Message | What it means |
|---|---|
| "*Deck* isn't connected to ESPDeck Bridge." | The deck didn't connect within 15 seconds. Check that it's powered and on Wi-Fi. |
| "No deck is connected to ESPDeck Bridge." | No deck is set up, or none connected within 15 seconds. |
| "*Deck* has no page *N*." | Go to Page asked for a page past the deck's last one. |
| "The menu *Name* no longer exists." | The menu's key was cleared or changed after the shortcut was made. |

## If the actions don't appear

Shortcuts reads its actions from one copy of ESPDeck Bridge. If the Mac has more than one, such as the App Store copy in Applications and a copy built in Xcode, it can read one that predates the actions (1.1.1 or earlier), and none appear.

1. Make sure the copy in Applications is 1.2.0 or later, or remove the older copies.
2. Open ESPDeck Bridge once.
3. Quit and reopen Shortcuts. The actions can take a minute to appear the first time.
