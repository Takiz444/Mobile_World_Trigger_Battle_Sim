class_name BlockedMask
extends RefCounted
## Ground nobody can walk on: rivers, canals, moats and fenced railway
## tracks (seen across, not walked), and everything outside the battle zone.
## A raster over the play area (RES units per cell) where a cell is blocked
## when its center is within `margin` (a character's radius) of any of
## those; bridges and level crossings are cut back out. Built the same way
## on the server and every client.
##
## Each cell also remembers why it is blocked (Reason), for the messages the
## player sees, and whether it lies inside the zone at all (roofs and
## interiors outside it are off limits too).

const RES := 0.25

enum Reason { OPEN, WATER, RAIL, ZONE_EDGE, OUTSIDE }

var origin := Vector2.ZERO
var nx := 0
var nz := 0
var _cells := PackedByteArray()   # Reason per cell
var _inside := PackedByteArray()  # 1 inside the zone
var _any := false
var _has_zone := false


## `area`: the play area's bounds. `tris`: water triangles (flat x, z list,
## 3 points each). `strokes`: [{pts: PackedVector2Array, half: float}]
## railway. `cuts`: the same for walkable bridges, `discs`: [Vector3(x, z, r)]
## walkable crossings. `zone`: the play area polygon (empty: the whole area).
func _init(area: Rect2, tris: PackedFloat32Array, strokes: Array, cuts: Array, discs: Array, margin: float,
		zone := PackedVector2Array()) -> void:
	var box := area.grow(1.0)
	origin = box.position
	nx = maxi(1, int(ceil(box.size.x / RES)))
	nz = maxi(1, int(ceil(box.size.y / RES)))
	_cells.resize(nx * nz)
	_cells.fill(Reason.OPEN)
	_inside.resize(nx * nz)
	_inside.fill(1)
	if not tris.is_empty():
		_fill_water(tris, margin)
	for s in strokes:
		_stroke(s["pts"], float(s["half"]) + margin, Reason.RAIL, false)
	for s in cuts:
		_stroke(s["pts"], maxf(0.0, float(s["half"]) - margin * 0.5), Reason.OPEN, false)
	for d in discs:
		var disc: Vector3 = d
		_stroke(PackedVector2Array([Vector2(disc.x, disc.y), Vector2(disc.x, disc.y)]), disc.z, Reason.OPEN, false)
	if zone.size() >= 3:
		_has_zone = true
		_mark_zone(zone, margin)
	_any = _cells.count(Reason.OPEN) < _cells.size()


func any_blocked() -> bool:
	return _any


func is_blocked(p: Vector2) -> bool:
	return reason(p) != Reason.OPEN


## Why `p` can't be walked on (Reason.OPEN if it can). Outside the raster
## counts as outside the zone when there is a zone.
func reason(p: Vector2) -> int:
	if not _any:
		return Reason.OPEN
	var i := _index(p)
	if i < 0:
		return Reason.OUTSIDE if _has_zone else Reason.OPEN
	return _cells[i]


## Whether `p` lies inside the battle zone (for interiors and roofs).
func in_zone(p: Vector2) -> bool:
	if not _has_zone:
		return true
	var i := _index(p)
	return i >= 0 and _inside[i] == 1


## A straight walk from a to b crosses no blocked cell (sampled finely).
func segment_clear(a: Vector2, b: Vector2) -> bool:
	if not _any:
		return true
	var n := maxi(1, int(ceil(a.distance_to(b) / (RES * 0.5))))
	for i in n + 1:
		if is_blocked(a.lerp(b, float(i) / n)):
			return false
	return true


func _index(p: Vector2) -> int:
	var cx := int(floor((p.x - origin.x) / RES))
	var cz := int(floor((p.y - origin.y) / RES))
	if cx < 0 or cz < 0 or cx >= nx or cz >= nz:
		return -1
	return cz * nx + cx


func _cell_center(cx: int, cz: int) -> Vector2:
	return origin + Vector2((cx + 0.5) * RES, (cz + 0.5) * RES)


func _range(lo: float, hi: float, o: float, n: int) -> Vector2i:
	return Vector2i(clampi(int(floor((lo - o) / RES)), 0, n - 1), clampi(int(floor((hi - o) / RES)), 0, n - 1))


## Outside the polygon: OUTSIDE (and not in the zone); within `margin` of its
## edge on the inside: ZONE_EDGE (unless already water / rail).
func _mark_zone(zone: PackedVector2Array, margin: float) -> void:
	# Scanline: each row is inside between pairs of edge crossings.
	var n := zone.size()
	for cz in nz:
		var zc := origin.y + (cz + 0.5) * RES
		var xs: Array[float] = []
		for k in n:
			var a := zone[k]
			var b := zone[(k + 1) % n]
			if (a.y > zc) != (b.y > zc):
				xs.append(a.x + (zc - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		var row := cz * nx
		var j := 0
		for cx in nx:
			var xc := origin.x + (cx + 0.5) * RES
			while j < xs.size() and xs[j] <= xc:
				j += 1
			if j % 2 == 0:   # an even number of crossings to the left: outside
				_inside[row + cx] = 0
				_cells[row + cx] = Reason.OUTSIDE
	var ring := PackedVector2Array(zone)
	ring.append(zone[0])
	var m2 := margin * margin
	for k in ring.size() - 1:
		var a := ring[k]
		var b := ring[k + 1]
		var xr := _range(minf(a.x, b.x) - margin, maxf(a.x, b.x) + margin, origin.x, nx)
		var zr := _range(minf(a.y, b.y) - margin, maxf(a.y, b.y) + margin, origin.y, nz)
		for cz in range(zr.x, zr.y + 1):
			for cx in range(xr.x, xr.y + 1):
				var i := cz * nx + cx
				if _cells[i] == Reason.OPEN and _seg_d2(_cell_center(cx, cz), a, b) <= m2:
					_cells[i] = Reason.ZONE_EDGE


## Water triangles by scanline (cost ~ their area), then grown by `margin`
## from the water's edge cells only.
func _fill_water(tris: PackedFloat32Array, margin: float) -> void:
	var water := PackedByteArray()
	water.resize(nx * nz)
	water.fill(0)
	for t in range(0, tris.size() - 5, 6):
		var pts := [Vector2(tris[t], tris[t + 1]), Vector2(tris[t + 2], tris[t + 3]), Vector2(tris[t + 4], tris[t + 5])]
		var zlo := minf(pts[0].y, minf(pts[1].y, pts[2].y))
		var zhi := maxf(pts[0].y, maxf(pts[1].y, pts[2].y))
		var r0 := maxi(0, int(ceil((zlo - origin.y) / RES - 0.5)))
		var r1 := mini(nz - 1, int(floor((zhi - origin.y) / RES - 0.5)))
		for row in range(r0, r1 + 1):
			var zc := origin.y + (row + 0.5) * RES
			var lo := INF
			var hi := -INF
			for k in 3:
				var a: Vector2 = pts[k]
				var b: Vector2 = pts[(k + 1) % 3]
				if (a.y <= zc and b.y >= zc) or (b.y <= zc and a.y >= zc):
					var x := a.x if absf(b.y - a.y) < 1e-9 else a.x + (zc - a.y) / (b.y - a.y) * (b.x - a.x)
					lo = minf(lo, x)
					hi = maxf(hi, x)
			if lo > hi:
				continue
			var c0 := maxi(0, int(ceil((lo - origin.x) / RES - 0.5)))
			var c1 := mini(nx - 1, int(floor((hi - origin.x) / RES - 0.5)))
			for c in range(c0, c1 + 1):
				water[row * nx + c] = 1
	var reach := int(ceil(margin / RES))
	var m2 := (margin + RES * 0.5) * (margin + RES * 0.5)
	for cz in nz:
		for cx in nx:
			var i := cz * nx + cx
			if water[i] == 0:
				continue
			_cells[i] = Reason.WATER
			var edge := (cx > 0 and water[i - 1] == 0) or (cx < nx - 1 and water[i + 1] == 0) 				or (cz > 0 and water[i - nx] == 0) or (cz < nz - 1 and water[i + nx] == 0)
			if not edge:
				continue
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var x := cx + dx
					var z := cz + dz
					if x >= 0 and z >= 0 and x < nx and z < nz and (dx * dx + dz * dz) * RES * RES <= m2:
						_cells[z * nx + x] = Reason.WATER


func _stroke(pts: PackedVector2Array, half: float, value: int, _unused: bool) -> void:
	if pts.size() == 0 or half <= 0.0:
		return
	var h2 := half * half
	for k in maxi(1, pts.size() - 1):
		var a := pts[k]
		var b := pts[mini(k + 1, pts.size() - 1)]
		if maxf(a.x, b.x) + half < origin.x or maxf(a.y, b.y) + half < origin.y \
				or minf(a.x, b.x) - half > origin.x + nx * RES or minf(a.y, b.y) - half > origin.y + nz * RES:
			continue
		var xr := _range(minf(a.x, b.x) - half, maxf(a.x, b.x) + half, origin.x, nx)
		var zr := _range(minf(a.y, b.y) - half, maxf(a.y, b.y) + half, origin.y, nz)
		for cz in range(zr.x, zr.y + 1):
			for cx in range(xr.x, xr.y + 1):
				if _seg_d2(_cell_center(cx, cz), a, b) <= h2:
					_cells[cz * nx + cx] = value


static func _seg_d2(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 < 1e-12 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_squared_to(a + ab * t)
