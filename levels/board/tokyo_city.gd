class_name TokyoCity
extends Node3D
## Draws a match's part of Tokyo in a low-poly style: the play area's
## buildings, towers, pillars and decks (with physics solids that match the
## rules exactly, and pick bodies on the roofs), the rest of the district
## around it as plain grey boxes (shaded darker the farther from the zone),
## fog where the map data ends (never a hard edge or a made-up row of
## blocks), the ground (TokyoGround), street furniture and landmarks
## (TokyoProps), and a straight red simulation boundary around the zone.
##
## Every box is one instance of a single MultiMesh (one draw call) using
## tokyo_building.gdshader.

const COLLISION_LAYER := 2   # CityBuildings.COLLISION_LAYER (vision rays)
const PICK_LAYER := 1        # CityBoard.PICK_LAYER (taps)

## Shader style ids: buildings use their TokyoDistrict.Style (0..7), solids
## SOLID_BASE + SolidStyle, decks DECK_BASE + DeckKind.
const SOLID_BASE := 10
const DECK_BASE := 20
## Temple halls: the box is drawn up to this share of the solid's height;
## TokyoProps puts a tiled hip roof on top.
const TEMPLE_EAVE := 0.58

const PALETTES := {
	0: [Color(0.92, 0.9, 0.85), Color(0.9, 0.84, 0.7), Color(0.8, 0.72, 0.6), Color(0.6, 0.66, 0.72),
		Color(0.58, 0.45, 0.35), Color(0.64, 0.71, 0.61), Color(0.78, 0.53, 0.43), Color(0.85, 0.85, 0.83)],
	1: [Color(0.94, 0.93, 0.9), Color(0.79, 0.8, 0.81), Color(0.87, 0.77, 0.63), Color(0.68, 0.42, 0.34),
		Color(0.91, 0.86, 0.66), Color(0.72, 0.76, 0.8)],
	2: [Color(0.43, 0.56, 0.7), Color(0.6, 0.65, 0.7), Color(0.32, 0.36, 0.42), Color(0.77, 0.76, 0.73),
		Color(0.4, 0.6, 0.63), Color(0.55, 0.52, 0.5)],
	3: [Color(0.95, 0.94, 0.91), Color(0.72, 0.4, 0.32), Color(0.63, 0.79, 0.73), Color(0.88, 0.74, 0.4),
		Color(0.86, 0.63, 0.63), Color(0.34, 0.34, 0.38), Color(0.61, 0.75, 0.87), Color(0.82, 0.8, 0.74)],
	4: [Color(0.66, 0.22, 0.16)],
	5: [Color(0.8, 0.79, 0.75), Color(0.7, 0.72, 0.74)],
	6: [Color(0.52, 0.6, 0.68)],
	7: [Color(0.9, 0.86, 0.76), Color(0.84, 0.82, 0.78)],
	10: [Color(0.62, 0.62, 0.6)],
	11: [Color(0.46, 0.57, 0.68), Color(0.58, 0.65, 0.71), Color(0.36, 0.42, 0.5), Color(0.66, 0.69, 0.72)],
	12: [Color(0.72, 0.2, 0.13)],
	13: [Color(0.78, 0.2, 0.12)],
	20: [Color(0.62, 0.62, 0.6)],
	21: [Color(0.66, 0.66, 0.65)],
}

## Radius (world units, on screen) of the cutaway around the selected
## character.
const CUTAWAY_RADIUS := 2.6

## Zone mask resolution (pixels per unit).
const MASK_PPU := 4.0

var district: TokyoDistrict
var play := Rect2()
var zone := PackedVector2Array()
var _mat: ShaderMaterial
var _lit: ShaderMaterial
var _glow: ShaderMaterial
var _water: ShaderMaterial


func _ready() -> void:
	name = "Tokyo"


## Builds everything for `layout` (its district and play area).
func build(layout: CityLayout) -> void:
	for c in get_children():
		c.queue_free()
	district = layout.district
	play = layout.bounds
	zone = layout.zone
	_make_materials()
	var pts := shader_polygon(zone)
	for m in [_mat, _lit, _glow, _water]:
		(m as ShaderMaterial).set_shader_parameter("zone_pts", pts)
		(m as ShaderMaterial).set_shader_parameter("zone_n", pts.size())
		(m as ShaderMaterial).set_shader_parameter("data_rect", Vector4(0.0, 0.0, district.size.x, district.size.y))
	set_focus(Vector3.ZERO, 0.0)
	_build_boxes(layout)
	TokyoGround.build(self, district, play, _lit, _water)
	TokyoProps.build(self, district, play, _lit, _glow, layout)
	_build_frame()


## The zone polygon for the shaders (at most ZONE_MAX points: simplified
## further if a zone ever has more).
const ZONE_MAX := 64


static func shader_polygon(poly: PackedVector2Array) -> PackedVector2Array:
	var tol := 0.2
	var out := poly
	while out.size() > ZONE_MAX:
		out = _rdp_ring(poly, tol)
		tol *= 1.5
	return out


static func _rdp_ring(ring: PackedVector2Array, tol: float) -> PackedVector2Array:
	var keep := PackedByteArray()
	keep.resize(ring.size())
	keep.fill(0)
	keep[0] = 1
	var far := 0
	for i in ring.size():
		if ring[i].distance_to(ring[0]) > ring[far].distance_to(ring[0]):
			far = i
	keep[far] = 1
	var stack: Array = [[0, far], [far, ring.size()]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var a: Vector2 = ring[seg[0]]
		var b: Vector2 = ring[seg[1] % ring.size()]
		var best := -1.0
		var at := -1
		for i in range(seg[0] + 1, seg[1]):
			var d := Geometry2D.get_closest_point_to_segment(ring[i], a, b).distance_to(ring[i])
			if d > best:
				best = d
				at = i
		if at >= 0 and best > tol:
			keep[at] = 1
			stack.append([seg[0], at])
			stack.append([at, seg[1]])
	var out := PackedVector2Array()
	for i in ring.size():
		if keep[i] == 1:
			out.append(ring[i])
	return out


## The zone polygon rasterised over `area` (1 inside).
static func zone_mask(poly: PackedVector2Array, area: Rect2, ppu: float) -> ImageTexture:
	var w := maxi(2, int(ceil(area.size.x * ppu)))
	var h := maxi(2, int(ceil(area.size.y * ppu)))
	var data := PackedByteArray()
	data.resize(w * h)
	data.fill(0)
	var n := poly.size()
	for row in h:
		var zc := area.position.y + (row + 0.5) / ppu
		var xs: Array[float] = []
		for k in n:
			var a := poly[k]
			var b := poly[(k + 1) % n]
			if (a.y > zc) != (b.y > zc):
				xs.append(a.x + (zc - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		for k in range(0, xs.size() - 1, 2):
			var c0 := clampi(int(ceil((xs[k] - area.position.x) * ppu - 0.5)), 0, w)
			var c1 := clampi(int(floor((xs[k + 1] - area.position.x) * ppu - 0.5)) + 1, 0, w)
			for c in range(c0, c1):
				data[row * w + c] = 255
	var img := Image.create_from_data(w, h, false, Image.FORMAT_L8, data)
	return ImageTexture.create_from_image(img)


## Cuts away buildings between `camera` and `at` (radius 0: off).
func set_focus(at: Vector3, radius: float, camera := Vector3.ZERO) -> void:
	if _mat != null:
		_mat.set_shader_parameter("focus", Vector4(at.x, at.y, at.z, radius))
		_mat.set_shader_parameter("cut_camera", camera)


func _make_materials() -> void:
	if _mat != null:
		return
	_mat = ShaderMaterial.new()
	_mat.shader = GfxLite.shader("res://levels/board/tokyo_building.gdshader")
	_mat.set_shader_parameter("floor_height", HexCoord.FLOOR_HEIGHT)
	_mat.set_shader_parameter("ground_y", HexCoord.GROUND_Y)
	_lit = ShaderMaterial.new()
	_lit.shader = GfxLite.shader("res://levels/board/tokyo_vc.gdshader")
	_glow = ShaderMaterial.new()
	_glow.shader = GfxLite.shader("res://levels/board/tokyo_glow.gdshader")
	_water = ShaderMaterial.new()
	_water.shader = GfxLite.shader("res://levels/board/tokyo_water.gdshader")


# --- Boxes ----------------------------------------------------------------------

func _build_boxes(layout: CityLayout) -> void:
	var near := play.grow(0.5)
	var inst: Array = []   # [box, style id, backdrop]
	for b in layout.buildings:
		inst.append([b, int(b["style"]), false])
	for b in layout.solids:
		if int(b["style"]) != TokyoDistrict.SolidStyle.PAGODA:
			inst.append([b, SOLID_BASE + int(b["style"]), false])
	for b in layout.decks:
		if int(b["style"]) <= TokyoDistrict.DeckKind.ROAD:
			inst.append([b, DECK_BASE + int(b["style"]), false])
	for b in district.buildings:
		if not (b["aabb"] as Rect2).intersects(near, true):
			inst.append([b, int(b["style"]), true])
	for b in district.solids:
		if not (b["aabb"] as Rect2).intersects(near, true) and int(b["style"]) != TokyoDistrict.SolidStyle.PAGODA:
			inst.append([b, SOLID_BASE + int(b["style"]), true])
	for b in district.decks:
		if not (b["aabb"] as Rect2).intersects(near, true) and int(b["style"]) <= TokyoDistrict.DeckKind.ROAD:
			inst.append([b, DECK_BASE + int(b["style"]), true])
	var mm := _box_multimesh(inst.size())
	for i in inst.size():
		var e: Array = inst[i]
		var b: Dictionary = e[0]
		if int(e[1]) == SOLID_BASE + TokyoDistrict.SolidStyle.TEMPLE:
			b = b.duplicate()
			b["y1"] = float(b["y1"]) * TEMPLE_EAVE
		_set_box(mm, i, b, e[1], e[2])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Boxes"
	mmi.multimesh = mm
	mmi.material_override = _mat
	add_child(mmi)
	_build_solids_physics(layout)
	_build_picks(layout)
	_build_roof_props(inst)


func _box_multimesh(count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE
	mm.mesh = cube
	mm.instance_count = count
	return mm


## Box heights: buildings 0..floors, solids 0..y1, decks y0..y1 (rules
## space), drawn above the street surface (GROUND_Y).
static func box_transform(b: Dictionary, lift := 0.0) -> Transform3D:
	var h: Vector2 = b["h"]
	var y0 := float(b["y0"])
	var y1 := float(b["y1"]) + lift
	var basis := Basis(Vector3.UP, -float(b["a"])) * Basis.from_scale(Vector3(2.0 * h.x, y1 - y0, 2.0 * h.y))
	var c: Vector2 = b["c"]
	return Transform3D(basis, Vector3(c.x, HexCoord.GROUND_Y + (y0 + y1) * 0.5, c.y))


func _set_box(mm: MultiMesh, i: int, b: Dictionary, style: int, backdrop: bool) -> void:
	var c: Vector2 = b["c"]
	var seed := fposmod(sin(c.x * 12.9898 + c.y * 78.233) * 43758.5453, 1.0)
	var pal: Array = PALETTES.get(style, PALETTES[0])
	var tint: Color = pal[int(seed * 997.0) % pal.size()]
	# A hair of extra height per building keeps touching roofs from flickering.
	var lift := 0.0
	if int(b["kind"]) == CityBox.Kind.BUILDING:
		lift = float(int(seed * 7.0)) * 0.0015
	mm.set_instance_transform(i, box_transform(b, lift))
	mm.set_instance_color(i, tint)
	var floors := float(b["y1"]) - float(b["y0"])
	var rows := 1.0
	match style:
		1, 3:
			rows = 1.0 if floors <= 2.0 else 2.0
		2:
			rows = 2.0 if floors <= 3.0 else 3.0
		11:
			rows = 3.0
	mm.set_instance_custom_data(i, Color(style, seed, 1.0 if backdrop else 0.0, rows))


## One static body with a box per solid thing in the play area: what the
## client's vision rays (physics) hit is exactly what the rules trace.
func _build_solids_physics(layout: CityLayout) -> void:
	var body := StaticBody3D.new()
	body.name = "Solids"
	body.collision_layer = COLLISION_LAYER
	body.collision_mask = 0
	for list in [layout.buildings, layout.solids, layout.decks]:
		for b in list:
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			var h: Vector2 = b["h"]
			box.size = Vector3(2.0 * h.x, float(b["y1"]) - float(b["y0"]), 2.0 * h.y)
			shape.shape = box
			var c: Vector2 = b["c"]
			shape.transform = Transform3D(Basis(Vector3.UP, -float(b["a"])),
				Vector3(c.x, HexCoord.GROUND_Y + (float(b["y0"]) + float(b["y1"])) * 0.5, c.y))
			body.add_child(shape)
	add_child(body)


## Taps: a thin body on every roof (meta floors / index, as CityBoard.pick
## expects) and a body over every sealed solid (floors -1: nobody stands
## there).
func _build_picks(layout: CityLayout) -> void:
	var root := Node3D.new()
	root.name = "Picks"
	add_child(root)
	for i in layout.buildings.size():
		var b: Dictionary = layout.buildings[i]
		_pick_body(root, b, int(b["floors"]), i, float(b["floors"]) - 0.025, float(b["floors"]) + 0.025)
	for b in layout.solids:
		_pick_body(root, b, -1, -1, 0.0, float(b["y1"]))


func _pick_body(root: Node3D, b: Dictionary, floors: int, index: int, y0: float, y1: float) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = PICK_LAYER
	body.collision_mask = 0
	body.set_meta(&"floors", floors)
	body.set_meta(&"index", index)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var h: Vector2 = b["h"]
	box.size = Vector3(2.0 * h.x, y1 - y0, 2.0 * h.y)
	shape.shape = box
	body.add_child(shape)
	var c: Vector2 = b["c"]
	body.transform = Transform3D(Basis(Vector3.UP, -float(b["a"])), Vector3(c.x, HexCoord.GROUND_Y + (y0 + y1) * 0.5, c.y))
	root.add_child(body)


## Rooftop clutter (AC units, water tanks, stair housings), kept to the
## corners so characters on roofs stay visible.
func _build_roof_props(inst: Array) -> void:
	var st := LowPoly.begin()
	var grey := Color(0.55, 0.56, 0.58)
	for e in inst:
		var b: Dictionary = e[0]
		if int(b["kind"]) != CityBox.Kind.BUILDING or int(b["floors"]) < 2:
			continue
		var h: Vector2 = b["h"]
		if h.x * h.y < 2.2 or h.x < 0.9 or h.y < 0.9:
			continue
		var c: Vector2 = b["c"]
		var r := fposmod(sin(c.x * 3.1 + c.y * 7.7) * 9731.17, 1.0)
		var roof := HexCoord.GROUND_Y + float(b["floors"])
		var basis := Basis(Vector3.UP, -float(b["a"]))
		var corner := Vector2(h.x - 0.45, h.y - 0.4) * Vector2(1 if r < 0.5 else -1, 1 if fposmod(r * 7.0, 1.0) < 0.5 else -1)
		var p := CityBox.to_world(b, corner)
		if r < 0.45:
			LowPoly.box(st, Vector3(p.x, roof + 0.16, p.y), Vector3(0.28, 0.16, 0.22), grey, basis)
		elif r < 0.75:
			LowPoly.prism(st, Vector3(p.x, roof, p.y), 0.24, 0.42, Color(0.72, 0.78, 0.82), 8)
		else:
			LowPoly.box(st, Vector3(p.x, roof + 0.22, p.y), Vector3(0.36, 0.22, 0.3), Color(0.68, 0.67, 0.64), basis)
		if h.x * h.y > 9.0:
			var q := CityBox.to_world(b, -corner * 0.55)
			LowPoly.box(st, Vector3(q.x, roof + 0.1, q.y), Vector3(0.2, 0.1, 0.16), grey, basis)
	var mi := MeshInstance3D.new()
	mi.name = "RoofProps"
	mi.mesh = st.commit()
	mi.material_override = _lit
	add_child(mi)


# --- Boundary -------------------------------------------------------------------

## The simulation boundary along the zone's edge: a red line on the ground
## and a low translucent red curtain rising from it, so the edge reads from
## any angle and through the gaps between buildings. (Everything outside is
## shaded out by the city shaders.)
func _build_frame() -> void:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var st := LowPoly.begin()
	var gy := HexCoord.GROUND_Y
	var line := Color(2.2, 0.18, 0.12, 1.0)
	var foot := Color(0.9, 0.05, 0.04, 0.3)
	var top := Color(0.9, 0.05, 0.04, 0.0)
	var w := 0.16
	var ring := PackedVector2Array()
	for p in zone:
		if ring.is_empty() or ring[ring.size() - 1].distance_to(p) > 0.01:
			ring.append(p)
	if ring.size() > 1 and ring[0].distance_to(ring[ring.size() - 1]) <= 0.01:
		ring.remove_at(ring.size() - 1)
	var inner := inset_ring(ring, w)
	var n := ring.size()
	for k in n:
		var a := ring[k]
		var b := ring[(k + 1) % n]
		var nrm := (b - a).normalized().orthogonal()
		var inward := nrm if Geometry2D.is_point_in_polygon((a + b) * 0.5 + nrm * 0.05, ring) else -nrm
		# One clean band on the ground just inside the edge, mitred at the
		# corners so the line runs straight and unbroken.
		var ia := inner[k]
		var ib := inner[(k + 1) % n]
		LowPoly.face(st, [Vector3(a.x, gy + 0.05, a.y), Vector3(b.x, gy + 0.05, b.y),
			Vector3(ib.x, gy + 0.05, ib.y), Vector3(ia.x, gy + 0.05, ia.y)], line, Vector3.UP)
		# Curtain: fades out upward.
		var h := 0.65
		var verts := [Vector3(a.x, gy, a.y), Vector3(b.x, gy, b.y), Vector3(b.x, gy + h, b.y), Vector3(a.x, gy + h, a.y)]
		var cols := [foot, foot, top, top]
		for t in [[0, 1, 2], [0, 2, 3]]:
			for idx in t:
				st.set_color(cols[idx])
				st.set_normal(Vector3(inward.x, 0, inward.y))
				st.add_vertex(verts[idx])
	var mi := MeshInstance3D.new()
	mi.name = "Boundary"
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## `ring` moved `w` inward at every corner (mitre joints, capped so a sharp
## corner doesn't spike).
static func inset_ring(ring: PackedVector2Array, w: float) -> PackedVector2Array:
	var n := ring.size()
	if n < 3:
		return ring
	# Which side is in: test the longest edge.
	var lk := 0
	for k in n:
		if ring[k].distance_to(ring[(k + 1) % n]) > ring[lk].distance_to(ring[(lk + 1) % n]):
			lk = k
	var e0 := ring[(lk + 1) % n] - ring[lk]
	var probe := (ring[lk] + ring[(lk + 1) % n]) * 0.5 + e0.normalized().orthogonal() * 0.05
	var sgn := 1.0 if Geometry2D.is_point_in_polygon(probe, ring) else -1.0
	var out := PackedVector2Array()
	for k in n:
		var p := ring[k]
		var d0 := (p - ring[(k - 1 + n) % n]).normalized()
		var d1 := (ring[(k + 1) % n] - p).normalized()
		# Inward normals of the two edges.
		var n0 := d0.orthogonal() * sgn
		var n1 := d1.orthogonal() * sgn
		var m := n0 + n1
		if m.length() < 1e-3:
			out.append(p + n0 * w)
			continue
		m = m.normalized()
		var scale := minf(w / maxf(m.dot(n0), 0.35), w * 3.0)
		out.append(p + m * scale)
	return out
