# SpaceMouse Godot Bridge v1.0.1

Use a 3Dconnexion SpaceMouse for six-axis navigation in the Godot 4 editor.
The bridge reads the standard multi-axis HID interface directly and sends
normalized motion to Godot over localhost UDP. Blender and 3DxWare can keep
working in parallel. The legacy TDxInput COM interface remains a fallback.

```text
SpaceMouse -> raw HID -> Python bridge -> localhost UDP -> Godot add-on
```

## What changed in v0.2 (Stage 1)

- **Fake input mode**: test the whole Godot side with no device, no driver,
  no pywin32. `run_bridge_fake.bat` sweeps each axis for 3 seconds.
- **Live input bars in the Godot dock**: 6 axis bars + button display.
  You see immediately whether Godot receives data.
- **Better `--debug-com`**: dumps COM fields AND prints live raw values for
  8 seconds, then suggests the right `--scale` for your device.
- **Clearer errors**: every failure prints a numbered WHAT TO DO list.
- **Stable packet format**: adds `v` (protocol version), `seq`, `src`.
- Bars zero out if packets stop (>500 ms), so a dead bridge is visible.

### v0.2.1

- All `.bat` files now auto-detect Python: they try the `py -3` launcher
  first (works even when Python is not on PATH), then `python`, then
  `python3`. Fixes "Python was not found" on installs without PATH.

### v0.2.2

- The addon no longer hardcodes `res://addons/spacemouse_bridge/` paths.
  It loads its receiver script relative to its own folder, so it works
  even if you copied the whole ZIP folder into `res://addons/`.
- Removed the receiver's global class name to avoid conflicts when the
  addon folder exists in more than one place in a project.
- Recommended location is still `res://addons/spacemouse_bridge/`
  (unzip straight into `res://addons/`), but any
  location under `res://` now loads fine.

### v0.2.3

- New `run_probe.bat` / `spacemouse_probe.py`: tests all three possible
  backends in one run (TDxInput COM, 3DxWare local WebSocket service,
  raw HID) and prints a verdict for each. Use it when the real device
  sends no data; paste the output in chat or send it to 3Dconnexion.
- `install_requirements.bat` now also installs `hidapi` (needed by the
  probe's raw HID test).

### v0.3.0

- **New raw HID backend, now the default.** The probe proved that TDxInput
  COM is dead on recent 3DxWare builds while raw HID delivers data with
  3DxWare still running. The bridge now reads the SpaceMouse directly
  (`--backend auto` tries HID first, then falls back to TDxInput).
- New `--invert` flag to flip individual axes without editing code,
  e.g. `run_bridge.bat --invert tz,ry`.
- **Horizon lock** in the Godot dock (default ON): roll input is ignored
  and accumulated roll is removed, the horizon stays level.
- **Focus guard** in the Godot dock (default ON): cameras only move while
  the Godot editor window is focused, so working in Blender next to Godot
  never moves your Godot view.
- **Editor Viewport is now the default target mode**: the SpaceMouse moves
  the 3D editor view directly, no Camera3D selection needed.

### v0.3.1

- **Invert-axis checkboxes in the Godot dock** (tx, ty, tz, rx, ry, rz),
  applied instantly, no bridge restart. rx and ry start inverted to match
  the raw HID feel on SpaceMouse Enterprise; untick if your device differs.
- **Dock settings now persist per project**: invert states, horizon lock,
  focus guard, target mode, move/rotation speed.
- Note: 3DxWare settings (invert, axis on/off, speed) do NOT affect this
  bridge - it reads the device directly. Configure everything in the Godot
  dock instead. Your 3DxWare/Blender profile stays untouched either way.

### v0.4.0

- **Auto-start: no more daily .bat.** The addon now launches the Python
  bridge itself when the editor opens (hidden, no console window) and
  stops it when the editor closes. "Auto-start bridge with editor" is on
  by default; Start/Stop buttons in the dock for manual control.
- The `python_bridge` folder now lives INSIDE the addon folder
  (`addons/spacemouse_bridge/python_bridge`), so copying the addon into
  your project brings the bridge along and the plugin can find it.
- **Deadzone spinner** in the dock (persisted per project).
- One-time prerequisites remain: Python 3 installed, and run
  `install_requirements.bat` once. After that: open Godot, done.

### v0.5.0

- **Adaptive speed (Blender-like), on by default.** Translation speed now
  scales with the distance to whatever the view is looking at: zoomed out
  over the level you fly like a giant, nose against a wall you move like
  an ant. Distance comes from a physics raycast when the scene has
  collision, with a ground-plane (y=0) fallback for pure-art scenes.
  Rotation speed stays constant (same as Blender).
- **Mouse wheel = fly speed (Godot freelook paradigm).** While the
  SpaceMouse is deflected, wheel up accelerates and wheel down slows the
  multiplier (persisted per project, Reset button in the dock). When the
  SpaceMouse is idle the wheel keeps zooming the viewport as usual.
- **Smoothing** spinner (seconds to ease starts/stops, default 0.12,
  0 = raw). Eases the motion-sickness edge on abrupt starts.
- Dock shows the live effective speed multiplier.

### v0.5.1

- **Fix: erratic motion in v0.5.0** (push and pull appearing to move the
  same way, near-frozen axes, sudden teleports). Root cause: the adaptive
  factor could swing from ~x0.02 to ~x200 in one frame when a mesh entered
  or left the ray, and smoothing was applied to the raw deflection BEFORE
  the scale - so the decaying tail of a previous push got re-amplified by
  a huge new scale and kept moving the view in the old direction.
  Smoothing now acts on the final velocity; an old deflection can never be
  re-amplified.
- **Adaptive speed capped and damped**: factor clamped to
  [Adapt min x, Adapt max x] (default 0.2..8) and distance changes eased
  in log space over "Adapt damping" seconds (default 0.5). A mesh passing
  in front of the camera now shifts the pace gradually.
- **Exposed parameters** in the dock, all persisted per project:
  Adapt ref dist (distance that means x1.0), Adapt min x, Adapt max x,
  Adapt damping (s).
- **Full manual mode**: untick Adaptive speed - the pace is then
  wheel-only (wheel while flying = faster/slower), like Godot freelook.

### v1.0.0 (stable)

- **Clean release after the zoomed-view bug was confirmed fixed by the
  v0.5.5 scrollable dock.** All diagnostic code removed: no more Output
  panel logging, no Safe mode checkbox, no cam readout line in the dock.
- Kept: the scrollable dock (the actual fix - the dock's minimum height
  can never inflate the editor layout again), the silent basis-scale
  guard (orthonormalize every frame), and every v0.5.x feature (adaptive
  speed, wheel multiplier, auto re-zero, horizon lock, focus guard,
  auto-start bridge, invert grid, per-project settings).

### v0.5.5

- **REAL FIX for the "view zoomed like crazy on enable" bug.** It was never
  fov, never the camera. The SpaceMouse dock had grown to ~30 rows of
  controls; a Godot dock declares a minimum height equal to the sum of its
  controls and does not scroll. Once that minimum was taller than the
  window could fit, the editor inflated the ENTIRE UI layout past the
  window bottom, clipped. The 3D view became a canvas ~3x the screen
  height and you only saw a crop of it - which looks exactly like extreme
  magnification (huge icons, no dolly). Multi-monitor changes shift the
  tipping point, which is why it appeared "out of nowhere" and affected
  old builds too (their docks were just shorter before).
- **Fix: the whole dock is now wrapped in a ScrollContainer.** Its minimum
  height is tiny forever; when the panel is short, you scroll inside it.
  The editor layout can never be inflated by this addon again.
- The Output panel log now also prints `win WxH | ui WxH` and flags
  `LAYOUT OVERFLOW` when the UI canvas is taller than the window, so this
  class of bug is visible instantly.

### v0.5.4 (diagnostic build for the "zoomed view on enable" bug)

- **Camera state now logs to the Output panel** (bottom of the editor),
  every 2 seconds: target camera name, fov, basis scale per axis, position.
  The very first log line is captured BEFORE the addon writes anything to
  any camera, so it shows the true camera state at enable time. This works
  around the catch: opening the SpaceMouse dock tab makes the bug vanish,
  so the dock readout could never show the bug. The Output panel can stay
  open with the Inspector in front.
- **Safe mode checkbox**: "Safe mode (diagnose only, never move camera)".
  When ticked, the addon still receives packets and logs, but never writes
  to any camera. Decisive test: tick it, disable + re-enable the plugin
  with the Inspector tab in front. If the zoom still appears, the addon's
  camera writes are innocent and the trigger is the enable itself. If it
  does not appear, the per-frame camera write is the culprit and the log
  shows which number goes bad.

### v0.5.3

- **Fix: view looked "zoomed in" (super narrow focal) while the addon was
  enabled, back to normal when disabled.** The addon never changes fov, but
  Godot rotation operations and look_at PRESERVE any scale that sneaks into
  the camera basis, and a scaled camera basis renders exactly like a longer
  focal length. The addon now orthonormalizes the camera basis every frame:
  its own writes can never accumulate scale, and any dirty state it inherits
  gets cleaned instead of preserved.
- **Diagnostic readout in the dock**: live target camera fov, basis scale
  per axis, and how many dirty frames were cleaned ("fixed N"). If the zoom
  ever comes back, this line tells exactly whether it is fov, basis scale,
  or something outside the addon.
- **Cleaner ZIP layout**: the ZIP now contains just the `spacemouse_bridge`
  folder, ready to drop into `res://addons/`. No more nested
  `godot_addon/addons/` wrapper folders. This README lives inside the addon
  folder.

### v0.5.2

- **Fix: view creeps forward / looks "super zoomed in" on its own, and
  wheel zoom stops working**. The addon never touches camera FOV - what
  looks like a narrow focal length is the camera slowly dollying into the
  scene. Cause: raw HID has no driver-side zero calibration (3DxWare
  normally does this for Blender). If the cap rests slightly off center,
  packets stay just above the deadzone: the camera creeps forward forever
  and, since the addon thinks you are flying, it also captures the mouse
  wheel as speed control - so you cannot zoom back out.
- **Auto re-zero**: the receiver measures the rest bias (1.5 s of
  near-stillness) and subtracts it, like the driver does. A **Re-zero
  device** button in the dock forces it instantly (hands off the puck
  when clicking).
- **Wheel capture threshold raised**: the wheel only becomes speed
  control on a deliberate deflection, never on drift. Wheel zoom always
  works when the puck is at rest.

## Quick start (no terminal needed)

### Step 1 - prove the Godot side works (no device needed)

1. Unzip the ZIP into your project's `res://addons/` folder, so you get
   `res://addons/spacemouse_bridge`. The ZIP contains just that one folder
   (this README lives inside it).
2. Godot: Project > Project Settings > Plugins > enable **SpaceMouse Bridge**.
3. Double-click `python_bridge/run_bridge_fake.bat`.
4. Watch the **SpaceMouse** dock in Godot: the six bars must sweep one by
   one (tx, ty, tz, rx, ry, rz), 3 seconds each.

If the bars move, Godot-side is done. Any remaining problem is driver-side.

### Step 2 - real device

1. Double-click `python_bridge/install_requirements.bat` (once).
2. Double-click `python_bridge/run_bridge.bat`. 3DxWare can keep running;
   the bridge reads the device directly and does not disturb it.
3. Move the SpaceMouse: bars in the Godot dock should move and the dock
   should show `src: hid`.
4. Default mode **Editor Viewport** moves the 3D editor view directly.
   For a scene camera instead, pick **Selected Camera3D** and select one.
5. If an axis feels backwards: tick it in the dock's **Invert axes** grid
   (applies instantly and is remembered per project). The `--invert` bridge
   flag still exists but is no longer needed.

### Step 3 - if the real device shows nothing

1. Double-click `python_bridge/run_debug_com.bat`.
2. Move the SpaceMouse during the live-values section.
3. If it prints raw values: note the suggested `--scale` and run
   `run_bridge.bat --scale <value>`.
4. If it prints no motion: send the full console output to the developer
   (or to 3Dconnexion support - mention you use the TDxInput COM interface).

## Target modes

- **Editor Viewport** (default): moves the 3D editor view directly.
  If the view snaps back when you grab the mouse afterwards, report it.
- **Selected Camera3D** (most reliable): select a Camera3D, it moves.
- **Active Viewport Camera**: drives the current runtime camera.

## Packet format (UDP JSON, one per tick)

```json
{"v":1,"seq":123,"t":1719990000.0,
 "tx":0.0,"ty":0.0,"tz":0.0,"rx":0.0,"ry":0.0,"rz":0.0,
 "buttons":0,"src":"tdx"}
```

- Axes normalized to roughly -1..1 (`--scale` controls raw-to-1.0 mapping).
- `src` is `tdx` (real driver) or `fake` (test mode).
- `buttons` is a bitmask, bit 0 = button 1.
- Default endpoint `127.0.0.1:42424`, override with `--host` / `--port`.

The Godot addon does not care which backend produced the packet. The Python
bridge can later be replaced by a compiled 3DxWare SDK (navlib) bridge with
zero Godot-side changes.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `No working Python 3 found` | The .bat files try `py -3`, `python`, `python3`. If all fail, install Python 3 from python.org and tick "Add python.exe to PATH" (an existing install is upgraded in place) |
| `pywin32 is required` | Run `install_requirements.bat` |
| `Could not create the TDxInput COM object` | Start/update 3DxWare, then retry; test Godot side with fake mode meanwhile |
| Bars move in fake mode but not real mode | Driver-side issue: run `run_debug_com.bat`, follow its output |
| Bars do not move even in fake mode | Godot side: check dock says "listening", port matches 42424, press Reconnect UDP, check firewall for local UDP |
| Motion too weak/strong | `--scale` (raw value treated as full deflection), or Move/Rotation speed in the dock |
| Axes feel inverted | Tick the axis in the dock Invert axes grid (applies instantly, saved per project) |

## Known limitations

- Windows-first. Linux/macOS later via spacenavd/libspnav backend.
- TDxInput is deprecated by 3Dconnexion (still shipped with 3DxWare).
  Long-term backend target is the official 3DxWare SDK (navlib).
- Godot has no stable public API for the editor viewport camera; the
  editor-viewport mode stays experimental by design.
- The bridge is a visible console window for now. Stage 5 adds a tray
  launcher with auto-start.

### v1.0.1

- **Fixed the stuck phantom input** (needing a huge deadzone like 0.19 until
  the addon was disabled and re-enabled). Cause: auto re-zero judged "at
  rest" relative to the current bias, so a slow steady cruise (constant
  deflection held over 1.5 s) could be adopted as the new center, and the
  bias could even walk upward across several cruises. Once stuck, true zero
  looked like motion and the bias never self-corrected.
- Auto re-zero now requires the raw values to be near TRUE zero, and the
  auto-captured bias is capped at 0.08. A held deflection can never become
  the center anymore, and a bad bias now heals itself after 1.5 s hands-off.
- The manual **Re-zero device** button is unchanged (still captures up to
  0.3 - it is explicit, you said hands-off).
