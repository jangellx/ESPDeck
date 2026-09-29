#!/usr/bin/env python3
"""Runs the virtual-eFuse scenarios on a board flashed with the nvstest build, over its
COM (UART) port: Improv commands in, log lines and Improv answers out. Every scenario starts
from a new, keyless device (NVS and the efuse_em partition erased with esptool).

Usage: nvstest.py --port /dev/cu.wchusbserial... [--log FILE] SCENARIO...
Scenarios: check, first-setup, opt-out, migrate, cut-migrate-1..3, cut-setup-1..5, all.
The Wi-Fi network comes from NVSTEST_SSID and NVSTEST_PASSWORD, or is asked for.
"""
import argparse
import getpass
import os
import re
import subprocess
import sys
import threading
import time
import zlib

import serial

HERE        = os.path.dirname(os.path.abspath(__file__))
PYTHON      = os.path.expanduser("~/.platformio/penv/bin/python")
ESPTOOL     = os.path.expanduser("~/.platformio/packages/tool-esptoolpy/esptool.py")
NVS         = ("0x9000", "0x5000")
EFUSE_EM    = ("0xFF0000", "0x2000")   # partitions_nvstest.csv
VIRTUAL     = "eFuse virtual mode is enabled"

SEND_WIFI, INFO, NAME, STORAGE = 0x01, 0x03, 0x06, 0xFD
T_ARM, T_MIGRATE, T_DUMP, T_PAIR, T_RESET = 0xF0, 0xF1, 0xF2, 0xF3, 0xF4
DUMP_FIELDS = ("storage", "new", "standard", "ssid", "pw", "verified", "paired", "key", "name", "restart")
TEST_NAME   = "NVS Test"


class Abort(Exception):
    pass


class ImprovError(Exception):
    pass


class Board:
    def __init__(self, port, logfile):
        self.port    = port
        self.logfile = open(logfile, "a")
        self.lines   = []
        self.packets = []
        self.lock    = threading.Lock()
        self.serial  = None

    # MARK: Port

    def open(self):
        port = serial.Serial()
        port.port, port.baudrate, port.timeout = self.port, 115200, 0.1
        port.dtr = port.rts = False   # EN and IO0 high: the board runs
        port.open()
        self.serial, self.stopping = port, False
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def close(self):
        if self.serial:
            self.stopping = True
            self.thread.join()
            self.serial.close()
            self.serial = None

    def reset(self):
        """A hard reset through the COM port's auto-reset circuit (RTS pulls EN low)."""
        self.note("reset")
        self.serial.dtr = False
        self.serial.rts = True
        time.sleep(0.15)
        self.serial.rts = False

    def esptool(self, *args):
        self.close()
        command = [PYTHON, ESPTOOL, "--chip", "esp32s3", "--port", self.port, *args]
        self.note("esptool " + " ".join(args))
        result = subprocess.run(command, capture_output=True, text=True)
        self.logfile.write(result.stdout + result.stderr)
        if result.returncode != 0:
            raise Abort(f"esptool {' '.join(args)} failed:\n{result.stdout}{result.stderr}")
        self.open()

    # MARK: Reading

    def _read(self):
        buffer = bytearray()
        while not self.stopping:
            try:
                data = self.serial.read(4096)
            except Exception:
                break
            if data:
                buffer += data
                self._split(buffer)

    def _split(self, buffer):
        while buffer:
            start, newline = buffer.find(b"IMPROV"), buffer.find(b"\n")
            if start == 0:
                if len(buffer) < 9:
                    return
                total = 9 + buffer[8] + 1
                if len(buffer) < total:
                    return
                packet = bytes(buffer[:total])
                if packet[6] == 1 and sum(packet[:-1]) & 0xFF == packet[-1]:
                    del buffer[:total]
                    with self.lock:
                        self.packets.append((packet[7], packet[9:-1]))
                    continue
                start = -1   # not a packet after all: text
            end = newline if start < 0 or ( newline >= 0 and newline < start ) else start
            if end < 0:
                if len(buffer) > 4096:
                    end = len(buffer)
                else:
                    return
            line = bytes(buffer[:end]).decode("utf-8", "replace").strip()
            del buffer[:end + 1 if end == newline else end]
            if line:
                self._line(line)

    def _line(self, line):
        line = re.sub(r"\x1b\[[0-9;]*m", "", line)
        with self.lock:
            self.lines.append(line)
        self.logfile.write(line + "\n")
        self.logfile.flush()
        if os.environ.get("NVSTEST_ECHO"):
            print("   | " + line)

    def note(self, text):
        self.logfile.write(f"=== {text}\n")
        self.logfile.flush()

    def mark(self):
        with self.lock:
            return len(self.lines)

    def wait_log(self, pattern, timeout, since):
        deadline = time.time() + timeout
        regex    = re.compile(pattern)
        while time.time() < deadline:
            with self.lock:
                for line in self.lines[since:]:
                    match = regex.search(line)
                    if match:
                        return match
            time.sleep(0.05)
        return None

    def seen(self, pattern, since):
        with self.lock:
            return any(re.search(pattern, line) for line in self.lines[since:])

    # MARK: Improv

    def rpc(self, command, data=b"", timeout=5):
        """The result's strings; ImprovError for an error answer; None without one."""
        body   = bytes([command, len(data)]) + data
        packet = b"IMPROV" + bytes([1, 0x03, len(body)]) + body
        packet += bytes([sum(packet) & 0xFF])
        with self.lock:
            self.packets = []
        self.serial.write(packet)
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                packets, self.packets = self.packets, []
            for kind, payload in packets:
                if kind == 0x02 and payload and payload[0] != 0:
                    raise ImprovError(payload[0])
                if kind == 0x04 and payload and payload[0] == command:
                    return strings(payload)
            time.sleep(0.05)
        return None


def strings(payload):
    result, index, end = [], 2, min(len(payload), 2 + payload[1])
    while index < end:
        length = payload[index]
        result.append(payload[index + 1:index + 1 + length].decode("utf-8", "replace"))
        index += 1 + length
    return result


# MARK: - Steps

class Run:
    def __init__(self, board, ssid, password):
        self.board, self.ssid, self.password = board, ssid, password
        self.results = []

    def check(self, what, ok, detail=""):
        self.results.append((what, bool(ok)))
        print(f"  {'PASS' if ok else 'FAIL'}  {what}" + (f"  ({detail})" if detail and not ok else ""))
        return ok

    def boot(self, reset=True, timeout=25, since=None):
        """Waits for a (re)start: virtual eFuses confirmed, NVS set up, and Improv answering.
        Without a reset, `since` is where to look from: a mark taken before whatever restarts it."""
        board = self.board
        since = board.mark() if since is None else since
        if reset:
            board.reset()
        if not board.wait_log(r"TEST: init -> ", timeout, since):
            raise Abort("The board didn't start (no 'TEST: init' line). Is the nvstest build on it?")
        if not board.seen(VIRTUAL, since):
            raise Abort("NO VIRTUAL eFUSES in this boot log. Stop now: restore the backup (nvstest.sh restore).")
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                info = board.rpc(INFO, timeout=1)
            except ImprovError:
                info = None
            if info:
                return since
        raise Abort("The board doesn't answer Improv.")

    def fresh(self):
        """A new device: NVS and the virtual eFuses erased (the next start copies the chip's
        real eFuses, which have no key, into efuse_em)."""
        self.board.esptool("--after", "no-reset", "erase-region", *NVS)
        self.board.esptool("--after", "no-reset", "erase-region", *EFUSE_EM)
        since = self.boot()
        self.board.rpc(T_ARM, b"\x00")
        return since

    def storage(self, choose=None):
        answer = self.board.rpc(STORAGE, b"" if choose is None else bytes([choose]))
        return tuple(answer) if answer else None

    def dump(self):
        answer = self.board.rpc(T_DUMP)
        if not answer:
            raise Abort("No answer to the dump command.")
        return dict(zip(DUMP_FIELDS, answer))

    def rename(self):
        return self.board.rpc(NAME, TEST_NAME.encode())

    def wifi(self, cut=False, timeout=35):
        """True once joined; False for an error; 'cut' when a simulated power cut restarted it."""
        board = self.board
        ssid, password = self.ssid.encode(), self.password.encode()
        data  = bytes([len(ssid)]) + ssid + bytes([len(password)]) + password
        since = board.mark()
        body   = bytes([SEND_WIFI, len(data)]) + data
        packet = b"IMPROV" + bytes([1, 0x03, len(body)]) + body
        packet += bytes([sum(packet) & 0xFF])
        with board.lock:
            board.packets = []
        board.serial.write(packet)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if board.seen(r"TEST: power cut at point", since):
                return "cut"
            with board.lock:
                packets, board.packets = board.packets, []
            for kind, payload in packets:
                if kind == 0x02 and payload and payload[0] == 0x03:
                    return False
                if kind == 0x04 and payload and payload[0] == SEND_WIFI:
                    return True
            time.sleep(0.05)
        return None

    def plain_setup(self):
        """A device set up with Standard storage, renamed and paired: what an existing
        device looks like before the move."""
        self.fresh()
        self.check("0xFD 0 chooses Standard", self.storage(0) == ("plain", "standard"))
        self.check("renamed", self.rename() == [TEST_NAME])
        self.check("joined the network", self.wifi() is True)
        self.check("made-up pairing", self.board.rpc(T_PAIR) == [])
        before = self.dump()
        self.check("plain, set up, paired", before["storage"] == "plain" and before["new"] == "0" and before["paired"] == "1")
        return before

    def kept(self, before, after):
        return all(before[k] == after[k] for k in ("ssid", "pw", "paired", "key", "name"))


def crc(text):
    return f"{zlib.crc32(text.encode()) & 0xFFFFFFFF:08x}"


# MARK: - Scenarios

def check(run):
    run.boot()
    print("  PASS  virtual eFuses and the test build are on the board")


def first_setup(run):
    """The default: a new device encrypts when it saves its first network."""
    run.fresh()
    run.check("new device offers encryption", run.storage() == ("plain", "encrypt"))
    run.check("renamed before setup", run.rename() == [TEST_NAME])
    since  = run.board.mark()
    joined = run.wifi()
    run.check("joined the network", joined is True)
    run.check("encrypted before saving it", run.board.seen(r"Storage is encrypted", since))
    run.check("0xFD reports encrypted", run.storage() == ("encrypted", "none"))
    after = run.dump()
    run.check("credentials and name stored", after["storage"] == "encrypted" and after["new"] == "0" and after["ssid"] == run.ssid
              and after["pw"] == crc(run.password) and after["name"] == TEST_NAME, after)
    since = run.boot()
    run.check("starts encrypted", run.board.seen(r"NVS is encrypted \(eFuse key block", since))
    run.check("no plain entries at start", not run.board.seen(r"Unencrypted NVS entries found", since))
    again = run.dump()
    run.check("everything read back after restart", run.kept(after, again) and again["storage"] == "encrypted", again)
    run.check("joins the saved network", run.board.wait_log(r"joining", 10, since) is not None)


def opt_out(run):
    """Standard chosen: nothing burned, remembered, and cleared by a factory reset."""
    run.fresh()
    run.check("0xFD 0 chooses Standard", run.storage(0) == ("plain", "standard"))
    run.check("joined the network", run.wifi() is True)
    run.check("still plain", run.storage() == ("plain", "none"))
    after = run.dump()
    run.check("Standard remembered", after["standard"] == "1" and after["storage"] == "plain", after)
    since = run.boot()
    run.check("plain after restart", run.board.seen(r"TEST: init -> ESP_OK, state plain", since))
    run.check("0xFD 1 then 0 switches the choice back and forth", run.storage(1) == ("plain", "none") and run.dump()["standard"] == "0"
              and run.storage(0) == ("plain", "none") and run.dump()["standard"] == "1")
    since = run.board.mark()
    run.board.rpc(T_RESET)
    run.boot(reset=False, timeout=150, since=since)   # erasing the 10 MB image cache takes a while
    run.check("factory reset clears the choice", run.storage() == ("plain", "encrypt"))


def migrate(run):
    """The bridge's encryptStorage on a device already set up: everything kept."""
    before = run.plain_setup()
    since  = run.board.mark()
    run.board.rpc(T_MIGRATE)
    run.check("encrypted and restarted", run.board.wait_log(r"Storage encrypted; restarting", 15, since) is not None)
    since = run.boot(reset=False, since=since)
    run.check("starts encrypted", run.board.seen(r"NVS is encrypted \(eFuse key block", since))
    after = run.dump()
    run.check("everything kept", run.kept(before, after) and after["storage"] == "encrypted", after)


def cut_migrate(run, point):
    before = run.plain_setup()
    run.board.rpc(T_ARM, bytes([point]))
    since = run.board.mark()
    run.board.rpc(T_MIGRATE)
    run.check(f"power cut at point {point}", run.board.wait_log(rf"TEST: power cut at point {point}", 15, since) is not None)
    since = run.boot(reset=False, since=since)
    after = run.dump()
    run.check("encrypted after the restart", after["storage"] == "encrypted", after)
    if point == 1:
        run.check("finished the move at startup", run.board.seen(r"Unencrypted NVS entries found; encrypting them", since))
        run.check("everything kept", run.kept(before, after), after)
    else:
        if point == 3:
            run.check("found the marker and erased", run.board.seen(r"Encrypting NVS didn't finish", since))
        run.check("starts over as new (setup mode)", after["new"] == "1" and after["paired"] == "0", after)
    run.check("can be set up again, encrypted", run.wifi() is True and run.storage() == ("encrypted", "none"))


def cut_setup(run, point):
    run.fresh()
    run.check("renamed", run.rename() == [TEST_NAME])
    run.board.rpc(T_ARM, bytes([point]))
    since  = run.board.mark()
    joined = run.wifi(cut=True)
    if point == 5:
        run.check("setup went on after the failure", joined is True)
        run.check("fell back to plain", run.board.seen(r"keeping it plain until the next start", since))
        run.check("restarts once setup mode ends", run.board.wait_log(r"Restarting to finish encrypting storage", 15, since) is not None)
        since = run.boot(reset=False, since=since)
        run.check("finished the move at startup", run.board.seen(r"Unencrypted NVS entries found; encrypting them", since))
        after = run.dump()
        run.check("encrypted, with the network and name", after["storage"] == "encrypted" and after["new"] == "0" and after["ssid"] == run.ssid
                  and after["pw"] == crc(run.password) and after["name"] == TEST_NAME, after)
        return
    run.check(f"power cut at point {point}", joined == "cut")
    since = run.boot(reset=False, since=since)
    after = run.dump()
    run.check("encrypted and new (setup mode)", after["storage"] == "encrypted" and after["new"] == "1", after)
    if point in (1, 4):
        run.check("name kept", after["name"] == TEST_NAME, after)
    run.check("setting up again works, encrypted", run.wifi() is True and run.storage() == ("encrypted", "none"))
    again = run.dump()
    run.check("network stored", again["ssid"] == run.ssid and again["pw"] == crc(run.password), again)


SCENARIOS = {
    "check":       check,
    "first-setup": first_setup,
    "opt-out":     opt_out,
    "migrate":     migrate,
}
for p in (1, 2, 3):
    SCENARIOS[f"cut-migrate-{p}"] = lambda run, p=p: cut_migrate(run, p)
for p in (1, 2, 3, 4, 5):
    SCENARIOS[f"cut-setup-{p}"] = lambda run, p=p: cut_setup(run, p)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", required=True)
    parser.add_argument("--log", default=os.path.join(HERE, "logs", time.strftime("run-%Y%m%d-%H%M%S.log")))
    parser.add_argument("scenarios", nargs="+")
    args = parser.parse_args()

    names = []
    for name in args.scenarios:
        names += [n for n in SCENARIOS if n != "check"] if name == "all" else [name]
    unknown = [n for n in names if n not in SCENARIOS]
    if unknown:
        sys.exit(f"Unknown scenario {', '.join(unknown)}. Known: {', '.join(SCENARIOS)}, all")

    ssid = password = ""
    if names != ["check"]:
        ssid     = os.environ.get("NVSTEST_SSID") or input("Wi-Fi network (2.4 GHz) for the test: ")
        password = os.environ.get("NVSTEST_PASSWORD")
        if password is None:
            password = getpass.getpass(f"Password for {ssid} (not stored): ")

    os.makedirs(os.path.dirname(args.log), exist_ok=True)
    board = Board(args.port, args.log)
    board.open()
    run     = Run(board, ssid, password)
    aborted = None
    try:
        for name in names:
            print(f"\n== {name}")
            board.note(f"scenario {name}")
            try:
                SCENARIOS[name](run)
            except ImprovError as error:
                run.check(f"{name}: no Improv error", False, f"error {error}")
    except Abort as error:
        aborted = str(error)
    finally:
        board.close()

    failed = [what for what, ok in run.results if not ok]
    print(f"\n{len(run.results) - len(failed)} passed, {len(failed)} failed. Log: {args.log}")
    if aborted:
        print(f"ABORTED: {aborted}")
    sys.exit(1 if failed or aborted else 0)


main()
