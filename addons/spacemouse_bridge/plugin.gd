@tool
extends EditorPlugin

const AXES: Array[String] = ["tx", "ty", "tz", "rx", "ry", "rz"]

enum TargetMode {
	SELECTED_CAMERA_3D,
	ACTIVE_VIEWPORT_CAMERA,
	EXPERIMENTAL_EDITOR_VIEWPORT,
}

# Receiver script instance. Loaded relative to this script's own folder so
# the addon works no matter where it sits under res://.
var receiver
var dock_scroll: ScrollContainer
var dock: VBoxContainer
var status_label: Label
var buttons_label: Label
var mode_option: OptionButton
var speed_spin: SpinBox
var rot_spin: SpinBox
var port_spin: SpinBox
var enable_check: CheckBox
var horizon_check: CheckBox
var focus_check: CheckBox
var invert_checks: Dictionary = {}
var deadzone_spin: SpinBox
var autostart_check: CheckBox
var adaptive_check: CheckBox
var adapt_ref_spin: SpinBox
var adapt_min_spin: SpinBox
var adapt_max_spin: SpinBox
var adapt_damp_spin: SpinBox
var smoothing_spin: SpinBox
var speed_scale_label: Label
var bridge_status_label: Label
var bridge_pid: int = -1
var _bridge_poll_accum: float = 0.0
var axis_bars: Dictionary = {}
var axis_labels: Dictionary = {}
var _editor_camera_candidate: Camera3D = null


func _enter_tree() -> void:
	var script_dir: String = (get_script() as Script).resource_path.get_base_dir()
	var receiver_script: Script = load(script_dir + "/spacemouse_receiver.gd")
	receiver = receiver_script.new()
	receiver.name = "SpaceMouseReceiver"
	add_child(receiver)
	_make_dock()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock_scroll)
	set_process(true)
	set_force_draw_over_forwarding_enabled()
	# Always receive 3D viewport input so the wheel can adjust fly speed.
	set_input_event_forwarding_always_enabled()
	if autostart_check and autostart_check.button_pressed:
		call_deferred("_autostart_bridge")


func _exit_tree() -> void:
	_stop_bridge()
	if dock_scroll:
		remove_control_from_docks(dock_scroll)
		dock_scroll.queue_free()
	if receiver:
		receiver.queue_free()


func _make_dock() -> void:
	# CRITICAL: the dock content is tall (about 30 rows of controls). A dock
	# declares a minimum height equal to the sum of its controls, and editor
	# docks do not scroll by themselves. If that minimum is taller than the
	# window can fit, the editor inflates the WHOLE UI layout past the window
	# bottom and clips it - the 3D view becomes a huge canvas you only see a
	# crop of, which looks exactly like an extreme zoom / narrow focal.
	# Wrapping everything in a ScrollContainer keeps the dock's minimum size
	# tiny forever, no matter how many controls get added later.
	dock_scroll = ScrollContainer.new()
	dock_scroll.name = "SpaceMouse"
	dock_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	dock_scroll.custom_minimum_size = Vector2(0, 120)
	dock = VBoxContainer.new()
	dock.name = "SpaceMouseContent"
	dock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dock_scroll.add_child(dock)

	var title := Label.new()
	title.text = "SpaceMouse Bridge"
	title.add_theme_font_size_override("font_size", 18)
	dock.add_child(title)

	status_label = Label.new()
	status_label.text = "Waiting for UDP packets..."
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dock.add_child(status_label)

	# Live axis visualization: raw incoming values, -1..1.
	var bars_title := Label.new()
	bars_title.text = "Live input"
	dock.add_child(bars_title)
	for axis in AXES:
		var row := HBoxContainer.new()
		var axis_label := Label.new()
		axis_label.text = axis
		axis_label.custom_minimum_size.x = 26
		row.add_child(axis_label)
		var bar := ProgressBar.new()
		bar.min_value = -1.0
		bar.max_value = 1.0
		bar.step = 0.001
		bar.value = 0.0
		bar.show_percentage = false
		bar.custom_minimum_size.y = 12
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bar)
		var value_label := Label.new()
		value_label.text = "+0.00"
		value_label.custom_minimum_size.x = 46
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value_label)
		dock.add_child(row)
		axis_bars[axis] = bar
		axis_labels[axis] = value_label

	buttons_label = Label.new()
	buttons_label.text = "buttons: -"
	dock.add_child(buttons_label)

	enable_check = CheckBox.new()
	enable_check.text = "Enabled"
	enable_check.button_pressed = true
	enable_check.toggled.connect(func(v): receiver.enabled = v)
	dock.add_child(enable_check)

	horizon_check = CheckBox.new()
	horizon_check.text = "Horizon lock (no roll)"
	horizon_check.button_pressed = bool(_meta_get("horizon_lock", true))
	receiver.horizon_lock = horizon_check.button_pressed
	horizon_check.toggled.connect(_on_horizon_toggled)
	dock.add_child(horizon_check)

	focus_check = CheckBox.new()
	focus_check.text = "Only when Godot is focused"
	focus_check.button_pressed = bool(_meta_get("focus_guard", true))
	focus_check.toggled.connect(_on_focus_toggled)
	dock.add_child(focus_check)

	# Per-axis inversion. Defaults: rx and ry inverted (matches the reported
	# feel of the raw HID mapping on SpaceMouse Enterprise).
	var invert_title := Label.new()
	invert_title.text = "Invert axes"
	dock.add_child(invert_title)
	var invert_grid := GridContainer.new()
	invert_grid.columns = 3
	for axis in AXES:
		var cb := CheckBox.new()
		cb.text = axis
		cb.button_pressed = bool(_meta_get("invert_" + axis, axis == "rx" or axis == "ry"))
		receiver.invert_axes[axis] = cb.button_pressed
		cb.toggled.connect(_on_invert_toggled.bind(axis))
		invert_grid.add_child(cb)
		invert_checks[axis] = cb
	dock.add_child(invert_grid)

	mode_option = OptionButton.new()
	mode_option.add_item("Editor Viewport", TargetMode.EXPERIMENTAL_EDITOR_VIEWPORT)
	mode_option.add_item("Selected Camera3D", TargetMode.SELECTED_CAMERA_3D)
	mode_option.add_item("Active Viewport Camera", TargetMode.ACTIVE_VIEWPORT_CAMERA)
	dock.add_child(mode_option)
	mode_option.select(clampi(int(_meta_get("mode_index", 0)), 0, mode_option.item_count - 1))
	mode_option.item_selected.connect(_on_mode_selected)

	port_spin = _spin("UDP port", 1, 65535, 1, 42424)
	port_spin.value_changed.connect(func(_v): _restart_udp())
	speed_spin = _spin("Move speed", 0.01, 100.0, 0.1, float(_meta_get("move_speed", receiver.translation_speed)))
	speed_spin.value_changed.connect(_on_move_speed_changed)
	rot_spin = _spin("Rotation speed", 0.01, 20.0, 0.05, float(_meta_get("rotation_speed", receiver.rotation_speed)))
	rot_spin.value_changed.connect(_on_rot_speed_changed)
	deadzone_spin = _spin("Deadzone", 0.0, 0.5, 0.005, float(_meta_get("deadzone", receiver.deadzone)))
	deadzone_spin.value_changed.connect(_on_deadzone_changed)
	receiver.deadzone = float(deadzone_spin.value)
	smoothing_spin = _spin("Smoothing (s)", 0.0, 0.5, 0.01, float(_meta_get("smoothing", receiver.smoothing)))
	smoothing_spin.value_changed.connect(_on_smoothing_changed)
	receiver.smoothing = float(smoothing_spin.value)

	# Blender-like adaptive speed + Godot-like wheel speed control.
	adaptive_check = CheckBox.new()
	adaptive_check.text = "Adaptive speed (by view distance)"
	adaptive_check.button_pressed = bool(_meta_get("adaptive_speed", true))
	receiver.adaptive_speed = adaptive_check.button_pressed
	adaptive_check.toggled.connect(_on_adaptive_toggled)
	dock.add_child(adaptive_check)

	adapt_ref_spin = _spin("Adapt ref dist", 1.0, 200.0, 0.5, float(_meta_get("adaptive_ref_dist", receiver.adaptive_ref_dist)))
	adapt_ref_spin.value_changed.connect(_on_adapt_ref_changed)
	receiver.adaptive_ref_dist = float(adapt_ref_spin.value)
	adapt_min_spin = _spin("Adapt min x", 0.05, 1.0, 0.05, float(_meta_get("adaptive_min_scale", receiver.adaptive_min_scale)))
	adapt_min_spin.value_changed.connect(_on_adapt_min_changed)
	receiver.adaptive_min_scale = float(adapt_min_spin.value)
	adapt_max_spin = _spin("Adapt max x", 1.0, 50.0, 0.5, float(_meta_get("adaptive_max_scale", receiver.adaptive_max_scale)))
	adapt_max_spin.value_changed.connect(_on_adapt_max_changed)
	receiver.adaptive_max_scale = float(adapt_max_spin.value)
	adapt_damp_spin = _spin("Adapt damping (s)", 0.0, 2.0, 0.05, float(_meta_get("adaptive_damping", receiver.adaptive_damping)))
	adapt_damp_spin.value_changed.connect(_on_adapt_damp_changed)
	receiver.adaptive_damping = float(adapt_damp_spin.value)

	receiver.speed_multiplier = float(_meta_get("speed_multiplier", 1.0))
	var scale_row := HBoxContainer.new()
	speed_scale_label = Label.new()
	speed_scale_label.text = "speed x1.00"
	speed_scale_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scale_row.add_child(speed_scale_label)
	var scale_reset := Button.new()
	scale_reset.text = "Reset"
	scale_reset.pressed.connect(_on_speed_scale_reset)
	scale_row.add_child(scale_reset)
	dock.add_child(scale_row)

	var restart := Button.new()
	restart.text = "Reconnect UDP"
	restart.pressed.connect(_restart_udp)
	dock.add_child(restart)

	# Bridge process: the addon can run the Python bridge itself, hidden.
	var bridge_title := Label.new()
	bridge_title.text = "Bridge process"
	dock.add_child(bridge_title)

	autostart_check = CheckBox.new()
	autostart_check.text = "Auto-start bridge with editor"
	autostart_check.button_pressed = bool(_meta_get("bridge_autostart", true))
	autostart_check.toggled.connect(_on_autostart_toggled)
	dock.add_child(autostart_check)

	var bridge_row := HBoxContainer.new()
	var start_btn := Button.new()
	start_btn.text = "Start bridge"
	start_btn.pressed.connect(_start_bridge)
	bridge_row.add_child(start_btn)
	var stop_btn := Button.new()
	stop_btn.text = "Stop bridge"
	stop_btn.pressed.connect(_stop_bridge)
	bridge_row.add_child(stop_btn)
	var rezero_btn := Button.new()
	rezero_btn.text = "Re-zero device"
	rezero_btn.tooltip_text = "Hands off the SpaceMouse, then click: takes the current rest position as zero. Also happens automatically after 1.5 s at rest."
	rezero_btn.pressed.connect(_on_rezero_pressed)
	bridge_row.add_child(rezero_btn)
	dock.add_child(bridge_row)

	bridge_status_label = Label.new()
	bridge_status_label.text = "bridge: not started"
	bridge_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dock.add_child(bridge_status_label)

	var help := RichTextLabel.new()
	help.fit_content = true
	help.bbcode_enabled = true
	help.text = "[b]Daily use:[/b] with Auto-start on, just open Godot - the bridge launches hidden and stops with the editor.\n[b]Default:[/b] Editor Viewport mode moves the 3D view directly.\n[b]Speed:[/b] adaptive on = pace follows view distance (capped by min/max, eased by damping). Adaptive off = full manual. Wheel while flying = faster/slower either way.\n[b]Test without device:[/b] python_bridge/run_bridge_fake.bat, bars must sweep."
	dock.add_child(help)


func _spin(label_text: String, min_v: float, max_v: float, step: float, value: float) -> SpinBox:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 110
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spin)
	dock.add_child(row)
	return spin


func _restart_udp() -> void:
	receiver.listen_port = int(port_spin.value)
	receiver.start()


# --- persisted dock settings (per project, via EditorSettings metadata) ---

func _meta_get(key: String, default_value):
	return get_editor_interface().get_editor_settings().get_project_metadata("spacemouse_bridge", key, default_value)


func _meta_set(key: String, value) -> void:
	get_editor_interface().get_editor_settings().set_project_metadata("spacemouse_bridge", key, value)


func _on_horizon_toggled(v: bool) -> void:
	receiver.horizon_lock = v
	_meta_set("horizon_lock", v)


func _on_focus_toggled(v: bool) -> void:
	_meta_set("focus_guard", v)


func _on_invert_toggled(v: bool, axis: String) -> void:
	receiver.invert_axes[axis] = v
	_meta_set("invert_" + axis, v)


func _on_mode_selected(index: int) -> void:
	_meta_set("mode_index", index)


func _on_move_speed_changed(v: float) -> void:
	receiver.translation_speed = float(v)
	_meta_set("move_speed", float(v))


func _on_rot_speed_changed(v: float) -> void:
	receiver.rotation_speed = float(v)
	_meta_set("rotation_speed", float(v))


func _on_deadzone_changed(v: float) -> void:
	receiver.deadzone = float(v)
	_meta_set("deadzone", float(v))


func _on_autostart_toggled(v: bool) -> void:
	_meta_set("bridge_autostart", v)


func _on_smoothing_changed(v: float) -> void:
	receiver.smoothing = float(v)
	_meta_set("smoothing", float(v))


func _on_adaptive_toggled(v: bool) -> void:
	receiver.adaptive_speed = v
	_meta_set("adaptive_speed", v)


func _on_adapt_ref_changed(v: float) -> void:
	receiver.adaptive_ref_dist = float(v)
	_meta_set("adaptive_ref_dist", float(v))


func _on_adapt_min_changed(v: float) -> void:
	receiver.adaptive_min_scale = float(v)
	_meta_set("adaptive_min_scale", float(v))


func _on_adapt_max_changed(v: float) -> void:
	receiver.adaptive_max_scale = float(v)
	_meta_set("adaptive_max_scale", float(v))


func _on_adapt_damp_changed(v: float) -> void:
	receiver.adaptive_damping = float(v)
	_meta_set("adaptive_damping", float(v))


func _on_rezero_pressed() -> void:
	receiver.force_rezero()


func _on_speed_scale_reset() -> void:
	receiver.speed_multiplier = 1.0
	_meta_set("speed_multiplier", 1.0)


# --- bridge process management ---

func _bridge_script_path() -> String:
	var script_dir: String = (get_script() as Script).resource_path.get_base_dir()
	var candidates: Array[String] = [
		script_dir + "/python_bridge/spacemouse_udp_bridge.py",
		script_dir + "/../../python_bridge/spacemouse_udp_bridge.py",
	]
	for c in candidates:
		if FileAccess.file_exists(c):
			return ProjectSettings.globalize_path(c)
	return ""


func _autostart_bridge() -> void:
	# Skip if a bridge is already feeding us packets (started manually).
	if receiver and not receiver.last_packet.is_empty() and receiver.get_packet_age_msec() < 2000:
		if bridge_status_label:
			bridge_status_label.text = "bridge: running (external)"
		return
	_start_bridge()


func _start_bridge() -> void:
	if bridge_pid > 0 and OS.is_process_running(bridge_pid):
		return
	var script_path := _bridge_script_path()
	if script_path == "":
		bridge_status_label.text = "bridge: script not found (keep the python_bridge folder inside the addon folder)"
		return
	# No console window: create_process defaults to open_console = false.
	bridge_pid = OS.create_process("py", PackedStringArray(["-3", script_path]))
	if bridge_pid <= 0:
		bridge_pid = OS.create_process("python", PackedStringArray([script_path]))
	if bridge_pid <= 0:
		bridge_pid = OS.create_process("python3", PackedStringArray([script_path]))
	if bridge_pid > 0:
		bridge_status_label.text = "bridge: running (hidden, pid %d)" % bridge_pid
	else:
		bridge_status_label.text = "bridge: Python not found - install Python 3, then press Start bridge"


func _stop_bridge() -> void:
	if bridge_pid <= 0:
		return
	if OS.get_name() == "Windows":
		# /T kills the whole tree (py launcher + python child).
		OS.execute("taskkill", ["/PID", str(bridge_pid), "/T", "/F"])
	else:
		OS.kill(bridge_pid)
	bridge_pid = -1
	if bridge_status_label:
		bridge_status_label.text = "bridge: stopped"


func _update_bridge_status() -> void:
	if bridge_pid > 0 and not OS.is_process_running(bridge_pid):
		bridge_pid = -1
		bridge_status_label.text = "bridge: exited right away - run python_bridge/install_requirements.bat once, then press Start bridge"


func _process(delta: float) -> void:
	if not receiver:
		return
	receiver.translation_speed = float(speed_spin.value)
	receiver.rotation_speed = float(rot_spin.value)

	_update_status()
	_update_bars()
	if speed_scale_label:
		speed_scale_label.text = "speed x%.2f" % receiver.get_move_scale()

	_bridge_poll_accum += delta
	if _bridge_poll_accum >= 1.0:
		_bridge_poll_accum = 0.0
		_update_bridge_status()

	var cam: Camera3D = null
	match mode_option.get_selected_id():
		TargetMode.SELECTED_CAMERA_3D:
			cam = _get_selected_camera()
		TargetMode.ACTIVE_VIEWPORT_CAMERA:
			cam = get_viewport().get_camera_3d()
		TargetMode.EXPERIMENTAL_EDITOR_VIEWPORT:
			cam = _get_editor_viewport_camera()

	# Focus guard: never move Godot cameras while working in Blender etc.
	if focus_check and focus_check.button_pressed and not _is_editor_focused():
		return

	_sanitize_camera(cam)
	receiver.apply_to_camera(cam, delta)


func _sanitize_camera(cam: Camera3D) -> void:
	# A scaled camera basis renders exactly like a changed focal length even
	# though fov never changes. Rotation ops and look_at PRESERVE scale, so
	# once scale sneaks in it stays. Clean it silently every frame.
	if cam == null or not is_instance_valid(cam):
		return
	var b := cam.global_transform.basis
	var s := Vector3(b.x.length(), b.y.length(), b.z.length())
	var max_dev := maxf(maxf(absf(s.x - 1.0), absf(s.y - 1.0)), absf(s.z - 1.0))
	if max_dev > 0.02:
		cam.global_transform.basis = b.orthonormalized()


func _is_editor_focused() -> bool:
	if dock == null:
		return true
	var w := dock.get_window()
	return w != null and w.has_focus()


func _get_editor_viewport_camera() -> Camera3D:
	# Godot 4.2+: first 3D editor viewport's working camera.
	var vp := get_editor_interface().get_editor_viewport_3d(0)
	if vp:
		var cam := vp.get_camera_3d()
		if cam:
			return cam
	return _editor_camera_candidate


func _update_status() -> void:
	if not receiver.is_listening():
		status_label.text = "UDP: not bound. %s" % receiver.bind_error
		return
	var age: int = receiver.get_packet_age_msec()
	if age < 0:
		status_label.text = "UDP: listening on %d | no packets yet" % receiver.listen_port
	else:
		status_label.text = "UDP: listening | pkts: %d | last: %d ms | src: %s" % [
			receiver.packet_count, age, receiver.get_source()
		]


func _update_bars() -> void:
	for axis in AXES:
		var v: float = receiver.get_raw_axis(axis)
		axis_bars[axis].value = v
		axis_labels[axis].text = "%+.2f" % v
	var b: int = receiver.get_buttons()
	if b == 0:
		buttons_label.text = "buttons: -"
	else:
		var pressed: Array[String] = []
		for i in range(32):
			if b & (1 << i):
				pressed.append(str(i + 1))
		buttons_label.text = "buttons: " + ", ".join(pressed)


func _get_selected_camera() -> Camera3D:
	var selection := get_editor_interface().get_selection().get_selected_nodes()
	for node in selection:
		if node is Camera3D:
			return node
	return null


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	# Godot passes the editor viewport camera here during 3D GUI forwarding.
	# Some versions allow moving it, some treat it as internal/read-only.
	_editor_camera_candidate = viewport_camera
	# Wheel while the SpaceMouse is deflected = fly speed up/down (Godot
	# freelook paradigm). Wheel alone keeps zooming the view as usual.
	if event is InputEventMouseButton and event.pressed and receiver and receiver.is_strongly_moving():
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_nudge_speed_multiplier(1.15)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_nudge_speed_multiplier(1.0 / 1.15)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _nudge_speed_multiplier(factor: float) -> void:
	receiver.speed_multiplier = clampf(receiver.speed_multiplier * factor, 0.05, 50.0)
	_meta_set("speed_multiplier", receiver.speed_multiplier)
