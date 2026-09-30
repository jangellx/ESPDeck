// Millisecond clocks and deadlines that stay right across millis()' 49-day wrap.
#pragma once

#include <cstdint>

#include "esp_timer.h"

namespace Timing {
	// Milliseconds since boot, from a clock that's safe on any task (no Arduino needed).
	inline uint32_t nowMillis() {
		return (uint32_t)( esp_timer_get_time() / 1000 );
	}

	// Whether `deadline` has come by `now`.
	inline bool reached( uint32_t deadline, uint32_t now ) {
		return (int32_t)( now - deadline ) >= 0;
	}
}
