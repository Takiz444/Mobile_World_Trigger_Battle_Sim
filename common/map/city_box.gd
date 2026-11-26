class_name CityBox
extends RefCounted
## One box of city geometry: an oriented rectangle on the ground plane (world
## X, Z) extruded between two heights. Everything solid in the city is made
## of these, shared by the rules (walking, line of sight), the server, and the
## renderer, so what blocks you is exactly what you see.
##
## Kinds:
##   BUILDING  enterable: a ground floor inside and a roof at `floors`
##             (y 0..floors); blocks walking and sight.
##   SOLID     sealed (pillars, towers, temples, gate posts): blocks walking
##             and sight (y 0..y1); nobody stands inside or on top.
##   DECK      elevated (rail viaducts, the expressway, gate roofs): blocks
##             sight between y0 and y1 only; you walk underneath.
##
## Boxes are Dictionaries (fast, and easy to cache):
##   c: Vector2 center, h: Vector2 half extents (local x, z), a: angle (the
##   local x axis is Vector2.from_angle(a)), cs / sn: cos / sin of a,
##   kind, floors, y0, y1, style, group (pieces of one building share it),
##   aabb: Rect2 (world bounds of the footprint),
##   axis: true when a == 0 (exact axis-aligned math, used by hex test maps).

enum Kind { BUILDING, SOLID, DECK }


static func make(center: Vector2, half: Vector2, angle: float, kind: int, floors: int = 0,
		y0: float = 0.0, y1: float = -1.0, style: int = 0, group: int = -1) -> Dictionary:
	var b := {
		"c": center, "h": Vector2(maxf(half.x, 0.001), maxf(half.y, 0.001)), "a": angle,
		"cs": cos(angle), "sn": sin(angle),
		"kind": kind, "floors": floors,
		"y0": y0, "y1": float(floors) if y1 < 0.0 else y1,
		"style": style, "group": group,
		"axis": angle == 0.0,
	}
	b["aabb"] = _aabb(b)
	return b


## An enterable building from an axis-aligned world rectangle.
static func from_rect(r: Rect2, floors: int, style: int = 0, group: int = -1) -> Dictionary:
	return make(r.get_center(), r.size * 0.5, 0.0, Kind.BUILDING, floors, 0.0, -1.0, style, group)


## World point -> box-local coordinates (local x along the box's angle).
static func to_local(b: Dictionary, p: Vector2) -> Vector2:
	var d: Vector2 = p - (b["c"] as Vector2)
	if b["axis"]:
		return d
	var cs: float = b["cs"]
	var sn: float = b["sn"]
	return Vector2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs)


static func to_world(b: Dictionary, l: Vector2) -> Vector2:
	if b["axis"]:
		return (b["c"] as Vector2) + l
	var cs: float = b["cs"]
	var sn: float = b["sn"]
	return (b["c"] as Vector2) + Vector2(l.x * cs - l.y * sn, l.x * sn + l.y * cs)


## Direction in world space of a local direction.
static func dir_to_world(b: Dictionary, l: Vector2) -> Vector2:
	if b["axis"]:
		return l
	var cs: float = b["cs"]
	var sn: float = b["sn"]
	return Vector2(l.x * cs - l.y * sn, l.x * sn + l.y * cs)


static func dir_to_local(b: Dictionary, d: Vector2) -> Vector2:
	if b["axis"]:
		return d
	var cs: float = b["cs"]
	var sn: float = b["sn"]
	return Vector2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs)


## The footprint, grown by `grow` on every side, contains `p` (edges count).
static func has_point(b: Dictionary, p: Vector2, grow: float = 0.0) -> bool:
	var aabb: Rect2 = b["aabb"]
	if p.x < aabb.position.x - grow or p.y < aabb.position.y - grow or p.x > aabb.end.x + grow or p.y > aabb.end.y + grow:
		return false
	var l := to_local(b, p)
	var h: Vector2 = b["h"]
	return absf(l.x) <= h.x + grow and absf(l.y) <= h.y + grow


static func corners(b: Dictionary, grow: float = 0.0) -> PackedVector2Array:
	var h: Vector2 = (b["h"] as Vector2) + Vector2(grow, grow)
	var out := PackedVector2Array()
	for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		out.append(to_world(b, h * s))
	return out


static func _aabb(b: Dictionary) -> Rect2:
	var pts := corners(b)
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r


## Segment a -> b (ground plane) touches the footprint grown by `grow`.
## Slab test in the box's frame; touching counts.
static func segment_hits(b: Dictionary, a: Vector2, c: Vector2, grow: float = 0.0) -> bool:
	var aabb: Rect2 = b["aabb"]
	if maxf(a.x, c.x) < aabb.position.x - grow or minf(a.x, c.x) > aabb.end.x + grow \
			or maxf(a.y, c.y) < aabb.position.y - grow or minf(a.y, c.y) > aabb.end.y + grow:
		return false
	var la := to_local(b, a)
	var d := to_local(b, c) - la
	var h: Vector2 = (b["h"] as Vector2) + Vector2(grow, grow)
	var t0 := 0.0
	var t1 := 1.0
	for axis in 2:
		var o := la[axis]
		var v := d[axis]
		var lo := -h[axis]
		var hi := h[axis]
		if absf(v) < 1e-9:
			if o < lo or o > hi:
				return false
			continue
		var ta := (lo - o) / v
		var tb := (hi - o) / v
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return false
	return true


## Parametric overlap [t0, t1] (clamped to [0, 1]) of the 3D segment pa -> pb
## with the box's volume (footprint grown by `pad`, y between y0 and y1), or
## {} if they don't meet. Touching does not count.
static func segment_overlap(b: Dictionary, pa: Vector3, pb: Vector3, pad: float = 0.0) -> Dictionary:
	var la2 := to_local(b, Vector2(pa.x, pa.z))
	var lb2 := to_local(b, Vector2(pb.x, pb.z))
	var h: Vector2 = b["h"]
	var lo := Vector3(-h.x - pad, float(b["y0"]), -h.y - pad)
	var hi := Vector3(h.x + pad, float(b["y1"]), h.y + pad)
	var o3 := Vector3(la2.x, pa.y, la2.y)
	var d := Vector3(lb2.x, pb.y, lb2.y) - o3
	var t0 := 0.0
	var t1 := 1.0
	for axis in 3:
		var o := o3[axis]
		var v := d[axis]
		if absf(v) < 1e-9:
			if o <= lo[axis] or o >= hi[axis]:
				return {}
			continue
		var ta := (lo[axis] - o) / v
		var tb := (hi[axis] - o) / v
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 >= t1:
			return {}
	return { "t0": t0, "t1": t1 }


## Distance from `p` (inside the footprint) along world direction `d` to
## where it leaves the footprint.
static func exit_distance(b: Dictionary, p: Vector2, d: Vector2) -> float:
	var l := to_local(b, p)
	var ld := dir_to_local(b, d)
	var h: Vector2 = b["h"]
	var t := INF
	for axis in 2:
		if ld[axis] > 1e-6:
			t = minf(t, (h[axis] - l[axis]) / ld[axis])
		elif ld[axis] < -1e-6:
			t = minf(t, (-h[axis] - l[axis]) / ld[axis])
	return maxf(0.0, t)


## `p` clamped into the footprint shrunk by `inset` (the center if too small).
static func clamp_inside(b: Dictionary, p: Vector2, inset: float) -> Vector2:
	var h: Vector2 = (b["h"] as Vector2) - Vector2(inset, inset)
	var l := to_local(b, p)
	l = Vector2(clampf(l.x, -maxf(h.x, 0.0), maxf(h.x, 0.0)), clampf(l.y, -maxf(h.y, 0.0), maxf(h.y, 0.0)))
	return to_world(b, l)


## A point at arc length `s` around the footprint grown by `grow` (starting
## at the local (-x, -z) corner), in world space.
static func perimeter_point(b: Dictionary, grow: float, s: float) -> Vector2:
	var h: Vector2 = (b["h"] as Vector2) + Vector2(grow, grow)
	var w := 2.0 * h.x
	var d := 2.0 * h.y
	var l: Vector2
	if s < w:
		l = Vector2(-h.x + s, -h.y)
	else:
		s -= w
		if s < d:
			l = Vector2(h.x, -h.y + s)
		else:
			s -= d
			if s < w:
				l = Vector2(h.x - s, h.y)
			else:
				s -= w
				l = Vector2(-h.x, h.y - s)
	return to_world(b, l)


static func perimeter(b: Dictionary, grow: float) -> float:
	var h: Vector2 = (b["h"] as Vector2) + Vector2(grow, grow)
	return 4.0 * (h.x + h.y)
