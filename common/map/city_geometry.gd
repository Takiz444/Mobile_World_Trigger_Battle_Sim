class_name CityGeometry
extends RefCounted
## Continuous play space: where a character can stand and how it gets from
## one place to another. Positions are 2D points on the ground plane (world
## X, Z in metres; one old hex spacing = sqrt(3) m) plus a level:
##   level 0           the street (outside every building)
##   1                 inside a building, on its ground floor (sees out of
##                     windows); a one-floor building has no inside, 1 is
##                     its roof
##   floors            on the building's roof
## Buildings have no middle floors: inside is the ground floor only, and
## stairs go straight between it and the roof.
##
## Buildings are the same world-space boxes the renderer draws and line of
## sight traces against (BuildingRects), so what blocks you is what you see.
##
## Ground routes go around buildings: an A* search on a fine grid
## (AStarGrid2D, native and deterministic) followed by string-pulling, so
## paths are short and straight. Getting into a building costs time at the
## wall (ENTER_TIME), and stairs cost time per floor (STAIR_TIME).
##
## A route is a list of segments {from, to, l0, l1, fixed}:
##   fixed == 0   walk from -> to on level l0 at the character's speed
##   fixed > 0    a timed transition (enter / exit / stairs / jump) that takes
##                `fixed` seconds (before stamina), moving from -> to and
##                ending on level l1.

const UNIT_RADIUS := 0.3
## Characters inside a building stay this far from its outer walls.
const WALL_MARGIN := 0.1
const NAV_CELL := 0.5
## Seconds to step through a building's wall (in or out).
const ENTER_TIME := 0.6
## Seconds per floor of stairs.
const STAIR_TIME := 0.8
## How far inside a wall a character stands after entering.
const INSIDE_DEPTH := 0.35
## Grasshopper jump reach (metres; two old hexes) and duration.
const JUMP_RANGE := 3.5
const JUMP_TIME := 0.6

var bounds := Rect2()
var rects: Array = []        # [{rect: Rect2, floors: int}]
var _expanded: Array[Rect2] = []
var _nav: AStarGrid2D
var _nav_size := Vector2i.ZERO


func _init(p_bounds: Rect2, building_rects: Array) -> void:
	bounds = p_bounds
	for r in building_rects:
		var box := BuildingRects.bounds(r)
		rects.append({ "rect": box, "floors": int(r["floors"]) })
		_expanded.append(box.grow(UNIT_RADIUS))


# --- Queries ------------------------------------------------------------------

## Index of the building whose footprint contains `p`, or -1.
func rect_at(p: Vector2) -> int:
	for i in rects.size():
		if (rects[i]["rect"] as Rect2).has_point(p):
			return i
	return -1


## Floors of the tallest building footprint containing `p` (0 = street).
func floors_at(p: Vector2) -> int:
	var best := 0
	for r in rects:
		if (r["rect"] as Rect2).has_point(p):
			best = maxi(best, int(r["floors"]))
	return best


## Whether a character may stand at `p` on `level`.
func level_ok(p: Vector2, level: int) -> bool:
	if not _finite(p) or level < 0:
		return false
	if level == 0:
		return ground_ok(p)
	# Only the ground floor (1) and the roof exist; no middle floors.
	if level != 1 and level != floors_at(p):
		return false
	# Inside buildings tall enough, and a little way from their outer walls.
	# (Adjacent segments of one block share walls: a point on that seam is
	# still inside, so the test looks at the union, not each box.)
	for q in [p, p + Vector2(WALL_MARGIN, 0), p - Vector2(WALL_MARGIN, 0), p + Vector2(0, WALL_MARGIN), p - Vector2(0, WALL_MARGIN)]:
		if not _in_floors(q, level):
			return false
	return true


func _in_floors(p: Vector2, level: int) -> bool:
	for r in rects:
		if int(r["floors"]) >= level and (r["rect"] as Rect2).has_point(p):
			return true
	return false


## Open street at `p` (inside the play area, clear of every wall).
func ground_ok(p: Vector2) -> bool:
	if not _finite(p) or not bounds.grow(-UNIT_RADIUS).has_point(p):
		return false
	for e in _expanded:
		if e.has_point(p):
			return false
	return true


## The nearest legal spot to (p, level), as {pos, level}: (p, level) itself
## when a character may stand there. Over a building it lands on the roof or
## the ground floor (whichever is closer to `level`); otherwise it steps onto
## the nearest open street. Used to put back a character a turn left
## somewhere it can't stand (e.g. cut off in the middle of a jump).
func settle(p: Vector2, level: int) -> Dictionary:
	if level_ok(p, level):
		return { "pos": p, "level": level }
	if not _finite(p):
		return { "pos": p, "level": level }
	var roof := floors_at(p)
	if roof > 0:
		var order := [1, roof] if level > 0 and level < roof else [roof, 1]
		var idx := rect_at(p)
		var box: Rect2 = rects[idx]["rect"]
		var inner := box.grow(-2.0 * WALL_MARGIN)
		var spots := [p]
		if inner.size.x > 0.0 and inner.size.y > 0.0:
			spots.append(Vector2(clampf(p.x, inner.position.x, inner.end.x), clampf(p.y, inner.position.y, inner.end.y)))
		for q in spots:
			for l in order:
				if level_ok(q, l):
					return { "pos": q, "level": l }
	# The street: here, or the nearest open spot around it.
	if ground_ok(p):
		return { "pos": p, "level": 0 }
	for ring in range(1, 41):
		var r := 0.15 * ring
		var n := 8 + ring * 2
		var best := Vector2.INF
		for k in n:
			var q := p + Vector2.from_angle(TAU * k / n) * r
			if ground_ok(q) and (best == Vector2.INF or q.distance_squared_to(p) < best.distance_squared_to(p)):
				best = q
		if best != Vector2.INF:
			return { "pos": best, "level": 0 }
	return { "pos": p, "level": level }


## Whether `level` at `p` is inside a building (below its roof): such a
## character sees and is seen only through the outer walls.
func is_inside(p: Vector2, level: int) -> bool:
	return level > 0 and level < floors_at(p)


## A straight walk on the street from `a` to `b` touches no wall.
func ground_clear(a: Vector2, b: Vector2) -> bool:
	if not bounds.grow(-UNIT_RADIUS + 0.001).has_point(a) or not bounds.grow(-UNIT_RADIUS + 0.001).has_point(b):
		return false
	for e in _expanded:
		if _segment_hits_rect(a, b, e):
			return false
	return true


## A straight walk from `a` to `b` stays inside buildings tall enough for
## `level` the whole way (interiors and roofs).
func interior_clear(a: Vector2, b: Vector2, level: int) -> bool:
	var steps := maxi(1, int(ceil(a.distance_to(b) / 0.2)))
	for i in steps + 1:
		if not level_ok(a.lerp(b, float(i) / steps), level):
			return false
	return true


# --- Ground navigation --------------------------------------------------------

## Shortest street path from `a` to `b` (both open street), or [] if there is
## none. Includes both end points.
func nav_path(a: Vector2, b: Vector2) -> PackedVector2Array:
	if not ground_ok(a) or not ground_ok(b):
		return PackedVector2Array()
	if ground_clear(a, b):
		return PackedVector2Array([a, b])
	_ensure_nav()
	var ca := _free_cell_near(a)
	var cb := _free_cell_near(b)
	if ca.x < 0 or cb.x < 0:
		return PackedVector2Array()
	var cells: Array[Vector2i] = _nav.get_id_path(ca, cb)
	if cells.is_empty():
		return PackedVector2Array()
	var raw := PackedVector2Array([a])
	for c in cells:
		raw.append(_cell_center(c))
	raw.append(b)
	return _smooth(raw)


func path_length(path: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


func _ensure_nav() -> void:
	if _nav != null:
		return
	_nav_size = Vector2i(int(ceil(bounds.size.x / NAV_CELL)), int(ceil(bounds.size.y / NAV_CELL)))
	_nav = AStarGrid2D.new()
	_nav.region = Rect2i(Vector2i.ZERO, _nav_size)
	_nav.cell_size = Vector2(NAV_CELL, NAV_CELL)
	_nav.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_nav.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	_nav.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	_nav.update()
	# Walls (grown by the character's radius) and the play-area edge.
	for x in _nav_size.x:
		for y in _nav_size.y:
			var p := _cell_center(Vector2i(x, y))
			if not bounds.grow(-UNIT_RADIUS).has_point(p):
				_nav.set_point_solid(Vector2i(x, y), true)
	for e in _expanded:
		var c0 := _cell_of(e.position)
		var c1 := _cell_of(e.end)
		for x in range(maxi(0, c0.x), mini(_nav_size.x, c1.x + 1)):
			for y in range(maxi(0, c0.y), mini(_nav_size.y, c1.y + 1)):
				if e.has_point(_cell_center(Vector2i(x, y))):
					_nav.set_point_solid(Vector2i(x, y), true)


func _cell_of(p: Vector2) -> Vector2i:
	var rel := (p - bounds.position) / NAV_CELL
	return Vector2i(int(floor(rel.x)), int(floor(rel.y)))


func _cell_center(c: Vector2i) -> Vector2:
	return bounds.position + (Vector2(c) + Vector2(0.5, 0.5)) * NAV_CELL


## The open grid cell nearest `p` that a straight walk from `p` reaches.
func _free_cell_near(p: Vector2) -> Vector2i:
	var c := _cell_of(p)
	for radius in 4:
		var best := Vector2i(-1, -1)
		var best_d := INF
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var q := c + Vector2i(dx, dy)
				if q.x < 0 or q.y < 0 or q.x >= _nav_size.x or q.y >= _nav_size.y or _nav.is_point_solid(q):
					continue
				var d := _cell_center(q).distance_squared_to(p)
				if d < best_d and ground_clear(p, _cell_center(q)):
					best_d = d
					best = q
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


## String-pulling: keep only the turning points of a grid path.
func _smooth(raw: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([raw[0]])
	var i := 0
	while i < raw.size() - 1:
		var j := raw.size() - 1
		while j > i + 1 and not ground_clear(raw[i], raw[j]):
			j -= 1
		out.append(raw[j])
		i = j
	return out


# --- Routes -------------------------------------------------------------------

## How to get from (a, la) to (b, lb) by walking, entering / leaving
## buildings, and stairs: {ok, segments}. See the class notes for segments.
func route(a: Vector2, la: int, b: Vector2, lb: int) -> Dictionary:
	var fail := { "ok": false, "segments": [] }
	if not level_ok(a, la) or not level_ok(b, lb):
		return fail
	var segs: Array = []
	if la == 0 and lb == 0:
		if not _add_walk(segs, a, b):
			return fail
		return { "ok": true, "segments": segs }
	if la > 0 and lb > 0:
		var m := mini(la, lb)
		# Same building block: stairs to the lower of the two floors, walk
		# across inside, stairs to the target floor.
		for level in [m, 1]:
			if interior_clear(a, b, level):
				_add_stairs(segs, a, la, level)
				if a.distance_to(b) > 0.001:
					segs.append({ "from": a, "to": b, "l0": level, "l1": level, "fixed": 0.0 })
				_add_stairs(segs, b, level, lb)
				return { "ok": true, "segments": segs }
	# Otherwise through the street: leave the start building, walk, enter.
	var street_a := a
	if la > 0:
		var exit := _door(a, b)
		if exit.is_empty():
			return fail
		_add_stairs(segs, a, la, 1)
		if a.distance_to(exit["inside"]) > 0.001:
			if not interior_clear(a, exit["inside"], 1):
				return fail
			segs.append({ "from": a, "to": exit["inside"], "l0": 1, "l1": 1, "fixed": 0.0 })
		segs.append({ "from": exit["inside"], "to": exit["outside"], "l0": 1, "l1": 0, "fixed": ENTER_TIME })
		street_a = exit["outside"]
	if lb == 0:
		if not _add_walk(segs, street_a, b):
			return fail
		return { "ok": true, "segments": segs }
	var entry := _door(b, street_a)
	if entry.is_empty() or not _add_walk(segs, street_a, entry["outside"]):
		return fail
	segs.append({ "from": entry["outside"], "to": entry["inside"], "l0": 0, "l1": 1, "fixed": ENTER_TIME })
	if entry["inside"].distance_to(b) > 0.001:
		if not interior_clear(entry["inside"], b, 1):
			return fail
		segs.append({ "from": entry["inside"], "to": b, "l0": 1, "l1": 1, "fixed": 0.0 })
	_add_stairs(segs, b, 1, lb)
	return { "ok": true, "segments": segs }


## A Grasshopper jump from (a, la) to (b, lb): within JUMP_RANGE, from the
## street or a roof, onto the street or a roof. {ok, segments}.
func jump_route(a: Vector2, la: int, b: Vector2, lb: int) -> Dictionary:
	var fail := { "ok": false, "segments": [] }
	if not level_ok(a, la) or not level_ok(b, lb) or a.distance_to(b) > JUMP_RANGE + 0.001:
		return fail
	if is_inside(a, la) or is_inside(b, lb):
		return fail   # no jumping through ceilings
	if a.distance_to(b) < 0.001 and la == lb:
		return fail
	return { "ok": true, "segments": [{ "from": a, "to": b, "l0": la, "l1": lb, "fixed": JUMP_TIME }] }


## Total walking distance and fixed time of a route.
static func route_cost(segments: Array) -> Dictionary:
	var walk := 0.0
	var fixed := 0.0
	for s in segments:
		if float(s["fixed"]) > 0.0:
			fixed += float(s["fixed"])
		else:
			walk += (s["from"] as Vector2).distance_to(s["to"])
	return { "walk": walk, "fixed": fixed }


func _add_walk(segs: Array, a: Vector2, b: Vector2) -> bool:
	if a.distance_to(b) < 0.001:
		return true
	var path := nav_path(a, b)
	if path.is_empty():
		return false
	for i in range(1, path.size()):
		segs.append({ "from": path[i - 1], "to": path[i], "l0": 0, "l1": 0, "fixed": 0.0 })
	return true


func _add_stairs(segs: Array, p: Vector2, from_level: int, to_level: int) -> void:
	if from_level != to_level:
		segs.append({ "from": p, "to": p, "l0": from_level, "l1": to_level,
			"fixed": STAIR_TIME * absi(to_level - from_level) })


## Where to pass through the wall of the building at `inside_p`, as close as
## possible to `toward`: {inside, outside} or {} if there is no open street
## next to that building.
func _door(inside_p: Vector2, toward: Vector2) -> Dictionary:
	var idx := rect_at(inside_p)
	if idx == -1:
		return {}
	var box: Rect2 = rects[idx]["rect"]
	var outer := box.grow(UNIT_RADIUS + 0.05)
	var inner := box.grow(-INSIDE_DEPTH)
	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		inner = Rect2(box.get_center(), Vector2.ZERO)
	var best := {}
	var best_d := INF
	# Candidate doors every 0.25 m around the wall.
	var per := 2.0 * (outer.size.x + outer.size.y)
	var n := maxi(8, int(per / 0.25))
	for i in n:
		var p := _perimeter_point(outer, per * i / n)
		if not ground_ok(p):
			continue
		var d := p.distance_to(toward)
		if d < best_d:
			best_d = d
			best = { "outside": p, "inside": Vector2(clampf(p.x, inner.position.x, inner.end.x), clampf(p.y, inner.position.y, inner.end.y)) }
	return best


static func _perimeter_point(r: Rect2, s: float) -> Vector2:
	var w := r.size.x
	var h := r.size.y
	if s < w:
		return r.position + Vector2(s, 0)
	s -= w
	if s < h:
		return r.position + Vector2(w, s)
	s -= h
	if s < w:
		return r.position + Vector2(w - s, h)
	s -= w
	return r.position + Vector2(0, h - s)


## Segment vs. axis-aligned rectangle (slab test, 2D). Touching counts.
static func _segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	for axis in 2:
		var o := a[axis]
		var v := d[axis]
		var lo := r.position[axis]
		var hi := r.end[axis]
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


static func _finite(p: Vector2) -> bool:
	return is_finite(p.x) and is_finite(p.y) and absf(p.x) < 1.0e6 and absf(p.y) < 1.0e6
