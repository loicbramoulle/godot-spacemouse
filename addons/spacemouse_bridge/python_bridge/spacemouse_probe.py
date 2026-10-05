#!/usr/bin/env python3
"""Backend probe for the SpaceMouse Godot bridge (v0.2.3).

Tests every way to get SpaceMouse data on this machine and prints a verdict
per backend. Run it, follow the MOVE prompts, then paste the full output in
chat (or send it to 3Dconnexion support).

Backends tested:
  1. TDxInput COM      - legacy 3DxWare API, used by bridge v0.x
  2. 3DxWare local service - navlib/WebSocket ports used by web apps
  3. Raw HID           - direct device read, fallback path only
"""
from __future__ import annotations

import socket
import time

LINE = "-" * 60


def log(msg: str = "") -> None:
    print(msg, flush=True)


def countdown(msg: str, seconds: int = 3) -> None:
    for i in range(seconds, 0, -1):
        log("  %s in %d..." % (msg, i))
        time.sleep(1)


def probe_tdxinput(read_seconds: float = 6.0) -> str:
    log(LINE)
    log("[1/3] TDxInput COM (legacy 3DxWare API)")
    log(LINE)
    try:
        import pythoncom  # type: ignore
        import win32com.client  # type: ignore
    except Exception as exc:
        log("  pywin32 not available: %s" % exc)
        log("  VERDICT: untested (run install_requirements.bat first)")
        return "untested"

    dev = None
    for progid in ("TDxInput.Device", "TDxInput.Device.1"):
        try:
            dev = win32com.client.Dispatch(progid)
            log("  COM object created via %s" % progid)
            break
        except Exception as exc:
            log("  %s: %s" % (progid, exc))
    if dev is None:
        log("  VERDICT: DEAD (COM object cannot be created)")
        return "dead"

    try:
        dev.Connect()
        log("  Connect() ok")
    except Exception as exc:
        log("  Connect() failed: %s" % exc)

    try:
        sensor = dev.Sensor
    except Exception as exc:
        log("  Sensor unavailable: %s" % exc)
        log("  VERDICT: DEAD (no Sensor interface)")
        return "dead"

    countdown("MOVE THE SPACEMOUSE NOW, live read starts")
    t_end = time.time() + read_seconds
    peak = 0.0
    reads = 0
    while time.time() < t_end:
        try:
            pythoncom.PumpWaitingMessages()
            tr = sensor.Translation
            ro = sensor.Rotation
            vals = (tr.X, tr.Y, tr.Z, ro.X, ro.Y, ro.Z)
            peak = max(peak, max(abs(float(v)) for v in vals))
            reads += 1
        except Exception as exc:
            log("  read error: %s" % exc)
            break
        time.sleep(0.01)
    log("  %d reads, peak absolute value: %s" % (reads, peak))
    if peak > 0:
        log("  VERDICT: ALIVE, data flows")
        return "alive"
    log("  VERDICT: connects but never delivers data")
    log("  (TDxInput is deprecated; likely disabled in this 3DxWare build)")
    return "silent"


def probe_local_service() -> str:
    log(LINE)
    log("[2/3] 3DxWare local service (navlib / WebSocket)")
    log(LINE)
    found = []
    for port in (8181, 8182, 8183):
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=0.7)
            s.close()
            log("  port %d: OPEN" % port)
            found.append(port)
        except Exception:
            log("  port %d: closed" % port)
    if found:
        log("  VERDICT: a local 3DxWare service is listening.")
        log("  A navlib/WebSocket backend is possible without raw HID.")
        return "open"
    log("  VERDICT: no local service on the usual ports.")
    return "closed"


def probe_hid(read_seconds: float = 6.0) -> str:
    log(LINE)
    log("[3/3] Raw HID (direct device read, fallback path)")
    log(LINE)
    try:
        import hid  # type: ignore
    except Exception as exc:
        log("  hidapi not available: %s" % exc)
        log("  VERDICT: untested (run install_requirements.bat first)")
        return "untested"

    try:
        devs = [d for d in hid.enumerate() if d.get("vendor_id") in (0x256F, 0x046D)]
    except Exception as exc:
        log("  enumerate failed: %s" % exc)
        return "untested"
    if not devs:
        log("  No 3Dconnexion HID devices found.")
        log("  VERDICT: none")
        return "none"

    for d in devs:
        log("  found: vid=0x%04x pid=0x%04x usage_page=0x%02x usage=0x%02x %s" % (
            d.get("vendor_id", 0), d.get("product_id", 0),
            d.get("usage_page", 0), d.get("usage", 0),
            d.get("product_string") or ""))

    # Multi-axis controller interface first (usage page 0x01, usage 0x08).
    ordered = sorted(
        devs,
        key=lambda d: 0 if (d.get("usage_page") == 1 and d.get("usage") == 8) else 1,
    )
    for d in ordered:
        path = d.get("path")
        try:
            h = hid.device()
            h.open_path(path)
        except Exception as exc:
            log("  open failed (%s): %s" % (d.get("product_string") or path, exc))
            continue
        try:
            h.set_nonblocking(True)
        except Exception:
            pass
        log("  reading from: %s" % (d.get("product_string") or path))
        countdown("MOVE THE SPACEMOUSE NOW, raw read starts")
        t_end = time.time() + read_seconds
        reports = 0
        sample = None
        while time.time() < t_end:
            try:
                data = h.read(64)
            except Exception as exc:
                log("  read error: %s" % exc)
                break
            if data:
                reports += 1
                if sample is None:
                    sample = list(data[:13])
            time.sleep(0.002)
        try:
            h.close()
        except Exception:
            pass
        log("  reports received: %d%s" % (
            reports, (", first bytes: %s" % sample) if sample else ""))
        if reports > 0:
            log("  VERDICT: raw HID delivers data even with 3DxWare running.")
            return "alive"
    log("  VERDICT: no raw HID data (3DxWare probably holds the device).")
    return "silent"


def main() -> None:
    log("SpaceMouse backend probe (bridge v0.2.3)")
    log("Keep 3DxWare running. Follow the MOVE prompts.")
    log("")
    r1 = probe_tdxinput()
    r2 = probe_local_service()
    r3 = probe_hid()
    log(LINE)
    log("SUMMARY")
    log(LINE)
    log("  TDxInput COM:         %s" % r1)
    log("  3DxWare local ports:  %s" % r2)
    log("  Raw HID:              %s" % r3)
    log("")
    log("Paste this whole output in chat.")


if __name__ == "__main__":
    main()
    try:
        input("\nPress Enter to close...")
    except EOFError:
        pass
