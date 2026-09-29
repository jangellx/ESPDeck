#!/bin/bash
# ESPDeck virtual-eFuse test kit: one command per step. See README.md.
#
#   ./nvstest.sh ports             list serial ports (the board's COM port is the WCH one)
#   ./nvstest.sh backup            real eFuse summary + the whole 16 MB flash, to $BACKUP
#   ./nvstest.sh build             test project in ./work, built into ./build (no board needed)
#   ./nvstest.sh flash             the test build onto the board, then `check`
#   ./nvstest.sh check             boots it and confirms virtual eFuses
#   ./nvstest.sh run SCENARIO...   first-setup, opt-out, migrate, cut-migrate-1..3,
#                                  cut-setup-1..5, or all
#   ./nvstest.sh restore           the backed-up flash back, then compares the real eFuses
#   ./nvstest.sh efuses            the chip's real eFuse summary (read-only)
#
# PORT=/dev/cu.… picks the port when there's more than one WCH serial port.
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="${ESPDECK_DEVICE:-$( cd "$KIT/../.." && pwd )}"   # this kit lives in ESPDeck Device/tools/nvstest
BACKUP="${NVSTEST_BACKUP:-$HOME/ESPDeck-nvstest-backup}"
WORK="$KIT/work"
BUILD="$KIT/build"
OUT="$BUILD/nvstest"
PY="$HOME/.platformio/penv/bin/python"
PIO="$HOME/.platformio/penv/bin/pio"
TOOLS="$HOME/.platformio/packages/tool-esptoolpy"

die() { echo "nvstest: $*" >&2; exit 1; }

# The board's COM port: $PORT, or the only WCH (CH343, 0x1A86) serial port.
port() {
	if [[ -n "${PORT:-}" ]]; then echo "$PORT"; return; fi
	local found
	found=$("$PY" -c 'from serial.tools import list_ports
print("\n".join(p.device for p in list_ports.comports() if p.vid == 0x1A86 and p.device.startswith("/dev/cu.")))')
	[[ -n "$found" ]] || die "no WCH serial port (the board's COM port). Plug it in, or set PORT=/dev/cu.…"
	[[ $(wc -l <<<"$found") -eq 1 ]] || die "several WCH serial ports; set PORT to one of: $found"
	echo "$found"
}

esptool()  { "$PY" "$TOOLS/esptool.py" --chip esp32s3 --port "$(port)" "$@"; }
espefuse() { "$PY" "$TOOLS/espefuse.py" --chip esp32s3 --port "$(port)" "$@"; }

mac() { esptool read-mac 2>&1 | awk '/^MAC:/ { print $2; exit }'; }

# Refuses to go on with a board other than the one backed up.
same_board() {
	[[ -f "$BACKUP/mac.txt" ]] || die "no backup yet: run ./nvstest.sh backup first"
	local now
	now=$(mac)
	[[ -n "$now" ]] || die "couldn't read the board's MAC address"
	[[ "$now" == "$(cat "$BACKUP/mac.txt")" ]] || die "this board ($now) isn't the one backed up ($(cat "$BACKUP/mac.txt"))"
}

# The build must use virtual eFuses kept in flash, or nothing may be flashed.
virtual_build() {
	[[ -f "$OUT/firmware.bin" && -f "$OUT/bootloader.bin" && -f "$OUT/partitions.bin" ]] || die "no test build: run ./nvstest.sh build"
	grep -qx "CONFIG_EFUSE_VIRTUAL=y" "$WORK/sdkconfig.nvstest" || die "the build's sdkconfig doesn't have CONFIG_EFUSE_VIRTUAL=y"
	grep -qx "CONFIG_EFUSE_VIRTUAL_KEEP_IN_FLASH=y" "$WORK/sdkconfig.nvstest" || die "the build's sdkconfig doesn't keep virtual eFuses in flash"
	LC_ALL=C grep -q "eFuse virtual mode is enabled" "$OUT/firmware.bin" || die "firmware.bin wasn't built with virtual eFuses"
	LC_ALL=C grep -q "TEST: init" "$OUT/firmware.bin" || die "firmware.bin has no test hooks"
}

command="${1:-}"
shift || true
case "$command" in
	ports)
		"$PY" -m serial.tools.list_ports -v
		;;

	backup)
		[[ ! -e "$BACKUP/flash-16MB.bin" || -n "${FORCE:-}" ]] || die "$BACKUP already has a backup. A second one taken after testing would save the test state; set FORCE=1 only if you're sure the board is back to normal."
		mkdir -p "$BACKUP"
		mac > "$BACKUP/mac.txt"
		[[ -s "$BACKUP/mac.txt" ]] || die "couldn't reach the board on $(port)"
		echo "Board $(cat "$BACKUP/mac.txt") on $(port)"
		espefuse summary > "$BACKUP/efuse-summary-before.txt"
		grep -E "KEY_PURPOSE_[0-5] " "$BACKUP/efuse-summary-before.txt" || true
		esptool --baud 921600 read-flash 0 0x1000000 "$BACKUP/flash-16MB.bin"
		(cd "$BACKUP" && shasum -a 256 flash-16MB.bin > flash-16MB.bin.sha256)
		echo "Backed up to $BACKUP"
		;;

	build)
		"$PY" "$KIT/prepare.py" "$PROJECT" "$WORK" "$BUILD"
		SSL_CERT_FILE=$("$PY" -c "import certifi;print(certifi.where())") "$PIO" run -d "$WORK" -e nvstest
		virtual_build
		echo "Test build ready: $OUT (virtual eFuses confirmed)"
		;;

	flash)
		virtual_build
		same_board
		# otadata erased so the board starts ota_0 (the test build); NVS and efuse_em erased so
		# it starts as a new, keyless device.
		esptool --after no-reset erase-region 0xE000 0x2000
		esptool --after no-reset erase-region 0x9000 0x5000
		esptool --after no-reset erase-region 0xFF0000 0x2000
		esptool --baud 921600 write-flash 0x0 "$OUT/bootloader.bin" 0x8000 "$OUT/partitions.bin" 0x10000 "$OUT/firmware.bin"
		"$PY" "$KIT/nvstest.py" --port "$(port)" check
		;;

	check)
		"$PY" "$KIT/nvstest.py" --port "$(port)" check
		;;

	run)
		[[ $# -gt 0 ]] || die "which scenario? first-setup, opt-out, migrate, cut-migrate-1..3, cut-setup-1..5, or all"
		"$PY" "$KIT/nvstest.py" --port "$(port)" "$@"
		;;

	restore)
		same_board
		(cd "$BACKUP" && shasum -a 256 -c flash-16MB.bin.sha256) || die "the backup doesn't match its checksum"
		esptool --baud 921600 write-flash 0x0 "$BACKUP/flash-16MB.bin"
		espefuse summary > "$BACKUP/efuse-summary-after.txt"
		if diff <(grep -v "^espefuse\|^Connecting\|^Detecting\|Serial port" "$BACKUP/efuse-summary-before.txt") \
		        <(grep -v "^espefuse\|^Connecting\|^Detecting\|Serial port" "$BACKUP/efuse-summary-after.txt"); then
			echo "Restored. The chip's real eFuses are unchanged."
		else
			echo "Restored, but the real eFuse summary differs (above). Tell Claude before using the board."
			exit 1
		fi
		;;

	efuses)
		espefuse summary
		;;

	*)
		sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac
