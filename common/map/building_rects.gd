class_name BuildingRects
extends RefCounted
## The city's building geometry, shared by the engine (line of sight), the
## server, and the renderer (CityBuildings), so what blocks sight is exactly
## what you see.
##
## Every building hex maps to a rectangular "brick" (flat-top hexes tile the
## plane as 1.5 x sqrt3 cells, odd columns offset by half). A column's run of
## building hexes becomes a vertical strip; its top/bottom edges are snapped a
## quarter hex toward the neighbouring column's edges, so zig-zag hex edges
## become straight walls. Every building hex center stays inside its building
## and every street hex center stays outside. Strips with identical spans and
## heights merge into rectangles: one building segment each.
##
## Rectangles are in hex-size-1 world units:
##   { c0, c1, top, bot, floors, hexes: Array[Vector2i] }
## covering x in [1.5*c0 - 0.75, 1.5*c1 + 0.75], z in [top, bot],
## y in [0, floors] (floors above the street surface).

const SQ3 := 1.7320508075688772
const QUARTER := SQ3 / 4.0


static func offset_row(hex: Vector2i) -> int:
	return hex.y + (hex.x - (hex.x & 1)) / 2


static func axial(col: int, row: int) -> Vector2i:
	return Vector2i(col, row - (col - (col & 1)) / 2)


static func _center_z(col: int, row: int) -> float:
	return SQ3 * (row + 0.5 * (col & 1))


## Snaps a strip edge a quarter hex in or out, preferring a value the previous
## column already uses (so straight hex edges become straight walls).
static func _snap(e: float, prev: Array, shrink_dir: float) -> float:
	var a := e - QUARTER
	var b := e + QUARTER
	for v in prev:
		if absf(v - a) < 1e-4:
			return a
		if absf(v - b) < 1e-4:
			return b
	return e + QUARTER * shrink_dir


## Rectangles covering `buildings` (axial hex -> floors). Deterministic and
## identical to the generator that designed the map's segment heights.
static func compute(buildings: Dictionary) -> Array:
	var by_col := {}
	var cmin := 0x7FFFFFFF
	var cmax := -0x7FFFFFFF
	for hex in buildings:
		var col: int = hex.x
		if not by_col.has(col):
			by_col[col] = {}
		by_col[col][offset_row(hex)] = int(buildings[hex])
		cmin = mini(cmin, col)
		cmax = maxi(cmax, col)
	var out: Array = []
	var open := {}
	var prev_edges: Array = []
	for col in range(cmin, cmax + 1):
		var runs: Array = []
		if by_col.has(col):
			var rows: Array = by_col[col].keys()
			rows.sort()
			var i := 0
			while i < rows.size():
				var k0: int = rows[i]
				var floors: int = by_col[col][k0]
				var k1 := k0
				while i + 1 < rows.size() and rows[i + 1] == k1 + 1 and by_col[col][rows[i + 1]] == floors:
					i += 1
					k1 = rows[i]
				i += 1
				runs.append([k0, k1, floors])
		var snapped: Array = []
		for run in runs:
			var top := _snap(_center_z(col, run[0]) - SQ3 / 2.0, prev_edges, 1.0)
			var bot := _snap(_center_z(col, run[1]) + SQ3 / 2.0, prev_edges, -1.0)
			snapped.append([top, bot, run[2], run[0], run[1]])
		prev_edges.clear()
		for s in snapped:
			prev_edges.append(s[0])
			prev_edges.append(s[1])
		var next := {}
		for s in snapped:
			var key := "%.3f|%.3f|%d" % [s[0], s[1], s[2]]
			var r: Dictionary
			if open.has(key):
				r = open[key]
				r["c1"] = col
			else:
				r = { "c0": col, "c1": col, "top": s[0], "bot": s[1], "floors": s[2], "hexes": [] }
				out.append(r)
			for row in range(s[3], s[4] + 1):
				r["hexes"].append(axial(col, row))
			next[key] = r
		open = next
	return out


## World-space footprint of a rectangle (scaled by `size`).
static func bounds(r: Dictionary, size: float = 1.0) -> Rect2:
	var x0 := (1.5 * int(r["c0"]) - 0.75) * size
	var x1 := (1.5 * int(r["c1"]) + 0.75) * size
	var z0 := float(r["top"]) * size
	var z1 := float(r["bot"]) * size
	return Rect2(x0, z0, x1 - x0, z1 - z0)
