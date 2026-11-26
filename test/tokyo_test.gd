extends Node
## Headless tests for the Tokyo battlefield: district data, sections (random,
## deterministic, playable, validated, JSON round trip), the city boxes
## (rotated buildings, sealed solids, elevated decks) in the rules, water and
## railway no-walk zones, bridges, and full matches on Tokyo sections.
##
## Run:
##   godot --headless --path . res://test/tokyo_test.tscn

var _failed := false


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	_test_districts()
	_test_sections()
	_test_rotated_boxes()
	_test_solids_and_decks()
	_test_water()
	_test_district_rules()
	_test_reasons()
	_test_render_matches_rules()
	_test_matches()
	print("  (%.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))
	print("TOKYO TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


# --- Data ---------------------------------------------------------------------

func _test_districts() -> void:
	var ids := TokyoMap.district_ids()
	_check(ids.size() >= 4, "Tokyo has districts (%d: %s)" % [ids.size(), ", ".join(ids)])
	var all_ok := true
	var detail := ""
	for id in ids:
		var d := TokyoMap.district(id)
		var ok := d != null and d.buildings.size() > 100 and d.roads.size() > 30 and d.land.size() > 0 \
			and d.size.x > 100 and d.size.y > 100 and d.attribution.contains("OpenStreetMap")
		if ok:
			for b in d.buildings:
				var f := int(b["floors"])
				var r: Rect2 = b["aabb"]
				if f < 1 or f > 7 or r.end.x < 0 or r.end.y < 0 or r.position.x > d.size.x or r.position.y > d.size.y:
					ok = false
					detail = " (%s: bad building %s)" % [id, b["c"]]
					break
		all_ok = all_ok and ok
		if not ok and detail == "":
			detail = " (%s)" % id
	_check(all_ok, "every district loads with buildings (1-7 floors) in it, roads, ground and OSM attribution%s" % detail)
	# The buildings match the official maps: PLATEAU footprints agree with
	# the GSI base map, and our boxes reproduce the footprints.
	var worst_q := ""
	var q_ok := true
	for id in ids:
		var q: Dictionary = TokyoMap.district(id).quality
		var ok := float(q.get("source_recall", 0)) >= 0.85 and float(q.get("box_recall", 0)) >= 0.9 			and float(q.get("box_precision", 0)) >= 0.95 and float(q.get("box_vs_gsi_recall", 0)) >= 0.85
		if not ok and worst_q == "":
			worst_q = " (%s: %s)" % [id, str(q)]
		q_ok = q_ok and ok
	_check(q_ok, "every district's buildings match PLATEAU and the GSI base map%s" % worst_q)
	# Roads are open: points along every carriageway (not bridges, which
	# may pass under deck-level buildings) are clear of buildings.
	var worst := ""
	var worst_share := 0.0
	for id in ids:
		var d := TokyoMap.district(id)
		var hits := 0
		var n := 0
		for r in d.roads:
			if int(r["cls"]) > TokyoDistrict.RoadClass.SERVICE or r["bridge"]:
				continue
			var pts: PackedVector2Array = r["pts"]
			for i in range(pts.size() - 1):
				var steps := maxi(1, int(pts[i].distance_to(pts[i + 1]) / 1.0))
				for k in steps:
					var p := pts[i].lerp(pts[i + 1], float(k) / steps)
					if p.x < 1 or p.y < 1 or p.x > d.size.x - 1 or p.y > d.size.y - 1:
						continue
					n += 1
					for b in d.buildings:
						if CityBox.has_point(b, p):
							hits += 1
							break
		var share := float(hits) / maxf(1.0, n)
		if share > worst_share:
			worst_share = share
			worst = id
	_check(worst_share < 0.01, "streets are clear of buildings in every district (worst %s: %.2f%% of road points)" % [worst, worst_share * 100.0])


func _test_sections() -> void:
	var a := TokyoMap.random_section(1234)
	var b := TokyoMap.random_section(1234)
	_check(a == b and not TokyoMap.is_sheet(a), "the same seed picks the same Tokyo section (%s)" % TokyoMap.place_name(a))
	var seen := {}
	var valid := true
	var playable := true
	for seed in range(1, 25):
		var s := TokyoMap.random_section(seed * 7919)
		seen[str(s["district"])] = true
		valid = valid and TokyoMap.valid_section(s)
		playable = playable and TokyoMap.playable(s)
	_check(valid and playable, "random sections are valid and playable")
	_check(seen.size() >= mini(3, TokyoMap.district_ids().size()), "sections come from several districts (%d)" % seen.size())
	var json: Variant = JSON.parse_string(JSON.stringify(TokyoMap.section_to_json(a)))
	_check(TokyoMap.section_from(json) == a and a.has("zone"), "sections survive JSON encoding (%s)" % str(json))
	var bad := [
		["nowhere", 0], [a["district"], -1], [a["district"], 99999], [a["district"], 1.5],
		["sheet", 0], "shibuya", [1, 2, 3], null,
	]
	var rejected := true
	for v in bad:
		rejected = rejected and TokyoMap.section_from(v).is_empty()
	_check(rejected, "malformed sections are rejected")
	var legacy := TokyoMap.section_from([0, 0, 20, 20])
	_check(TokyoMap.is_sheet(legacy) and legacy["rect"] == Rect2i(0, 0, 20, 20), "old hex-sheet sections are still understood")
	var old_rect := TokyoMap.section_from(["ueno", 60, 60, 44, 44])
	_check(not old_rect.is_empty() and TokyoMap.layout(old_rect) != null, "old rectangle sections still load")
	# Zones: every district has several; they keep clear of scenery-only
	# landmarks and their borders follow streets.
	var counts := []
	var clear := true
	var in_buildings := 0.0
	var samples := 0
	for id in TokyoMap.district_ids():
		var d := TokyoMap.district(id)
		counts.append(d.zones.size())
		for z in d.zones:
			for n in d.noplay:
				var c := Vector2(n.x, n.y)
				var dist := INF
				for k in z.size():
					dist = minf(dist, Geometry2D.get_closest_point_to_segment(c, z[k], z[(k + 1) % z.size()]).distance_to(c))
				clear = clear and not Geometry2D.is_point_in_polygon(c, z) and dist > n.z * 0.85
			for k in z.size():
				var a2 := z[k]
				var b2 := z[(k + 1) % z.size()]
				var steps := maxi(1, int(a2.distance_to(b2) / 0.5))
				for t in steps:
					in_buildings += 1.0 if d.built_at(a2.lerp(b2, float(t) / steps), 0.6) else 0.0
					samples += 1
	_check(counts.min() >= 10, "every district has battle zones (%s)" % str(counts))
	# Every zone keeps well inside the map data (the fog starts ~20 units in
	# from its edge), so nothing near a battle ever runs out of real city.
	var edge_gap := INF
	for id in TokyoMap.district_ids():
		var d := TokyoMap.district(id)
		for z in d.zones:
			for p in z:
				edge_gap = minf(edge_gap, minf(minf(p.x, p.y), minf(d.size.x - p.x, d.size.y - p.y)))
	_check(edge_gap >= 30.0, "zones keep away from the edge of the map data (closest %.1f units)" % edge_gap)
	_check(clear, "no zone covers a scenery-only landmark")
	_check(in_buildings / samples < 0.02, "zone borders follow streets and block edges (%.1f%% of the border cuts into a building)" % (in_buildings / samples * 100.0))
	# Zones are as rectangular as the blocks allow: each fills most of its
	# smallest enclosing rectangle.
	var fills: Array[float] = []
	for id in TokyoMap.district_ids():
		for z in TokyoMap.district(id).zones:
			fills.append(_rect_fill(z))
	fills.sort()
	_check(fills[0] >= 0.75 and fills[fills.size() / 2] >= 0.88,
		"zones are near-rectangular (fill of their rectangle: min %.2f, median %.2f)" % [fills[0], fills[fills.size() / 2]])
	# Zones are the size and shape of the original battle map (the whole
	# 32 x 32 hex sheet, about 48.5 x 56.3 units).
	var sheet := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 1,
		{ "district": TokyoMap.SHEET, "rect": Rect2i() }).bounds()
	var sheet_area := sheet.get_area()
	var areas: Array[float] = []
	var worst_aspect := 0.0
	for id in TokyoMap.district_ids():
		for z in TokyoMap.district(id).zones:
			var r := _min_rect(z)
			areas.append(_poly_area(z))
			worst_aspect = maxf(worst_aspect, maxf(r.x, r.y) / minf(r.x, r.y))
	areas.sort()
	var mid := areas[areas.size() / 2]
	_check(areas[0] >= sheet_area * 0.75 and areas[-1] <= sheet_area * 1.5 and absf(mid / sheet_area - 1.0) < 0.15,
		"zones are about the size of the original map (%.0f units²): %.0f / %.0f / %.0f" % [sheet_area, areas[0], mid, areas[-1]])
	_check(worst_aspect <= 1.65, "zones are no longer than 1.6 to 1 (worst %.2f)" % worst_aspect)


static func _poly_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	for k in poly.size():
		area += poly[k].cross(poly[(k + 1) % poly.size()])
	return absf(area) * 0.5


## Sides of a polygon's minimum-area enclosing rectangle.
static func _min_rect(poly: PackedVector2Array) -> Vector2:
	var hull := Geometry2D.convex_hull(poly)
	var best := INF
	var sides := Vector2.ONE
	for k in hull.size() - 1:
		var e := (hull[k + 1] - hull[k]).normalized()
		if e == Vector2.ZERO:
			continue
		var n := Vector2(-e.y, e.x)
		var u0 := INF
		var u1 := -INF
		var v0 := INF
		var v1 := -INF
		for p in hull:
			u0 = minf(u0, p.dot(e))
			u1 = maxf(u1, p.dot(e))
			v0 = minf(v0, p.dot(n))
			v1 = maxf(v1, p.dot(n))
		if (u1 - u0) * (v1 - v0) < best:
			best = (u1 - u0) * (v1 - v0)
			sides = Vector2(u1 - u0, v1 - v0)
	return sides


## A polygon's area over its minimum-area enclosing rectangle's.
func _rect_fill(poly: PackedVector2Array) -> float:
	var hull := Geometry2D.convex_hull(poly)
	var area := 0.0
	for k in poly.size():
		area += poly[k].cross(poly[(k + 1) % poly.size()])
	area = absf(area) * 0.5
	var best := INF
	for k in hull.size() - 1:
		var e := (hull[k + 1] - hull[k]).normalized()
		if e == Vector2.ZERO:
			continue
		var n := Vector2(-e.y, e.x)
		var u0 := INF
		var u1 := -INF
		var v0 := INF
		var v1 := -INF
		for p in hull:
			u0 = minf(u0, p.dot(e))
			u1 = maxf(u1, p.dot(e))
			v0 = minf(v0, p.dot(n))
			v1 = maxf(v1, p.dot(n))
		best = minf(best, (u1 - u0) * (v1 - v0))
	return area / best


# --- Geometry ---------------------------------------------------------------------

## An open 40 x 40 arena with the given boxes.
func _arena(buildings: Array, solids: Array = [], decks: Array = [], blocked: BlockedMask = null) -> MatchState:
	var ms := MatchState.new(1)
	var lay := CityLayout.new()
	lay.bounds = Rect2(0, 0, 40, 40)
	lay.buildings = buildings
	lay.solids = solids
	lay.decks = decks
	lay.blocked = blocked
	ms.layout = lay
	return ms


func _test_rotated_boxes() -> void:
	var a := deg_to_rad(30.0)
	var bld := CityBox.make(Vector2(20, 20), Vector2(5, 2), a, CityBox.Kind.BUILDING, 2)
	var ms := _arena([bld])
	var geo := ms.geometry()
	var along := Vector2.from_angle(a)
	var across := along.orthogonal()
	_check(geo.level_ok(Vector2(20, 20) + along * 4.5, 1) and not geo.level_ok(Vector2(20, 20) + across * 2.6, 1),
		"a rotated building's inside follows its angle")
	_check(not geo.ground_ok(Vector2(20, 20) + along * 4.0) and geo.ground_ok(Vector2(20, 20) + across * 3.0),
		"the street around a rotated building is walkable, the building is not")
	# The corner of the axis-aligned bounds is street.
	var r: Rect2 = bld["aabb"]
	_check(geo.ground_ok(r.position + Vector2(0.4, 0.4)), "the empty corner of a rotated building's bounds is street")
	var left := Vector2(20, 20) - across * 4.0
	var right := Vector2(20, 20) + across * 4.0
	var path := geo.nav_path(left, right)
	var clear := path.size() >= 3
	for i in range(1, path.size()):
		clear = clear and geo.ground_clear(path[i - 1], path[i])
	_check(clear, "routes go around a rotated building")
	_check(not Visibility.has_los(ms, left, 0, right, 0), "nobody sees through a rotated building")
	_check(Visibility.has_los(ms, left, 0, left + along * 8.0, 0), "lines along a rotated building's side are clear")
	var into := geo.route(left, 0, Vector2(20, 20), 2)
	_check(bool(into["ok"]), "a rotated building can be entered and climbed")
	var deep := Vector2(20, 20)
	var window := Vector2(20, 20) - across * 1.75
	_check(not Visibility.has_los(ms, left - across * 2.0, 0, deep, 1) and Visibility.has_los(ms, left, 0, window, 1),
		"inside a rotated building only the window side is seen")


func _test_solids_and_decks() -> void:
	var tower := CityBox.make(Vector2(10, 20), Vector2(2, 2), 0.3, CityBox.Kind.SOLID, 0, 0.0, 7.0)
	var deck := CityBox.make(Vector2(30, 20), Vector2(8, 1.0), PI / 2.0, CityBox.Kind.DECK, 0, 2.2, 2.55)
	var roof := CityBox.make(Vector2(26, 20), Vector2(1.5, 3), 0.0, CityBox.Kind.BUILDING, 3)
	var ms := _arena([roof], [tower], [deck])
	var geo := ms.geometry()
	_check(not geo.ground_ok(Vector2(10, 20)) and not geo.level_ok(Vector2(10, 20), 1) and not geo.level_ok(Vector2(10, 20), 7),
		"nobody stands in or on a sealed tower")
	_check(not Visibility.has_los(ms, Vector2(5, 20), 0, Vector2(15, 20), 0), "a tower blocks sight")
	_check(geo.ground_ok(Vector2(30, 20)) and geo.ground_clear(Vector2(29, 14), Vector2(31, 26)), "people walk under a deck")
	_check(Visibility.has_los(ms, Vector2(33, 16), 0, Vector2(27, 24), 0), "street-level sight passes under a deck")
	_check(not Visibility.has_los(ms, Vector2(26, 20), 3, Vector2(36, 20), 0), "a deck blocks sight from a roof to the street beyond")
	var fix := geo.settle(Vector2(10, 20), 0)
	_check(geo.ground_ok(fix["pos"]) and int(fix["level"]) == 0, "a character left inside a tower is put back on the street")


func _test_water() -> void:
	# A canal across the arena (x 18..22), a bridge over it at z = 10, and a
	# fenced railway along z = 30 with a level crossing at x = 10.
	var tris := PackedFloat32Array([18, 0, 22, 0, 22, 40, 18, 0, 22, 40, 18, 40])
	var bridge := { "pts": PackedVector2Array([Vector2(14, 10), Vector2(26, 10)]), "half": 1.5 }
	var rail := { "pts": PackedVector2Array([Vector2(0, 30), Vector2(17, 30)]), "half": 0.85 }
	var mask := BlockedMask.new(Rect2(0, 0, 40, 40), tris, [rail], [bridge], [Vector3(10, 30, 1.8)], CityGeometry.UNIT_RADIUS)
	var ms := _arena([], [], [], mask)
	var geo := ms.geometry()
	_check(not geo.ground_ok(Vector2(20, 20)) and not geo.ground_ok(Vector2(17.8, 20)) and geo.ground_ok(Vector2(17.5, 20)),
		"water (and a character's width from its edge) can't be walked on")
	_check(geo.ground_ok(Vector2(20, 10)), "bridges cross water")
	_check(Visibility.has_los(ms, Vector2(15, 20), 0, Vector2(25, 20), 0), "sight crosses water")
	var path := geo.nav_path(Vector2(15, 20), Vector2(25, 20))
	var via_bridge := false
	for p in path:
		via_bridge = via_bridge or absf(p.y - 10.0) < 1.6
	_check(path.size() >= 3 and via_bridge, "routes across water use the bridge")
	_check(bool(geo.jump_route(Vector2(17.5, 20), 0, Vector2(20.0, 20), 0)["ok"]) == false
		and bool(geo.jump_route(Vector2(17.3, 22), 0, Vector2(17.4, 24), 0)["ok"]), "a jump can't land in the water")
	_check(not geo.ground_ok(Vector2(5, 30)) and geo.ground_ok(Vector2(10, 30)), "railway tracks are fenced off, level crossings are open")


func _test_district_rules() -> void:
	# On a real section: every building box is drawn where the rules use it,
	# and spawns are on connected open street.
	var s := TokyoMap.random_section(99)
	var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 99, s)
	_check(ms.layout != null and ms.section == s and ms.layout.zone == TokyoMap.section_polygon(s), "a match is played in its zone")
	var geo := ms.geometry()
	var ok := true
	for u in ms.all_units():
		ok = ok and geo.ground_ok(u.pos) and Geometry2D.is_point_in_polygon(u.pos, ms.layout.zone)
	_check(ok, "spawns are on open street inside the zone")
	# Outside the zone (but inside its bounding box) nothing is reachable:
	# not the street, not a roof.
	var outside_ok := false
	var roof_outside_ok := false
	var tested := 0
	var b := ms.bounds()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for _i in 3000:
		var p := Vector2(rng.randf_range(b.position.x, b.end.x), rng.randf_range(b.position.y, b.end.y))
		if Geometry2D.is_point_in_polygon(p, ms.layout.zone):
			continue
		tested += 1
		outside_ok = outside_ok or geo.ground_ok(p)
		roof_outside_ok = roof_outside_ok or geo.level_ok(p, maxi(1, geo.floors_at(p)))
		if tested == 1:
			_check(geo.why_not(p, 0) == "outside", "a spot outside the zone says so")
	_check(tested > 50 and not outside_ok and not roof_outside_ok, "nothing outside the zone is reachable (%d spots)" % tested)
	var reach := true
	var units := ms.all_units()
	for i in range(1, units.size()):
		reach = reach and not geo.nav_path(units[0].pos, units[i].pos).is_empty()
	_check(reach, "every character can walk to every other")


## Every box is drawn exactly where the rules have it: the renderer's
## instance transform maps the unit cube onto the box's corners and heights
## (a rotated box must not come out sheared).
func _test_reasons() -> void:
	var tower := CityBox.make(Vector2(10, 20), Vector2(2, 2), 0.3, CityBox.Kind.SOLID, 0, 0.0, 7.0)
	var tris := PackedFloat32Array([18, 0, 22, 0, 22, 40, 18, 0, 22, 40, 18, 40])
	var rail := { "pts": PackedVector2Array([Vector2(0, 30), Vector2(17, 30)]), "half": 0.85 }
	var mask := BlockedMask.new(Rect2(0, 0, 40, 40), tris, [rail], [], [], CityGeometry.UNIT_RADIUS,
		PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(40, 40), Vector2(0, 40)]))
	var ms := _arena([CityBox.make(Vector2(30, 10), Vector2(2, 2), 0.0, CityBox.Kind.BUILDING, 2)], [tower], [], mask)
	var geo := ms.geometry()
	_check(geo.why_not(Vector2(20, 20), 0) == "water" and geo.why_not(Vector2(5, 30), 0) == "rail"
		and geo.why_not(Vector2(10, 20), 0) == "sealed" and geo.why_not(Vector2(30, 10), 0) == "wall"
		and geo.why_not(Vector2(30, 10), 1) == "" and geo.why_not(Vector2(5, 5), 0) == "",
		"every unreachable spot has a reason (water, railway, sealed, wall)")
	var d := TokyoMap.district("asakusa")
	var named := false
	for w in d.water:
		named = named or str(w["name"]).contains("Sumida")
	_check(named, "the Sumida River is named")


func _test_render_matches_rules() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var worst := 0.0
	for i in 60:
		var kind := i % 3
		var y0 := 2.2 if kind == CityBox.Kind.DECK else 0.0
		var b := CityBox.make(Vector2(rng.randf_range(0, 100), rng.randf_range(0, 100)),
			Vector2(rng.randf_range(0.3, 9), rng.randf_range(0.3, 9)), rng.randf_range(-PI, PI), kind,
			rng.randi_range(1, 5), y0, y0 + rng.randf_range(0.3, 6.0))
		var t := TokyoCity.box_transform(b)
		var want := CityBox.corners(b)
		for sy in [-0.5, 0.5]:
			var y := HexCoord.GROUND_Y + (float(b["y0"]) if sy < 0.0 else float(b["y1"]))
			for s in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]:
				var p := t * Vector3(s.x, sy, s.y)
				var best := INF
				for c in want:
					best = minf(best, Vector3(c.x, y, c.y).distance_to(p))
				worst = maxf(worst, best)
	_check(worst < 1e-4, "drawn boxes match the rules' boxes exactly (worst corner %.6f)" % worst)
	# On a real section, the physics solids (vision rays) are the rules' boxes.
	var s := TokyoMap.random_section(31)
	var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 31, s)
	var city := TokyoCity.new()
	add_child(city)
	city.build(ms.layout)
	var shapes := (city.get_node("Solids") as StaticBody3D).get_children()
	var boxes: Array = ms.layout.buildings + ms.layout.solids + ms.layout.decks
	var same := shapes.size() == boxes.size()
	for i in mini(shapes.size(), boxes.size()):
		var sh := shapes[i] as CollisionShape3D
		var b: Dictionary = boxes[i]
		var size := (sh.shape as BoxShape3D).size
		var h: Vector2 = b["h"]
		var c: Vector2 = b["c"]
		same = same and size.distance_to(Vector3(2.0 * h.x, float(b["y1"]) - float(b["y0"]), 2.0 * h.y)) < 1e-4 			and Vector2(sh.position.x, sh.position.z).distance_to(c) < 1e-4 			and absf(sh.transform.basis.x.normalized().dot(Vector3(cos(float(b["a"])), 0, sin(float(b["a"])))) - 1.0) < 1e-4
	_check(same, "the section's physics solids are its rule boxes (%d)" % boxes.size())
	city.free()


func _test_matches() -> void:
	# A few full turns on Tokyo: plans validate and resolve, deterministically.
	var squads := [TriggerLibrary.sample_units(), TriggerLibrary.sample_units()]
	var s := TokyoMap.random_section(4242)
	var m1 := MatchRunner.build_match(squads[0], squads[1], 4242, s)
	var m2 := MatchRunner.build_match(squads[0], squads[1], 4242, s)
	for turn in 3:
		for ms in [m1, m2]:
			var plans: Array = []
			for team in 2:
				var plan := TurnPlan.new(squads[team])
				for i in plan.units.size():
					var u: UnitState = (ms as MatchState).teams[team][i]
					var mv := PlanAction.new(TriggerLibrary.get_move_card())
					var target: Dictionary = (ms as MatchState).geometry().settle(u.pos + Vector2.from_angle(turn + i + team * 2.0) * 6.0, 0)
					mv.set_point(target["pos"], 0)
					plan.add(i, mv)
				plans.append(plan)
			MatchRunner.resolve_turn(ms, plans[0], plans[1])
	var same := true
	for i in m1.all_units().size():
		same = same and m1.all_units()[i].pos.distance_to(m2.all_units()[i].pos) < 1e-6
	_check(same, "turns on a Tokyo section resolve deterministically")


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
