class_name HexCoord
extends RefCounted
## The map sheet's hex lattice (flat-top, axial coordinates). Play itself is
## continuous: the lattice only lays out the reference map (MapData) and its
## buildings (BuildingRects) in world space, and sets the world's vertical
## scale (street surface height and floor height).

const SQRT3 := 1.7320508075688772

## World height of one building floor (gameplay floors map to this).
const FLOOR_HEIGHT := 1.0

## World height of the street surface that characters stand on.
const GROUND_Y := 0.175

const AXIAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),    # SE
	Vector2i(1, -1),   # NE
	Vector2i(0, -1),   # N
	Vector2i(-1, 0),   # NW
	Vector2i(-1, 1),   # SW
	Vector2i(0, 1),    # S
]


## World position (XZ plane) of a map hex's center.
static func axial_to_world(hex: Vector2i, size: float) -> Vector3:
	var x := size * (1.5 * hex.x)
	var z := size * (SQRT3 * 0.5 * hex.x + SQRT3 * hex.y)
	return Vector3(x, 0.0, z)


static func neighbors(hex: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dir in AXIAL_DIRECTIONS:
		result.append(hex + dir)
	return result
