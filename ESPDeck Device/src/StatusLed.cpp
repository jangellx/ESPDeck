#include "StatusLed.h"

#include <Arduino.h>

#include <cmath>

namespace {
	// The board's WS2812 is very bright; these are full-scale values for each state.
	constexpr uint8_t  kPulsePeak      = 110;
	constexpr uint8_t  kPulseFloor     = 6;
	constexpr uint8_t  kConnectedLevel = 64;    // 25%
	constexpr uint8_t  kKeyLevel       = 140;
	constexpr uint32_t kPulsePeriod    = 2000;  // ms
	constexpr uint32_t kKeyFlash       = 150;   // ms of white, at least, per key press
	constexpr uint32_t kActivityHold   = 300;   // ms the data pulse lasts after the last message
	constexpr uint32_t kActivityPeriod = 400;   // ms, a quicker pulse than the searching ones
	constexpr uint8_t  kActivityPeak   = 160;

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

void StatusLed::update( Mode mode, bool keyDown ) {
	if( !ready_ )
		return;

	if( keyDown || before( keyUntil_ ) ) {
		write( kKeyLevel, kKeyLevel, kKeyLevel );
		return;
	}

	switch( mode ) {
		case Mode::Setup: {
			uint8_t level = pulseLevel();
			write( 0, level / 4, level );            // Wi-Fi blue
			break;
		}
		case Mode::Searching: {
			uint8_t level = pulseLevel();
			write( level, (uint8_t)( level * 3 / 4 ), 0 );   // yellow (a touch less green reads as yellow on WS2812s)
			break;
		}
		case Mode::Connected:
			if( before( activityUntil_ ) )
				write( 0, (uint8_t)( kConnectedLevel + ( kActivityPeak - kConnectedLevel ) * pulse( kActivityPeriod ) ), 0 );
			else
				write( 0, kConnectedLevel, 0 );
			break;
	}
}

void StatusLed::write( uint8_t red, uint8_t green, uint8_t blue ) {
	uint32_t colour = (uint32_t)red << 16 | (uint32_t)green << 8 | blue;
	if( colour == written_ )
		return;
	written_ = colour;
	rgbLedWrite( pin_, red, green, blue );
}
