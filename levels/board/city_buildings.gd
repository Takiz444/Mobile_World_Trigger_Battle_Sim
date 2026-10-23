class_name CityBuildings
extends Node3D
## Renders the map's buildings as clean rectangular city blocks instead of
## stacked hex prisms.
##
## The footprints come from BuildingRects (shared with the engine's line of
## sight): one rectangular segment per merged strip of building hexes, each
## rendered with walls, windows, parapets, and rooftop details. Segment heights
## come straight from the map's floors, so visuals always match the gameplay
## rooftops and exactly what blocks sight.

## Physics layer of building solids (tile picking uses layer 1).
const COLLISION_LAYER := 2
const PARAPET_HEIGHT := 0.16
const PARAPET_THICKNESS := 0.08
const TINTS: Array[Color] = [
	Color(0.80, 0.80, 0.82), Color(0.84, 0.80, 0.72), Color(0.70, 0.75, 0.81),
	Color(0.88, 0.87, 0.84), Color(0.74, 0.71, 0.69), Color(0.66, 0.70, 0.72),
]

var rects: Array = []   # [{c0, c1, top, bot, floors}] in hex-size-1 units
var _hex_size := 1.0
var _facade: ShaderMaterial
var _trim: StandardMaterial3D
var _equipment: StandardMaterial3D


## Rebuilds all buildings from `buildings` (axial hex -> floors).
func build(buildings: Dictionary, hex_size: float) -> void:
	for c in get_children():
		c.queue_free()
	_hex_size = hex_size
	_make_materials()
	rects = compute_rects(buildings)
	for r in rects:
		_spawn_segment(r)


# --- Footprints ---------------------------------------------------------------

## Kept for callers/tests: the shared building geometry (BuildingRects).
static func compute_rects(buildings: Dictionary) -> Array:
	return BuildingRects.compute(buildings)


func _bounds(r: Dictionary) -> Rect2:
	return BuildingRects.bounds(r, _hex_size)


# --- Construction -------------------------------------------------------------

func _spawn_segment(r: Dictionary) -> void:
	var b := _bounds(r)
	var floors: int = r["floors"]
	var h := floors * HexCoord.FLOOR_HEIGHT
	var roof_y := HexCoord.GROUND_Y + h
	var look_seed := int(r["c0"]) * 73 + int(round(float(r["top"]) * 10.0)) * 31 + floors

	var body := MeshInstance3D.new()
	body.name = "Building_%d_%d" % [r["c0"], int(round(float(r["top"]) * 10.0))]
	var box := BoxMesh.new()
	box.size = Vector3(b.size.x, h, b.size.y)
	body.mesh = box
	body.material_override = _facade
	body.position = Vector3(b.get_center().x, HexCoord.GROUND_Y + h * 0.5, b.get_center().y)
	body.set_instance_shader_parameter("tint", TINTS[look_seed % TINTS.size()])
	# Walls block light from both sides (units inside can't light up the street).
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	add_child(body)

	# Solid physics body: vision rays (and lights' shadows) stop at the walls.
	var solid := StaticBody3D.new()
	solid.name = body.name + "_Solid"
	solid.collision_layer = COLLISION_LAYER
	solid.collision_mask = 0
	solid.position = body.position
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	solid.add_child(shape)
	add_child(solid)

	_spawn_parapets(r, b, roof_y)
	_spawn_rooftop(r, b, roof_y, look_seed)


## Parapet rims on roof edges that aren't against an equal-or-taller segment.
func _spawn_parapets(r: Dictionary, b: Rect2, roof_y: float) -> void:
	var t := PARAPET_THICKNESS * _hex_size
	var y := roof_y + PARAPET_HEIGHT * 0.5
	var edges := [
		["n", Vector3(b.get_center().x, y, b.position.y + t * 0.5), Vector3(b.size.x, PARAPET_HEIGHT, t)],
		["s", Vector3(b.get_center().x, y, b.end.y - t * 0.5), Vector3(b.size.x, PARAPET_HEIGHT, t)],
		["w", Vector3(b.position.x + t * 0.5, y, b.get_center().y), Vector3(t, PARAPET_HEIGHT, b.size.y)],
		["e", Vector3(b.end.x - t * 0.5, y, b.get_center().y), Vector3(t, PARAPET_HEIGHT, b.size.y)],
	]
	for e in edges:
		if _edge_sheltered(r, b, e[0]):
			continue
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = e[2]
		mi.mesh = box
		mi.material_override = _trim
		mi.position = e[1]
		add_child(mi)


## Whether a neighbouring segment at least as tall covers most of this edge.
func _edge_sheltered(r: Dictionary, b: Rect2, side: String) -> bool:
	for o in rects:
		if o == r or int(o["floors"]) < int(r["floors"]):
			continue
		var ob := _bounds(o)
		var overlap := 0.0
		match side:
			"n":
				if absf(ob.end.y - b.position.y) < 0.01:
					overlap = minf(ob.end.x, b.end.x) - maxf(ob.position.x, b.position.x)
			"s":
				if absf(ob.position.y - b.end.y) < 0.01:
					overlap = minf(ob.end.x, b.end.x) - maxf(ob.position.x, b.position.x)
			"w":
				if absf(ob.end.x - b.position.x) < 0.01:
					overlap = minf(ob.end.y, b.end.y) - maxf(ob.position.y, b.position.y)
			"e":
				if absf(ob.position.x - b.end.x) < 0.01:
					overlap = minf(ob.end.y, b.end.y) - maxf(ob.position.y, b.position.y)
		var length := b.size.x if side in ["n", "s"] else b.size.y
		if overlap > length * 0.5:
			return true
	return false


## Rooftop equipment: stair housings / AC units on larger roofs, a water tank
## and antenna on towers. Kept near roof corners so units stay visible.
func _spawn_rooftop(r: Dictionary, b: Rect2, roof_y: float, look_seed: int) -> void:
	var area := b.size.x * b.size.y
	if area >= 6.0:
		var corner := Vector3(b.position.x + 0.45, roof_y + 0.18, b.position.y + 0.45)
		if look_seed % 2 == 0:
			corner = Vector3(b.end.x - 0.45, roof_y + 0.18, b.end.y - 0.45)
		_add_box(corner, Vector3(0.5, 0.36, 0.42), _equipment)
	if int(r["floors"]) >= 4 and area >= 4.0:
		var tank := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.24
		cyl.bottom_radius = 0.24
		cyl.height = 0.42
		tank.mesh = cyl
		tank.material_override = _equipment
		tank.position = Vector3(b.end.x - 0.4, roof_y + 0.21, b.position.y + 0.4)
		add_child(tank)
		var mast := MeshInstance3D.new()
		var rod := CylinderMesh.new()
		rod.top_radius = 0.02
		rod.bottom_radius = 0.03
		rod.height = 1.1
		mast.mesh = rod
		mast.material_override = _trim
		mast.position = Vector3(b.position.x + 0.3, roof_y + 0.55, b.end.y - 0.3)
		add_child(mast)


func _add_box(pos: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	mi.position = pos
	add_child(mi)


func _make_materials() -> void:
	if _facade != null:
		return
	_facade = ShaderMaterial.new()
	_facade.shader = load("res://levels/board/building.gdshader")
	_facade.set_shader_parameter("floor_height", HexCoord.FLOOR_HEIGHT)
	_facade.set_shader_parameter("ground_y", HexCoord.GROUND_Y)
	_trim = StandardMaterial3D.new()
	_trim.albedo_color = Color(0.58, 0.6, 0.64)
	_trim.roughness = 0.8
	_equipment = StandardMaterial3D.new()
	_equipment.albedo_color = Color(0.5, 0.52, 0.55)
	_equipment.roughness = 0.6
	_equipment.metallic = 0.3
