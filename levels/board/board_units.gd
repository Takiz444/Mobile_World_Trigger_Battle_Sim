class_name BoardUnits
extends Node3D
## Visualizes UnitState markers on the hex board: team-colored emissive
## humanoid "Trion body" figures, a facing indicator, a selection ring, and
## name/HP labels. Bailed units are hidden. Units stand on the tile surface
## (HexCoord.GROUND_Y) and are raised by floor * HexCoord.FLOOR_HEIGHT inside or
## on top of buildings.
##
## Fog of war: each unit's `fog` state decides how it is drawn — exact
## (SIGHT), as a pulsing radar ping at `ping_hex` (RADAR), or not at all
## (HIDDEN). Provides tween helpers for the replay controller.

const BODY_Y := 0.875

var _hex_size: float = 1.0
var _markers: Dictionary = {}        # UnitState -> Node3D
var _hp_labels: Dictionary = {}      # UnitState -> Label3D
var _nose_nodes: Dictionary = {}     # UnitState -> MeshInstance3D
var _body_materials: Dictionary = {} # UnitState -> StandardMaterial3D
var _body_colors: Dictionary = {}    # UnitState -> Color
var _rings: Dictionary = {}          # UnitState -> MeshInstance3D
var _move_tweens: Dictionary = {}    # UnitState -> Tween
var _face_tweens: Dictionary = {}    # UnitState -> Tween
var _ghost: Node3D = null            # translucent movement-destination preview
var _ghost_body: MeshInstance3D = null
var _pings: Dictionary = {}          # UnitState -> Node3D (radar ghost)


## Clears existing markers and spawns one per unit.
func setup(units: Array[UnitState], hex_size: float) -> void:
	_hex_size = hex_size
	for c in get_children():
		c.queue_free()
	_markers.clear()
	_hp_labels.clear()
	_nose_nodes.clear()
	_body_materials.clear()
	_body_colors.clear()
	_rings.clear()
	_pings.clear()
	_move_tweens.clear()
	_face_tweens.clear()
	_ghost = null
	_ghost_body = null
	for u in units:
		_spawn_marker(u)


## Updates HP labels, fog visibility, and stealth alpha without moving markers.
func update_labels() -> void:
	for u in _markers:
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
		if not u.is_bailed:
			_markers[u].visible = u.fog == Visibility.State.SIGHT
		_apply_body_style(u)
	apply_fog()


## Shows/hides markers and radar pings from each unit's fog state.
func apply_fog() -> void:
	for u in _markers:
		var state: int = u.fog
		if not u.is_bailed:
			_markers[u].visible = state == Visibility.State.SIGHT
		var show_ping: bool = state == Visibility.State.RADAR and not u.is_bailed
		var ping: Node3D = _pings.get(u)
		if show_ping:
			if ping == null:
				ping = _build_ping(u)
				_pings[u] = ping
			var p := HexCoord.axial_to_world(u.ping_hex, _hex_size)
			p.y = HexCoord.GROUND_Y
			ping.position = p
			ping.visible = true
		elif ping != null:
			ping.visible = false


## Hard-syncs every marker to the unit's current hex/facing/HP. Kills tweens.
func refresh() -> void:
	for u in _markers:
		_kill_tween(_move_tweens, u)
		_kill_tween(_face_tweens, u)
		var root: Node3D = _markers[u]
		root.scale = Vector3.ONE
		root.position = _world_pos(u)
		root.visible = not u.is_bailed and u.fog == Visibility.State.SIGHT
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
		var nose: MeshInstance3D = _nose_nodes[u]
		nose.position = _nose_offset(u.facing)


## Places one marker at its unit's position/facing immediately (no tween).
func snap(u: UnitState) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	_kill_tween(_face_tweens, u)
	root.position = _world_pos(u)
	var nose: MeshInstance3D = _nose_nodes[u]
	nose.position = _nose_offset(u.facing)


## Shows the selection ring under `u` (or clears it when null).
func set_selected(u: UnitState) -> void:
	for key in _rings:
		var ring: MeshInstance3D = _rings[key]
		ring.visible = key == u


# --- Tween Helpers ----------------------------------------------------------

## Tweens a marker from its current position to `world`.
func tween_to(u: UnitState, world: Vector3, duration: float = 0.35) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	var tw := root.create_tween()
	tw.tween_property(root, "position", world, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_move_tweens[u] = tw


## Tweens the facing "nose" toward a new direction.
func tween_facing(u: UnitState, facing: int, duration: float = 0.35) -> void:
	var nose: MeshInstance3D = _nose_nodes.get(u)
	if nose == null:
		return
	_kill_tween(_face_tweens, u)
	var tw := nose.create_tween()
	tw.tween_property(nose, "position", _nose_offset(facing), duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_face_tweens[u] = tw


## Quick red flash on a unit that took damage.
func flash_hit(u: UnitState) -> void:
	var root: Node3D = _markers.get(u)
	var mat: StandardMaterial3D = _body_materials.get(u)
	if root == null or mat == null:
		return
	var base: Color = _body_color_for(u)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var tw := root.create_tween()
	tw.tween_property(mat, "albedo_color", Color(1.0, 0.18, 0.18), 0.1)
	tw.tween_property(mat, "albedo_color", base, 0.28)
	tw.tween_callback(_apply_body_style.bind(u))


## Shrinks a bailed unit out and hides it.
func play_bail(u: UnitState) -> void:
	var root: Node3D = _markers.get(u)
	if root == null:
		return
	_kill_tween(_move_tweens, u)
	_kill_tween(_face_tweens, u)
	var tw := root.create_tween()
	tw.tween_property(root, "scale", Vector3(0.01, 0.01, 0.01), 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void: root.visible = false)


# --- Ghost Preview ----------------------------------------------------------

## Shows a translucent "ghost" of `u` at `hex` (movement destination preview).
func show_ghost(u: UnitState, hex: Vector2i, floor: int = 0) -> void:
	if _ghost == null:
		_ghost = _build_ghost()
	var team_color := Color(0.15, 0.62, 1.0) if u.team == 0 else Color(1.0, 0.3, 0.22)
	var mat: StandardMaterial3D = _ghost_body.material_override
	mat.albedo_color = Color(team_color.r, team_color.g, team_color.b, 0.35)
	mat.emission = team_color
	var p := HexCoord.axial_to_world(hex, _hex_size)
	p.y = HexCoord.GROUND_Y + floor * HexCoord.FLOOR_HEIGHT
	_ghost.position = p
	_ghost.visible = true


func clear_ghost() -> void:
	if _ghost != null:
		_ghost.visible = false


func _build_ghost() -> Node3D:
	var root := Node3D.new()
	root.name = "GhostPreview"

	var ring := MeshInstance3D.new()
	ring.name = "GhostRing"
	var ring_cyl := CylinderMesh.new()
	ring_cyl.top_radius = 0.56
	ring_cyl.bottom_radius = 0.56
	ring_cyl.height = 0.06
	ring.mesh = ring_cyl
	ring.material_override = _make_emissive(Color(1.0, 0.9, 0.3), 1.2)
	ring.position = Vector3(0, 0.03, 0)
	root.add_child(ring)

	var body := MeshInstance3D.new()
	body.name = "GhostBody"
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 0.8, 0.8)
	body.mesh = box
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.35)
	mat.metallic = 0.0
	mat.roughness = 0.35
	mat.emission_enabled = true
	mat.emission = Color(1, 1, 1)
	mat.emission_energy_multiplier = 1.1
	body.material_override = mat
	body.position = Vector3(0, BODY_Y, 0)
	root.add_child(body)
	_ghost_body = body

	add_child(root)
	root.visible = false
	return root


# --- Construction -----------------------------------------------------------

func _spawn_marker(u: UnitState) -> void:
	var root := Node3D.new()
	root.name = "Unit_" + u.display_name()
	root.position = _world_pos(u)

	var team_color := Color(0.15, 0.62, 1.0) if u.team == 0 else Color(1.0, 0.3, 0.22)

	# Selection ring (hidden until this unit is selected).
	var ring := MeshInstance3D.new()
	ring.name = "SelectionRing"
	var ring_cyl := CylinderMesh.new()
	ring_cyl.top_radius = 0.56
	ring_cyl.bottom_radius = 0.56
	ring_cyl.height = 0.06
	ring.mesh = ring_cyl
	ring.material_override = _make_emissive(Color(1.0, 0.9, 0.3), 2.5)
	ring.position = Vector3(0, 0.03, 0)
	ring.visible = false
	root.add_child(ring)

	# Trion body material (shared by head, torso, arms, and legs so that
	# stealth alpha and damage flashes affect the whole figure).
	var body_mat := _make_emissive(team_color, 1.1)
	body_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

	root.add_child(_make_box("LegL", Vector3(0.16, 0.45, 0.16), Vector3(-0.13, 0.225, 0), body_mat))
	root.add_child(_make_box("LegR", Vector3(0.16, 0.45, 0.16), Vector3(0.13, 0.225, 0), body_mat))
	root.add_child(_make_box("Torso", Vector3(0.5, 0.55, 0.32), Vector3(0, 0.725, 0), body_mat))
	root.add_child(_make_box("ArmL", Vector3(0.14, 0.5, 0.14), Vector3(-0.32, 0.65, 0), body_mat))
	root.add_child(_make_box("ArmR", Vector3(0.14, 0.5, 0.14), Vector3(0.32, 0.65, 0), body_mat))

	# Head.
	var head := MeshInstance3D.new()
	head.name = "Head"
	var head_sphere := SphereMesh.new()
	head_sphere.radius = 0.16
	head_sphere.height = 0.32
	head.mesh = head_sphere
	head.material_override = body_mat
	head.position = Vector3(0, 1.2, 0)
	root.add_child(head)

	# Glowing chest core.
	var core := MeshInstance3D.new()
	core.name = "Core"
	var core_sphere := SphereMesh.new()
	core_sphere.radius = 0.08
	core_sphere.height = 0.16
	core.mesh = core_sphere
	core.material_override = _make_emissive(Color(1.0, 0.95, 0.85), 1.6)
	core.position = Vector3(0, 0.74, 0.2)
	root.add_child(core)

	# Facing indicator ("nose") in the unit's facing direction.
	var nose := MeshInstance3D.new()
	nose.name = "Nose"
	var sphere := SphereMesh.new()
	sphere.radius = 0.09
	sphere.height = 0.18
	nose.mesh = sphere
	nose.material_override = _make_emissive(Color(0.95, 0.95, 1.0), 0.9)
	nose.position = _nose_offset(u.facing)
	root.add_child(nose)

	# Name + HP labels (always face the camera). Depth-tested so they are
	# hidden behind solid geometry instead of floating on top of it.
	var name_label := Label3D.new()
	name_label.text = u.unit_data.unit_name
	name_label.position = Vector3(0, 2.6, 0)
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.pixel_size = 0.018
	name_label.outline_size = 8
	name_label.modulate = team_color
	root.add_child(name_label)

	var label := Label3D.new()
	label.text = str(u.trion_hp)
	label.position = Vector3(0, 1.7, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.022
	label.outline_size = 8
	root.add_child(label)

	add_child(root)
	_markers[u] = root
	_hp_labels[u] = label
	_nose_nodes[u] = nose
	_body_materials[u] = body_mat
	_body_colors[u] = team_color
	_rings[u] = ring


## Small helper for the humanoid's box-shaped body parts.
func _make_box(part_name: String, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	mi.position = pos
	return mi


## World position of a unit standing on the tile surface / its floor.
func _world_pos(u: UnitState) -> Vector3:
	var p := HexCoord.axial_to_world(u.hex, _hex_size)
	p.y = HexCoord.GROUND_Y + u.floor * HexCoord.FLOOR_HEIGHT
	return p


## Opaque body normally; translucent only while Bagworm is active (opaque
## bodies avoid sorting artifacts against tiles and buildings).
func _apply_body_style(u: UnitState) -> void:
	var mat: StandardMaterial3D = _body_materials.get(u)
	if mat == null:
		return
	mat.albedo_color = _body_color_for(u)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if u.stealth_active else BaseMaterial3D.TRANSPARENCY_DISABLED


## Radar Signal marker: a pulsing team-colored ring with a "?" — presence
## only, no identity or HP (GDD 4.3).
func _build_ping(u: UnitState) -> Node3D:
	var color := Color(0.15, 0.62, 1.0) if u.team == 0 else Color(1.0, 0.3, 0.22)
	var root := Node3D.new()
	root.name = "RadarPing"

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.42
	torus.outer_radius = 0.55
	ring.mesh = torus
	var mat := _make_emissive(color, 2.0)
	mat.albedo_color = Color(color.r, color.g, color.b, 0.75)
	ring.material_override = mat
	ring.position.y = 0.06
	root.add_child(ring)

	var q := Label3D.new()
	q.text = "?"
	q.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	q.pixel_size = 0.02
	q.outline_size = 8
	q.modulate = color
	q.position.y = 0.6
	root.add_child(q)

	add_child(root)
	var tw := ring.create_tween().set_loops()
	tw.tween_property(ring, "scale", Vector3(1.35, 1.0, 1.35), 0.7)
	tw.tween_property(ring, "scale", Vector3.ONE, 0.7)
	return root


func _nose_offset(facing: int) -> Vector3:
	var fwd := _facing_vector(facing)
	return Vector3(fwd.x * 0.24, 1.2, fwd.z * 0.24)


## Team color with stealth applied (semi-transparent while Bagworm is active).
func _body_color_for(u: UnitState) -> Color:
	var base: Color = _body_colors.get(u, Color(1, 1, 1))
	return Color(base.r, base.g, base.b, 0.35 if u.stealth_active else 1.0)


func _kill_tween(dict: Dictionary, key: Variant) -> void:
	var tw: Tween = dict.get(key)
	if tw != null:
		tw.kill()
	dict.erase(key)


func _facing_vector(facing: int) -> Vector3:
	var dir_hex := HexCoord.AXIAL_DIRECTIONS[posmod(facing, 6)]
	var a := HexCoord.axial_to_world(Vector2i.ZERO, 1.0)
	var b := HexCoord.axial_to_world(dir_hex, 1.0)
	return (b - a).normalized()


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 0.5
	return mat


func _make_emissive(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 0.35
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat
