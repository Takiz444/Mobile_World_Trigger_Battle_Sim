class_name LowPoly
extends RefCounted
## Tiny mesh kit for the low-poly city: flat-shaded faces with vertex colors
## (every prop shares one or two materials, which keeps the Web build's
## shader count low). All helpers append to a SurfaceTool begun with
## PRIMITIVE_TRIANGLES.

## A flat polygon (convex, points in order) facing `outward`.
static func face(st: SurfaceTool, pts: Array, color: Color, outward: Vector3) -> void:
	var n := outward.normalized()
	for i in range(1, pts.size() - 1):
		var a: Vector3 = pts[0]
		var b: Vector3 = pts[i]
		var c: Vector3 = pts[i + 1]
		# Godot's front faces wind clockwise as seen from outside.
		if (b - a).cross(c - a).dot(n) > 0.0:
			var t := b
			b = c
			c = t
		st.set_color(color)
		st.set_normal(n)
		st.add_vertex(a)
		st.add_vertex(b)
		st.add_vertex(c)


static func tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color, center: Vector3) -> void:
	var mid := (a + b + c) / 3.0
	var n := (b - a).cross(c - a)
	if n.dot(mid - center) < 0.0:
		n = -n
	face(st, [a, b, c], color, n)


## An oriented box: `basis` columns are its axes (unit), `half` extents.
static func box(st: SurfaceTool, center: Vector3, half: Vector3, color: Color, basis := Basis.IDENTITY,
		top_color := Color(0, 0, 0, 0), skip_bottom := true) -> void:
	var ax := basis.x * half.x
	var ay := basis.y * half.y
	var az := basis.z * half.z
	var top := color if top_color.a == 0.0 else top_color
	var sides := [
		[ax, ay, az, color], [-ax, ay, az, color],
		[az, ax, ay, color], [-az, ax, ay, color],
		[ay, ax, az, top], [-ay, ax, az, color],
	]
	for i in sides.size():
		if skip_bottom and i == 5:
			continue
		var s: Array = sides[i]
		var nrm: Vector3 = s[0]
		var u: Vector3 = s[1]
		var v: Vector3 = s[2]
		var c := center + nrm
		face(st, [c - u - v, c + u - v, c + u + v, c - u + v], s[3], nrm)


## A frustum from a rectangle (half extents `hb`) at `base` to `ht` at
## base + up * height, rotated by `yaw`. Roofs, tower sections.
static func frustum(st: SurfaceTool, base: Vector3, hb: Vector2, ht: Vector2, height: float, color: Color,
		yaw: float = 0.0, cap := true, top_color := Color(0, 0, 0, 0)) -> void:
	var b := Basis(Vector3.UP, yaw)
	var lo: Array = []
	var hi: Array = []
	for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		lo.append(base + b * Vector3(s.x * hb.x, 0, s.y * hb.y))
		hi.append(base + b * Vector3(s.x * ht.x, height, s.y * ht.y))
	var center := base + Vector3(0, height * 0.5, 0)
	for i in 4:
		var j := (i + 1) % 4
		var l0: Vector3 = lo[i]
		var l1: Vector3 = lo[j]
		var h0: Vector3 = hi[i]
		var h1: Vector3 = hi[j]
		var quad := [l0, l1, h1, h0]
		var mid: Vector3 = (l0 + l1 + h1 + h0) / 4.0
		var n: Vector3 = (l1 - l0).cross(h0 - l0)
		if n.dot(mid - center) < 0.0:
			n = -n
		if ht.x <= 0.0001 and ht.y <= 0.0001:
			face(st, [lo[i], lo[j], hi[i]], color, n)
		else:
			face(st, quad, color, n)
	if cap and (ht.x > 0.0001 or ht.y > 0.0001):
		face(st, hi, color if top_color.a == 0.0 else top_color, Vector3.UP)


## An n-sided vertical prism (low-poly cylinder) from y0 to y1.
static func prism(st: SurfaceTool, base: Vector3, radius: float, height: float, color: Color, sides := 6,
		top_radius := -1.0, cap := true) -> void:
	var rt := radius if top_radius < 0.0 else top_radius
	var center := base + Vector3(0, height * 0.5, 0)
	var top: Array = []
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var p0 := base + Vector3(cos(a0) * radius, 0, sin(a0) * radius)
		var p1 := base + Vector3(cos(a1) * radius, 0, sin(a1) * radius)
		var q0 := base + Vector3(cos(a0) * rt, height, sin(a0) * rt)
		var q1 := base + Vector3(cos(a1) * rt, height, sin(a1) * rt)
		var mid := (p0 + p1 + q0 + q1) / 4.0
		var n := Vector3(mid.x - center.x, 0, mid.z - center.z)
		face(st, [p0, p1, q1, q0], color, n)
		top.append(q0)
	if cap and rt > 0.0:
		face(st, top, color, Vector3.UP)


## A low-poly blob (icosahedron), slightly squashed: tree canopies.
static func blob(st: SurfaceTool, center: Vector3, radius: Vector3, color: Color, shade := 0.12) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var v := [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	var f := [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
	]
	for tri_i in f:
		var pts: Array = []
		for k in tri_i:
			var p: Vector3 = (v[k] as Vector3).normalized()
			pts.append(center + Vector3(p.x * radius.x, p.y * radius.y, p.z * radius.z))
		var mid: Vector3 = ((pts[0] as Vector3) + (pts[1] as Vector3) + (pts[2] as Vector3)) / 3.0
		# Faces toward the sky are lighter: a faceted low-poly look.
		var k := clampf((mid - center).normalized().y, -1.0, 1.0)
		var c := color.lightened(shade * maxf(k, 0.0)).darkened(shade * maxf(-k, 0.0))
		tri(st, pts[0], pts[1], pts[2], c, center)


static func begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


## The shared lit vertex-color material (MultiMesh instance colors multiply in).
static func lit_material(rough := 0.85) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true   # colors here are authored in sRGB
	m.roughness = rough
	GfxLite.lit(m)
	return m


## Bright unshaded vertex color (neon signs, lamps, screens); colors above 1
## bloom.
static func glow_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m
