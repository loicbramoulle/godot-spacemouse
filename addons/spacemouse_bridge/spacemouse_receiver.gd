@tool
extends Node
# No class_name on purpose: avoids global class conflicts if the addon
# folder exists in more than one place in the project.

signal packet_received(data: Dictionary)

@export var listen_port: int = 42424
@export var deadzone: float = 0.035
@export var translation_speed: float = 8.0
@export var rotation_speed: float = 2.2
@export var enabled: bool = true
# Keep the horizon level: ignore roll input and remove accumulated roll.
# Essential for motion-sickness-free navigation. Default ON.
@export var horizon_lock: bool = true
# Per-axis inversion applied to motion. Dock bars keep showing raw values.
var invert_axes: Dictionary = {
	"tx": false, "ty": false, "tz": false,
	"rx": false, "ry": false, "rz": false,
}
# Adaptive speed: translation speed scales with the distance to whatever the
# camera is looking at (Blender-like: giant when zoomed out, ant up close).
var adaptive_speed: bool = true
# Wheel-while-flying multiplier on top of Move speed (Godot freelook paradigm).
var speed_multiplier: float = 1.0
# Seconds to ease starts/stops. 0 = raw input.
var smoothing: float = 0.12
# Adaptive tuning (exposed in the dock).
var adaptive_ref_dist: float = 10.0 # distance that means x1.0
var adaptive_min_scale: float = 0.2 # hard floor for the adaptive factor
var adaptive_max_scale: float = 8.0 # hard ceiling for the adaptive factor
var adaptive_damping: float = 0.5 # seconds to ease distance changes
var _adaptive_dist: float = 10.0
var _adaptive_log: float = 2.302585 # log(10)
var _target_camera: Camera3D = null
# Raw HID has no driver-side zero calibration (3DxWare normally does that
# for Blender). If the cap does not settle exactly at center, rest values
# stay slightly nonzero and the camera creeps forward forever - which looks
# like the view zooming in on its own. Auto re-zero measures the rest bias
# and subtracts it, like the driver does.
var auto_rezero: bool = true
const REST_MAX_DEFLECTION := 0.08
const REST_SETTLE_MSEC := 1500
# Manual Re-zero button (user explicitly says hands-off) may capture up to this.
const BIAS_LIMIT := 0.3
# Auto re-zero may only ever capture a small bias near true zero. A real
# mechanical rest offset is a few percent; anything bigger is a hand on the
# puck and must never become the center.
const AUTO_BIAS_LIMIT := 0.08
var _bias := {"tx": 0.0, "ty": 0.0, "tz": 0.0, "rx": 0.0, "ry": 0.0, "rz": 0.0}
var _rest_avg := {"tx": 0.0, "ty": 0.0, "tz": 0.0, "rx": 0.0, "ry": 0.0, "rz": 0.0}
var _rest_start_msec: int = -1
var _smooth_t := Vector3.ZERO
var _smooth_r := Vector3.ZERO

var _udp := PacketPeerUDP.new()
var _listening := false
var last_packet: Dictionary = {}
var last_input_time_msec: int = 0
var packet_count: int = 0
var bind_error: String = ""


func _ready() -> void:
	start()


func _exit_tree() -> void:
	stop()


func start() -> void:
	stop()
	var err := _udp.bind(listen_port, "127.0.0.1")
	if err != OK:
		bind_error = "could not bind UDP 127.0.0.1:%d (error %s)" % [listen_port, err]
		push_warning("SpaceMouseReceiver: " + bind_error)
		return
	bind_error = ""
	_listening = true


func stop() -> void:
	if _listening:
		_udp.close()
	_listening = false


func is_listening() -> bool:
	return _listening


func _process(_delta: float) -> void:
	if not enabled or not _listening:
		return
	while _udp.get_available_packet_count() > 0:
		var text := _udp.get_packet().get_string_from_utf8()
		var parsed = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			last_packet = parsed
			last_input_time_msec = Time.get_ticks_msec()
			packet_count += 1
			packet_received.emit(last_packet)
			_update_rezero()


func get_packet_age_msec() -> int:
	if packet_count == 0:
		return -1
	return Time.get_ticks_msec() - last_input_time_msec


func get_source() -> String:
	return String(last_packet.get("src", "?"))


func get_raw_axis(axis_name: String) -> float:
	# Raw incoming value, no deadzone. Use for visualization.
	var age := get_packet_age_msec()
	if age < 0 or age > 500:
		return 0.0
	return float(last_packet.get(axis_name, 0.0)) - float(_bias.get(axis_name, 0.0))


func get_axis(axis_name: String) -> float:
	var v := get_raw_axis(axis_name)
	if absf(v) < deadzone:
		return 0.0
	if invert_axes.get(axis_name, false):
		return -v
	return v


func get_buttons() -> int:
	var age := get_packet_age_msec()
	if age < 0 or age > 500:
		return 0
	return int(last_packet.get("buttons", 0))


func get_translation_vector() -> Vector3:
	return Vector3(get_axis("tx"), get_axis("ty"), get_axis("tz"))


func get_rotation_vector() -> Vector3:
	return Vector3(get_axis("rx"), get_axis("ry"), get_axis("rz"))


func is_moving() -> bool:
	# True while the device is deflected beyond the deadzone (fresh packet).
	return get_translation_vector() != Vector3.ZERO or get_rotation_vector() != Vector3.ZERO


func is_strongly_moving() -> bool:
	# Deliberate deflection, not sensor drift. Used as the wheel-capture
	# gate so leftover drift can never steal the wheel from viewport zoom.
	return get_translation_vector().length() + get_rotation_vector().length() > 0.1


func force_rezero() -> void:
	# Take the current rest position as the new zero (hands off the puck).
	var age := get_packet_age_msec()
	for a in _bias.keys():
		if age < 0 or age > 500:
			_bias[a] = 0.0
		else:
			_bias[a] = clampf(float(last_packet.get(a, 0.0)), -BIAS_LIMIT, BIAS_LIMIT)
	_rest_start_msec = -1


func _update_rezero() -> void:
	if not auto_rezero:
		return
	var now := Time.get_ticks_msec()
	for a in _bias.keys():
		# Rest means raw values near TRUE zero, not near the current bias.
		# (v1.0.1 fix: comparing against the bias let a steady slow cruise -
		# constant deflection held over 1.5 s - be adopted as the new center,
		# and the bias could walk up in 0.08 steps. Result: a stuck phantom
		# input of ~0.19 that only disabling the addon cleared. The absolute
		# check prevents the capture AND self-heals a bad bias at rest.)
		if absf(float(last_packet.get(a, 0.0))) > REST_MAX_DEFLECTION:
			# Real motion: restart the rest timer.
			_rest_start_msec = -1
			return
	if _rest_start_msec < 0:
		_rest_start_msec = now
		for a in _rest_avg.keys():
			_rest_avg[a] = float(last_packet.get(a, 0.0))
		return
	for a in _rest_avg.keys():
		_rest_avg[a] = lerpf(float(_rest_avg[a]), float(last_packet.get(a, 0.0)), 0.05)
	if now - _rest_start_msec >= REST_SETTLE_MSEC:
		for a in _bias.keys():
			_bias[a] = clampf(float(_rest_avg[a]), -AUTO_BIAS_LIMIT, AUTO_BIAS_LIMIT)


func get_move_scale() -> float:
	# Effective translation multiplier: wheel multiplier x adaptive factor.
	# The adaptive factor is hard-capped so a ray hitting the void or a mesh
	# right in front of the camera can never teleport or freeze the view.
	var s := speed_multiplier
	if adaptive_speed:
		s *= clampf(_adaptive_dist / adaptive_ref_dist, adaptive_min_scale, adaptive_max_scale)
	return s


func _physics_process(_delta: float) -> void:
	# Adaptive distance is sampled in the physics step (raycast requirement).
	if not adaptive_speed:
		return
	if _target_camera == null or not is_instance_valid(_target_camera):
		return
	var d := clampf(_estimate_view_distance(_target_camera), 0.1, 4000.0)
	# Damp in log space: a mesh entering/leaving the ray is a multiplicative
	# jump, so easing the logarithm keeps the pace change gradual and
	# symmetric in both directions.
	var alpha := 1.0 - exp(-_delta / maxf(adaptive_damping, 0.01))
	_adaptive_log = lerpf(_adaptive_log, log(d), alpha)
	_adaptive_dist = exp(_adaptive_log)


func _estimate_view_distance(camera: Camera3D) -> float:
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z
	# 1) Physics raycast: exact distance to anything with collision.
	var world := camera.get_world_3d()
	if world:
		var state := world.direct_space_state
		if state:
			var query := PhysicsRayQueryParameters3D.create(from, from + dir * 4000.0)
			var hit := state.intersect_ray(query)
			if hit.has("position"):
				return from.distance_to(hit["position"])
	# 2) Fallback for scenes without collision: hit the ground plane (y = 0).
	if absf(dir.y) > 0.02:
		var t := -from.y / dir.y
		if t > 0.5:
			return t
	# 3) Last resort: height above the ground plane.
	return maxf(absf(from.y), 2.0)


func apply_to_camera(camera: Camera3D, delta: float) -> void:
	if not camera or not is_instance_valid(camera):
		return
	_target_camera = camera
	var t := get_translation_vector()
	var r := get_rotation_vector()

	# Smoothing acts on the FINAL velocity (deflection x speed x adaptive
	# scale), never on the raw deflection. This way a speed-scale jump can
	# never re-amplify the leftover tail of a previous move (the v0.5.0 bug
	# that made push and pull appear to move the same way).
	var target_vel := Vector3(t.x, t.y, -t.z) * translation_speed * get_move_scale()
	var target_rot := r * rotation_speed
	if smoothing > 0.001:
		var alpha := 1.0 - exp(-delta / smoothing)
		_smooth_t = _smooth_t.lerp(target_vel, alpha)
		_smooth_r = _smooth_r.lerp(target_rot, alpha)
	else:
		_smooth_t = target_vel
		_smooth_r = target_rot
	if t == Vector3.ZERO and r == Vector3.ZERO and _smooth_t.length() < 0.01 and _smooth_r.length() < 0.01:
		_smooth_t = Vector3.ZERO
		_smooth_r = Vector3.ZERO
		return

	# SpaceMouse translations in camera-local space.
	# Adaptive scale applies to translation only; rotation feel stays constant.
	camera.global_translate(camera.global_transform.basis * (_smooth_t * delta))

	# Rotation: rx=pitch, ry=yaw, rz=roll (roll ignored under horizon lock).
	camera.rotate_object_local(Vector3.RIGHT, -_smooth_r.x * delta)
	camera.rotate_y(-_smooth_r.y * delta)
	if horizon_lock:
		_level_horizon(camera)
	else:
		camera.rotate_object_local(Vector3.FORWARD, -_smooth_r.z * delta)

	# Never leave scale in the camera basis: rotate/look_at preserve scale,
	# and a scaled camera basis renders exactly like a narrower focal length.
	camera.global_transform.basis = camera.global_transform.basis.orthonormalized()


func _level_horizon(camera: Camera3D) -> void:
	# Remove any roll so the horizon stays level.
	var fwd := -camera.global_transform.basis.z
	if absf(fwd.dot(Vector3.UP)) > 0.999:
		return # Looking almost straight up/down; leave the basis alone.
	camera.look_at(camera.global_position + fwd, Vector3.UP)
