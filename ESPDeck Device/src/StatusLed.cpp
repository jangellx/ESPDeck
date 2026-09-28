#include "StatusLed.h"

#include <Arduino.h>

#include <cmath>

namespace {
	// The board's WS2812 is very bright; these are full-scale values for each state.
	constexpr uint8_t  kPulsePeak      = 110;
	constexpr uint8_t  kPulseFloor     = 6;
	constexpr uint8_t  kConnectedLevel = 64;    // 25%
	constexpr uint8_t  kKeyLevel       = 140;
	constexpr uint8_t  kPairingLevel   = 120;
	constexpr uint32_t kPairingBlink   = 250;   // ms on, then off
	constexpr uint32_t kPulsePeriod    = 2000;  // ms
	constexpr uint32_t kKeyFlash       = 150;   // ms of white, at least, per key press
	constexpr uint32_t kActivityHold   = 300;   // ms the data pulse lasts after the last message
	constexpr uint32_t kActivityPeriod = 400;   // ms, a quicker pulse than the searching ones
	constexpr uint8_t  kActivityPeak   = 160;
	// Asleep, the pulse peak scales down to this: visible in a dark room, but no more.
	constexpr uint8_t  kSleepPeak      = 8;

	// Scales a channel for sleep, keeping anything that was lit at least barely lit.
	uint8_t dimmed( uint8_t level ) {
		if( level == 0 )
			return 0;
		unsigned scaled = ( (unsigned)level * kSleepPeak + kPulsePeak / 2 ) / kPulsePeak;
		return (uint8_t)( scaled < 1 ? 1 : scaled > 255 ? 255 : scaled );
	}

	bool before( uint32_t deadline ) {
		return (int32_t)( deadline - millis() ) > 0;
	}

	// 0…1…0 over the period, eased so it breathes rather than blinks.
	float pulse( uint32_t period = kPulsePeriod ) {
		float phase = (float)( millis() % period ) / period;
		return 0.5f - 0.5f * cosf( phase * 2.0f * (float)M_PI );
	}

	uint8_t pulseLevel() {
		return (uint8_t)( kPulseFloor + ( kPulsePeak - kPulseFloor ) * pulse() );
	}
}

void StatusLed::begin( uint8_t pin ) {
	pin_   = pin;
	ready_ = true;
	write( 0, 0, 0 );
}

void StatusLed::keyPressed() {
	keyUntil_ = millis() + kKeyFlash;
}

void StatusLed::activity() {
	activityUntil_ = millis() + kActivityHold;
}

void StatusLed::update( Mode mode, bool keyDown, bool asleep ) {
	if( !ready_ )
		return;
	dim_ = asleep;

	if( keyDown || before( keyUntil_ ) ) {
		show( kKeyLevel, kKeyLevel, kKeyLevel );
		return;
	}

	if( asleep && mode == Mode::Connected ) {
		show( 0, 0, 0 );
		return;
	}

	switch( mode ) {
		case Mode::Setup: {
			uint8_t level = pulseLevel();
			show( 0, level / 4, level );             // Wi-Fi blue
			break;
		}
		case Mode::Searching: {
			uint8_t level = pulseLevel();
			show( level, (uint8_t)( level * 3 / 4 ), 0 );    // yellow (a touch less green reads as yellow on WS2812s)
			break;
		}
		case Mode::Pairing:
			if( ( millis() / kPairingBlink ) % 2 == 0 )
				show( kPairingLevel, 0, kPairingLevel );
			else
				show( 0, 0, 0 );
			break;
		case Mode::PairingConfirmed:
			show( kPairingLevel, 0, kPairingLevel );
			break;
		case Mode::Connected:
			if( before( activityUntil_ ) )
				show( 0, (uint8_t)( kConnectedLevel + ( kActivityPeak - kConnectedLevel ) * pulse( kActivityPeriod ) ), 0 );
			else
				show( 0, kConnectedLevel, 0 );
			break;
	}
}

void StatusLed::show( uint8_t red, uint8_t green, uint8_t blue ) {
	if( dim_ )
		write( dimmed( red ), dimmed( green ), dimmed( blue ) );
	else
		write( red, green, blue );
}

void StatusLed::write( uint8_t red, uint8_t green, uint8_t blue ) {
	uint32_t colour = (uint32_t)red << 16 | (uint32_t)green << 8 | blue;
	if( colour == written_ )
		return;
	written_ = colour;
	rgbLedWrite( pin_, red, green, blue );
}
