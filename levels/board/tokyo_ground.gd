class_name TokyoGround
extends RefCounted
## The ground of a Tokyo district, low-poly: paved land, parks, asphalt
## roads (with round joints), lane markings and zebra crossings, rivers and
## canals sunk below the street between embankment walls, bridges, and
## railway tracks fenced off at street level.
##
## Heights (above HexCoord.GROUND_Y, the street characters stand on): layers
## are stacked a few millimetres apart so they never flicker.

const WATER_DEPTH := 0.6
const Y_GREEN := 0.004
const Y_RAIL := 0.006
const Y_ROAD := 0.009          # + class offsets, bigger roads on top
const Y_MARK := 0.03
## Land not along a street (block interiors, lots, courtyards) is darker
## than the sidewalks, so the street network reads at a glance.
const COL_LAND := Color(0.42, 0.42, 0.4)
const COL_SIDEWALK := Color(0.64, 0.63, 0.6)
## Sidewalk width (each side) per road class.
const SIDEWALK := [1.4, 1.2, 0.9, 0.55, 0.0, 0.0]
const Y_SIDEWALK := 0.005
const COL_OUTER := Color(0.36, 0.36, 0.38)
const COL_GREEN := Color(0.28, 0.46, 0.22)
const COL_CURB := Color(0.78, 0.77, 0.74)
const COL_WATER := Color(0.22, 0.42, 0.52)
const COL_BANK := Color(0.47, 0.46, 0.44)
const COL_BALLAST := Color(0.4, 0.36, 0.33)
const COL_RAIL := Color(0.62, 0.62, 0.66)
const COL_FENCE := Color(0.26, 0.33, 0.3)
const COL_PLATFORM := Color(0.7, 0.69, 0.66)
const COL_PATH := Color(0.74, 0.68, 0.56)
const ROAD_COLORS := [
	Color(0.12, 0.125, 0.14), Color(0.135, 0.14, 0.155), Color(0.15, 0.155, 0.17),
	Color(0.18, 0.18, 0.195), Color(0.21, 0.21, 0.225), Color(0.62, 0.55, 0.5),
]


static func build(parent: Node3D, d: TokyoDistrict, _play: Rect2, lit: Material, water_mat: Material) -> void:
	var gy := HexCoord.GROUND_Y
	var root := Node3D.new()
	root.name = "Ground"
	parent.add_child(root)

	# Beyond the district: ground far out, all of it in the fog (the city
	# shaders fog everything past the map data). A frame around the district,
	# not a plane under it: rivers are sunk below street level and a plane
	# would cover them.
	var outer := LowPoly.begin()
	var r := Rect2(Vector2(-1500, -1500), d.size + Vector2(3000, 3000))
	var inner := Rect2(Vector2.ZERO, d.size)
	var oy := gy - 0.004
	for q in [
		Rect2(r.position, Vector2(r.size.x, -r.position.y)),
		Rect2(Vector2(r.position.x, inner.end.y), Vector2(r.size.x, r.end.y - inner.end.y)),
		Rect2(Vector2(r.position.x, 0), Vector2(-r.position.x, inner.size.y)),
		Rect2(Vector2(inner.end.x, 0), Vector2(r.end.x - inner.end.x, inner.size.y)),
	]:
		var b: Rect2 = q
		LowPoly.face(outer, [Vector3(b.position.x, oy, b.position.y), Vector3(b.end.x, oy, b.position.y),
			Vector3(b.end.x, oy, b.end.y), Vector3(b.position.x, oy, b.end.y)], COL_OUTER, Vector3.UP)
	_add(root, "Outer", outer, lit)

	# Land (everything that isn't water), parks.
	var land := LowPoly.begin()
	_tris(land, d.land, gy, COL_LAND, 0.0)
	_add(root, "Land", land, lit)
	var green := LowPoly.begin()
	_tris(green, d.green, gy + Y_GREEN, COL_GREEN, 0.06)
	_add(root, "Parks", green, lit)
	if not d.parking.is_empty():
		var lots := LowPoly.begin()
		_tris(lots, d.parking, gy + Y_GREEN + 0.0003, Color(0.3, 0.3, 0.32), 0.0)
		_add(root, "ParkingLots", lots, lit)

	# Footpaths: gravel / paving through parks and between buildings.
	if not d.paths.is_empty():
		var walks := LowPoly.begin()
		for pts in d.paths:
			_strip(walks, pts, 0.9, gy + Y_GREEN + 0.0006, COL_PATH, true)
		_add(root, "Paths", walks, lit)

	# Water, sunk between walls.
	if not d.water.is_empty():
		var water := LowPoly.begin()
		var banks := LowPoly.begin()
		var bridges_pts: Array = []
		for rd in d.roads:
			if rd["bridge"]:
				bridges_pts.append(rd)
		for w in d.water:
			_tris(water, w["tris"], gy - WATER_DEPTH, COL_WATER, 0.0)
			for ring in w["rings"]:
				_walls(banks, ring, gy - WATER_DEPTH, gy, d.size)
				_railing(banks, ring, gy, d.size, bridges_pts)
		_add(root, "Water", water, water_mat)
		_add(root, "Embankments", banks, lit)

	# Railway at street level: ballast, rails, fences.
	if not d.rail.is_empty() or not d.platforms.is_empty():
		var rail := LowPoly.begin()
		for t in d.rail:
			var pts: PackedVector2Array = t["pts"]
			var w := float(t["w"])
			_strip(rail, pts, w * 0.92, gy + Y_RAIL, COL_BALLAST)
			for off in [-0.3, 0.3]:
				_strip(rail, _offset(pts, off), 0.07, gy + Y_RAIL + 0.03, COL_RAIL, false)
			for side in [-1.0, 1.0]:
				_fence(rail, _offset(pts, side * (w * 0.5 + 0.04)), gy, 0.32, d.crossings)
		_tris(rail, d.platforms, gy + 0.22, COL_PLATFORM, 0.0)
		_add(root, "Railway", rail, lit)

	# Roads: smaller classes first, so bigger roads draw over them where
	# they meet.
	var roads := LowPoly.begin()
	var bridges := LowPoly.begin()
	var order := range(d.roads.size())
	order.sort_custom(func(a: int, b: int) -> bool: return int(d.roads[a]["cls"]) > int(d.roads[b]["cls"]))
	# Sidewalks along the streets, then curbs (a light rim just wider than
	# each carriageway), then the asphalt over them.
	var walks := LowPoly.begin()
	for i in order:
		var rd: Dictionary = d.roads[i]
		var sw: float = SIDEWALK[int(rd["cls"])]
		if sw > 0.0 and not rd["bridge"]:
			_strip(walks, rd["pts"], float(rd["w"]) + 2.0 * sw, gy + Y_SIDEWALK, COL_SIDEWALK, true)
	_add(root, "Sidewalks", walks, lit)
	for i in order:
		var rd: Dictionary = d.roads[i]
		if int(rd["cls"]) <= TokyoDistrict.RoadClass.MINOR and not rd["bridge"]:
			_strip(roads, rd["pts"], float(rd["w"]) + 0.16, gy + Y_ROAD - 0.002, COL_CURB, true)
	for i in order:
		var rd: Dictionary = d.roads[i]
		var cls := int(rd["cls"])
		var y := gy + Y_ROAD + (5 - cls) * 0.003
		_strip(roads, rd["pts"], float(rd["w"]), y, ROAD_COLORS[cls], true)
		if rd["bridge"]:
			_bridge(bridges, rd["pts"], float(rd["w"]), gy)
	_add(root, "Roads", roads, lit)
	_add(root, "Bridges", bridges, lit)

	# Markings: one MultiMesh of flat quads.
	if not d.markings.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		var quad := PlaneMesh.new()
		quad.size = Vector2.ONE
		mm.mesh = quad
		mm.instance_count = d.markings.size()
		for k in d.markings.size():
			var m: Array = d.markings[k]
			var basis := Basis(Vector3.UP, -float(m[4])) * Basis.from_scale(Vector3(2.0 * float(m[2]), 1.0, 2.0 * float(m[3])))
			mm.set_instance_transform(k, Transform3D(basis, Vector3(float(m[0]), gy + Y_MARK, float(m[1]))))
			mm.set_instance_color(k, Color(0.9, 0.9, 0.88) if int(m[5]) == 0 else Color(0.95, 0.72, 0.18))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Markings"
		mmi.multimesh = mm
		mmi.material_override = lit
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)


static func _add(root: Node3D, nm: String, st: SurfaceTool, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


## Flat triangles (flat x, z list); `vary` tints each a little (faceted look).
static func _tris(st: SurfaceTool, t: PackedFloat32Array, y: float, color: Color, vary: float) -> void:
	for i in range(0, t.size() - 5, 6):
		var c := color
		if vary > 0.0:
			var h := fposmod(sin(t[i] * 1.7 + t[i + 1] * 3.1) * 4375.85, 1.0)
			c = color.lightened(vary * h) if h > 0.5 else color.darkened(vary * (1.0 - h))
		LowPoly.face(st, [Vector3(t[i], y, t[i + 1]), Vector3(t[i + 2], y, t[i + 3]), Vector3(t[i + 4], y, t[i + 5])], c, Vector3.UP)


## A ribbon `width` wide along `pts`, with octagonal joints (round-ish ends).
static func _strip(st: SurfaceTool, pts: PackedVector2Array, width: float, y: float, color: Color, joints := true) -> void:
	var hw := width * 0.5
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		if a.distance_to(b) < 0.001:
			continue
		var n := (b - a).normalized().orthogonal() * hw
		LowPoly.face(st, [Vector3(a.x - n.x, y, a.y - n.y), Vector3(b.x - n.x, y, b.y - n.y),
			Vector3(b.x + n.x, y, b.y + n.y), Vector3(a.x + n.x, y, a.y + n.y)], color, Vector3.UP)
	if joints and hw > 0.2:
		for p in pts:
			var ring: Array = []
			for k in 8:
				var ang := TAU * (k + 0.5) / 8.0
				ring.append(Vector3(p.x + cos(ang) * hw, y, p.y + sin(ang) * hw))
			LowPoly.face(st, ring, color, Vector3.UP)


static func _offset(pts: PackedVector2Array, off: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size():
		var a := pts[maxi(0, i - 1)]
		var b := pts[mini(pts.size() - 1, i + 1)]
		var n := (b - a).normalized().orthogonal() if a.distance_to(b) > 0.0001 else Vector2.ZERO
		out.append(pts[i] + n * off)
	return out


## Vertical walls under every water edge, except along the district border.
static func _walls(st: SurfaceTool, ring: PackedVector2Array, y0: float, y1: float, size: Vector2) -> void:
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		if _on_border(a, size) and _on_border(b, size):
			continue
		# The wall faces the water: outward from the land is toward the
		# polygon's inside; both sides look right with a double face.
		var n := (b - a).normalized().orthogonal()
		var quad := [Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y)]
		LowPoly.face(st, quad, COL_BANK, Vector3(n.x, 0, n.y))
		LowPoly.face(st, quad, COL_BANK.darkened(0.15), Vector3(-n.x, 0, -n.y))


## A low railing along a riverbank (Tokyo's rivers are walled and railed),
## with gaps where bridges cross.
static func _railing(st: SurfaceTool, ring: PackedVector2Array, gy: float, size: Vector2, bridges: Array) -> void:
	var rail_col := Color(0.66, 0.68, 0.7)
	var post_col := Color(0.42, 0.44, 0.46)
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		if _on_border(a, size) and _on_border(b, size):
			continue
		var seg := a.distance_to(b)
		var steps := maxi(1, int(ceil(seg / 1.2)))
		for k in steps:
			var p := a.lerp(b, float(k) / steps)
			var q := a.lerp(b, float(k + 1) / steps)
			var mid := (p + q) * 0.5
			var on_bridge := false
			for rd in bridges:
				var pts: PackedVector2Array = rd["pts"]
				for j in range(pts.size() - 1):
					if Geometry2D.get_closest_point_to_segment(mid, pts[j], pts[j + 1]).distance_to(mid) < float(rd["w"]) * 0.5 + 0.4:
						on_bridge = true
						break
				if on_bridge:
					break
			if on_bridge:
				continue
			var n := (q - p).normalized().orthogonal()
			var out := Vector3(n.x, 0, n.y)
			# Top rail and a post at the segment start.
			var quad := [Vector3(p.x, gy + 0.26, p.y), Vector3(q.x, gy + 0.26, q.y), Vector3(q.x, gy + 0.31, q.y), Vector3(p.x, gy + 0.31, p.y)]
			LowPoly.face(st, quad, rail_col, out)
			LowPoly.face(st, quad, rail_col, -out)
			LowPoly.box(st, Vector3(p.x, gy + 0.15, p.y), Vector3(0.03, 0.15, 0.03), post_col)


static func _on_border(p: Vector2, size: Vector2) -> bool:
	return p.x < 0.3 or p.y < 0.3 or p.x > size.x - 0.3 or p.y > size.y - 0.3


## Bridge sides: a girder under each edge and a low railing on top.
static func _bridge(st: SurfaceTool, pts: PackedVector2Array, width: float, gy: float) -> void:
	for side in [-1.0, 1.0]:
		var edge := _offset(pts, side * width * 0.5)
		for i in range(edge.size() - 1):
			var a := edge[i]
			var b := edge[i + 1]
			if a.distance_to(b) < 0.001:
				continue
			var n := (b - a).normalized().orthogonal() * float(side)
			var out := Vector3(n.x, 0, n.y)
			LowPoly.face(st, [Vector3(a.x, gy - 0.35, a.y), Vector3(b.x, gy - 0.35, b.y), Vector3(b.x, gy + 0.01, b.y), Vector3(a.x, gy + 0.01, a.y)],
				Color(0.55, 0.55, 0.56), out)
			LowPoly.face(st, [Vector3(a.x, gy, a.y), Vector3(b.x, gy, b.y), Vector3(b.x, gy + 0.22, b.y), Vector3(a.x, gy + 0.22, a.y)],
				Color(0.72, 0.72, 0.7), out)
			LowPoly.face(st, [Vector3(a.x, gy, a.y), Vector3(b.x, gy, b.y), Vector3(b.x, gy + 0.22, b.y), Vector3(a.x, gy + 0.22, a.y)],
				Color(0.62, 0.62, 0.6), -out)


## A low fence along `pts` (both faces), with gaps at level crossings.
static func _fence(st: SurfaceTool, pts: PackedVector2Array, gy: float, height: float, crossings: Array) -> void:
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		var seg_len := a.distance_to(b)
		if seg_len < 0.001:
			continue
		var steps := maxi(1, int(ceil(seg_len / 1.0)))
		for k in steps:
			var p := a.lerp(b, float(k) / steps)
			var q := a.lerp(b, float(k + 1) / steps)
			var mid := (p + q) * 0.5
			var gap := false
			for c in crossings:
				if mid.distance_to(Vector2(c.x, c.y)) < float(c.z) + 0.2:
					gap = true
					break
			if gap:
				continue
			var n := (q - p).normalized().orthogonal()
			var quad := [Vector3(p.x, gy, p.y), Vector3(q.x, gy, q.y), Vector3(q.x, gy + height, q.y), Vector3(p.x, gy + height, p.y)]
			LowPoly.face(st, quad, COL_FENCE, Vector3(n.x, 0, n.y))
			LowPoly.face(st, quad, COL_FENCE, Vector3(-n.x, 0, -n.y))
