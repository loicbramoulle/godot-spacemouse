# SpaceMouse Bridge for Godot 4

![SpaceMouse Bridge icon](assets/icon.svg)

Free, open-source 6DoF editor navigation for 3Dconnexion SpaceMouse devices in Godot 4 on Windows.

SpaceMouse Bridge lets you pan, orbit, fly, and zoom through Godot's 3D editor viewport with a SpaceMouse. It reads the device through raw HID and sends normalized motion to a Godot editor plugin over localhost UDP. Blender and 3DxWare can continue running at the same time.

> Unofficial community project. Not affiliated with or endorsed by 3Dconnexion.

## Why this exists

Godot does not currently provide native SpaceMouse navigation. Older approaches based on the legacy TDxInput COM interface may connect without delivering motion on recent 3DxWare versions. This bridge prefers raw HID, which has been verified with a SpaceMouse Enterprise while 3DxWare remains active.

## Features

- Six-axis SpaceMouse navigation in the Godot 4 editor viewport
- Selected Camera3D and active viewport camera modes
- Per-axis inversion, deadzone, smoothing, and speed controls
- Adaptive movement speed and live input bars
- Automatic hidden bridge startup when the plugin loads
- Manual re-zero and automatic rest calibration
- Diagnostic probe and synthetic-input test mode
- Coexists with 3DxWare and other 3D applications

## Requirements

- Windows 10 or Windows 11
- Godot 4.x
- Python 3
- A 3Dconnexion SpaceMouse-compatible device
- `hidapi` and `pywin32` Python packages (installed by the included helper)

## Installation

1. Download the latest release ZIP.
2. Copy `addons/spacemouse_bridge` into your Godot project's `addons` directory.
3. Run `addons/spacemouse_bridge/python_bridge/install_requirements.bat` once.
4. In Godot, open **Project > Project Settings > Plugins** and enable **SpaceMouse Bridge**.
5. Open the **SpaceMouse** dock and move the controller.

The dock should report `src: hid`. The bridge normally starts automatically and remains hidden.

## Quick diagnosis

- Run `run_bridge_fake.bat`. If the dock bars move, the Godot side works.
- Run `run_probe.bat` to inspect raw HID, TDxInput, and local-service availability.
- If the bridge exits immediately, rerun `install_requirements.bat` using the same Python installation Godot launches through `py -3`.
- If 3DxWare itself fails to start or repeatedly loses profiles, update it before testing the bridge.

Full controls, troubleshooting, architecture, and version history are in [the add-on documentation](addons/spacemouse_bridge/README.md).

## Privacy and networking

The bridge communicates only over UDP on `127.0.0.1:42424` by default. It does not collect telemetry, contact an internet service, or transmit device input off the computer unless you explicitly change the host argument.

## Compatibility

The current release has been verified with:

- Godot 4.x on 64-bit Windows
- 3Dconnexion SpaceMouse Enterprise
- Current 3DxWare 10 releases
- Python 3.14 with `hidapi` 0.15 and `pywin32` 312

Other USB SpaceMouse models using the standard multi-axis HID usage should work. Reports and pull requests for additional devices are welcome.

## Search terms

Godot SpaceMouse plugin, 3Dconnexion Godot addon, 6DoF controller Godot, SpaceMouse editor navigation, SpaceMouse Enterprise Godot, 3D mouse Godot 4.

## License

MIT. See [LICENSE](LICENSE).
