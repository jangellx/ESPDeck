#include "StreamDeck.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/task.h"
#include "usb/usb_helpers.h"

static const char *TAG = "StreamDeck";

namespace {
	using Protocol  = StreamDeck::Protocol;
	using Format    = StreamDeck::Format;
	using Transform = StreamDeck::Transform;

	constexpr uint16_t kElgatoVID = 0x0FD9;
	// Models the code treats specially (their rows are in kModels).
	constexpr uint16_t kMiniPID   = 0x0063;   // the first Mini: short serial number report
	constexpr uint16_t kNeoPID    = 0x009A;   // info bar
	constexpr uint16_t kPlusPID   = 0x0084;   // touch strip

	// One row of the model table.
	struct Model {
		uint16_t    pid;
		const char *name;
		Protocol    protocol;
		uint8_t     rows;
		uint8_t     cols;
		uint16_t    keySize;
		Format      format;
		Transform   transform;
		bool        reversed;
	};

	constexpr Model kModels[] = {
		{ 0x0063, "Stream Deck Mini",           Protocol::Mini,     2, 3,  80, Format::BMP,  Transform::Transpose, false },
		{ 0x0090, "Stream Deck Mini 2022",      Protocol::Mini,     2, 3,  80, Format::BMP,  Transform::Transpose, false },
		{ 0x00B3, "Stream Deck Mini Discord",   Protocol::Mini,     2, 3,  80, Format::BMP,  Transform::Transpose, false },
		{ 0x00B8, "Stream Deck 6-Key Module",   Protocol::Mini,     2, 3,  80, Format::BMP,  Transform::Transpose, false },
		// Untested: written from python-elgato-streamdeck without an original Stream Deck to try.
		{ 0x0060, "Stream Deck (Original)",     Protocol::Original, 3, 5,  72, Format::BMP,  Transform::Rotate180, true  },
		{ 0x006D, "Stream Deck (Original V2)",  Protocol::Main,     3, 5,  72, Format::JPEG, Transform::Rotate180, false },
		{ 0x0080, "Stream Deck MK.2",           Protocol::Main,     3, 5,  72, Format::JPEG, Transform::Rotate180, false },
		{ 0x00A5, "Stream Deck MK.2 Scissor",   Protocol::Main,     3, 5,  72, Format::JPEG, Transform::Rotate180, false },
		{ 0x00B9, "Stream Deck 15-Key Module",  Protocol::Main,     3, 5,  72, Format::JPEG, Transform::Rotate180, false },
		{ 0x00E4, "Stream Deck 15-Key Module (Scissor)", Protocol::Main, 3, 5, 72, Format::JPEG, Transform::Rotate180, false },
		{ 0x006C, "Stream Deck XL",             Protocol::Main,     4, 8,  96, Format::JPEG, Transform::Rotate180, false },
		{ 0x008F, "Stream Deck XL V2",          Protocol::Main,     4, 8,  96, Format::JPEG, Transform::Rotate180, false },
		{ 0x00BA, "Stream Deck 32-Key Module",  Protocol::Main,     4, 8,  96, Format::JPEG, Transform::Rotate180, false },
		{ 0x009A, "Stream Deck Neo",            Protocol::Main,     2, 4,  96, Format::JPEG, Transform::Rotate180, false },
		{ 0x0084, "Stream Deck +",              Protocol::Main,     2, 4, 120, Format::JPEG, Transform::None,      false },
		{ 0x0086, "Stream Deck Pedal",          Protocol::Main,     1, 3,   0, Format::None, Transform::None,      false },
	};

	// Output report 0x02 carries image data, split into pages.
	//   Mini:     [0x02, 0x01, page, 0, last, key + 1, 0…] (16 bytes), 1024-byte reports
	//   Original: same header with a 1-based page number, 8191-byte reports
	//   Main:     [0x02, 0x07, key, last, length LE16, page LE16] (8 bytes), 1024-byte reports
	constexpr uint8_t  kImageReportID   = 0x02;
	constexpr size_t   kReportSize      = 1024;
	constexpr size_t   kMaxReportSize   = 8191;  // the Original's
	constexpr uint16_t kMaxPeriodicOut  = 128;   // the host's limit with CONFIG_USB_HOST_HW_BUFFER_BIAS_IN
	constexpr uint16_t kFullSpeedPacket = 64;    // the most an interrupt packet can be at full speed
	// ESP-IDF's host splits an interrupt transfer into at most this many packets (it asserts
	// otherwise), so the Original's 8191-byte reports go out as several transfers.
	constexpr size_t   kMaxInterruptPackets = 32;

	// A protocol's image report size, and the size of the header before the image data.
	size_t reportSize( Protocol protocol ) {
		return protocol == Protocol::Original ? kMaxReportSize : kReportSize;
	}

	size_t headerSize( Protocol protocol ) {
		return protocol == Protocol::Main ? 8 : 16;
	}

	// Input report 0x01: one byte per key, 0 = up, 1 = down. Main-protocol reports start
	// with an event type (0x00 = keys) and a 16-bit length, so key states begin at byte 4.
	constexpr uint8_t  kKeyReportID     = 0x01;

	// Feature reports. The Mini and Original use 17-byte feature reports (the later Minis
	// return up to 32 for the serial number); the main protocol uses 32.
	constexpr size_t   kShortFeatureSize = 17;
	constexpr size_t   kLongFeatureSize  = 32;
	constexpr uint8_t  kUnitInfoReportID = 0x08;   // main protocol: rows, cols, key width

	constexpr uint32_t kTransferTimeout  = 2000;   // ms; an 8191-byte interrupt report takes ~130

	// Our client may only open a new device once it has heard of it (see shrinkOversizedOut()).
	constexpr int      kOpenAttempts     = 50;
	constexpr uint32_t kOpenRetryDelay   = 10;     // ms

	// Tasks: the USB host library's, our client's and the HID driver's on core 0, and deviceTask().
	constexpr uint32_t    kTaskStack          = 4096;   // bytes, every task
	constexpr UBaseType_t kUsbPriority        = 5;
	constexpr BaseType_t  kUsbCore            = 0;
	constexpr UBaseType_t kDevicePriority     = 4;

	constexpr UBaseType_t kEventQueueLength   = 64;
	constexpr UBaseType_t kRequestQueueLength = 8;

	// Calls fn( ep ) for each interrupt OUT endpoint of interface `number`.
	template <typename Fn>
	void forEachInterruptOut( const usb_config_desc_t *config, uint8_t number, Fn fn ) {
		int intfOffset = 0;
		const usb_intf_desc_t *intf = usb_parse_interface_descriptor( config, number, 0, &intfOffset );
		for( int i = 0; intf && i < intf->bNumEndpoints; i++ ) {
			int offset = intfOffset;
			const usb_ep_desc_t *ep = usb_parse_endpoint_descriptor_by_index( intf, i, config->wTotalLength, &offset );
			if( ep && !( ep->bEndpointAddress & USB_B_ENDPOINT_ADDRESS_EP_DIR_MASK )
			    && ( ep->bmAttributes & USB_BM_ATTRIBUTES_XFERTYPE_MASK ) == USB_BM_ATTRIBUTES_XFER_INT )
				fn( ep );
		}
	}
}

// MARK: - Names

const char *StreamDeck::formatName( Format format ) {
	switch( format ) {
		case Format::BMP:  return "bmp";
		case Format::JPEG: return "jpeg";
		default:           return "none";
	}
}

const char *StreamDeck::transformName( Transform transform ) {
	switch( transform ) {
		case Transform::Transpose: return "transpose";
		case Transform::Rotate90:  return "rotate90";
		case Transform::Rotate270: return "rotate270";
		case Transform::Rotate180: return "rotate180";
		default:                   return "none";
	}
}

// Parses a transformName() back.
bool StreamDeck::transformFromName( const char *name, Transform &out ) {
	static constexpr Transform kAll[] = { Transform::None, Transform::Transpose, Transform::Rotate90, Transform::Rotate270, Transform::Rotate180 };
	for( Transform transform : kAll ) {
		if( name && strcmp( name, transformName( transform ) ) == 0 ) {
			out = transform;
			return true;
		}
	}
	return false;
}

// MARK: - Setup

bool StreamDeck::begin() {
	events_      = xQueueCreate( kEventQueueLength, sizeof( Event ) );
	requests_    = xQueueCreate( kRequestQueueLength, sizeof( Request ) );
	mutex_       = xSemaphoreCreateMutex();
	transferSem_ = xSemaphoreCreateBinary();
	report_      = (uint8_t *)heap_caps_malloc( kMaxReportSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT );
	if( !events_ || !requests_ || !mutex_ || !transferSem_ || !report_ )
		return false;

	usb_host_config_t hostConfig = {};
	hostConfig.skip_phy_setup = false;
	hostConfig.intr_flags     = ESP_INTR_FLAG_LEVEL1;
	esp_err_t err = usb_host_install( &hostConfig );
	if( err != ESP_OK ) {
		ESP_LOGE( TAG, "usb_host_install failed: %s", esp_err_to_name( err ) );
		return false;
	}
	xTaskCreatePinnedToCore( usbLibraryTask, "usb_lib", kTaskStack, this, kUsbPriority, nullptr, kUsbCore );

	usb_host_client_config_t clientConfig = {};
	clientConfig.is_synchronous              = false;
	clientConfig.max_num_event_msg           = 5;
	clientConfig.async.client_event_callback = clientEventCallback;
	clientConfig.async.callback_arg          = this;
	err = usb_host_client_register( &clientConfig, &client_ );
	if( err != ESP_OK ) {
		ESP_LOGE( TAG, "usb_host_client_register failed: %s", esp_err_to_name( err ) );
		return false;
	}
	xTaskCreatePinnedToCore( clientTask, "usb_deck", kTaskStack, this, kUsbPriority, nullptr, kUsbCore );

	hid_host_driver_config_t driverConfig = {};
	driverConfig.create_background_task = true;
	driverConfig.task_priority          = kUsbPriority;
	driverConfig.stack_size             = kTaskStack;
	driverConfig.core_id                = kUsbCore;
	driverConfig.callback               = driverCallback;
	driverConfig.callback_arg           = this;
	err = hid_host_install( &driverConfig );
	if( err != ESP_OK ) {
		ESP_LOGE( TAG, "hid_host_install failed: %s", esp_err_to_name( err ) );
		return false;
	}

	xTaskCreate( deviceTask, "deck", kTaskStack, this, kDevicePriority, nullptr );
	ESP_LOGI( TAG, "USB host ready" );
	return true;
}

// Everything below is inert until begin() has run (with a computer on the USB port it never does).
bool StreamDeck::nextEvent( Event &event, TickType_t wait ) {
	return events_ && xQueueReceive( events_, &event, wait ) == pdTRUE;
}

bool StreamDeck::isConnected() const {
	if( !mutex_ )
		return false;
	xSemaphoreTake( mutex_, portMAX_DELAY );
	bool connected = handle_ != nullptr;
	xSemaphoreGive( mutex_ );
	return connected;
}

StreamDeck::UsbDevice StreamDeck::lastUsbDevice() const {
	if( !mutex_ )   // no USB host: a computer is on the port
		return {};
	xSemaphoreTake( mutex_, portMAX_DELAY );
	UsbDevice copy = usbDevice_;
	xSemaphoreGive( mutex_ );
	return copy;
}

StreamDeck::Info StreamDeck::info() const {
	if( !mutex_ )
		return {};
	xSemaphoreTake( mutex_, portMAX_DELAY );
	Info copy = info_;
	xSemaphoreGive( mutex_ );
	return copy;
}

// Queues an event for nextEvent(); dropped if the queue is full.
void StreamDeck::post( EventType type, uint8_t key ) {
	Event event = { type, key };
	if( xQueueSend( events_, &event, 0 ) != pdTRUE )
		ESP_LOGW( TAG, "Event queue full; dropped event %d", (int)type );
}

// Reversing within a row is its own inverse, so this maps both ways.
uint8_t StreamDeck::wireKey( uint8_t key ) const {
	if( !info_.reversed )
		return key;
	uint8_t row = key / info_.cols;
	uint8_t col = key % info_.cols;
	return row * info_.cols + ( info_.cols - 1 - col );
}

// MARK: - Tasks and callbacks

// The USB host library's event loop.
void StreamDeck::usbLibraryTask( void * ) {
	while( true ) {
		uint32_t flags = 0;
		usb_host_lib_handle_events( portMAX_DELAY, &flags );
		if( flags & USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS )
			usb_host_device_free_all();
	}
}

// Runs our client's completion callbacks (control transfers submitted through client_).
void StreamDeck::clientTask( void *arg ) {
	StreamDeck *self = static_cast<StreamDeck *>( arg );
	while( true )
		usb_host_client_handle_events( self->client_, portMAX_DELAY );
}

// Stream Decks reach us through the HID driver, which ignores anything that isn't HID
// without a word, so log every device here (and tell the Mac): a deck that never shows up
// can then be told apart from one that never attached.
void StreamDeck::clientEventCallback( const usb_host_client_event_msg_t *message, void *arg ) {
	StreamDeck *self = static_cast<StreamDeck *>( arg );
	if( message->event == USB_HOST_CLIENT_EVENT_DEV_GONE ) {
		ESP_LOGI( TAG, "USB device unplugged" );
		return;
	}
	if( message->event != USB_HOST_CLIENT_EVENT_NEW_DEV )
		return;

	uint8_t                  address = message->new_dev.address;
	usb_device_handle_t      device  = nullptr;
	const usb_device_desc_t *desc    = nullptr;
	usb_device_info_t        info    = {};
	UsbDevice                seen    = { true };
	if( usb_host_device_open( self->client_, address, &device ) != ESP_OK ) {
		ESP_LOGI( TAG, "USB device plugged in (address %u)", address );
		self->recordUsbDevice( seen );
		return;
	}
	if( usb_host_get_device_descriptor( device, &desc ) == ESP_OK && usb_host_device_info( device, &info ) == ESP_OK ) {
		seen = { true, desc->idVendor, desc->idProduct, desc->bDeviceClass };
		// Class 0x09 is a hub, which this firmware doesn't support; 0x00 means per interface (HID for a deck).
		ESP_LOGI( TAG, "USB device plugged in: %04X:%04X, class 0x%02X, %s speed", desc->idVendor, desc->idProduct, desc->bDeviceClass,
				  info.speed == USB_SPEED_LOW ? "low" : info.speed == USB_SPEED_FULL ? "full" : "high" );
		if( desc->bDeviceClass == USB_CLASS_HUB )
			ESP_LOGW( TAG, "That's a USB hub; a Stream Deck behind a hub isn't supported" );
	}
	// Its endpoints: the host's FIFOs limit how big their packets can be.
	const usb_config_desc_t *config = nullptr;
	if( usb_host_get_active_config_descriptor( device, &config ) == ESP_OK ) {
		int offset = 0;
		for( const usb_standard_desc_t *next = (const usb_standard_desc_t *)config; ( next = usb_parse_next_descriptor_of_type( next, config->wTotalLength, USB_B_DESCRIPTOR_TYPE_ENDPOINT, &offset ) ); ) {
			const usb_ep_desc_t *ep = (const usb_ep_desc_t *)next;
			static const char *const types[] = { "control", "isochronous", "bulk", "interrupt" };
			ESP_LOGI( TAG, "  Endpoint 0x%02X: %s %s, max packet %u bytes, interval %u", ep->bEndpointAddress,
					  types[ep->bmAttributes & USB_BM_ATTRIBUTES_XFERTYPE_MASK], ( ep->bEndpointAddress & USB_B_ENDPOINT_ADDRESS_EP_DIR_MASK ) ? "IN" : "OUT",
					  USB_EP_DESC_GET_MPS( ep ), ep->bInterval );
		}
	}
	usb_host_device_close( self->client_, device );
	self->recordUsbDevice( seen );
}

// Keeps what was plugged in for lastUsbDevice() and tells the owner.
void StreamDeck::recordUsbDevice( const UsbDevice &device ) {
	xSemaphoreTake( mutex_, portMAX_DELAY );
	usbDevice_ = device;
	xSemaphoreGive( mutex_ );
	post( EventType::UsbDevice );
}

// Called on whichever client owns the endpoint: ours for control transfers, the HID
// driver's for the interrupt OUT endpoint.
void StreamDeck::transferDone( usb_transfer_t *transfer ) {
	StreamDeck *self = static_cast<StreamDeck *>( transfer->context );
	xSemaphoreGive( self->transferSem_ );
}

// Opening and closing happen here rather than in the driver callbacks, so a key image
// upload holding the mutex can't stall the HID driver's background task.
void StreamDeck::deviceTask( void *arg ) {
	StreamDeck *self = static_cast<StreamDeck *>( arg );
	Request     request;
	while( true ) {
		if( xQueueReceive( self->requests_, &request, portMAX_DELAY ) != pdTRUE )
			continue;
		if( request.type == RequestType::Connected )
			self->handleConnected( request.handle );
		else
			self->handleDisconnected( request.handle );
	}
}

// The HID driver saw a new interface: handleConnected() takes it from deviceTask().
void StreamDeck::driverCallback( hid_host_device_handle_t handle, const hid_host_driver_event_t event, void *arg ) {
	StreamDeck *self = static_cast<StreamDeck *>( arg );
	if( event == HID_HOST_DRIVER_EVENT_CONNECTED ) {
		Request request = { RequestType::Connected, handle };
		xQueueSend( self->requests_, &request, 0 );
	}
}

// Input reports, unplugging and errors on an open interface, on the HID driver's task.
void StreamDeck::interfaceCallback( hid_host_device_handle_t handle, const hid_host_interface_event_t event, void *arg ) {
	StreamDeck *self = static_cast<StreamDeck *>( arg );
	switch( event ) {
		case HID_HOST_INTERFACE_EVENT_INPUT_REPORT: {
			uint8_t data[64];
			size_t  length = 0;
			if( hid_host_device_get_raw_input_report_data( handle, data, sizeof( data ), &length ) == ESP_OK )
				self->handleInputReport( data, length );
			break;
		}
		case HID_HOST_INTERFACE_EVENT_DISCONNECTED: {
			Request request = { RequestType::Disconnected, handle };
			xQueueSend( self->requests_, &request, 0 );
			break;
		}
		case HID_HOST_INTERFACE_EVENT_TRANSFER_ERROR:
			ESP_LOGW( TAG, "Transfer error" );
			break;
		default:
			break;
	}
}

// MARK: - Connection

// Opens a newly attached interface and, if it's a Stream Deck and none is connected yet,
// makes it the deck.
void StreamDeck::handleConnected( hid_host_device_handle_t handle ) {
	hid_host_device_config_t deviceConfig = {};
	deviceConfig.callback     = interfaceCallback;
	deviceConfig.callback_arg = this;
	shrinkOversizedOut( handle );   // before the HID driver claims the interface
	if( hid_host_device_open( handle, &deviceConfig ) != ESP_OK ) {
		ESP_LOGW( TAG, "Couldn't open HID interface" );
		return;
	}

	hid_host_dev_info_t deviceInfo = {};
	hid_host_get_device_info( handle, &deviceInfo );
	Info info = {};
	if( !identify( handle, deviceInfo.VID, deviceInfo.PID, info ) ) {
		ESP_LOGW( TAG, "Ignoring HID device %04X:%04X (not a known Stream Deck)", deviceInfo.VID, deviceInfo.PID );
		hid_host_device_close( handle );
		return;
	}

	xSemaphoreTake( mutex_, portMAX_DELAY );
	bool busy = handle_ != nullptr;
	xSemaphoreGive( mutex_ );
	if( busy ) {
		ESP_LOGW( TAG, "A Stream Deck is already connected; ignoring the second one" );
		hid_host_device_close( handle );
		return;
	}

	if( info.protocol == Protocol::Main ) {
		readFeatureString( handle, 0x06, kLongFeatureSize, 2, info.serial, sizeof( info.serial ) );
		readFeatureString( handle, 0x05, kLongFeatureSize, 6, info.firmware, sizeof( info.firmware ) );
	} else {
		size_t serialLength = info.pid == kMiniPID || info.protocol == Protocol::Original ? kShortFeatureSize : kLongFeatureSize;
		readFeatureString( handle, 0x03, serialLength, 5, info.serial, sizeof( info.serial ) );
		readFeatureString( handle, 0x04, kShortFeatureSize, 5, info.firmware, sizeof( info.firmware ) );
	}

	// From python-elgato-streamdeck and Elgato's HID documentation.
	if( info.pid == kNeoPID ) {         // Neo: info bar, flipped both ways like its keys
		info.screenWidth     = 248;
		info.screenHeight    = 58;
		info.screenTransform = Transform::Rotate180;
	} else if( info.pid == kPlusPID ) { // +: touch strip, upright
		info.screenWidth     = 800;
		info.screenHeight    = 100;
		info.screenTransform = Transform::None;
	}

	// info_ is in place before input reports start, since handleInputReport() reads it
	// without the mutex.
	xSemaphoreTake( mutex_, portMAX_DELAY );
	info_ = info;
	memset( keyStates_, 0, sizeof( keyStates_ ) );
	bool ready = info.format == Format::None || openOutput( handle );
	if( ready )
		handle_ = handle;
	xSemaphoreGive( mutex_ );

	if( !ready || hid_host_device_start( handle ) != ESP_OK ) {
		ESP_LOGW( TAG, "Couldn't start the Stream Deck" );
		xSemaphoreTake( mutex_, portMAX_DELAY );
		handle_ = nullptr;
		closeOutput();
		xSemaphoreGive( mutex_ );
		hid_host_device_close( handle );
		return;
	}

	ESP_LOGI( TAG, "%s connected (PID 0x%04X, %u × %u keys, serial %s, firmware %s)", info.model, info.pid, info.rows, info.cols, info.serial, info.firmware );
	prepareDeck( handle );
	post( EventType::Connected );
}

// Like python-elgato-streamdeck's open(): an empty image report ends any image a previous
// connection left half-sent (the board restarted mid-upload, say), which would otherwise
// swallow the start of the next one. And the deck's own sleep timer goes off, so only
// ESPDeck's decides when the keys go dark.
void StreamDeck::prepareDeck( hid_host_device_handle_t handle ) {
	xSemaphoreTake( mutex_, portMAX_DELAY );
	Protocol protocol = info_.protocol;
	if( info_.format != Format::None ) {
		size_t size = reportSize( protocol );
		memset( report_, 0, size );
		report_[0] = kImageReportID;
		esp_err_t err = sendReport( size );
		if( err != ESP_OK )
			ESP_LOGW( TAG, "Couldn't reset the image stream: %s", esp_err_to_name( err ) );
	}
	xSemaphoreGive( mutex_ );

	// A seconds count of 0 turns sleep off; feature reports are sized as for setBrightness().
	// The Original's equivalent isn't documented.
	uint8_t payload[kLongFeatureSize] = {};
	size_t  length = kLongFeatureSize;
	if( protocol == Protocol::Main ) {
		payload[0] = 0x03;
		payload[1] = 0x0D;
	} else if( protocol == Protocol::Mini ) {
		payload[0] = 0x0B;
		payload[1] = 0xA2;
		length     = kShortFeatureSize;
	} else {
		return;
	}
	esp_err_t err = hid_class_request_set_report( handle, HID_REPORT_TYPE_FEATURE, payload[0], payload, length );
	if( err != ESP_OK )
		ESP_LOGW( TAG, "Couldn't turn off the deck's own sleep timer: %s", esp_err_to_name( err ) );
}

// Closes an interface that went away, and drops the deck if it was ours.
void StreamDeck::handleDisconnected( hid_host_device_handle_t handle ) {
	xSemaphoreTake( mutex_, portMAX_DELAY );
	bool ours = handle == handle_;
	if( ours ) {
		handle_ = nullptr;
		closeOutput();
	}
	xSemaphoreGive( mutex_ );

	hid_host_device_close( handle );
	if( ours ) {
		ESP_LOGI( TAG, "Stream Deck disconnected" );
		post( EventType::Disconnected );
	}
}

// Known models come from the table. Other Elgato devices are asked for their layout with
// the main protocol's "Get Unit Information" feature report.
bool StreamDeck::identify( hid_host_device_handle_t handle, uint16_t vid, uint16_t pid, Info &info ) {
	if( vid != kElgatoVID )
		return false;

	info.pid = pid;
	for( const Model &model : kModels ) {
		if( model.pid != pid )
			continue;
		strlcpy( info.model, model.name, sizeof( info.model ) );
		info.protocol  = model.protocol;
		info.rows      = model.rows;
		info.cols      = model.cols;
		info.keySize   = model.keySize;
		info.format    = model.format;
		info.transform = model.transform;
		info.reversed  = model.reversed;
		return true;
	}

	uint8_t buffer[kLongFeatureSize] = { kUnitInfoReportID };
	size_t  received = sizeof( buffer );
	if( hid_class_request_get_report( handle, HID_REPORT_TYPE_FEATURE, kUnitInfoReportID, buffer, &received ) != ESP_OK || received < 5 )
		return false;

	uint8_t  rows  = buffer[1];
	uint8_t  cols  = buffer[2];
	uint16_t width = buffer[3] | ( buffer[4] << 8 );
	ESP_LOGI( TAG, "PID 0x%04X reports %u × %u keys of %u px", pid, rows, cols, width );
	if( rows < 1 || rows > 8 || cols < 1 || cols > 8 || rows * cols > kMaxKeys || width < 32 || width > 256 )
		return false;

	snprintf( info.model, sizeof( info.model ), "Stream Deck (PID 0x%04X)", pid );
	info.protocol  = Protocol::Main;
	info.rows      = rows;
	info.cols      = cols;
	info.keySize   = width;
	info.format    = Format::JPEG;
	info.transform = Transform::Rotate180;
	info.reversed  = false;
	return true;
}

// Posts KeyDown and KeyUp for keys whose state changed. Input reports are longer than the
// endpoint's 64-byte max packet size, so the tail arrives as separate transfers; only
// transfers starting with the key report ID count.
void StreamDeck::handleInputReport( const uint8_t *data, size_t length ) {
	bool    main  = info_.protocol == Protocol::Main;
	size_t  first = main ? 4 : 1;
	uint8_t count = info_.keyCount();
	if( length < first + count || data[0] != kKeyReportID )
		return;
	if( main && data[1] != 0x00 )
		return;   // dials or touch strip

	for( uint8_t wire = 0; wire < count; wire++ ) {
		uint8_t key   = wireKey( wire );
		uint8_t state = data[first + wire] ? 1 : 0;
		if( state != keyStates_[key] ) {
			keyStates_[key] = state;
			post( state ? EventType::KeyDown : EventType::KeyUp, key );
		}
	}
}

// Reads an ASCII string starting at `offset` in a feature report.
void StreamDeck::readFeatureString( hid_host_device_handle_t handle, uint8_t reportID, size_t length, size_t offset, char *out, size_t outSize ) {
	out[0] = '\0';

	uint8_t buffer[kLongFeatureSize] = { reportID };
	size_t  received = std::min( length, sizeof( buffer ) );
	esp_err_t err = hid_class_request_get_report( handle, HID_REPORT_TYPE_FEATURE, reportID, buffer, &received );
	if( err != ESP_OK ) {
		ESP_LOGW( TAG, "Feature report 0x%02X failed: %s", reportID, esp_err_to_name( err ) );
		return;
	}

	size_t written = 0;
	for( size_t i = offset; i < received && written + 1 < outSize; i++ ) {
		char c = (char)buffer[i];
		if( c < 0x20 || c > 0x7E )
			break;
		out[written++] = c;
	}
	out[written] = '\0';
}

// MARK: - Output transfers

// Most current decks (the MK.2 Scissor, XL, Neo, Mini 2022, Original) are high-speed parts
// that keep their high-speed endpoint sizes at full speed: a 512-byte interrupt IN and a
// 1024-byte interrupt OUT, where full speed allows 64. The host's FIFOs take IN packets up to
// 600 bytes (biased towards IN in sdkconfig.defaults) but periodic OUT only up to 128, and
// claiming the interface allocates every endpoint, so the claim fails. An oversized OUT
// endpoint is shrunk to 64 bytes in the host's copy of the descriptor: the deck's endpoint
// really takes 64-byte packets (128-byte ones fail, and it ignores SET_REPORT), and it
// reassembles them into full 1024-byte reports.
void StreamDeck::shrinkOversizedOut( hid_host_device_handle_t handle ) {
	outShrunk_ = false;
	hid_host_dev_params_t params = {};
	usb_device_handle_t   device = nullptr;
	esp_err_t err = hid_host_device_get_params( handle, &params );
	// The HID driver hears about a new device before our client does, and until then opening
	// it fails with ESP_ERR_INVALID_STATE.
	for( int attempt = 0; err == ESP_OK; attempt++ ) {
		err = usb_host_device_open( client_, params.addr, &device );
		if( err != ESP_ERR_INVALID_STATE || attempt == kOpenAttempts )
			break;
		err = ESP_OK;
		vTaskDelay( pdMS_TO_TICKS( kOpenRetryDelay ) );
	}
	if( err != ESP_OK ) {
		ESP_LOGW( TAG, "Couldn't check the endpoints: %s", esp_err_to_name( err ) );
		return;
	}

	const usb_config_desc_t *config = nullptr;
	if( usb_host_get_active_config_descriptor( device, &config ) == ESP_OK ) {
		forEachInterruptOut( config, params.iface_num, [this]( const usb_ep_desc_t *found ) {
			if( USB_EP_DESC_GET_MPS( found ) <= kMaxPeriodicOut )
				return;
			usb_ep_desc_t *ep = const_cast<usb_ep_desc_t *>( found );
			ESP_LOGI( TAG, "Interrupt OUT 0x%02X is %u bytes, more than the host takes; sending %u-byte packets", ep->bEndpointAddress, USB_EP_DESC_GET_MPS( ep ), kFullSpeedPacket );
			ep->wMaxPacketSize = kFullSpeedPacket;
			outShrunk_         = true;
		} );
	}
	usb_host_device_close( client_, device );
}

// Opens the deck on our own client and allocates the output transfer. Caller holds mutex_;
// info_ is already set.
bool StreamDeck::openOutput( hid_host_device_handle_t handle ) {
	hid_host_dev_params_t params = {};
	if( hid_host_device_get_params( handle, &params ) != ESP_OK )
		return false;

	esp_err_t err = usb_host_device_open( client_, params.addr, &device_ );
	if( err != ESP_OK ) {
		ESP_LOGW( TAG, "usb_host_device_open failed: %s", esp_err_to_name( err ) );
		device_ = nullptr;
		return false;
	}

	interface_    = params.iface_num;
	outEndpoint_  = 0;
	outPacket_    = 0;
	useInterrupt_ = false;
	stuck_        = false;

	const usb_config_desc_t *config = nullptr;
	if( usb_host_get_active_config_descriptor( device_, &config ) == ESP_OK ) {
		forEachInterruptOut( config, interface_, [this]( const usb_ep_desc_t *ep ) {
			outEndpoint_ = ep->bEndpointAddress;
			outPacket_   = USB_EP_DESC_GET_MPS( ep );
			ESP_LOGI( TAG, "Interrupt OUT 0x%02X: max packet %u bytes, interval %u", ep->bEndpointAddress, ep->wMaxPacketSize, ep->bInterval );
		} );
	}

	// Like the macOS and Linux HID stacks (and so python-elgato-streamdeck), send output
	// reports through the interrupt OUT endpoint when the deck has one. SET_REPORT on the
	// control pipe is only the fallback: ESP-IDF doesn't time out control transfers, so one
	// the deck never finishes blocks the control pipe for good.
	useInterrupt_ = outEndpoint_ != 0;
	ESP_LOGI( TAG, "Output reports go to %s (interface %u)", useInterrupt_ ? "the interrupt OUT endpoint" : "SET_REPORT on the control pipe", interface_ );

	err = usb_host_transfer_alloc( sizeof( usb_setup_packet_t ) + reportSize( info_.protocol ), 0, &transfer_ );
	if( err != ESP_OK ) {
		ESP_LOGW( TAG, "Couldn't allocate the output transfer: %s", esp_err_to_name( err ) );
		closeOutput();
		return false;
	}
	transfer_->device_handle = device_;
	transfer_->callback      = transferDone;
	transfer_->context       = this;
	transfer_->timeout_ms    = kTransferTimeout;
	return true;
}

// Frees the output transfer and closes our handle on the deck. Caller holds mutex_.
void StreamDeck::closeOutput() {
	if( transfer_ ) {
		// A stuck transfer completes (with an error) once the device is gone.
		if( stuck_ )
			xSemaphoreTake( transferSem_, pdMS_TO_TICKS( kTransferTimeout ) );
		usb_host_transfer_free( transfer_ );
		transfer_ = nullptr;
	}
	if( device_ ) {
		usb_host_device_close( client_, device_ );
		device_ = nullptr;
	}
}

// Submits transfer_ (on the control pipe or its endpoint) and waits for it to complete.
// Caller holds mutex_.
esp_err_t StreamDeck::submitAndWait( bool control ) {
	xSemaphoreTake( transferSem_, 0 );   // clear a completion left over from a timeout
	esp_err_t err = control ? usb_host_transfer_submit_control( client_, transfer_ ) : usb_host_transfer_submit( transfer_ );
	if( err != ESP_OK )
		return err;

	if( xSemaphoreTake( transferSem_, pdMS_TO_TICKS( kTransferTimeout ) ) != pdTRUE ) {
		stuck_ = true;
		return ESP_ERR_TIMEOUT;
	}
	if( transfer_->status != USB_TRANSFER_STATUS_COMPLETED )
		ESP_LOGW( TAG, "Output report not delivered (transfer status %d, %d of %d bytes)", (int)transfer_->status, transfer_->actual_num_bytes, transfer_->num_bytes );
	return transfer_->status == USB_TRANSFER_STATUS_COMPLETED ? ESP_OK : ESP_FAIL;
}

// Sends report_ as an output report. Caller holds mutex_.
esp_err_t StreamDeck::sendReport( size_t length ) {
	if( !transfer_ || stuck_ )
		return ESP_ERR_INVALID_STATE;

	if( !useInterrupt_ ) {
		usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer_->data_buffer;
		setup->bmRequestType = USB_BM_REQUEST_TYPE_DIR_OUT | USB_BM_REQUEST_TYPE_TYPE_CLASS | USB_BM_REQUEST_TYPE_RECIP_INTERFACE;
		setup->bRequest      = HID_CLASS_SPECIFIC_REQ_SET_REPORT;
		setup->wValue        = ( HID_REPORT_TYPE_OUTPUT << 8 ) | report_[0];
		setup->wIndex        = interface_;
		setup->wLength       = (uint16_t)length;
		memcpy( transfer_->data_buffer + sizeof( usb_setup_packet_t ), report_, length );
		transfer_->bEndpointAddress = 0;
		transfer_->num_bytes        = sizeof( usb_setup_packet_t ) + length;

		return submitAndWait( true );
	}

	// In pieces of whole packets, the last one short: on the wire that's the same packets as
	// one transfer, which the deck reassembles into the report.
	size_t most = outPacket_ ? outPacket_ * kMaxInterruptPackets : length;
	for( size_t sent = 0; sent < length; ) {
		size_t piece = std::min( most, length - sent );
		memcpy( transfer_->data_buffer, report_ + sent, piece );
		transfer_->bEndpointAddress = outEndpoint_;
		transfer_->num_bytes        = piece;
		esp_err_t err = submitAndWait( false );
		if( err != ESP_OK )
			return err;
		sent += piece;
	}
	return ESP_OK;
}

// MARK: - Output

// Sends an image as consecutive image reports: the report ID, the header that
// fillHeader( page, chunk, last ) writes into report_, then `chunk` bytes of the image from
// report_ + header. sent counts the bytes that went out. Caller holds mutex_.
template <typename FillHeader>
esp_err_t StreamDeck::sendImage( const uint8_t *image, size_t length, size_t header, FillHeader fillHeader, size_t &sent ) {
	size_t    size = reportSize( info_.protocol );
	esp_err_t err  = ESP_OK;
	sent = 0;
	for( uint16_t page = 0; sent < length; page++ ) {
		size_t chunk = std::min( size - header, length - sent );
		bool   last  = sent + chunk == length;

		memset( report_, 0, size );
		report_[0] = kImageReportID;
		fillHeader( page, chunk, last );
		memcpy( report_ + header, image + sent, chunk );

		err = sendReport( size );
		if( err != ESP_OK )
			break;
		sent += chunk;
	}
	return err;
}

esp_err_t StreamDeck::setKeyImage( uint8_t key, const uint8_t *image, size_t length ) {
	if( !image || length == 0 )
		return ESP_ERR_INVALID_ARG;
	if( !mutex_ )
		return ESP_ERR_INVALID_STATE;

	int64_t started = esp_timer_get_time();
	xSemaphoreTake( mutex_, portMAX_DELAY );
	if( !handle_ || key >= info_.keyCount() || info_.format == Format::None ) {
		xSemaphoreGive( mutex_ );
		return ESP_ERR_INVALID_STATE;
	}

	Protocol  protocol = info_.protocol;
	uint8_t   wire     = wireKey( key );
	size_t    sent     = 0;
	esp_err_t err      = sendImage( image, length, headerSize( protocol ), [&]( uint16_t page, size_t chunk, bool last ) {
		if( protocol == Protocol::Main ) {
			report_[1] = 0x07;              // command: set key image
			report_[2] = wire;
			report_[3] = last ? 0x01 : 0x00;
			report_[4] = chunk & 0xFF;
			report_[5] = chunk >> 8;
			report_[6] = page & 0xFF;
			report_[7] = page >> 8;
		} else {
			report_[1] = 0x01;              // command: upload to image memory bank
			report_[2] = protocol == Protocol::Original ? page + 1 : page;
			report_[4] = last ? 0x01 : 0x00;   // show image once this page lands
			report_[5] = wire + 1;          // key indices are 1-based on the wire
		}
	}, sent );
	xSemaphoreGive( mutex_ );
	ESP_LOGD( TAG, "Key %u: %u bytes in %lld ms", key, (unsigned)length, ( esp_timer_get_time() - started ) / 1000 );

	if( err != ESP_OK )
		ESP_LOGW( TAG, "Key %u image upload failed after %u bytes: %s", key, (unsigned)sent, esp_err_to_name( err ) );
	return err;
}

// The Neo's info bar: the key header with command 0x0B. The +'s touch strip: command 0x0C
// with a 16-byte header placing the image (x, y, width, height), then last, page, length.
esp_err_t StreamDeck::setScreenImage( const uint8_t *image, size_t length ) {
	if( !image || length == 0 )
		return ESP_ERR_INVALID_ARG;
	if( !mutex_ )
		return ESP_ERR_INVALID_STATE;

	xSemaphoreTake( mutex_, portMAX_DELAY );
	if( !handle_ || info_.screenWidth == 0 ) {
		xSemaphoreGive( mutex_ );
		return ESP_ERR_INVALID_STATE;
	}

	bool      plus = info_.pid == kPlusPID;
	size_t    sent = 0;
	esp_err_t err  = sendImage( image, length, plus ? 16 : 8, [&]( uint16_t page, size_t chunk, bool last ) {
		if( plus ) {
			report_[1]  = 0x0C;
			report_[6]  = info_.screenWidth & 0xFF;    // x and y (bytes 2–5) stay 0
			report_[7]  = info_.screenWidth >> 8;
			report_[8]  = info_.screenHeight & 0xFF;
			report_[9]  = info_.screenHeight >> 8;
			report_[10] = last ? 0x01 : 0x00;
			report_[11] = page & 0xFF;
			report_[12] = page >> 8;
			report_[13] = chunk & 0xFF;
			report_[14] = chunk >> 8;
		} else {
			report_[1] = 0x0B;
			report_[3] = last ? 0x01 : 0x00;
			report_[4] = chunk & 0xFF;
			report_[5] = chunk >> 8;
			report_[6] = page & 0xFF;
			report_[7] = page >> 8;
		}
	}, sent );
	xSemaphoreGive( mutex_ );

	if( err != ESP_OK )
		ESP_LOGW( TAG, "Screen image upload failed after %u bytes: %s", (unsigned)sent, esp_err_to_name( err ) );
	return err;
}

// The backlight, with a feature report.
esp_err_t StreamDeck::setBrightness( uint8_t percent ) {
	percent = std::min<uint8_t>( percent, 100 );
	if( !mutex_ )
		return ESP_ERR_INVALID_STATE;

	xSemaphoreTake( mutex_, portMAX_DELAY );
	esp_err_t err = ESP_ERR_INVALID_STATE;
	if( handle_ && info_.format != Format::None ) {
		if( info_.protocol == Protocol::Main ) {
			uint8_t payload[kLongFeatureSize] = { 0x03, 0x08, percent };
			err = hid_class_request_set_report( handle_, HID_REPORT_TYPE_FEATURE, payload[0], payload, sizeof( payload ) );
		} else {
			uint8_t payload[kShortFeatureSize] = { 0x05, 0x55, 0xAA, 0xD1, 0x01, percent };
			err = hid_class_request_set_report( handle_, HID_REPORT_TYPE_FEATURE, payload[0], payload, sizeof( payload ) );
		}
	}
	xSemaphoreGive( mutex_ );
	return err;
}
