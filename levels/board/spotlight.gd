class_name Spotlight
extends Control
## Fog-of-war spotlight for the character being commanded: everything it
## can't see is dimmed, and what it can see stays bright. The lit shape is
## the character's real vision (the detection circle plus the sight cone, cut
## by walls) taken from BoardUnits.vision_outline(), so the screen shows
## exactly what that character knows.
##
## Drawn in screen space every frame from the 3D outline, so it follows the
## camera (pan, zoom, rotate). The vision shape is star-shaped around the
## character's eye (every outline point is a ray from it), so the dimmed
## area is drawn as one quad per outline segment, from the outline out past
## the edge of the screen, with a soft feathered band along the edge. Sits in
## the UI layer under the HUD panels and never takes input.

const FADE_SEC := 0.2
const DIM := 0.5
const FEATHER_PX := 16.0
const SHADE := Color(0.02, 0.03, 0.07)
const RIM := Color(0.55, 0.88, 1.0, 0.85)

var camera: Camera3D

var _center := Vector3.ZERO
var _outline := PackedVector3Array()
var _strength := 0.0
var _active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_fit()
	get_viewport().size_changed.connect(_fit)


## Lights the area inside `outline` (world space, ordered around `center`).
func focus_shape(center: Vector3, outline: PackedVector3Array) -> void:
	if outline.size() < 3:
		clear()
		return
	_center = center
	_outline = outline
	_active = true
	visible = true


func clear() -> void:
	_active = false


func is_active() -> bool:
	return _active


func _fit() -> void:
	position = Vector2.ZERO
	size = get_viewport().get_visible_rect().size


func _process(delta: float) -> void:
	_strength = move_toward(_strength, 1.0 if _active else 0.0, delta / FADE_SEC)
	if _strength <= 0.0:
		visible = false
		return
	queue_redraw()


static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5


func _draw() -> void:
	if camera == null or not camera.is_inside_tree() or _outline.size() < 3:
		return
	var c := camera.unproject_position(_center)
	var far := size.length() * 2.0
	var dim := Color(SHADE, DIM * _strength)
	var clear_col := Color(SHADE, 0.0)
	var n := _outline.size()
	var inner := PackedVector2Array()
	var outer := PackedVector2Array()
	var beyond := PackedVector2Array()
	inner.resize(n)
	outer.resize(n)
	beyond.resize(n)
	for i in n:
		var p := camera.unproject_position(_outline[i])
		var dir := p - c
		dir = dir / dir.length() if dir.length() > 0.001 else Vector2.UP
		inner[i] = p
		outer[i] = p + dir * FEATHER_PX
		beyond[i] = c + dir * far
	# The outline runs all the way round (-180° to +180°): close it.
	for i in n:
		var j := (i + 1) % n
		# Neighbouring rays at the same angle (the cone's straight sides)
		# give zero-width quads: skip those.
		var band := PackedVector2Array([inner[i], inner[j], outer[j], outer[i]])
		if _area(band) > 0.25:
			draw_polygon(band, PackedColorArray([clear_col, clear_col, dim, dim]))
		var out := PackedVector2Array([outer[i], outer[j], beyond[j], beyond[i]])
		if _area(out) > 0.25:
			draw_colored_polygon(out, dim)
	var rim := inner.duplicate()
	if rim.is_empty():
		return
	rim.append(inner[0])
	draw_polyline(rim, Color(RIM, RIM.a * _strength), 2.0, true)
