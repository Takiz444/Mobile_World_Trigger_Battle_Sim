class_name HexMesh
extends RefCounted
## Procedural hex-prism mesh generation for the 3D tabletop board.
##
## Produces a pointy-top hex prism centered at the origin, matching the
## HexCoord.axial_to_world() layout (vertices at 30 + 60*i degrees on the XZ
## plane). Vertices carry flat-shaded normals (up / down / outward radial).
## Back-face culling is not assumed; use CULL_DISABLED or correct winding.

## Six hex vertices on the XZ plane (y = 0), ordered counter-clockwise.
static func ring_points(size: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in 6:
		var angle := deg_to_rad(30.0 + 60.0 * i)
		pts.append(Vector3(size * cos(angle), 0.0, size * sin(angle)))
	return pts


static func build(size: float, height: float) -> ArrayMesh:
	var half_h := height * 0.5
	var ring := ring_points(size)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	# Top cap (normal +Y).
	var top_base := vertices.size()
	for p in ring:
		vertices.append(Vector3(p.x, half_h, p.z))
		normals.append(Vector3.UP)
	for i in range(1, 5):
		indices.append_array(PackedInt32Array([top_base, top_base + i, top_base + i + 1]))

	# Bottom cap (normal -Y, reversed winding).
	var bot_base := vertices.size()
	for p in ring:
		vertices.append(Vector3(p.x, -half_h, p.z))
		normals.append(Vector3.DOWN)
	for i in range(1, 5):
		indices.append_array(PackedInt32Array([bot_base, bot_base + i + 1, bot_base + i]))

	# Side walls (outward radial normals, flat shaded).
	for i in 6:
		var j := (i + 1) % 6
		var a := ring[i]
		var b := ring[j]
		var n := Vector3(a.x + b.x, 0.0, a.z + b.z).normalized()
		var base := vertices.size()
		vertices.append(Vector3(a.x, half_h, a.z))
		vertices.append(Vector3(b.x, half_h, b.z))
		vertices.append(Vector3(b.x, -half_h, b.z))
		vertices.append(Vector3(a.x, -half_h, a.z))
		for _k in 4:
			normals.append(n)
		indices.append_array(PackedInt32Array([base, base + 1, base + 2]))
		indices.append_array(PackedInt32Array([base, base + 2, base + 3]))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Convex collision shape matching the hex prism (12 points: top + bottom rings).
static func build_convex_shape(size: float, height: float) -> ConvexPolygonShape3D:
	var half_h := height * 0.5
	var pts := PackedVector3Array()
	for p in ring_points(size):
		pts.append(Vector3(p.x, half_h, p.z))
	for p in ring_points(size):
		pts.append(Vector3(p.x, -half_h, p.z))

	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	return shape
