class_name BoardUnits
extends Node3D
## Visualizes UnitState markers on the hex board: team-colored emissive boxes
## on pedestals, a facing "nose", a selection ring, and floating name/HP labels.
## Bailed units are hidden. Provides tween helpers for the replay controller.

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
	_move_tweens.clear()
	_face_tweens.clear()
	_ghost = null
	_ghost_body = null
	for u in units:
		_spawn_marker(u)


## Updates HP labels, visibility, and stealth alpha without moving markers.
func update_labels() -> void:
	for u in _markers:
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
		if not u.is_bailed:
			_markers[u].visible = true
		var mat: StandardMaterial3D = _body_materials.get(u)
		if mat != null:
			mat.albedo_color = _body_color_for(u)


## Hard-syncs every marker to the unit's current hex/facing/HP. Kills tweens.
func refresh() -> void:
	for u in _markers:
		_kill_tween(_move_tweens, u)
		_kill_tween(_face_tweens, u)
		var root: Node3D = _markers[u]
		root.scale = Vector3.ONE
		root.position = HexCoord.axial_to_world(u.hex, _hex_size)
		root.visible = not u.is_bailed
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)
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
	var tw := root.create_tween()
	tw.tween_property(mat, "albedo_color", Color(1.0, 0.18, 0.18), 0.1)
	tw.tween_property(mat, "albedo_color", base, 0.28)


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
func show_ghost(u: UnitState, hex: Vector2i) -> void:
	if _ghost == null:
		_ghost = _build_ghost()
	var team_color := Color(0.15, 0.62, 1.0) if u.team == 0 else Color(1.0, 0.3, 0.22)
	var mat: StandardMaterial3D = _ghost_body.material_override
	mat.albedo_color = Color(team_color.r, team_color.g, team_color.b, 0.35)
	mat.emission = team_color
	_ghost.position = HexCoord.axial_to_world(hex, _hex_size)
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
	ring.position = Vector3(0, 0.2, 0)
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
	root.position = HexCoord.axial_to_world(u.hex, _hex_size)

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
	ring.position = Vector3(0, 0.2, 0)
	ring.visible = false
	root.add_child(ring)

	# Pedestal grounds the unit and lifts it off the tile.
	var pedestal := MeshInstance3D.new()
	pedestal.name = "Pedestal"
	var pcyl := CylinderMesh.new()
	pcyl.top_radius = 0.42
	pcyl.bottom_radius = 0.52
	pcyl.height = 0.3
	pedestal.mesh = pcyl
	pedestal.material_override = _make_material(Color(0.14, 0.16, 0.22))
	pedestal.position = Vector3(0, 0.325, 0)
	root.add_child(pedestal)

	# Body (team-colored, emissive).
	var body := MeshInstance3D.new()
	body.name = "Body"
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 0.8, 0.8)
	body.mesh = box
	body.material_override = _make_emissive(team_color, 1.1)
	body.position = Vector3(0, BODY_Y, 0)
	root.add_child(body)

	# Facing indicator ("nose") in the unit's facing direction.
	var nose := MeshInstance3D.new()
	nose.name = "Nose"
	var sphere := SphereMesh.new()
	sphere.radius = 0.16
	sphere.height = 0.32
	nose.mesh = sphere
	nose.material_override = _make_emissive(Color(0.95, 0.95, 1.0), 0.9)
	nose.position = _nose_offset(u.facing)
	root.add_child(nose)

	# Name + HP labels (always face the camera).
	var name_label := Label3D.new()
	name_label.text = u.display_name()
	name_label.position = Vector3(0, 2.15, 0)
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.no_depth_test = true
	name_label.pixel_size = 0.016
	name_label.modulate = team_color
	root.add_child(name_label)

	var label := Label3D.new()
	label.text = str(u.trion_hp)
	label.position = Vector3(0, 1.6, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.024
	root.add_child(label)

	add_child(root)
	_markers[u] = root
	_hp_labels[u] = label
	_nose_nodes[u] = nose
	_body_materials[u] = body.material_override
	_body_colors[u] = team_color
	_rings[u] = ring


func _nose_offset(facing: int) -> Vector3:
	var fwd := _facing_vector(facing)
	return Vector3(fwd.x * 0.6, BODY_Y, fwd.z * 0.6)


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
