class_name MapData
extends RefCounted
## The battlefield from the World Trigger "battle simulation exercise" map
## sheet ("Project Docs/Map refrence with building.png"): a 32x32 flat-top hex
## grid of city blocks and streets.
##
## LAYOUT was traced from the reference image hex by hex (the scan's hex
## lattice was fitted and every hex classified as street or building), so the
## street network and building footprints match the sheet exactly. The sheet
## is point-symmetric (180 degrees), so both sides are equivalent.
##
## The sheet is drawn top-down and does not show heights; floors are
## assigned per building block from its footprint (small houses 1-2 floors,
## mid-size blocks 3, the large complexes 4). Edit the digits to change them.
##
## Legend:
##   .    street (open ground)
##   1-4  building hex with that many floors (walkable inside / on top)
##   h    half cover (cars, crates)        H  full cover (walls)
##   A    team 0 spawn (street)            Z  team 1 spawn (street)
##
## Each string is one row; characters are columns. Columns use "odd-q"
## offset coordinates (odd columns sit half a hex lower), converted to axial
## (q, r) for the engine.

const COLS := 32
const ROWS := 32

const LAYOUT: Array[String] = [
	"....Z.......Z2...Z4444.4.4Z11.22",
	".11.........22....44444444.11.22",
	".11.......2222....4.444.......22",
	"...................2.44.33....2.",
	"333..11.444444....22..4.33......",
	"333..11.444444....22.3.333.3.3.3",
	"333....444........22.33333.33333",
	"333..44444.4.4....2...3.3..333..",
	"3.....4.4..444.............333.1",
	".33..4.4.4.444....44444444.....1",
	"333..444444444....44444444.222..",
	"333..444444444....44444444.22..1",
	"333..44......................2.1",
	"333..44444.44.....222.2222..22.1",
	"333..44444444.....222.2222..22.1",
	"................................",
	"................................",
	"1.22..2222.222.....44444444..333",
	"1.22..2222.222.....44.44444..333",
	"1.2......................44..333",
	"1..22.44444444....444444444..333",
	"..222.44444444....444444444..333",
	"1.....44444444....444.4.4.4..33.",
	"1.333.............444..4.4.....3",
	"..333..3.3...2....4.4.44444..333",
	"33333.33333.22........444....333",
	"3.3.3.333.3.22....444444.11..333",
	"......33.4..22....444444.11..333",
	".2....33.44.2...................",
	"22.......444.4....2222.......11.",
	"22.11.44444444....22.........11.",
	"22.11A4.4.4444A...2A.......A....",
]

var tiles: Dictionary = {}      # Vector2i -> true
var buildings: Dictionary = {}  # Vector2i -> floors (1..4)
var cover: Dictionary = {}      # Vector2i -> 1 (half) | 2 (full)
var spawns: Array = [[], []]    # spawns[team] -> Array of Vector2i
var center: Vector2i = Vector2i.ZERO


static func offset_to_axial(col: int, row: int) -> Vector2i:
	return Vector2i(col, row - (col - (col & 1)) / 2)


## Builds the standard city map.
static func city() -> MapData:
	var m := MapData.new()
	assert(LAYOUT.size() == ROWS, "map must have %d rows" % ROWS)
	for row in ROWS:
		var line := LAYOUT[row]
		assert(line.length() == COLS, "map row %d must be %d wide" % [row, COLS])
		for col in COLS:
			var hex := offset_to_axial(col, row)
			m.tiles[hex] = true
			var ch := line[col]
			match ch:
				"1", "2", "3", "4":
					m.buildings[hex] = int(ch)
				"h":
					m.cover[hex] = 1
				"H":
					m.cover[hex] = 2
				"A":
					m.spawns[0].append(hex)
				"Z":
					m.spawns[1].append(hex)
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
