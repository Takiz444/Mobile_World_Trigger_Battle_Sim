class_name HexCoord
extends RefCounted
## Static utility library for hexagonal grid math using the axial coordinate
## system (q, r) described in the GDD. All positions are represented as
## Vector2i where x = q (column) and y = r (row).
##
## Cube coordinates (x, y, z) with x + y + z == 0 are derived internally to
## simplify distance, line-drawing, and rounding operations.
##
## World-space conversion maps the hex board onto the XZ plane (y = 0) to
## support the 3D low-poly "hologram tabletop" diorama. Layout is flat-top
## (hexes stacked in columns), matching the reference map sheet.

const SQRT3 := 1.7320508075688772

## World-space height of one building floor (used for unit elevation).
const FLOOR_HEIGHT := 1.0
## World-space Y of the top face of a board tile (tiles are centered on y=0).
## Units, props, and buildings stand on this surface.
const GROUND_Y := 0.175

## Cube-space neighbor directions, indexed 0..5. With the flat-top layout
## (+Z = south / toward team 0): SE, NE, N, NW, SW, S.
const CUBE_DIRECTIONS: Array[Vector3i] = [
	Vector3i(1, -1, 0),
	Vector3i(1, 0, -1),
	Vector3i(0, 1, -1),
	Vector3i(-1, 1, 0),
	Vector3i(-1, 0, 1),
	Vector3i(0, -1, 1),
]

## Axial neighbor directions, indexed identically to CUBE_DIRECTIONS.
const AXIAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),    # SE
	Vector2i(1, -1),   # NE
	Vector2i(0, -1),   # N
	Vector2i(-1, 0),   # NW
	Vector2i(-1, 1),   # SW
	Vector2i(0, 1),    # S
]


# --- Coordinate Conversions -------------------------------------------------

static func axial_to_cube(hex: Vector2i) -> Vector3i:
	var x := hex.x
	var z := hex.y
	return Vector3i(x, -x - z, z)


static func cube_to_axial(cube: Vector3i) -> Vector2i:
	return Vector2i(cube.x, cube.z)


## Rounds fractional cube coordinates back to the nearest valid hex.
static func cube_round(frac: Vector3) -> Vector3i:
	var rx := roundi(frac.x)
	var ry := roundi(frac.y)
	var rz := roundi(frac.z)

	var dx := absf(frac.x - rx)
	var dy := absf(frac.y - ry)
	var dz := absf(frac.z - rz)

	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry

	return Vector3i(rx, ry, rz)


# --- Topology ---------------------------------------------------------------

static func distance(a: Vector2i, b: Vector2i) -> int:
	var ca := axial_to_cube(a)
	var cb := axial_to_cube(b)
	return (absi(ca.x - cb.x) + absi(ca.y - cb.y) + absi(ca.z - cb.z)) / 2


static func neighbor(hex: Vector2i, direction: int) -> Vector2i:
	return hex + AXIAL_DIRECTIONS[posmod(direction, 6)]


static func neighbors(hex: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dir in AXIAL_DIRECTIONS:
		result.append(hex + dir)
	return result


## Returns the direction index (0..5) from `from` to an adjacent `to`.
## Returns -1 when the two hexes are not adjacent.
static func direction_to(from: Vector2i, to: Vector2i) -> int:
	return AXIAL_DIRECTIONS.find(to - from)


## Rotates a direction index by `steps` (clockwise), wrapping 0..5.
static func rotate_direction(direction: int, steps: int) -> int:
	return posmod(direction + steps, 6)


## All hexes at exactly `radius` distance from `center`.
static func ring(center: Vector2i, radius: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if radius < 1:
		result.append(center)
		return result

	var hex := center + AXIAL_DIRECTIONS[4] * radius
	for i in 6:
		for _j in range(radius):
			result.append(hex)
			hex = neighbor(hex, i)
	return result


## All hexes within `radius` distance of `center` (inclusive), ring by ring.
static func spiral(center: Vector2i, radius: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = [center]
	for r in range(1, radius + 1):
		result.append_array(ring(center, r))
	return result


## A straight line of hexes between `a` and `b` (inclusive), using cube lerp.
static func line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var n := distance(a, b)
	var ca := axial_to_cube(a)
	var cb := axial_to_cube(b)

	for i in range(n + 1):
		var t := 0.0 if n == 0 else float(i) / float(n)
		var x := lerpf(float(ca.x), float(cb.x), t)
		var y := lerpf(float(ca.y), float(cb.y), t)
		var z := lerpf(float(ca.z), float(cb.z), t)
		result.append(cube_to_axial(cube_round(Vector3(x, y, z))))
	return result


# --- World-Space Mapping ----------------------------------------------------

## Converts axial coordinates to a 3D world position on the XZ plane
## (flat-top: q steps 1.5 sizes right, r steps one hex height down).
static func axial_to_world(hex: Vector2i, size: float) -> Vector3:
	var x := size * (1.5 * hex.x)
	var z := size * (SQRT3 * 0.5 * hex.x + SQRT3 * hex.y)
	return Vector3(x, 0.0, z)


## Converts a 3D world position (XZ plane) to the nearest axial hex.
static func world_to_axial(pos: Vector3, size: float) -> Vector2i:
	var q := (2.0 / 3.0 * pos.x) / size
	var r := (-1.0 / 3.0 * pos.x + SQRT3 / 3.0 * pos.z) / size
	return cube_to_axial(cube_round(Vector3(q, -q - r, r)))


# --- Pathfinding ------------------------------------------------------------

## A* pathfinding over uniform-cost hex steps.
## `is_walkable` is a Callable taking a Vector2i and returning a bool.
## Returns the shortest path (start..goal inclusive), or an empty array if
## unreachable. Exploration is bounded by `max_distance` hexes.
static func find_path(
	start: Vector2i,
	goal: Vector2i,
	is_walkable: Callable,
	max_distance: int = 1000
) -> Array[Vector2i]:
	if start == goal:
		return [start]
	if not bool(is_walkable.call(goal)):
		return []

	var open: Array[Vector2i] = [start]
	var came_from: Dictionary = {}
	var g_score: Dictionary = {}
	var f_score: Dictionary = {}
	g_score[start] = 0
	f_score[start] = distance(start, goal)

	while not open.is_empty():
		# Linear scan for the lowest f-score (deterministic; boards are small).
		var current: Vector2i = open[0]
		var best_f: int = f_score[current]
		var best_idx := 0
		for i in range(open.size()):
			var node: Vector2i = open[i]
			var f: int = f_score.get(node, 0x7FFFFFFF)
			if f < best_f:
				current = node
				best_f = f
				best_idx = i

		if current == goal:
			return _reconstruct_path(came_from, current)

		open.remove_at(best_idx)

		var current_g: int = g_score.get(current, 0)
		if current_g >= max_distance:
			continue

		for nxt in neighbors(current):
			if not bool(is_walkable.call(nxt)):
				continue
			var tentative_g := current_g + 1
			if tentative_g < int(g_score.get(nxt, 0x7FFFFFFF)):
				came_from[nxt] = current
				g_score[nxt] = tentative_g
				f_score[nxt] = tentative_g + distance(nxt, goal)
				if not open.has(nxt):
					open.append(nxt)

	return []


static func _reconstruct_path(came_from: Dictionary, current: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [current]
	while came_from.has(current):
		current = came_from[current]
		path.append(current)
	path.reverse()
	return path
