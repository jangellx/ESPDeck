# Third-Party Notices

ESPDeck itself is under the MIT License (see [LICENSE](LICENSE)). Everything below allows that: the permissive licenses (MIT, BSD, Apache 2.0, the SIL Open Font License) ask for their notices to be kept, which this file does, and the one copyleft library (the Arduino core, LGPL 2.1) asks that the firmware can be rebuilt against a changed copy of it, which the published source allows. It includes or is derived from the work below. The ESPDeck Bridge app contains no third-party code; everything listed here is part of the ESP32 firmware or the web installer, except where noted.

## Firmware

The firmware images published on GitHub Releases, installed by the web installer, and installed by ESPDeck Bridge are built from this repository with PlatformIO and contain the following.

### Arduino core for the ESP32 (LGPL 2.1)

- https://github.com/espressif/arduino-esp32, version 3.3 (through the pioarduino platform pinned in `ESPDeck Device/platformio.ini`)
- Copyright Espressif Systems and the Arduino core contributors
- Licensed under the GNU Lesser General Public License, version 2.1: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html

The firmware is statically linked with this library. Its source is available at the link above, and the complete source of the rest of the firmware is in this repository, so you can rebuild the firmware against a modified version of the library with `pio run` (see the README).

### ESP-IDF (Apache 2.0)

- https://github.com/espressif/esp-idf, version 5.5
- Copyright Espressif Systems (Shanghai) Co., Ltd.
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0

ESP-IDF includes components under their own permissive licenses, among them Mbed TLS (Apache 2.0), FreeRTOS (MIT) and lwIP (BSD 3-Clause); see the ESP-IDF repository for their notices.

### Espressif components (Apache 2.0)

From the Espressif component registry, each Copyright Espressif Systems (Shanghai) Co., Ltd., under the Apache License 2.0:

- `espressif/esp_websocket_client`
- `espressif/mdns`
- `espressif/usb_host_hid`
- `espressif/qrcode`, which includes the QR Code generator library by Project Nayuki (MIT License):

```
Copyright (c) Project Nayuki. (MIT License)
https://www.nayuki.io/page/qr-code-generator-library

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:
- The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.
- The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall the
  authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising from,
  out of or in connection with the Software or the use or other dealings in the
  Software.
```

### esp_new_jpeg (Espressif MIT)

- `espressif/esp_new_jpeg`, Copyright (c) 2024 Espressif Systems (Shanghai) Co., Ltd.
- Espressif MIT License: the MIT License, with use limited to Espressif products, which is what ESPDeck runs on:

```
ESPRESSIF MIT License

Copyright (c) 2024 <ESPRESSIF SYSTEMS (SHANGHAI) CO.，LTD>

Permission is hereby granted for use on all ESPRESSIF SYSTEMS products, in which case,
it is free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished
to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### littlefs

- `joltwallet/littlefs` (the ESP-IDF port), Copyright (c) 2020 Brian Pugh, MIT License
- littlefs, Copyright (c) 2022 The littlefs authors and Copyright (c) 2017 Arm Limited, BSD 3-Clause License

The port's license:

```
Copyright 2020 Brian Pugh

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

littlefs's license:

```
Copyright (c) 2022, The littlefs authors.  
Copyright (c) 2017, Arm Limited. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

-  Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
-  Redistributions in binary form must reproduce the above copyright notice, this
   list of conditions and the following disclaimer in the documentation and/or
   other materials provided with the distribution.
-  Neither the name of ARM nor the names of its contributors may be used to
   endorse or promote products derived from this software without specific prior
   written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Inter (SIL Open Font License 1.1)

- https://rsms.me/inter/, by Rasmus Andersson, Copyright (c) The Inter Project Authors
- SIL Open Font License, Version 1.1: https://openfontlicense.org
- The firmware contains bitmaps rendered from Inter (`ESPDeck Device/src/Font.h`, generated by `tools/make_font.swift`).

### python-elgato-streamdeck (MIT)

The Stream Deck model layouts and USB report formats in `ESPDeck Device/src/StreamDeck.{h,cpp}` are derived from python-elgato-streamdeck (https://github.com/abcminiuser/python-elgato-streamdeck).

Its license, which the project calls MIT, reads:

```
Copyright (c) Dean Camera

Permission to use, copy, modify, and distribute this software
and its documentation for any purpose is hereby granted without
fee, provided that the above copyright notice appear in all
copies and that both that the copyright notice and this
permission notice and warranty disclaimer appear in supporting
documentation, and that the name of the author not be used in
advertising or publicity pertaining to distribution of the
software without specific, written prior permission.

The author disclaims all warranties with regard to this
software, including all implied warranties of merchantability
and fitness.  In no event shall the author be liable for any
special, indirect or consequential damages or any damages
whatsoever resulting from loss of use, data or profits, whether
in an action of contract, negligence or other tortious action,
arising out of or in connection with the use or performance of
this software.
```

## Web installer

- ESP Web Tools (https://github.com/esphome/esp-web-tools), Copyright ESPHome, Apache License 2.0. The installer page in `web/` loads it from the unpkg CDN.

## ESPDeck Bridge

- Uses SF Symbols, under Apple's license for SF Symbols, for key icons and interface symbols. They are not included in the app icon.
- Inter is also credited on the app's About page, which lists these notices.
