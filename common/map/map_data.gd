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
## The sheet is drawn top-down and does not show heights. Each building block
## is split into rectangular segments (the same rectangles the 3D city is built
## from, see levels/board/city_buildings.gd) and each segment has its own
## height, giving towers with lower wings; heights mirror across the map's
## 180-degree symmetry so both sides stay fair. Edit the digits to change them
## (keep a segment's hexes the same digit).
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
	"....Z.......Z2...Z3333.2.2Z21.33",
	".11.........22....33333222.21.33",
	".11.......1122....3.333.......33",
	"...................2.33.22....3.",
	"332..11.332222....22..3.22......",
	"332..11.332222....22.4.422.4.4.3",
	"332....133........22.44422.44433",
	"332..11133.4.4....2...4.2..444..",
	"3.....1.3..444.............444.1",
	".23..4.4.4.444....44444444.....1",
	"123..444444444....44444444.211..",
	"123..444444444....44444444.21..2",
	"123..44......................3.2",
	"123..44222.11.....222.3333..33.2",
	"123..44222111.....222.3333..33.2",
	"................................",
	"................................",
	"2.33..3333.222.....11122244..321",
	"2.33..3333.222.....11.22244..321",
	"2.3......................44..321",
	"2..12.44444444....444444444..321",
	"..112.44444444....444444444..321",
	"1.....44444444....444.4.4.4..32.",
	"1.444.............444..3.1.....3",
	"..444..2.4...2....4.4.33111..233",
	"33444.22444.22........331....233",
	"3.4.4.224.4.22....222233.11..233",
	"......22.3..22....222233.11..233",
	".3....22.33.2...................",
	"33.......333.3....2211.......11.",
	"33.12.22233333....22.........11.",
	"33.12A2.2.3333A...2A.......A....",
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


## Facing (0..5) from `hex` that points most directly at the map center
## (compared in world space — several hex directions can tie on distance).
func facing_toward_center(hex: Vector2i) -> int:
	var to := HexCoord.axial_to_world(center, 1.0) - HexCoord.axial_to_world(hex, 1.0)
	var best := 0
	var best_dot := -INF
	for d in 6:
		var dir := HexCoord.axial_to_world(HexCoord.AXIAL_DIRECTIONS[d], 1.0).normalized()
		var dot := dir.dot(to.normalized())
		if dot > best_dot:
			best_dot = dot
			best = d
	return best
