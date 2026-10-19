class_name BoardCamera
extends Camera3D
## Orthographic orbit/pan/zoom camera for the hologram tabletop diorama.
##
## Desktop controls (PC-secondary per GDD 2.1):
##   scroll wheel = zoom, middle-drag = pan, right-drag = orbit (yaw/pitch).
## Touch gestures (pinch-zoom, drag) will be layered on later for mobile.

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

var _panning := false
var _orbiting := false
var _bounds := AABB()
var _has_bounds := false


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


## direction +1 = zoom in (smaller ortho size), -1 = zoom out.
func _zoom(direction: int) -> void:
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
	var right := global_transform.basis.x
	var up := global_transform.basis.y
	target -= right * move.x
	target += up * move.y
	_update_transform()


func _orbit(rel: Vector2) -> void:
	yaw -= rel.x * rotate_sensitivity
	pitch = clampf(pitch + rel.y * rotate_sensitivity, deg_to_rad(5.0), deg_to_rad(85.0))
	_update_transform()


func _update_transform() -> void:
	if _has_bounds:
		target.x = clampf(target.x, _bounds.position.x, _bounds.end.x)
		target.z = clampf(target.z, _bounds.position.z, _bounds.end.z)
	if is_inside_tree():
		var world_per_px := size / maxf(1.0, get_viewport().get_visible_rect().size.y)
		h_offset = -screen_offset_px.x * world_per_px
		v_offset = screen_offset_px.y * world_per_px
	var dir := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	)
	global_position = target + dir * orbit_distance
	look_at(target, Vector3.UP)


## Re-centers the orbit target onto a world position (used when the player
## selects a unit).
func recenter(pos: Vector3) -> void:
	target = Vector3(pos.x, 0.0, pos.z)
	_update_transform()
