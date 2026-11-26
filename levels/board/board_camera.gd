class_name BoardCamera
extends Camera3D
## Orthographic orbit/pan/zoom camera for the hologram tabletop diorama.
##
## Desktop controls (PC-secondary per GDD 2.1):
##   scroll wheel = zoom, middle-drag = pan, right-drag = orbit (yaw/pitch).
## Touch controls (mobile-first per GDD 2.1):
##   one-finger drag = pan, pinch = zoom, two-finger twist = rotate.
## Trackpad magnify / pan gestures are handled too.

@export var target: Vector3 = Vector3.ZERO
@export var start_size := 16.0
@export var min_size := 4.0
@export var max_size := 80.0
@export var pitch := deg_to_rad(35.264)   # isometric pitch
@export var yaw := deg_to_rad(45.0)
@export var pan_sensitivity := 0.0012     # fraction of ortho size per pixel
@export var rotate_sensitivity := 0.01    # radians per pixel
@export var orbit_distance := 60.0        # camera-to-target distance (fixed)
## Where the orbit target should appear relative to the viewport center, in
## pixels (negative = left / up). Lets the board center sit in the area not
## covered by UI panels.
@export var screen_offset_px := Vector2.ZERO

const ZOOM_STEP := 0.1
## Directional lights in this group get their shadow range fitted to the
## view: an orthographic view zoomed out past the range lost every shadow
## (the whole city went dark).
const SUN_GROUP := &"board_sun"
## Finger travel (px) before a one-finger touch counts as a pan, not a tap.
const TOUCH_PAN_THRESHOLD := 12.0

var _panning := false
var _orbiting := false
var _bounds := AABB()
var _has_bounds := false
var _shake := 0.0
var _focus_tween: Tween
var _shake_phase := 0.0
var _touches: Dictionary = {}     # finger index -> current position
var _touch_travel := 0.0          # accumulated one-finger drag distance
var _pinch_dist := 0.0
var _pinch_angle := 0.0


func _ready() -> void:
	projection = Camera3D.PROJECTION_ORTHOGONAL
	size = start_size
	current = true
	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom(1)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom(-1)
			MOUSE_BUTTON_MIDDLE:
				_panning = event.pressed
			MOUSE_BUTTON_RIGHT:
				_orbiting = event.pressed
	elif event is InputEventMouseMotion:
		if _panning:
			_pan_pixels(event.relative)
		elif _orbiting:
			_orbit(event.relative)
	elif event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)
	elif event is InputEventMagnifyGesture:
		_zoom_by(1.0 / maxf(0.01, event.factor))
	elif event is InputEventPanGesture:
		_pan_pixels(-event.delta * 8.0)


# --- Touch ------------------------------------------------------------------

func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
		_touch_travel = 0.0
	else:
		_touches.erase(event.index)
	if _touches.size() == 2:
		_begin_pinch()


func _on_drag(event: InputEventScreenDrag) -> void:
	_touches[event.index] = event.position
	if _touches.size() == 1:
		# One finger: pan once it has moved far enough to not be a tap.
		_touch_travel += event.relative.length()
		if _touch_travel >= TOUCH_PAN_THRESHOLD:
			_pan_pixels(event.relative)
	elif _touches.size() == 2:
		# Two fingers: pinch to zoom, twist to rotate.
		var pts: Array = _touches.values()
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[1]
		var dist := a.distance_to(b)
		var angle := (b - a).angle()
		if _pinch_dist > 0.0 and dist > 0.0:
			_zoom_by(_pinch_dist / dist)
		yaw -= wrapf(angle - _pinch_angle, -PI, PI)
		_pinch_dist = dist
		_pinch_angle = angle
		_update_transform()


func _begin_pinch() -> void:
	var pts: Array = _touches.values()
	_pinch_dist = (pts[0] as Vector2).distance_to(pts[1])
	_pinch_angle = ((pts[1] as Vector2) - (pts[0] as Vector2)).angle()


## Glides to look at `pos` and (when `zoom_size` > 0) zooms to that ortho
## size. Any manual pan / zoom / rotate cancels the glide.
func focus_on(pos: Vector3, zoom_size: float = -1.0, duration: float = 0.4) -> void:
	_stop_focus()
	var from_target := target
	var from_size := size
	var to_target := Vector3(pos.x, 0.0, pos.z)
	var to_size := clampf(zoom_size, min_size, max_size) if zoom_size > 0.0 else size
	if not is_inside_tree() or duration <= 0.0:
		target = to_target
		size = to_size
		_update_transform()
		return
	_focus_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_focus_tween.tween_method(func(k: float) -> void:
		target = from_target.lerp(to_target, k)
		size = lerpf(from_size, to_size, k)
		_update_transform(), 0.0, 1.0, duration)


func _stop_focus() -> void:
	if _focus_tween != null and _focus_tween.is_valid():
		_focus_tween.kill()
	_focus_tween = null


## Multiplies the ortho size (factor > 1 zooms out).
func _zoom_by(factor: float) -> void:
	_stop_focus()
	size = clampf(size * factor, min_size, max_size)
	_update_transform()


## direction +1 = zoom in (smaller ortho size), -1 = zoom out.
func _zoom(direction: int) -> void:
	_stop_focus()
	size = clampf(size * pow(1.0 + ZOOM_STEP, -direction), min_size, max_size)
	_update_transform()


## Keeps the orbit target inside the board so the camera can't drift off
## the map.
func set_bounds(bounds: AABB) -> void:
	_bounds = bounds
	_has_bounds = true
	_update_transform()


func _pan_pixels(rel: Vector2) -> void:
	_pan_world(rel * size * pan_sensitivity)


func _pan_world(move: Vector2) -> void:
	_stop_focus()
	var right := global_transform.basis.x
	var up := global_transform.basis.y
	target -= right * move.x
	target += up * move.y
	_update_transform()


func _orbit(rel: Vector2) -> void:
	_stop_focus()
	yaw -= rel.x * rotate_sensitivity
	pitch = clampf(pitch + rel.y * rotate_sensitivity, deg_to_rad(5.0), deg_to_rad(85.0))
	_update_transform()


## Brief screen jolt for heavy hits; `strength` 0..1. Screen-space only (it
## never moves the camera target, so input and framing are unaffected).
func shake(strength: float) -> void:
	_shake = maxf(_shake, clampf(strength, 0.0, 1.0))
	set_process(true)


func _process(delta: float) -> void:
	if _shake <= 0.0:
		set_process(false)
		return
	_shake = maxf(0.0, _shake - delta * 3.2)
	_shake_phase += delta * 55.0
	_update_transform()


func _update_transform() -> void:
	if _has_bounds:
		target.x = clampf(target.x, _bounds.position.x, _bounds.end.x)
		target.z = clampf(target.z, _bounds.position.z, _bounds.end.z)
	if is_inside_tree():
		var world_per_px := size / maxf(1.0, get_viewport().get_visible_rect().size.y)
		h_offset = -screen_offset_px.x * world_per_px
		v_offset = screen_offset_px.y * world_per_px
		if _shake > 0.0:
			var amp := size * 0.006 * _shake * _shake
			h_offset += sin(_shake_phase * 1.3) * amp
			v_offset += cos(_shake_phase) * amp
	var dir := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	)
	global_position = target + dir * orbit_distance
	look_at(target, Vector3.UP)
	if is_inside_tree():
		for l in get_tree().get_nodes_in_group(SUN_GROUP):
			(l as DirectionalLight3D).directional_shadow_max_distance = orbit_distance + size * 1.7


## Re-centers the orbit target onto a world position (used when the player
## selects a unit).
func recenter(pos: Vector3) -> void:
	target = Vector3(pos.x, 0.0, pos.z)
	_update_transform()
