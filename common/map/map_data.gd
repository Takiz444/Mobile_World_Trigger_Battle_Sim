class_name MapData
extends RefCounted
## The city battlefield, modelled on "Project Docs/Map refrence with building.png":
## a rectangular hex grid of building blocks separated by streets.
##
## The layout is authored as text for the top half (team 1's side) and rotated
## 180 degrees to produce the bottom half (team 0's side), so the map is
## perfectly fair. Shared by client and server (the engine needs buildings
## and cover to resolve movement and line of sight).
##
## Legend:
##   .    street (open ground)
##   1-4  building with that many floors (walkable inside / on top)
##   h    half cover (cars, crates)        H  full cover (walls)
##   S    spawn hex (street)
##
## Rows use "odd-r" offset coordinates (odd rows shifted half a hex right),
## converted to axial (q, r) for the engine.

const COLS := 18
const ROWS := 24  # must be even so the 180-degree rotation maps rows cleanly

const TOP_HALF: Array[String] = [
	"3.22.S......S.33.2",
	"3.22...h..h...33.2",
	"......S....S......",
	".11.44..22...44.1.",
	".11.44..22.h.44.1.",
	"....h........h....",
	"22.333.H..3...222.",
	"22.333....3...222.",
	"....h..11....h....",
	".44.....11..h..33.",
	".44..h.......2.33.",
	"......2..h...2....",
]

var tiles: Dictionary = {}      # Vector2i -> true
var buildings: Dictionary = {}  # Vector2i -> floors (1..4)
var cover: Dictionary = {}      # Vector2i -> 1 (half) | 2 (full)
var spawns: Array = [[], []]    # spawns[team] -> Array of Vector2i
var center: Vector2i = Vector2i.ZERO


static func offset_to_axial(col: int, row: int) -> Vector2i:
	return Vector2i(col - (row - (row & 1)) / 2, row)


## Builds the standard city map.
static func city() -> MapData:
	var m := MapData.new()
	var rows: Array[String] = []
	for line in TOP_HALF:
		assert(line.length() == COLS, "map row must be %d wide: %s" % [COLS, line])
		rows.append(line)
	# Bottom half: the top half rotated 180 degrees.
	for i in range(TOP_HALF.size() - 1, -1, -1):
		rows.append(TOP_HALF[i].reverse())

	for row in ROWS:
		for col in COLS:
			var hex := offset_to_axial(col, row)
			m.tiles[hex] = true
			var ch := rows[row][col]
			match ch:
				"1", "2", "3", "4":
					m.buildings[hex] = int(ch)
				"h":
					m.cover[hex] = 1
				"H":
					m.cover[hex] = 2
				"S":
					# Top half spawns team 1, the rotated bottom half team 0.
					m.spawns[1 if row < ROWS / 2 else 0].append(hex)
	m.center = offset_to_axial(COLS / 2, ROWS / 2)
	return m


## Facing (0..5) from `hex` that points most directly at the map center.
func facing_toward_center(hex: Vector2i) -> int:
	var best := 0
	var best_d := 0x7FFFFFFF
	for d in 6:
		var dist := HexCoord.distance(HexCoord.neighbor(hex, d), center)
		if dist < best_d:
			best_d = dist
			best = d
	return best
