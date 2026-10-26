class_name CombatFx
extends Node3D
## Simple procedural combat effects for the board, following the visual
## language of the design doc (World trigger project.pdf):
##   - a warm horizontal slash arc for melee
##   - a travelling bullet + beam for ranged attacks
##   - an expanding impact ring on hits
##   - a blue shield pulse
## It also renders a looping *preview* while planning: a breathing slash arc
## for melee and a marching dotted path for ranged, so the area of effect is
## animated before the turn resolves.
##
## Purely cosmetic — nothing here reads or changes game state. All meshes are
## built in code, so there are no assets to import.

const SLASH_COLOR := Color(1.0, 0.86, 0.38)
const BULLET_COLOR := Color(0.55, 0.95, 1.0)
const SHIELD_COLOR := Color(0.4, 0.72, 1.0)
const IMPACT_COLOR := Color(1.0, 0.6, 0.22)

const SLASH_DURATION := 0.34
## Hexes per second a bullet travels during a resolution animation.
const BULLET_SPEED_HEX := 11.0

var hex_size := 1.0

# Looping planning preview (at most one at a time).
var _preview: Node3D = null
var _preview_kind := ""
var _preview_key := ""
var _preview_time := 0.0
var _preview_mat: StandardMaterial3D = null
var _preview_base_yaw := 0.0
var _preview_hexes: Array[Vector2i] = []
var _preview_floor := 0
var _preview_pulse: Node3D = null
var _preview_dots: Array[Node3D] = []


func setup(p_hex_size: float) -> void:
	hex_size = p_hex_size


func _process(delta: float) -> void:
	if _preview == null:
		return
	_preview_time += delta
	if _preview_kind == "slash":
		# Breathe the arc and sweep it gently side to side.
		if _preview_mat != null:
			_preview_mat.albedo_color.a = 0.22 + 0.16 * (0.5 + 0.5 * sin(_preview_time * 4.2))
		_preview.rotation.y = _preview_base_yaw + deg_to_rad(13.0) * sin(_preview_time * 2.6)
	elif _preview_kind == "line":
		var n := _preview_hexes.size()
		if n == 0:
			return
		var segs := maxi(1, n - 1)
		var t := fmod(_preview_time * 1.1, 1.0)
		var f := t * float(segs)
		var i := clampi(int(floor(f)), 0, segs - 1)
		var frac := f - float(i)
		var a := _hex_pos(_preview_hexes[i], _preview_floor)
		var b := _hex_pos(_preview_hexes[mini(i + 1, n - 1)], _preview_floor)
		if _preview_pulse != null:
			_preview_pulse.position = a.lerp(b, frac)
		# Hex markers light up as the pulse passes over them.
		for k in _preview_dots.size():
			var mat := _preview_dots[k].get_meta(&"mat", null) as StandardMaterial3D
			if mat == null:
				continue
			var at := float(k) / float(segs)
			var lit := maxf(0.0, 1.0 - absf(at - t) * 3.5)
			mat.albedo_color.a = 0.2 + 0.6 * lit


# --- One-shot animations ----------------------------------------------------

## Horizontal slash arc centred on `hex`, sweeping in `facing`'s direction.
func play_slash(hex: Vector2i, floor: int, facing: int) -> void:
	var root := Node3D.new()
	root.position = _hex_pos(hex, floor)
	var fwd := _dir_vector(facing)
	root.rotation.y = atan2(fwd.x, fwd.z)

	var mat := _additive(SLASH_COLOR, 0.9)
	var mi := MeshInstance3D.new()
	mi.mesh = _arc_mesh(hex_size * 0.45, hex_size * 1.3, 64.0)
	mi.material_override = mat
	root.add_child(mi)

	root.scale = Vector3(0.55, 1.0, 0.55)
	add_child(root)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(root, "scale", Vector3(1.12, 1.0, 1.12), SLASH_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(root, "rotation:y", root.rotation.y - deg_to_rad(22.0), SLASH_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, SLASH_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.finished.connect(root.queue_free)


## Bullet flying along a hex path (each hex the line crosses), leaving fading
## beam segments and bursting on the final hex.
func play_bullet_path(path: Array[Vector2i], floor: int) -> void:
	if path.is_empty():
		return
	if path.size() == 1:
		play_impact(path[0], floor)
		return

	var beams: Array[MeshInstance3D] = []
	for i in range(1, path.size()):
		beams.append(_make_beam(_hex_pos(path[i - 1], floor), _hex_pos(path[i], floor), 0.4))

	# Bullet head.
	var dot := MeshInstance3D.new()
	var orb := SphereMesh.new()
	orb.radius = hex_size * 0.15
	orb.height = hex_size * 0.3
	dot.mesh = orb
	dot.material_override = _additive(BULLET_COLOR, 1.0)
	dot.position = _hex_pos(path[0], floor)
	add_child(dot)

	var tw := create_tween()
	var total := 0.0
	for i in range(1, path.size()):
		var a := _hex_pos(path[i - 1], floor)
		var b := _hex_pos(path[i], floor)
		var d := maxf(0.03, a.distance_to(b) / (BULLET_SPEED_HEX * hex_size))
		total += d
		tw.tween_property(dot, "position", b, d).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		play_impact(path[path.size() - 1], floor)
		dot.queue_free())

	# Beams fade out behind the bullet.
	for bm in beams:
		var mat := bm.material_override as StandardMaterial3D
		if mat == null:
			continue
		var ft := create_tween()
		ft.tween_interval(total * 0.6)
		ft.tween_property(mat, "albedo_color:a", 0.0, total * 0.4)
		ft.tween_callback(bm.queue_free)


## Expanding ring burst at a hex (hit feedback).
func play_impact(hex: Vector2i, floor: int) -> void:
	var root := Node3D.new()
	root.position = _hex_pos(hex, floor) + Vector3(0.0, hex_size * 0.45, 0.0)
	var mat := _additive(IMPACT_COLOR, 0.95)
	var mi := MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = hex_size * 0.26
	ring.outer_radius = hex_size * 0.4
	ring.rings = 12
	ring.ring_segments = 8
	mi.mesh = ring
	mi.material_override = mat
	mi.rotation_degrees.x = 90.0
	root.add_child(mi)
	root.scale = Vector3(0.35, 0.35, 0.35)
	add_child(root)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(root, "scale", Vector3(1.7, 1.7, 1.7), 0.3).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.3).set_ease(Tween.EASE_OUT)
	tw.finished.connect(root.queue_free)


## Blue ring pulse around a unit that raised a shield.
func play_shield(hex: Vector2i, floor: int) -> void:
	var root := Node3D.new()
	root.position = _hex_pos(hex, floor) + Vector3(0.0, hex_size * 0.5, 0.0)
	var mat := _additive(SHIELD_COLOR, 0.8)
	var mi := MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = hex_size * 0.5
	ring.outer_radius = hex_size * 0.62
	ring.rings = 16
	ring.ring_segments = 8
	mi.mesh = ring
	mi.material_override = mat
	mi.rotation_degrees.x = 90.0
	root.add_child(mi)
	root.scale = Vector3(0.5, 0.5, 0.5)
	add_child(root)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(root, "scale", Vector3(1.25, 1.25, 1.25), 0.45).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.45).set_ease(Tween.EASE_OUT)
	tw.finished.connect(root.queue_free)


## Plays the right one-shot attack animation for a card type.
func play_attack(card_type: int, from_hex: Vector2i, to_hex: Vector2i, floor: int) -> void:
	if card_type == TriggerCard.CardType.MELEE:
		var facing := TickEngine.attack_direction(from_hex, to_hex)
		play_slash(from_hex, floor, facing if facing != -1 else 0)
	elif card_type == TriggerCard.CardType.RANGED:
		play_bullet_path(HexCoord.line(from_hex, to_hex), floor)


# --- Looping planning preview ----------------------------------------------

## Breathing slash arc in front of `origin`, aimed along `facing`.
func show_slash_preview(origin: Vector2i, floor: int, facing: int) -> void:
	var key := "slash:%d:%d:%d:%d" % [origin.x, origin.y, floor, facing]
	if _preview != null and _preview_key == key:
		return
	_clear_preview_nodes()
	_preview_key = key
	_preview_kind = "slash"
	_preview_time = 0.0
	_preview = Node3D.new()
	_preview.position = _hex_pos(origin, floor)
	var fwd := _dir_vector(facing)
	_preview_base_yaw = atan2(fwd.x, fwd.z)
	_preview.rotation.y = _preview_base_yaw

	_preview_mat = _additive(Color(SLASH_COLOR, 1.0), 0.3)
	var mi := MeshInstance3D.new()
	mi.mesh = _arc_mesh(hex_size * 0.45, hex_size * 1.28, 62.0)
	mi.material_override = _preview_mat
	_preview.add_child(mi)
	add_child(_preview)


## Animated bullet line along a hex path: a thin beam through the crossed
## hexes, a ring marker on each hex the line touches, and a travelling pulse.
## (No filled tiles — the path itself is the preview.)
func show_line_preview(path: Array[Vector2i], floor: int) -> void:
	if path.is_empty():
		clear_preview()
		return
	var key := "line:%d:" % floor
	for h in path:
		key += "%d,%d;" % [h.x, h.y]
	if _preview != null and _preview_key == key:
		return
	_clear_preview_nodes()
	_preview_key = key
	_preview_kind = "line"
	_preview_time = 0.0
	_preview_hexes = path.duplicate()
	_preview_floor = floor
	_preview = Node3D.new()
	add_child(_preview)

	# Beam segments between consecutive hex centres.
	for i in range(1, path.size()):
		_preview.add_child(_make_beam(_hex_pos(path[i - 1], floor), _hex_pos(path[i], floor), 0.3))

	# A flat ring on every hex the line crosses (replaces the old tile fill).
	for h in path:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = hex_size * 0.42
		torus.outer_radius = hex_size * 0.5
		torus.rings = 6
		torus.ring_segments = 6
		ring.mesh = torus
		var m := _additive(Color(BULLET_COLOR, 1.0), 0.3)
		ring.material_override = m
		ring.set_meta(&"mat", m)
		ring.rotation_degrees.x = 90.0
		ring.position = _hex_pos(h, floor)
		_preview.add_child(ring)
		_preview_dots.append(ring)

	# Travelling pulse that loops from the unit to the end of the path.
	_preview_pulse = MeshInstance3D.new()
	var orb := SphereMesh.new()
	orb.radius = hex_size * 0.12
	orb.height = hex_size * 0.24
	(_preview_pulse as MeshInstance3D).mesh = orb
	(_preview_pulse as MeshInstance3D).material_override = _additive(Color(BULLET_COLOR, 1.0), 1.0)
	_preview_pulse.position = _hex_pos(path[0], floor)
	_preview.add_child(_preview_pulse)


func clear_preview() -> void:
	_clear_preview_nodes()


func _clear_preview_nodes() -> void:
	if _preview != null:
		_preview.queue_free()
	_preview = null
	_preview_kind = ""
	_preview_key = ""
	_preview_mat = null
	_preview_pulse = null
	_preview_hexes.clear()
	_preview_dots.clear()


## Thin additive cylinder stretched between two world points (a beam).
func _make_beam(a: Vector3, b: Vector3, alpha: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = hex_size * 0.035
	cyl.bottom_radius = hex_size * 0.035
	cyl.height = maxf(0.001, a.distance_to(b))
	cyl.radial_segments = 6
	mi.mesh = cyl
	mi.material_override = _additive(Color(BULLET_COLOR, 1.0), alpha)
	if a.distance_to(b) > 0.001:
		mi.look_at_from_position((a + b) * 0.5, b, Vector3.UP)
		mi.rotate_object_local(Vector3.RIGHT, -PI * 0.5)
	else:
		mi.position = a
	return mi


# --- Helpers ----------------------------------------------------------------

func _hex_pos(hex: Vector2i, floor: int) -> Vector3:
	var p := HexCoord.axial_to_world(hex, hex_size)
	p.y = HexCoord.GROUND_Y + floor * HexCoord.FLOOR_HEIGHT + 0.06
	return p


## Unit-length world direction (XZ) of an axial direction index.
func _dir_vector(facing: int) -> Vector3:
	var v := HexCoord.axial_to_world(HexCoord.AXIAL_DIRECTIONS[posmod(facing, 6)], hex_size)
	v.y = 0.0
	return v.normalized()


## A flat horizontal arc band (crescent) in the local XZ plane, bisector on +Z.
func _arc_mesh(inner: float, outer: float, half_deg: float, segments: int = 26) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_in := Vector3.ZERO
	var prev_out := Vector3.ZERO
	for i in segments + 1:
		var a := deg_to_rad(-half_deg + (2.0 * half_deg) * float(i) / float(segments))
		var dir := Vector3(sin(a), 0.0, cos(a))
		var vi := dir * inner
		var vo := dir * outer
		if i > 0:
			st.add_vertex(prev_in)
			st.add_vertex(prev_out)
			st.add_vertex(vi)
			st.add_vertex(prev_out)
			st.add_vertex(vo)
			st.add_vertex(vi)
		prev_in = vi
		prev_out = vo
	st.generate_normals()
	return st.commit()


func _additive(color: Color, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.3
	return mat
