class_name TokyoProps
extends RefCounted
## Street furniture and landmarks of a Tokyo district, low-poly and purely
## visual: everything here is either below eye height (vending machines,
## fences), thin (poles, wires, signs on walls), or matches the gameplay
## boxes it decorates (temple roofs, gates), so the rules' line of sight
## still matches what you see.
##
## Instanced with MultiMesh wherever a prop repeats.

const LAMP_LIGHTS := 10
const NEON := [
	Color(1.6, 0.35, 0.85), Color(0.35, 1.4, 1.7), Color(1.7, 1.35, 0.35),
	Color(1.5, 1.5, 1.6), Color(1.8, 0.65, 0.2), Color(0.45, 1.6, 0.6),
]
const VERMILION := Color(0.82, 0.22, 0.12)


static func build(parent: Node3D, d: TokyoDistrict, play: Rect2, lit: Material, glow: Material, layout: CityLayout) -> void:
	var root := Node3D.new()
	root.name = "Props"
	parent.add_child(root)
	var p: Dictionary = d.props
	_trees(root, p.get("tree", []), lit)
	_lamps(root, p.get("lamp", []), lit, glow, play)
	_poles(root, p.get("pole", []), p.get("wire", []), lit)
	_vending(root, p.get("vending", []), lit, glow)
	_signs(root, p.get("sign", []), glow)
	_signals(root, p.get("signal", []), lit, glow)
	_cars(root, p.get("car", []), lit)
	_torii(root, p.get("torii", []), lit)
	_temples(root, d, lit)
	_boats(root, d, lit, glow)
	for lm in d.landmarks:
		_landmark(root, lm, lit, glow)
	for f in d.far:
		_far(root, d, f, lit, glow)


static func _mm(parent: Node3D, nm: String, mesh: Mesh, xforms: Array, colors: Array, mat: Material, shadows := true) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i] if i < colors.size() else Color.WHITE)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	mmi.material_override = mat
	if not shadows:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)


static func _add_mesh(parent: Node3D, nm: String, st: SurfaceTool, mat: Material, shadows := true) -> void:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = st.commit()
	mi.material_override = mat
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


static func _ground(x: float, z: float) -> Vector3:
	return Vector3(x, HexCoord.GROUND_Y, z)


static func _hash(x: float, z: float, salt := 0.0) -> float:
	return fposmod(sin(x * 12.9898 + z * 78.233 + salt * 37.719) * 43758.5453, 1.0)


# --- Street furniture -------------------------------------------------------------

static func _trees(root: Node3D, rows: Array, lit: Material) -> void:
	var trunk := LowPoly.begin()
	LowPoly.prism(trunk, Vector3.ZERO, 0.07, 0.55, Color(0.38, 0.28, 0.2), 5, 0.05)
	var crown := LowPoly.begin()
	LowPoly.blob(crown, Vector3(0, 0.95, 0), Vector3(0.52, 0.48, 0.52), Color(0.85, 0.85, 0.85), 0.18)
	var xf: Array = []
	var cols: Array = []
	for t in rows:
		var s := float(t[2])
		var h := _hash(t[0], t[1])
		xf.append(Transform3D(Basis(Vector3.UP, h * TAU) * Basis.from_scale(Vector3(s, s * (0.9 + 0.25 * h), s)), _ground(t[0], t[1])))
		# Mostly greens; avenue trees (smaller) are often ginkgo, gold in
		# autumn, and a few maples turn red.
		var c := Color(0.3, 0.52, 0.24).lerp(Color(0.2, 0.42, 0.22), h)
		if s < 0.97 and h < 0.55:
			c = Color(0.93, 0.74, 0.2).lerp(Color(0.85, 0.62, 0.16), h * 2.0)
		elif h > 0.9:
			c = Color(0.78, 0.28, 0.14)
		cols.append(c)
	_mm(root, "TreeTrunks", trunk.commit(), xf, [], lit)
	_mm(root, "TreeCrowns", crown.commit(), xf, cols, lit)


static func _lamps(root: Node3D, rows: Array, lit: Material, glow: Material, play: Rect2) -> void:
	var pole := LowPoly.begin()
	LowPoly.prism(pole, Vector3.ZERO, 0.035, 1.25, Color(0.2, 0.21, 0.24), 6, 0.028)
	LowPoly.box(pole, Vector3(0.14, 1.22, 0), Vector3(0.16, 0.02, 0.02), Color(0.2, 0.21, 0.24))
	var head := LowPoly.begin()
	LowPoly.box(head, Vector3(0.28, 1.19, 0), Vector3(0.07, 0.025, 0.05), Color(1.8, 1.45, 0.95), Basis.IDENTITY, Color(0, 0, 0, 0), false)
	var xf: Array = []
	for l in rows:
		xf.append(Transform3D(Basis(Vector3.UP, -float(l[2])), _ground(l[0], l[1])))
	_mm(root, "LampPoles", pole.commit(), xf, [], lit)
	_mm(root, "LampHeads", head.commit(), xf, [], glow, false)
	# A few real lights near the play area (pools of warm light on the street).
	var center := play.get_center()
	var near: Array = []
	for i in rows.size():
		var q := Vector2(rows[i][0], rows[i][1])
		if play.grow(3.0).has_point(q):
			near.append([q.distance_squared_to(center), i])
	near.sort()
	for k in mini(LAMP_LIGHTS, near.size()):
		var t: Transform3D = xf[near[k][1]]
		var light := OmniLight3D.new()
		light.position = t * Vector3(0.28, 1.12, 0)
		light.light_color = Color(1.0, 0.8, 0.55)
		light.light_energy = 1.1
		light.omni_range = 3.0
		light.omni_attenuation = 1.6
		root.add_child(light)


static func _poles(root: Node3D, poles: Array, wires: Array, lit: Material) -> void:
	var mesh := LowPoly.begin()
	var concrete := Color(0.6, 0.6, 0.58)
	LowPoly.prism(mesh, Vector3.ZERO, 0.055, 2.3, concrete, 6, 0.04)
	LowPoly.box(mesh, Vector3(0, 2.15, 0), Vector3(0.025, 0.025, 0.28), Color(0.3, 0.3, 0.32))
	LowPoly.prism(mesh, Vector3(0.09, 1.75, 0), 0.07, 0.2, Color(0.5, 0.52, 0.5), 6)
	var xf: Array = []
	for p in poles:
		xf.append(Transform3D(Basis(Vector3.UP, _hash(p[0], p[1]) * 0.5), _ground(p[0], p[1])))
	_mm(root, "UtilityPoles", mesh.commit(), xf, [], lit)
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
	var wx: Array = []
	var wc: Array = []
	for w in wires:
		var a := Vector3(w[0], HexCoord.GROUND_Y, w[1])
		var b := Vector3(w[2], HexCoord.GROUND_Y, w[3])
		var d := b - a
		var length := d.length()
		if length < 0.1:
			continue
		var ang := atan2(d.z, d.x)
		for y in [2.12, 1.96]:
			var basis := Basis(Vector3.UP, -ang) * Basis.from_scale(Vector3(length, 0.018, 0.018))
			wx.append(Transform3D(basis, (a + b) * 0.5 + Vector3(0, y, 0)))
			wc.append(Color(0.12, 0.12, 0.13))
	_mm(root, "Wires", unit, wx, wc, lit, false)


static func _vending(root: Node3D, rows: Array, lit: Material, glow: Material) -> void:
	var body := LowPoly.begin()
	LowPoly.box(body, Vector3(0, 0.36, 0), Vector3(0.13, 0.36, 0.17), Color.WHITE)
	var panel := LowPoly.begin()
	LowPoly.box(panel, Vector3(0.135, 0.46, 0), Vector3(0.008, 0.2, 0.13), Color(1.35, 1.45, 1.6), Basis.IDENTITY, Color(0, 0, 0, 0), false)
	var xf: Array = []
	var cols: Array = []
	var kinds := [Color(0.85, 0.12, 0.12), Color(0.92, 0.92, 0.9), Color(0.15, 0.35, 0.75), Color(0.2, 0.55, 0.3)]
	for v in rows:
		xf.append(Transform3D(Basis(Vector3.UP, -float(v[2])), _ground(v[0], v[1])))
		cols.append(kinds[int(v[3]) % kinds.size()])
	_mm(root, "VendingMachines", body.commit(), xf, cols, lit)
	_mm(root, "VendingPanels", panel.commit(), xf, [], glow, false)


static func _signs(root: Node3D, rows: Array, glow: Material) -> void:
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
	var xf: Array = []
	var cols: Array = []
	for s in rows:
		var ang := float(s[2])
		var w := float(s[3])
		var h := float(s[4])
		var y := HexCoord.GROUND_Y + float(s[5])
		var basis := Basis(Vector3.UP, -ang)
		if int(s[7]) == 0:
			basis = basis * Basis.from_scale(Vector3(w, h, 0.06))   # blade: sticks out from the wall
		else:
			basis = basis * Basis.from_scale(Vector3(0.05, h, w))   # screen: flat on the wall
		xf.append(Transform3D(basis, Vector3(s[0], y, s[1])))
		var c: Color = NEON[int(s[6]) % NEON.size()]
		if int(s[7]) == 1:
			c = c.lerp(Color(1.3, 1.35, 1.5), 0.45)
		cols.append(c)
	_mm(root, "Signs", unit, xf, cols, glow, false)


## Parked cars: a low-poly body and cabin, length along local z.
static func _cars(root: Node3D, rows: Array, lit: Material) -> void:
	var st := LowPoly.begin()
	LowPoly.box(st, Vector3(0, 0.16, 0), Vector3(0.32, 0.12, 0.78), Color.WHITE)
	LowPoly.box(st, Vector3(0, 0.34, -0.05), Vector3(0.28, 0.08, 0.44), Color(0.75, 0.78, 0.82), Basis.IDENTITY, Color(0.85, 0.85, 0.85))
	var paints := [Color(0.92, 0.92, 0.9), Color(0.15, 0.16, 0.18), Color(0.62, 0.64, 0.66), Color(0.7, 0.14, 0.12),
		Color(0.2, 0.3, 0.55), Color(0.85, 0.85, 0.8), Color(0.4, 0.42, 0.45), Color(0.9, 0.75, 0.3)]
	var xf: Array = []
	var cols: Array = []
	for c in rows:
		xf.append(Transform3D(Basis(Vector3.UP, -float(c[2])), _ground(c[0], c[1])))
		cols.append(paints[int(c[3]) % paints.size()])
	_mm(root, "Cars", st.commit(), xf, cols, lit)


static func _signals(root: Node3D, rows: Array, lit: Material, glow: Material) -> void:
	var mesh := LowPoly.begin()
	var grey := Color(0.32, 0.33, 0.36)
	LowPoly.prism(mesh, Vector3.ZERO, 0.035, 1.55, grey, 6)
	LowPoly.box(mesh, Vector3(0, 1.5, 0.28), Vector3(0.02, 0.02, 0.3), grey)
	LowPoly.box(mesh, Vector3(0, 1.48, 0.52), Vector3(0.06, 0.05, 0.16), Color(0.2, 0.22, 0.25))
	var lamp := LowPoly.begin()
	LowPoly.box(lamp, Vector3(0.065, 1.48, 0.62), Vector3(0.005, 0.03, 0.03), Color(0.3, 1.6, 0.9), Basis.IDENTITY, Color(0, 0, 0, 0), false)
	var xf: Array = []
	for s in rows:
		xf.append(Transform3D(Basis(Vector3.UP, -float(s[2])), _ground(s[0], s[1])))
	_mm(root, "Signals", mesh.commit(), xf, [], lit)
	_mm(root, "SignalLamps", lamp.commit(), xf, [], glow, false)


static func _torii(root: Node3D, rows: Array, lit: Material) -> void:
	var st := LowPoly.begin()
	_torii_mesh(st, Vector3.ZERO, 1.0, Basis.IDENTITY)
	var xf: Array = []
	for t in rows:
		var s := float(t[3])
		xf.append(Transform3D(Basis(Vector3.UP, -float(t[2])) * Basis.from_scale(Vector3(s, s, s)), _ground(t[0], t[1])))
	_mm(root, "Torii", st.commit(), xf, [], lit)


## A torii, its passage along local x.
static func _torii_mesh(st: SurfaceTool, at: Vector3, s: float, basis: Basis) -> void:
	for side in [-1.0, 1.0]:
		LowPoly.prism(st, at + basis * Vector3(0, 0, side * 0.45 * s), 0.06 * s, 1.12 * s, VERMILION, 8)
	LowPoly.box(st, at + basis * Vector3(0, 1.16 * s, 0), Vector3(0.07, 0.04, 0.68) * s, Color(0.12, 0.1, 0.1), basis)
	LowPoly.box(st, at + basis * Vector3(0, 1.08 * s, 0), Vector3(0.06, 0.04, 0.62) * s, VERMILION, basis)
	LowPoly.box(st, at + basis * Vector3(0, 0.88 * s, 0), Vector3(0.04, 0.035, 0.54) * s, VERMILION, basis)


# --- Boats ------------------------------------------------------------------------

## Boats on the larger rivers: yakatabune (low wooden pleasure boats with
## red lanterns) and water buses, lined up with the current and bobbing.
static func _boats(root: Node3D, d: TokyoDistrict, lit: Material, glow: Material) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(d.id + "boats")
	var water_y := HexCoord.GROUND_Y - TokyoGround.WATER_DEPTH
	var placed: Array[Vector2] = []
	for w in d.water:
		var rings: Array = w["rings"]
		if rings.is_empty():
			continue
		var ring: PackedVector2Array = rings[0]
		var tris: PackedFloat32Array = w["tris"]
		var area := 0.0
		for i in range(0, tris.size() - 5, 6):
			area += absf((tris[i + 2] - tris[i]) * (tris[i + 5] - tris[i + 1]) - (tris[i + 4] - tris[i]) * (tris[i + 3] - tris[i + 1])) * 0.5
		if area < 250.0:
			continue
		var want := mini(6, int(area / 700.0) + 1)
		var tries := 0
		while want > 0 and tries < 200:
			tries += 1
			# A random point in a random (area-weighted) triangle.
			var pick := rng.randf() * area
			var i := 0
			while i < tris.size() - 6:
				var ta := absf((tris[i + 2] - tris[i]) * (tris[i + 5] - tris[i + 1]) - (tris[i + 4] - tris[i]) * (tris[i + 3] - tris[i + 1])) * 0.5
				if pick <= ta:
					break
				pick -= ta
				i += 6
			var r1 := rng.randf()
			var r2 := rng.randf()
			if r1 + r2 > 1.0:
				r1 = 1.0 - r1
				r2 = 1.0 - r2
			var a := Vector2(tris[i], tris[i + 1])
			var p := a + (Vector2(tris[i + 2], tris[i + 3]) - a) * r1 + (Vector2(tris[i + 4], tris[i + 5]) - a) * r2
			if p.x < 3 or p.y < 3 or p.x > d.size.x - 3 or p.y > d.size.y - 3:
				continue
			# Clear of the banks and of other boats; heading along the bank.
			var nearest := INF
			var heading := 0.0
			for k in ring.size():
				var q0 := ring[k]
				var q1 := ring[(k + 1) % ring.size()]
				var c := Geometry2D.get_closest_point_to_segment(p, q0, q1)
				var dd := c.distance_to(p)
				if dd < nearest:
					nearest = dd
					heading = (q1 - q0).angle()
			if nearest < 2.6:
				continue
			var crowded := false
			for o in placed:
				crowded = crowded or o.distance_to(p) < 7.0
			if crowded:
				continue
			placed.append(p)
			want -= 1
			var boat := Node3D.new()
			boat.name = "Boat"
			boat.position = Vector3(p.x, water_y, p.y)
			boat.rotation.y = -heading + (PI if rng.randf() < 0.5 else 0.0)
			var body := MeshInstance3D.new()
			var lights := MeshInstance3D.new()
			var st := LowPoly.begin()
			var gl := LowPoly.begin()
			if rng.randf() < 0.6:
				_yakatabune(st, gl)
			else:
				_water_bus(st, gl)
			body.mesh = st.commit()
			body.material_override = lit
			lights.mesh = gl.commit()
			lights.material_override = glow
			lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			boat.add_child(body)
			boat.add_child(lights)
			root.add_child(boat)
			if boat.is_inside_tree():
				var tw := boat.create_tween().set_loops()
				var bob := 0.035
				tw.tween_property(boat, "position:y", water_y + bob, 1.6 + rng.randf()).set_trans(Tween.TRANS_SINE)
				tw.tween_property(boat, "position:y", water_y - bob, 1.6 + rng.randf()).set_trans(Tween.TRANS_SINE)


## A yakatabune, about 7 x 1.6 units, its length along local x.
static func _yakatabune(st: SurfaceTool, gl: SurfaceTool) -> void:
	var wood := Color(0.45, 0.3, 0.2)
	LowPoly.frustum(st, Vector3(0, -0.05, 0), Vector2(3.1, 0.7), Vector2(3.5, 0.82), 0.3, wood)
	LowPoly.box(st, Vector3(0.2, 0.45, 0), Vector3(2.6, 0.2, 0.68), Color(0.88, 0.84, 0.74))
	LowPoly.frustum(st, Vector3(0.2, 0.65, 0), Vector2(2.75, 0.8), Vector2(2.3, 0.22), 0.28, Color(0.24, 0.22, 0.24))
	# Paper windows glowing warm, and a row of red lanterns under the eaves.
	LowPoly.box(gl, Vector3(0.2, 0.46, 0.69), Vector3(2.3, 0.09, 0.005), Color(1.7, 1.25, 0.7), Basis.IDENTITY, Color(0, 0, 0, 0), false)
	LowPoly.box(gl, Vector3(0.2, 0.46, -0.69), Vector3(2.3, 0.09, 0.005), Color(1.7, 1.25, 0.7), Basis.IDENTITY, Color(0, 0, 0, 0), false)
	for k in 6:
		for s in [-1.0, 1.0]:
			LowPoly.prism(gl, Vector3(-2.1 + k * 0.85, 0.58, s * 0.86), 0.07, 0.13, Color(2.0, 0.35, 0.2), 6)


## A water bus, sleek and white with blue glass.
static func _water_bus(st: SurfaceTool, gl: SurfaceTool) -> void:
	LowPoly.frustum(st, Vector3(0, -0.05, 0), Vector2(3.0, 0.75), Vector2(3.4, 0.9), 0.35, Color(0.9, 0.92, 0.94))
	LowPoly.frustum(st, Vector3(-0.2, 0.3, 0), Vector2(2.4, 0.7), Vector2(1.9, 0.5), 0.36, Color(0.3, 0.5, 0.72))
	LowPoly.box(st, Vector3(-0.2, 0.69, 0), Vector3(1.85, 0.03, 0.48), Color(0.92, 0.93, 0.95))
	LowPoly.box(gl, Vector3(-0.2, 0.48, 0), Vector3(2.0, 0.07, 0.62), Color(0.7, 1.3, 1.8), Basis.IDENTITY, Color(0, 0, 0, 0), false)


# --- Temples, pagodas -----------------------------------------------------------

## Hipped tile roofs on temple halls (the hall body is a solid box drawn
## by TokyoCity up to the eaves), and five-storey pagodas.
static func _temples(root: Node3D, d: TokyoDistrict, lit: Material) -> void:
	var st := LowPoly.begin()
	var tiles := Color(0.24, 0.25, 0.28)
	var any := false
	for b in d.solids:
		var style := int(b["style"])
		var h: Vector2 = b["h"]
		var c: Vector2 = b["c"]
		var top := float(b["y1"])
		if style == TokyoDistrict.SolidStyle.TEMPLE:
			any = true
			var eave := top * TokyoCity.TEMPLE_EAVE
			LowPoly.frustum(st, Vector3(c.x, HexCoord.GROUND_Y + eave, c.y), h * 1.16, Vector2(h.x * 0.55, h.y * 0.12),
				top - eave, tiles, -float(b["a"]))
		elif style == TokyoDistrict.SolidStyle.PAGODA:
			any = true
			var r := minf(h.x, h.y)
			var y := HexCoord.GROUND_Y
			var tier_h := (top - 1.0) / 5.0
			for k in 5:
				var bh := r * (1.0 - 0.1 * k)
				LowPoly.box(st, Vector3(c.x, y + tier_h * 0.35, c.y), Vector3(bh * 0.7, tier_h * 0.35, bh * 0.7), VERMILION,
					Basis(Vector3.UP, -float(b["a"])))
				LowPoly.frustum(st, Vector3(c.x, y + tier_h * 0.7, c.y), Vector2(bh * 1.45, bh * 1.45), Vector2(bh * 0.75, bh * 0.75),
					tier_h * 0.3, tiles, -float(b["a"]))
				y += tier_h
			LowPoly.prism(st, Vector3(c.x, y, c.y), 0.07, 1.0, Color(0.7, 0.6, 0.3), 6, 0.02)
	if any:
		_add_mesh(root, "TempleRoofs", st, lit)


# --- Landmarks ------------------------------------------------------------------

static func _landmark(root: Node3D, lm: Dictionary, lit: Material, glow: Material) -> void:
	var p: Vector2 = lm["pos"]
	var a: float = lm["rot"]
	var basis := Basis(Vector3.UP, -a)
	var at := _ground(p.x, p.y)
	match lm["type"]:
		"tokyo_tower":
			var st := LowPoly.begin()
			_tokyo_tower(st, at)
			_add_mesh(root, "TokyoTower", st, lit)
			var beacon := LowPoly.begin()
			var md := _tower_half(0.43) + 1.42
			LowPoly.box(beacon, at + Vector3(0, TOWER_H * 0.43 + 1.25, 0), Vector3(md, 0.25, md), Color(1.9, 1.35, 0.7))
			var tdk := _tower_half(0.73) + 0.92
			LowPoly.box(beacon, at + Vector3(0, TOWER_H * 0.73 + 0.65, 0), Vector3(tdk, 0.15, tdk), Color(1.6, 1.4, 1.9))
			LowPoly.box(beacon, at + Vector3(0, TOWER_H + 0.2, 0), Vector3(0.25, 0.25, 0.25), Color(2.4, 0.3, 0.2))
			_add_mesh(root, "TokyoTowerLights", beacon, glow, false)
		"kaminarimon":
			var st := LowPoly.begin()
			# Roof over the two halls and the passage (the deck in the rules).
			LowPoly.box(st, at + Vector3(0, 2.15, 0), Vector3(1.7, 0.15, 2.7), Color(0.18, 0.12, 0.1), basis)
			LowPoly.frustum(st, at + Vector3(0, 2.3, 0), Vector2(2.1, 3.3), Vector2(0.5, 2.3), 0.8, Color(0.22, 0.23, 0.26), -a)
			# The great red lantern.
			LowPoly.prism(st, at + Vector3(0, 1.22, 0), 0.4, 0.7, Color(0.85, 0.14, 0.1), 10, 0.4)
			LowPoly.prism(st, at + Vector3(0, 1.12, 0), 0.3, 0.1, Color(0.12, 0.1, 0.1), 10)
			LowPoly.prism(st, at + Vector3(0, 1.92, 0), 0.3, 0.12, Color(0.12, 0.1, 0.1), 10)
			_add_mesh(root, "Kaminarimon", st, lit)
		"kabukicho_gate":
			var st := LowPoly.begin()
			LowPoly.box(st, at + Vector3(0, 2.375, 0), Vector3(0.12, 0.325, 2.3), Color(2.0, 0.35, 0.45), basis)
			_add_mesh(root, "KabukichoSign", st, glow, false)


## Tokyo Tower as a lattice: the real 80 m base (32 units), about 85 units
## tall. Four corner members follow the tower's curved taper, open arches
## between the legs at the bottom, cross bracing and ring beams on every
## face, international orange and white bands, the Main Deck and Top Deck,
## and the antenna.
const TOWER_H := 85.0
const TOWER_ORANGE := Color(0.95, 0.33, 0.1)
const TOWER_WHITE := Color(0.95, 0.94, 0.92)


static func _tower_half(t: float) -> float:
	return 0.9 + 15.1 * exp(-3.5 * t)


static func _tower_color(t: float) -> Color:
	return TOWER_ORANGE if int(floor(t * 11.0)) % 2 == 0 else TOWER_WHITE


static func _tokyo_tower(st: SurfaceTool, at: Vector3) -> void:
	var top_t := 0.8
	var segs := 26
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for k in segs:
		var t0 := top_t * k / segs
		var t1 := top_t * (k + 1) / segs
		var y0 := TOWER_H * t0
		var y1 := TOWER_H * t1
		var w0 := _tower_half(t0)
		var w1 := _tower_half(t1)
		var col := _tower_color((t0 + t1) * 0.5)
		var thick := lerpf(0.75, 0.28, t0 / top_t)
		var p0: Array = []
		var p1: Array = []
		for c in corners:
			p0.append(at + Vector3(c.x * w0, y0, c.y * w0))
			p1.append(at + Vector3(c.x * w1, y1, c.y * w1))
		for i in 4:
			# Corner member.
			_beam(st, p0[i], p1[i], thick, col)
			var j := (i + 1) % 4
			if t0 < 0.07:
				continue   # the open arches between the legs
			# Ring beam and X bracing on the face between corners i and j.
			_beam(st, p1[i], p1[j], thick * 0.6, col)
			_beam(st, p0[i], p1[j], thick * 0.45, col)
			_beam(st, p0[j], p1[i], thick * 0.45, col)
	# Arches over the legs at the base.
	var arch_t := 0.07
	for i in 4:
		var j := (i + 1) % 4
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[j]
		var prev := Vector3.INF
		for k in 9:
			var u := float(k) / 8.0
			var wa := _tower_half(arch_t * (1.0 - sin(u * PI)) * 0.0 + arch_t)
			var p := a.lerp(b, u) * wa
			var y := TOWER_H * arch_t * (0.45 + 0.55 * sin(u * PI))
			var q := at + Vector3(p.x, y, p.y)
			if prev != Vector3.INF:
				_beam(st, prev, q, 0.45, TOWER_ORANGE)
			prev = q
	# Main Deck (two floors) and Top Deck.
	var md := _tower_half(0.43) + 1.4
	LowPoly.box(st, at + Vector3(0, TOWER_H * 0.43 + 1.0, 0), Vector3(md, 1.0, md), TOWER_WHITE, Basis.IDENTITY, Color(0.8, 0.8, 0.8), false)
	LowPoly.box(st, at + Vector3(0, TOWER_H * 0.43 + 2.6, 0), Vector3(md - 0.6, 0.6, md - 0.6), TOWER_WHITE)
	var tdk := _tower_half(0.73) + 0.9
	LowPoly.box(st, at + Vector3(0, TOWER_H * 0.73 + 0.6, 0), Vector3(tdk, 0.6, tdk), TOWER_WHITE, Basis.IDENTITY, Color(0.8, 0.8, 0.8), false)
	# Antenna: banded, tapering to the top.
	var y := TOWER_H * top_t
	var r := _tower_half(top_t) * 0.75
	var n := 6
	for k in n:
		var h := (TOWER_H - y) / float(n - k) if k == n - 1 else (TOWER_H * (1.0 - top_t)) / n
		LowPoly.prism(st, at + Vector3(0, y, 0), r, h, TOWER_ORANGE if k % 2 == 0 else TOWER_WHITE, 6, r * 0.78)
		y += h
		r *= 0.78


## An oriented square beam from `a` to `b`, `thick` across.
static func _beam(st: SurfaceTool, a: Vector3, b: Vector3, thick: float, color: Color) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.001:
		return
	var x := d / length
	var up := Vector3.UP if absf(x.y) < 0.95 else Vector3.RIGHT
	var z := x.cross(up).normalized()
	var yv := z.cross(x).normalized()
	LowPoly.box(st, (a + b) * 0.5, Vector3(length * 0.5, thick * 0.5, thick * 0.5), color, Basis(x, yv, z), Color(0, 0, 0, 0), false)


## A slanted square leg from `a` (bottom) to `b` (top).
static func _leg(st: SurfaceTool, a: Vector3, b: Vector3, ra: float, rb: float, color: Color) -> void:
	var lo: Array = []
	var hi: Array = []
	for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		lo.append(a + Vector3(s.x * ra, 0, s.y * ra))
		hi.append(b + Vector3(s.x * rb, 0, s.y * rb))
	var center := (a + b) * 0.5
	for i in 4:
		var j := (i + 1) % 4
		var mid: Vector3 = ((lo[i] as Vector3) + (lo[j] as Vector3) + (hi[i] as Vector3) + (hi[j] as Vector3)) / 4.0
		LowPoly.face(st, [lo[i], lo[j], hi[j], hi[i]], color, mid - center)


## Distant skyline landmarks, outside the district (compressed distance).
static func _far(root: Node3D, d: TokyoDistrict, f: Dictionary, lit: Material, glow: Material) -> void:
	var bearing := deg_to_rad(float(f.get("bearing_deg", 0)))
	var dist := float(f.get("dist_u", 150))
	# `dir`: the bearing in the district's (turned) frame, from the build.
	var dir := Vector2(sin(bearing), -cos(bearing))
	if f.get("dir") is Array:
		dir = Vector2(float(f["dir"][0]), float(f["dir"][1]))
	var c := d.size * 0.5 + dir * dist
	var at := _ground(c.x, c.y)
	match str(f.get("type", "")):
		"skytree":
			var st := LowPoly.begin()
			var white := Color(0.86, 0.89, 0.94)
			LowPoly.prism(st, at, 4.0, 18.0, white, 3, 2.2, false)
			LowPoly.prism(st, at + Vector3(0, 18, 0), 2.2, 22.0, white, 9, 1.5, false)
			LowPoly.prism(st, at + Vector3(0, 40, 0), 2.9, 2.2, Color(0.55, 0.62, 0.72), 12, 2.9)
			LowPoly.prism(st, at + Vector3(0, 42.2, 0), 1.4, 9.0, white, 9, 1.1, false)
			LowPoly.prism(st, at + Vector3(0, 51.2, 0), 1.9, 1.2, Color(0.55, 0.62, 0.72), 12, 1.9)
			LowPoly.prism(st, at + Vector3(0, 52.4, 0), 0.9, 10.0, white, 8, 0.3)
			LowPoly.prism(st, at + Vector3(0, 62.4, 0), 0.25, 5.0, white, 6, 0.05)
			_add_mesh(root, "Skytree", st, lit, false)
			var lights := LowPoly.begin()
			LowPoly.prism(lights, at + Vector3(0, 41.0, 0), 2.95, 0.25, Color(0.6, 1.0, 1.8), 12, 2.95)
			LowPoly.prism(lights, at + Vector3(0, 51.7, 0), 1.95, 0.2, Color(1.2, 0.6, 1.8), 12, 1.95)
			_add_mesh(root, "SkytreeLights", lights, glow, false)
