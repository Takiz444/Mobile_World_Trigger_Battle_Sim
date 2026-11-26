class_name SquadMarkers
extends Control
## Screen-space markers that keep your whole squad findable at any zoom.
##
## Each living character gets a small team-coloured badge (its first two
## letters) above its head, with a pointer on the rim showing which way it
## faces. The badge is drawn over the spotlight dimming, so characters stay
## visible outside the lit area. A character off screen (or under a HUD panel)
## gets its badge pinned to the edge of the board view with an arrow toward
## it. Tapping a badge commands that character.
##
## When the camera is zoomed in close and the character is in view, its
## badge hides (the figure and its name label are clear enough).

signal unit_tapped(index: int)

const BADGE := 40.0
const EDGE_INSET := 30.0
## Ortho size below which on-screen badges hide (close-up view).
const CLOSE_ZOOM := 15.0

var camera: Camera3D
var view: BoardUnits
var units: Array[UnitState] = []
var selected := -1
## The part of the screen the board shows (outside the HUD panels).
var board_rect := Rect2()

var _buttons: Array[Button] = []
var _info: Array = []   # per unit: {show, pos, edge, facing_dir}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fit()
	get_viewport().size_changed.connect(_fit)


func _fit() -> void:
	position = Vector2.ZERO
	size = get_viewport().get_visible_rect().size
	# The board shows between the top bar, the planning panel, and the log.
	board_rect = Rect2(0.0, TimelineUI.TOP_BAR_HEIGHT, size.x - 386.0,
		size.y - TimelineUI.TOP_BAR_HEIGHT - TimelineUI.PANEL_HEIGHT)


func set_units(p_units: Array[UnitState]) -> void:
	units = p_units
	for b in _buttons:
		b.queue_free()
	_buttons.clear()
	for i in units.size():
		var b := Button.new()
		b.text = units[i].unit_data.unit_name.left(2)
		b.tooltip_text = units[i].unit_data.unit_name
		b.custom_minimum_size = Vector2(BADGE, BADGE)
		b.size = Vector2(BADGE, BADGE)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 15)
		b.add_theme_color_override("font_color", Color.WHITE)
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		b.add_theme_color_override("font_pressed_color", Color.WHITE)
		b.pressed.connect(func() -> void: unit_tapped.emit(i))
		add_child(b)
		_buttons.append(b)
	_info.resize(units.size())


func _process(_delta: float) -> void:
	if camera == null or view == null or not camera.is_inside_tree():
		return
	var area := board_rect if board_rect.has_area() else Rect2(Vector2.ZERO, size)
	var inner := area.grow(-EDGE_INSET)
	for i in units.size():
		var u := units[i]
		var b := _buttons[i]
		var info := { "show": false }
		if u.is_bailed or not view.has_marker(u) or camera.is_position_behind(view.head_pos(u)):
			b.visible = false
			_info[i] = info
			continue
		var head := view.head_pos(u) + Vector3(0, 0.35, 0)
		var p := camera.unproject_position(head)
		var on_screen := inner.has_point(p)
		if on_screen and camera.size < CLOSE_ZOOM:
			b.visible = false
			_info[i] = info
			continue
		var pinned := p
		if not on_screen:
			pinned = _clamp_to_rect(inner.get_center(), p, inner)
		var facing_tip := camera.unproject_position(head + view.facing_vector(u))
		# Don't stack on a badge placed earlier this frame (e.g. two
		# characters pinned to the same edge spot).
		for k in i:
			var other: Dictionary = _info[k] if _info[k] != null else {}
			if other.get("show", false) and (other["pos"] as Vector2).distance_to(pinned) < BADGE + 4.0:
				var push := Vector2(BADGE + 6.0, 0.0)
				if pinned.x + push.x > inner.end.x:
					push = Vector2(0.0, BADGE + 6.0) if pinned.y + BADGE + 6.0 < inner.end.y else -push
				pinned += push
		info = { "show": true, "pos": pinned, "edge": not on_screen, "target": p,
			"facing": (facing_tip - p).normalized() if facing_tip.distance_to(p) > 0.5 else Vector2.UP }
		_info[i] = info
		b.visible = true
		b.position = pinned - Vector2(BADGE, BADGE) * 0.5
		_style(b, u, i == selected)
	queue_redraw()


## Where the line from `from` toward `to` leaves `r` (for off-screen pins).
func _clamp_to_rect(from: Vector2, to: Vector2, r: Rect2) -> Vector2:
	var d := to - from
	var t := 1.0
	if d.x > 0.001:
		t = minf(t, (r.end.x - from.x) / d.x)
	elif d.x < -0.001:
		t = minf(t, (r.position.x - from.x) / d.x)
	if d.y > 0.001:
		t = minf(t, (r.end.y - from.y) / d.y)
	elif d.y < -0.001:
		t = minf(t, (r.position.y - from.y) / d.y)
	return from + d * clampf(t, 0.0, 1.0)


func _style(b: Button, u: UnitState, is_selected: bool) -> void:
	var team := BoardUnits.team_color(u.team)
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = team.darkened(0.15 if state == "normal" else 0.0)
		sb.set_corner_radius_all(int(BADGE / 2.0))
		sb.border_color = Color.WHITE if is_selected else Color(0.05, 0.07, 0.12, 0.9)
		sb.set_border_width_all(3 if is_selected else 2)
		sb.shadow_color = Color(0, 0, 0, 0.45)
		sb.shadow_size = 4
		b.add_theme_stylebox_override(state, sb)


func _draw() -> void:
	for i in _info.size():
		var info: Dictionary = _info[i] if _info[i] != null else {}
		if not info.get("show", false):
			continue
		var c: Vector2 = info["pos"]
		var col := Color.WHITE if i == selected else Color(0.92, 0.95, 1.0, 0.95)
		# Facing pointer on the rim: which way this character is looking.
		var f: Vector2 = info["facing"]
		var tip := c + f * (BADGE * 0.5 + 9.0)
		var base := c + f * (BADGE * 0.5 + 1.0)
		var side := Vector2(-f.y, f.x) * 6.0
		draw_colored_polygon(PackedVector2Array([tip, base + side, base - side]), col)
		if info["edge"]:
			# Off screen: an arrow from the pin toward the character.
			var d: Vector2 = ((info["target"] as Vector2) - c).normalized()
			var a_tip := c + d * (BADGE * 0.5 + 16.0)
			var a_base := c + d * (BADGE * 0.5 + 4.0)
			var a_side := Vector2(-d.y, d.x) * 8.0
			draw_colored_polygon(PackedVector2Array([a_tip, a_base + a_side, a_base - a_side]),
				BoardUnits.team_color(units[i].team).lightened(0.3))
