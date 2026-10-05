#!/usr/bin/env python3
"""
SpaceMouse -> UDP bridge for Godot (v0.3, raw HID backend).

Backends (--backend auto|hid|tdx|fake, default auto):
  1. Raw HID (hidapi): reads the device directly. Verified to coexist with
     3DxWare on Windows - Blender keeps working through the driver in parallel.
  2. TDxInput COM (legacy 3DxWare API): connects but delivers no data on
     recent 3DxWare builds. Kept only as a fallback for old installs.
  3. fake: synthetic motion. No driver, no device, no dependencies.

Install (real mode only):
    python -m pip install pywin32 hidapi

Run:
    python spacemouse_udp_bridge.py              # real device via 3DxWare
    python spacemouse_udp_bridge.py --fake       # synthetic test motion
    python spacemouse_udp_bridge.py --verbose    # print live values
    python spacemouse_udp_bridge.py --debug-com  # COM troubleshooting dump

UDP packet (JSON, one per tick, default 127.0.0.1:42424):
    {"v":1,"seq":123,"t":1719990000.0,
     "tx":0.0,"ty":0.0,"tz":0.0,"rx":0.0,"ry":0.0,"rz":0.0,
     "buttons":0,"src":"tdx"}

Axes are normalized to roughly -1..1. Godot must not care which backend
produced the packet.
"""
from __future__ import annotations

import argparse
import json
import math
import socket
import sys
import time
from dataclasses import dataclass

PROTOCOL_VERSION = 1
DEFAULT_PORT = 42424
PROGIDS = ("TDxInput.Device", "TDxInput.Device.1")
HID_VENDOR_IDS = (0x256F, 0x046D)  # 3Dconnexion (new), Logitech (legacy devices)
HID_USAGE_PAGE_GENERIC = 0x01
HID_USAGE_MULTI_AXIS = 0x08


def log(msg: str) -> None:
    print(msg, flush=True)


def err(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def clamp(v: float, lo: float = -1.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, v))


def norm(v: float, scale: float) -> float:
    if scale <= 0:
        return 0.0
    return clamp(float(v) / scale)


@dataclass
class Packet:
    tx: float = 0.0
    ty: float = 0.0
    tz: float = 0.0
    rx: float = 0.0
    ry: float = 0.0
    rz: float = 0.0
    buttons: int = 0

    def is_idle(self) -> bool:
        return (
            self.buttons == 0
            and abs(self.tx) < 1e-4 and abs(self.ty) < 1e-4 and abs(self.tz) < 1e-4
            and abs(self.rx) < 1e-4 and abs(self.ry) < 1e-4 and abs(self.rz) < 1e-4
        )

    def as_json(self, seq: int, src: str) -> bytes:
        return json.dumps(
            {
                "v": PROTOCOL_VERSION,
                "seq": seq,
                "t": time.time(),
                "tx": round(self.tx, 4),
                "ty": round(self.ty, 4),
                "tz": round(self.tz, 4),
                "rx": round(self.rx, 4),
                "ry": round(self.ry, 4),
                "rz": round(self.rz, 4),
                "buttons": self.buttons,
                "src": src,
            },
            separators=(",", ":"),
        ).encode("utf-8")


class FakeReader:
    """Synthetic motion: sweeps each of the 6 axes in turn with a sine wave.

    3 seconds per axis, in packet order: tx, ty, tz, rx, ry, rz.
    Buttons: during translation phases, one button bit walks 0..7.
    Lets you verify axis mapping and bar order in the Godot dock visually.
    """

    src = "fake"

    def __init__(self) -> None:
        self._t0 = time.time()

    def read(self) -> Packet:
        t = time.time() - self._t0
        axes = [0.0] * 6
        active = int(t / 3.0) % 6
        axes[active] = math.sin((t % 3.0) * math.tau / 1.5)
        buttons = (1 << (int(t) % 8)) if active < 3 else 0
        return Packet(axes[0], axes[1], axes[2], axes[3], axes[4], axes[5], buttons)


class HidReader:
    """Raw HID reader (hidapi). Talks to the SpaceMouse directly.

    Verified to coexist with 3DxWare on Windows: the driver keeps feeding
    Blender while this reader receives its own copy of the reports.

    Report layout (SpaceMouse Enterprise and other modern devices):
      id 0x01, 12 data bytes: tx, ty, tz, rx, ry, rz as int16 little-endian
      id 0x01, 6 data bytes: translation only (older split-report devices)
      id 0x02, 6 data bytes: rotation only (older split-report devices)
      id 0x03: button bitfield

    Device frame is X right, Y toward user, Z down. Converted here to the
    packet frame (X right, Y up, Z forward). If an axis feels wrong on a
    given device, flip it with --invert instead of editing this mapping.
    """

    src = "hid"

    def __init__(self, scale: float):
        self.scale = scale
        try:
            import hid  # type: ignore
        except Exception as exc:
            raise RuntimeError(
                "hidapi is required for HID mode.\n"
                "WHAT TO DO: run install_requirements.bat "
                "(or: python -m pip install hidapi)"
            ) from exc

        self._dev = [0] * 6
        self._buttons = 0
        self._last_motion = time.time()
        self.device_name = ""

        candidates = []
        for info in hid.enumerate():
            if info.get("vendor_id") not in HID_VENDOR_IDS:
                continue
            if (info.get("usage_page") == HID_USAGE_PAGE_GENERIC
                    and info.get("usage") == HID_USAGE_MULTI_AXIS):
                candidates.append(info)
        if not candidates:
            raise RuntimeError(
                "No 3Dconnexion multi-axis HID device found.\n"
                "WHAT TO DO:\n"
                "  1. Check the device is connected, then run run_probe.bat.\n"
                "  2. If the probe finds it, send the probe output in chat."
            )

        # Prefer a SpaceMouse over other 3Dconnexion devices (e.g. CadMouse
        # also exposes a multi-axis collection).
        def _rank(info):
            name = (info.get("product_string") or "").lower()
            return 0 if "space" in name else 1

        candidates.sort(key=_rank)
        chosen = candidates[0]
        self.device_name = chosen.get("product_string") or "unknown device"

        self._h = hid.device()
        try:
            self._h.open_path(chosen["path"])
        except Exception as exc:
            raise RuntimeError(
                f"Could not open HID device '{self.device_name}': {exc}\n"
                "WHAT TO DO: close tools that may hold the device exclusively, "
                "replug the device, retry."
            ) from exc
        self._h.set_nonblocking(True)
        log("HID connected: {} (vid={:#06x} pid={:#06x})".format(
            self.device_name, chosen["vendor_id"], chosen["product_id"]))

    @staticmethod
    def _i16(data, offset: int) -> int:
        v = data[offset] | (data[offset + 1] << 8)
        return v - 0x10000 if v >= 0x8000 else v

    def read(self) -> Packet:
        got_motion = False
        for _ in range(64):  # drain everything queued since the last tick
            data = self._h.read(64)
            if not data:
                break
            rid = data[0]
            if rid == 0x01 and len(data) >= 13:
                self._dev = [self._i16(data, 1 + i * 2) for i in range(6)]
                got_motion = True
            elif rid == 0x01 and len(data) >= 7:
                self._dev[0:3] = [self._i16(data, 1 + i * 2) for i in range(3)]
                got_motion = True
            elif rid == 0x02 and len(data) >= 7:
                self._dev[3:6] = [self._i16(data, 1 + i * 2) for i in range(3)]
                got_motion = True
            elif rid == 0x03:
                bits = 0
                for i, byte in enumerate(data[1:7]):
                    bits |= (byte & 0xFF) << (8 * i)
                self._buttons = bits & 0xFFFFFFFF

        if got_motion:
            self._last_motion = time.time()
        elif time.time() - self._last_motion > 0.25:
            # Stream stopped without an explicit zero report: treat as released.
            self._dev = [0] * 6

        x, y, z, rx, ry, rz = self._dev
        return Packet(
            tx=norm(x, self.scale),
            ty=norm(-z, self.scale),
            tz=norm(-y, self.scale),
            rx=norm(rx, self.scale),
            ry=norm(-rz, self.scale),
            rz=norm(-ry, self.scale),
            buttons=self._buttons,
        )


class TDxInputReader:
    """Wrapper around 3Dconnexion's TDxInput COM object (3DxWare layer)."""

    src = "tdx"

    def __init__(self, scale: float):
        self.scale = scale
        try:
            import pythoncom  # type: ignore
            import win32com.client  # type: ignore
        except Exception as exc:
            raise RuntimeError(
                "pywin32 is required for real-device mode.\n"
                "WHAT TO DO:\n"
                "  1. Run install_requirements.bat (or: python -m pip install pywin32)\n"
                "  2. Or test without a device first: run_bridge_fake.bat"
            ) from exc

        self.pythoncom = pythoncom
        self.win32com = win32com.client
        self.device = None
        self.sensor = None
        self.keyboard = None
        self.progid_used = ""
        self._read_failures = 0
        self._connect()

    def _connect(self) -> None:
        errors = []
        for progid in PROGIDS:
            try:
                self.device = self.win32com.Dispatch(progid)
                self.progid_used = progid
                break
            except Exception as exc:
                errors.append(f"  {progid}: {exc}")
        if self.device is None:
            raise RuntimeError(
                "Could not create the TDxInput COM object. Tried:\n"
                + "\n".join(errors)
                + "\nWHAT TO DO:\n"
                "  1. Make sure 3DxWare is installed AND running (tray icon).\n"
                "  2. Update/reinstall 3DxWare; the TDxInput component ships with it.\n"
                "  3. Retry from a normal (non-admin) terminal first.\n"
                "  4. To test Godot without the device: run_bridge_fake.bat"
            )

        try:
            self.device.Connect()
        except Exception:
            pass  # Some driver builds connect implicitly.

        try:
            self.sensor = self.device.Sensor
        except Exception as exc:
            raise RuntimeError(
                f"TDxInput device created via '{self.progid_used}' but Sensor is unavailable: {exc}\n"
                "WHAT TO DO: run with --debug-com and send the output."
            ) from exc

        try:
            self.keyboard = self.device.Keyboard
        except Exception:
            self.keyboard = None

        log(f"TDxInput connected via ProgID '{self.progid_used}'"
            + (" (keyboard/buttons available)" if self.keyboard else " (no button interface)"))

    def _read_raw(self):
        try:
            self.pythoncom.PumpWaitingMessages()
        except Exception:
            pass
        tr = self.sensor.Translation
        ro = self.sensor.Rotation
        return (
            float(getattr(tr, "X", 0.0)), float(getattr(tr, "Y", 0.0)), float(getattr(tr, "Z", 0.0)),
            float(getattr(ro, "X", 0.0)), float(getattr(ro, "Y", 0.0)), float(getattr(ro, "Z", 0.0)),
        )

    def read(self) -> Packet:
        try:
            tx, ty, tz, rx, ry, rz = self._read_raw()
            self._read_failures = 0
        except Exception as exc:
            self._read_failures += 1
            if self._read_failures >= 50:
                raise RuntimeError(
                    "TDxInput Sensor stopped exposing Translation/Rotation "
                    f"({exc}).\n"
                    "WHAT TO DO:\n"
                    "  1. Check that 3DxWare is still running.\n"
                    "  2. Run with --debug-com and send the output."
                ) from exc
            return Packet()

        buttons = 0
        try:
            if self.keyboard is not None:
                count = int(getattr(self.keyboard, "Keys", 0) or 0)
                for i in range(min(count, 32)):
                    try:
                        if self.keyboard.IsKeyDown(i + 1):
                            buttons |= 1 << i
                    except Exception:
                        pass
        except Exception:
            buttons = 0

        return Packet(
            tx=norm(tx, self.scale), ty=norm(ty, self.scale), tz=norm(tz, self.scale),
            rx=norm(rx, self.scale), ry=norm(ry, self.scale), rz=norm(rz, self.scale),
            buttons=buttons,
        )

    def debug_com(self, seconds: float = 8.0) -> None:
        log(f"ProgID used: {self.progid_used}")
        for name, obj in (("device", self.device), ("sensor", self.sensor), ("keyboard", self.keyboard)):
            log(f"\n--- {name} attributes ---")
            try:
                for a in [a for a in dir(obj) if not a.startswith("_")][:200]:
                    log(f"  {a}")
            except Exception as exc:
                log(f"  Could not dir(): {exc}")

        log(f"\n--- live raw values for {seconds:.0f}s, MOVE THE SPACEMOUSE NOW ---")
        peak = 0.0
        t_end = time.time() + seconds
        while time.time() < t_end:
            try:
                vals = self._read_raw()
            except Exception as exc:
                log(f"  read error: {exc}")
                time.sleep(0.5)
                continue
            peak = max(peak, max(abs(v) for v in vals))
            log("  T=({:8.2f},{:8.2f},{:8.2f})  R=({:8.2f},{:8.2f},{:8.2f})".format(*vals))
            time.sleep(0.1)

        if peak > 0:
            log(f"\nPeak raw magnitude observed: {peak:.1f}")
            log(f"Suggested flag: --scale {max(peak, 1.0):.0f}")
        else:
            log("\nNo motion detected. Either the device was not moved, or this "
                "3DxWare build needs an event-based adapter. Send this full output.")


def main() -> int:
    parser = argparse.ArgumentParser(description="SpaceMouse -> UDP bridge for Godot")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--hz", type=float, default=120.0)
    parser.add_argument("--scale", type=float, default=350.0,
                        help="Raw TDxInput value treated as normalized 1.0 (find yours with --debug-com)")
    parser.add_argument("--backend", choices=("auto", "hid", "tdx", "fake"), default="auto",
                        help="Data source: hid (direct read, coexists with 3DxWare), "
                             "tdx (legacy COM), fake (synthetic). auto tries hid, then tdx.")
    parser.add_argument("--invert", default="",
                        help="Comma list of packet axes to flip, e.g. --invert tz,ry")
    parser.add_argument("--fake", action="store_true",
                        help="Shortcut for --backend fake")
    parser.add_argument("--verbose", action="store_true", help="Print live values to console")
    parser.add_argument("--debug-com", action="store_true", help="Dump COM fields + live raw values, then exit")
    args = parser.parse_args()

    if args.debug_com and args.fake:
        err("ERROR: --debug-com inspects the real driver; do not combine it with --fake.")
        return 2

    invert_axes = {a.strip() for a in args.invert.split(",") if a.strip()}
    bad_axes = invert_axes - {"tx", "ty", "tz", "rx", "ry", "rz"}
    if bad_axes:
        err(f"ERROR: unknown axes for --invert: {', '.join(sorted(bad_axes))}")
        return 2

    backend = "fake" if args.fake else args.backend
    if args.debug_com:
        backend = "tdx"

    if backend == "fake":
        reader = FakeReader()
    elif backend == "hid":
        try:
            reader = HidReader(scale=args.scale)
        except Exception as exc:
            err(f"ERROR: {exc}")
            return 2
    elif backend == "tdx":
        try:
            reader = TDxInputReader(scale=args.scale)
        except Exception as exc:
            err(f"ERROR: {exc}")
            return 2
    else:  # auto: HID first, TDxInput is dead on recent 3DxWare builds
        try:
            reader = HidReader(scale=args.scale)
        except Exception as hid_exc:
            log(f"HID backend unavailable: {hid_exc}")
            log("Falling back to TDxInput COM...")
            try:
                reader = TDxInputReader(scale=args.scale)
            except Exception as tdx_exc:
                err("ERROR: no working backend.\n"
                    f"HID: {hid_exc}\n"
                    f"TDxInput: {tdx_exc}")
                return 2

    if args.debug_com:
        reader.debug_com()
        return 0

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    addr = (args.host, args.port)
    sleep_s = 1.0 / max(args.hz, 1.0)

    log(f"SpaceMouse UDP bridge v0.3 | mode: {reader.src} | -> {args.host}:{args.port} @ {args.hz:.0f}Hz")
    if reader.src == "fake":
        log("FAKE MODE: sweeping tx, ty, tz, rx, ry, rz (3s each). No device needed.")
    log("Ctrl+C to stop.")

    seq = 0
    last_status = time.time()
    try:
        while True:
            try:
                packet = reader.read()
            except Exception as exc:
                err(f"ERROR: {exc}")
                return 3
            for axis in invert_axes:
                setattr(packet, axis, -getattr(packet, axis))
            seq += 1
            try:
                sock.sendto(packet.as_json(seq, reader.src), addr)
            except OSError as exc:
                err(f"ERROR: UDP send to {addr} failed: {exc}\n"
                    "WHAT TO DO: check firewall rules for local UDP, or change --port.")
                return 4

            now = time.time()
            if args.verbose and not packet.is_idle():
                log(f"seq={seq} T=({packet.tx:+.2f},{packet.ty:+.2f},{packet.tz:+.2f}) "
                    f"R=({packet.rx:+.2f},{packet.ry:+.2f},{packet.rz:+.2f}) btn={packet.buttons:#010x}")
                last_status = now
            elif now - last_status > 5.0:
                log(f"alive, seq={seq}, idle" if packet.is_idle() else f"alive, seq={seq}")
                last_status = now

            time.sleep(sleep_s)
    except KeyboardInterrupt:
        log("Stopped.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
