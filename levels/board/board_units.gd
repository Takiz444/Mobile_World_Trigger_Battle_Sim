class_name BoardUnits
extends Node3D
## Visualizes UnitState markers on the hex board: team-colored boxes, a facing
## "nose", and a floating Trion HP label. Bailed units are hidden.

var _hex_size: float = 1.0
var _markers: Dictionary = {}    # UnitState -> Node3D
var _hp_labels: Dictionary = {}  # UnitState -> Label3D


## Clears existing markers and spawns one per unit.
func setup(units: Array[UnitState], hex_size: float) -> void:
	_hex_size = hex_size
	for c in get_children():
		c.queue_free()
	_markers.clear()
	_hp_labels.clear()
	for u in units:
		_spawn_marker(u)


func refresh() -> void:
	for u in _markers:
		var root: Node3D = _markers[u]
		root.position = HexCoord.axial_to_world(u.hex, _hex_size)
		root.visible = not u.is_bailed
		var label: Label3D = _hp_labels[u]
		label.text = str(u.trion_hp)


func _spawn_marker(u: UnitState) -> void:
	var root := Node3D.new()
	root.name = "Unit_" + u.display_name()
	root.position = HexCoord.axial_to_world(u.hex, _hex_size)

	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.7, 0.7, 0.7)
	body.mesh = box
	body.material_override = _make_material(Color(0.2, 0.5, 1.0) if u.team == 0 else Color(1.0, 0.35, 0.3))
	root.add_child(body)

	# Facing indicator ("nose") in the unit's facing direction.
	var nose := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.12
	sphere.height = 0.24
	nose.mesh = sphere
	nose.material_override = _make_material(Color(0.9, 0.9, 0.95))
	var fwd := _facing_vector(u.facing)
	nose.position = Vector3(fwd.x * 0.55, 0.0, fwd.z * 0.55)
	root.add_child(nose)

	var label := Label3D.new()
	label.text = str(u.trion_hp)
	label.position = Vector3(0, 1.0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.02
	root.add_child(label)

	add_child(root)
	_markers[u] = root
	_hp_labels[u] = label


func _facing_vector(facing: int) -> Vector3:
	var dir_hex := HexCoord.AXIAL_DIRECTIONS[posmod(facing, 6)]
	var a := HexCoord.axial_to_world(Vector2i.ZERO, 1.0)
	var b := HexCoord.axial_to_world(dir_hex, 1.0)
	return (b - a).normalized()


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 0.45
	return mat
