// The dev board's RGB LED as a status light:
//   setup mode              pulsing blue
//   looking for Wi-Fi       pulsing yellow
//   on Wi-Fi, no bridge     pulsing green (looking for the bridge, or waiting on one)
//   connected to the bridge solid green at 25%, pulsing brighter while data moves
//   a key pressed or held   white, for at least a moment even on a quick tap
//   pairing                 blinking magenta (the Pedal has no screen for the code), steady
//                           once confirmed on the deck
// While the deck is asleep, connected is off and everything else is very dim (pulses keep
// pulsing), so the light doesn't glow in a dark room.
#pragma once

#include <cstdint>

// Drives the status LED; see above for what each state looks like.
class StatusLed {
public:
	// What the device is doing, which picks the colour.
	enum class Mode : uint8_t {
		Setup,
		Searching,
		OnWifi,
		Connected,
		Pairing,
		PairingConfirmed,
	};

	// Starts driving the LED on pin, off.
	void begin( uint8_t pin );

	// A key went down: white now, and for at least kKeyFlash even if it's released at once
	// (the loop can be busy uploading an image for a third of a second).
	void keyPressed();

	// Data went to or came from the Mac.
	void activity();

	// Call every loop pass; writes the LED only when its colour changes.
	void update( Mode mode, bool keyDown, bool asleep );

private:
	// Shows a full-scale colour, dimmed while asleep.
	void show( uint8_t red, uint8_t green, uint8_t blue );
	// Sends a colour to the LED, unless it's already showing it.
	void write( uint8_t red, uint8_t green, uint8_t blue );

	uint8_t  pin_           = 0;
	bool     ready_         = false;
	uint32_t written_       = 0xFFFFFFFF;   // last colour sent, 0xRRGGBB
	uint32_t keyUntil_      = 0;            // millis()
	uint32_t activityUntil_ = 0;
	bool     dim_           = false;        // asleep, as of the last update()
};
