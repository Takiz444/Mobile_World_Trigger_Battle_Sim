extends Node
## Headless tests for the game rules: continuous geometry and routes, plan
## timing (the 6-second turn, Stamina), the turn engine (movement, collisions,
## attacks, shields, triggers, simultaneity), vision and fog, spawns, map
## sections, plan / squad validation, and the server's rating and saves.
##
## Run:
##   godot --headless --path . res://test/rules_test.tscn

const HEX := 1.7320508075688772

var _failed := false


func _ready() -> void:
	_test_geometry()
	_test_timing()
	_test_movement()
	_test_building_levels()
	_test_collisions()
	_test_attacks()
	_test_shields()
	_test_triggers()
	_test_simultaneity()
	_test_visibility()
	_test_city_map()
	_test_city_rects()
	_test_spawns()
	_test_map_sections()
	_test_plan_codec()
	_test_squad_validation()
	_test_elo()
	_test_server_persistence()
	_test_state_snapshot()
	print("RULES TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


# --- Geometry & routes -----------------------------------------------------------

func _test_geometry() -> void:
	var ms := _arena(_block(6, 7, 6, 9, 2))
	var geo := ms.geometry()
	var box := _box(ms)
	var mid := box.get_center()
	var left := Vector2(box.position.x - 2.0, mid.y)
	var right := Vector2(box.end.x + 2.0, mid.y)
	_check(geo.ground_ok(left) and geo.ground_ok(right) and not geo.ground_ok(mid), "street is walkable, buildings are not")
	_check(geo.level_ok(mid, 1) and geo.level_ok(mid, 2) and not geo.level_ok(mid, 3) and not geo.level_ok(left, 1),
		"floors exist only inside buildings, up to the roof")
	_check(geo.is_inside(mid, 1) and not geo.is_inside(mid, 2), "floor 1 of a 2-floor building is inside, floor 2 is the roof")
	var path := geo.nav_path(left, right)
	var clear := path.size() >= 3
	for i in range(1, path.size()):
		clear = clear and geo.ground_clear(path[i - 1], path[i])
	_check(clear and geo.path_length(path) > left.distance_to(right) + 0.5, "street routes go around buildings")
	_check(geo.nav_path(left, left + Vector2(0, 3)).size() == 2, "an open straight line is walked directly")
	var into := geo.route(left, 0, mid, 2)
	var enters := false
	var climbs := false
	for s in into["segments"]:
		enters = enters or (int(s["l0"]) == 0 and int(s["l1"]) == 1)
		climbs = climbs or (int(s["l0"]) == 1 and int(s["l1"]) == 2)
	_check(bool(into["ok"]) and enters and climbs, "a route onto a roof enters the building and takes the stairs")
	var out := geo.route(mid, 2, right, 0)
	_check(bool(out["ok"]) and int(out["segments"].back()["l1"]) == 0, "a route from a roof back to the street")
	_check(not bool(geo.route(left, 0, mid, 0)["ok"]), "nobody stands on the street inside a wall")
	_check(not bool(geo.route(left, 0, Vector2(500, 500), 0)["ok"]), "routes off the map are rejected")
	var near := Vector2(box.position.x - 0.5, mid.y)
	var on_roof := Vector2(box.position.x + 1.0, mid.y)
	_check(bool(geo.jump_route(near, 0, on_roof, 2)["ok"]), "Grasshopper jumps from the street onto a roof")
	_check(not bool(geo.jump_route(left + Vector2(-3, 0), 0, on_roof, 2)["ok"]), "jumps have a limited reach")
	_check(not bool(geo.jump_route(near, 0, on_roof, 1)["ok"]), "no jumping into a building's interior")


# --- Plan timing ----------------------------------------------------------------

func _test_timing() -> void:
	var data := TestUnits.legacy()[0]
	var fast := TestUnits.legacy()[0]
	fast.talent_stamina = 2
	Talents.apply(fast)
	var kogetsu := PlanAction.new(TriggerLibrary.get_card("Kogetsu"))
	_check(is_equal_approx(TurnPlan.action_time(data, kogetsu), 1.8), "Kogetsu takes 1.8 s")
	_check(TurnPlan.action_time(fast, kogetsu) < TurnPlan.action_time(data, kogetsu), "Stamina makes every action take less time")
	_check(TurnPlan.speed(fast) > TurnPlan.speed(data), "Stamina makes characters faster on foot")

	var ms := _arena()
	var plain := TestUnits.legacy()[1]   # no blade: no Melee Penchant bonus
	var us := UnitState.new(plain, 0, Vector2(4, 10))
	var plan := TurnPlan.new([plain])
	plan.add(0, _point("Move", Vector2(9, 10)))
	var t := plan.move_used(ms, us, 0)
	_check(absf(t - 5.0 / TurnPlan.BASE_SPEED) < 0.01, "a move takes distance / speed (%.2f s)" % t)
	plan.add(0, _hold("Wait", 1.0), TurnPlan.MOVE_LANE)
	_check(absf(plan.move_used(ms, us, 0) - t - 1.0) < 0.01, "Wait adds its hold time")
	var at := TurnPlan.position_at(plan.move_schedule(ms, us, 0), us, t * 0.5, plain)
	_check((at["pos"] as Vector2).distance_to(Vector2(6.5, 10)) < 0.05, "the plan knows where a character is mid-move")

	var busy := TurnPlan.new([data])
	for _i in 4:
		busy.add(0, PlanAction.new(TriggerLibrary.get_card("Kogetsu")))
	(busy.lane(0, TurnPlan.ACT_LANE)[0] as PlanAction).target_unit = 0
	for a in busy.lane(0, TurnPlan.ACT_LANE):
		(a as PlanAction).target_unit = 0
	_check(busy.unit_error(ms, UnitState.new(data, 0, Vector2(4, 10)), 0).contains("longer"), "a lane can't run past the 6-second turn")
	var lost := TurnPlan.new([plain])
	lost.add(0, _point("Move", Vector2(500, 10)))
	_check(lost.unit_error(ms, us, 0) != "", "an unreachable move makes the plan invalid")
	var untargeted := TurnPlan.new([plain])
	untargeted.add(0, PlanAction.new(TriggerLibrary.get_card("Asteroid")))
	_check(untargeted.unit_error(ms, us, 0).contains("no target"), "an attack needs a target")
	_check(TurnPlan.fits_lane(TriggerLibrary.get_wait_card(), TurnPlan.MOVE_LANE)
		and TurnPlan.fits_lane(TriggerLibrary.get_wait_card(), TurnPlan.ACT_LANE)
		and not TurnPlan.fits_lane(TriggerLibrary.get_card("Asteroid"), TurnPlan.MOVE_LANE), "lanes accept only their actions (Wait fits both)")


# --- Movement -------------------------------------------------------------------

func _test_movement() -> void:
	var ms := _arena()
	_duel(ms, Vector2(4, 10), Vector2(18, 20), 1, 1)
	var a: UnitState = ms.teams[0][0]
	var p0 := _plan_for(ms, 0)
	p0.add(0, _point("Move", Vector2(9, 10)))
	var engine := TurnEngine.new()
	engine.begin(ms, p0, _plan_for(ms, 1))
	var arrived := -1.0
	while not engine.done():
		engine.step()
		if arrived < 0.0 and a.pos.distance_to(Vector2(9, 10)) < 0.01:
			arrived = engine.time
	_check(absf(arrived - 2.0) <= TurnEngine.STEP + 0.001, "a 5 m walk arrives after 2.0 s (%.2f)" % arrived)
	_check(absf(a.facing - 0.0) < 0.01, "walking faces the way you go")

	# Look: keep watching a point while walking.
	ms = _arena()
	_duel(ms, Vector2(4, 10), Vector2(18, 20), 1, 1)
	a = ms.teams[0][0]
	p0 = _plan_for(ms, 0)
	p0.add(0, _point("Look", Vector2(4, 20)))
	p0.add(0, _point("Move", Vector2(9, 10)))
	TurnEngine.new().resolve(ms, p0, _plan_for(ms, 1))
	var want := (Vector2(4, 20) - a.pos).angle()
	_check(absf(angle_difference(a.facing, want)) < 0.05, "Look keeps the character watching a point while it moves")

	# Lead Bullet weight: no moving.
	ms = _arena()
	_duel(ms, Vector2(4, 10), Vector2(18, 20), 1, 1)
	a = ms.teams[0][0]
	a.weight_time = TurnEngine.WEIGHT_SECONDS
	p0 = _plan_for(ms, 0)
	p0.add(0, _point("Move", Vector2(14, 10)))
	TurnEngine.new().resolve(ms, p0, _plan_for(ms, 1))
	var walked := a.pos.distance_to(Vector2(4, 10))
	_check(walked > 0.0 and walked < (TurnEngine.TURN_SECONDS - TurnEngine.WEIGHT_SECONDS) * TurnPlan.BASE_SPEED + 0.1,
		"a weighed-down character starts moving only when the weight wears off")

	# Into a building and up to the roof.
	ms = _arena(_block(6, 7, 6, 9, 2))
	var box := _box(ms)
	_duel(ms, Vector2(box.position.x - 2.0, box.get_center().y), Vector2(1, 1), 1, 1)
	a = ms.teams[0][0]
	p0 = _plan_for(ms, 0)
	p0.add(0, _point("Move", box.get_center(), 2))
	TurnEngine.new().resolve(ms, p0, _plan_for(ms, 1))
	_check(a.level == 2 and a.pos.distance_to(box.get_center()) < 0.01, "a character can walk in and climb to the roof")


## Buildings have a ground floor and a roof only, and a Grasshopper jump the
## turn cuts off never leaves anyone inside a wall or in mid-air.
func _test_building_levels() -> void:
	var ms := _arena(_block(6, 7, 6, 9, 3))
	var geo := ms.geometry()
	var box := _box(ms)
	var mid := box.get_center()
	_check(geo.level_ok(mid, 1) and geo.level_ok(mid, 3) and not geo.level_ok(mid, 2),
		"a 3-floor building has a ground floor and a roof, no middle floor")
	_check(bool(geo.route(Vector2(box.position.x - 2.0, mid.y), 0, mid, 3)["ok"]), "the roof is still reachable on foot")
	var stuck := geo.settle(mid, 0)
	_check(geo.level_ok(stuck["pos"], stuck["level"]) and int(stuck["level"]) == 3, "someone at street level inside a building is put on its roof")
	var floating := geo.settle(Vector2(box.position.x - 1.0, mid.y), 3)
	_check(geo.level_ok(floating["pos"], floating["level"]) and int(floating["level"]) == 0, "someone in mid-air beside a building is put on the street")
	var wall := geo.settle(Vector2(box.position.x - 0.1, mid.y), 0)
	_check(geo.level_ok(wall["pos"], wall["level"]), "someone inside a wall is put somewhere legal")

	var near := Vector2(box.position.x - 0.8, mid.y)
	var on_roof := Vector2(box.position.x + 1.5, mid.y)
	# The turn ends at 1/2, 1/3 and 1/6 of the way through a jump onto the
	# roof, and of a jump off it.
	for hold in [5.7, 5.8, 5.9]:
		for up in [true, false]:
			ms = _arena(_block(6, 7, 6, 9, 3))
			geo = ms.geometry()
			var start: Vector2 = near if up else on_roof
			_duel(ms, start, Vector2(1, 1), 1, 1)
			var a: UnitState = ms.teams[0][0]
			a.level = 0 if up else 3
			var p0 := _plan_for(ms, 0)
			p0.add(0, _hold("Wait", hold), TurnPlan.MOVE_LANE)
			p0.add(0, _point("Grasshopper", on_roof if up else near, 3 if up else 0))
			TurnEngine.new().resolve(ms, p0, _plan_for(ms, 1))
			var where := "%s, turn ends %.1f s into the jump" % ["up" if up else "down", TurnEngine.TURN_SECONDS - hold]
			_check(geo.level_ok(a.pos, a.level), "a cut-off jump lands somewhere legal (%s: %s level %d)" % [where, a.pos, a.level])
			_check(a.pos.distance_to(near) < 0.01 or a.pos.distance_to(on_roof) < 0.01, "a cut-off jump ends at its start or its landing (%s)" % where)
			var step := geo.route(a.pos, a.level, Vector2(box.position.x - 3.0, mid.y), 0)
			_check(bool(step["ok"]), "after a cut-off jump the character can move again (%s)" % where)

	# A character already stranded (an older turn) is put back at turn start.
	ms = _arena(_block(6, 7, 6, 9, 3))
	geo = ms.geometry()
	_duel(ms, mid, Vector2(1, 1), 1, 1)
	var lost: UnitState = ms.teams[0][0]
	lost.level = 0
	var p1 := _plan_for(ms, 0)
	TurnEngine.new().resolve(ms, p1, _plan_for(ms, 1))
	_check(geo.level_ok(lost.pos, lost.level), "a character stuck inside a building is freed at the next turn")


func _test_collisions() -> void:
	# Head-on: two characters walking into each other never overlap, and the
	# outcome is mirror-symmetric whichever team is processed first.
	var results := []
	for swap in [false, true]:
		var ms := _arena()
		var west := Vector2(5, 10)
		var east := Vector2(15, 10)
		_duel(ms, east if swap else west, west if swap else east, 1, 1)
		var p0 := _plan_for(ms, 0)
		p0.add(0, _point("Move", west if swap else east))
		var p1 := _plan_for(ms, 1)
		p1.add(0, _point("Move", east if swap else west))
		var engine := TurnEngine.new()
		engine.begin(ms, p0, p1)
		var closest := INF
		while not engine.done():
			engine.step()
			closest = minf(closest, ms.teams[0][0].pos.distance_to(ms.teams[1][0].pos))
		_check(closest >= CityGeometry.UNIT_RADIUS * 2.0 - 0.001, "walkers never overlap (closest %.2f m)" % closest)
		var w: UnitState = ms.teams[1][0] if swap else ms.teams[0][0]
		var e: UnitState = ms.teams[0][0] if swap else ms.teams[1][0]
		results.append([snappedf(w.pos.x, 0.001), snappedf(e.pos.x, 0.001)])
	_check(results[0] == results[1], "collisions don't favour either team (%s vs %s)" % [results[0], results[1]])
	_check(absf((float(results[0][0]) - 5.0) - (15.0 - float(results[0][1]))) < 0.01, "both walkers stop the same distance short")


# --- Attacks --------------------------------------------------------------------

func _test_attacks() -> void:
	# Asteroid (5 + 5 power) into an unshielded target: 10 damage.
	_check(_shot("Asteroid", Vector2(5, 10), Vector2(10, 10)) == 90, "a ranged hit in range deals attack + power")
	_check(_shot("Asteroid", Vector2(5, 10), Vector2(15, 10)) == 100, "out of range: no shot")
	_check(_shot("Kogetsu", Vector2(5, 10), Vector2(6.5, 10)) == 89, "melee hits within reach (5 + 6)")
	_check(_shot("Kogetsu", Vector2(5, 10), Vector2(8, 10)) == 100, "melee can't reach 3 m")

	# A building between shooter and target blocks the shot; Viper curves
	# around it when a teammate sees the target.
	var ms := _arena(_block(6, 7, 5, 10, 3))
	var box := _box(ms)
	var y := box.get_center().y
	var shooter := Vector2(box.position.x - 1.5, y)
	var target := Vector2(box.end.x + 1.5, y)
	ms.setup_team(0, _typed([UnitState.new(TestUnits.legacy()[1], 0, shooter, 0.0),
		UnitState.new(TestUnits.legacy()[3], 0, target + Vector2(0, 4), -PI / 2)]))
	ms.setup_team(1, _typed([UnitState.new(TestUnits.legacy()[1], 1, target, PI)]))
	for card_name in ["Asteroid", "Viper"]:
		var copy := _clone(ms)
		var p0 := _plan_for(copy, 0)
		var shot := PlanAction.new(TriggerLibrary.get_card(card_name))
		shot.target_unit = 0
		p0.add(0, shot)
		var engine := TurnEngine.new()
		engine.always_hit = true
		engine.resolve(copy, p0, _plan_for(copy, 1))
		var hp: int = copy.teams[1][0].trion_hp
		if card_name == "Asteroid":
			_check(hp == 100, "a building between shooter and target blocks the shot")
		else:
			_check(hp < 100, "Viper curves around the building to a target the team sees")

	# Can't shoot what the team doesn't see (target behind, out of detection).
	var blind := _arena()
	blind.setup_team(0, _typed([UnitState.new(TestUnits.legacy()[1], 0, Vector2(5, 10), PI)]))
	blind.setup_team(1, _typed([UnitState.new(TestUnits.legacy()[1], 1, Vector2(11, 10), PI)]))
	_check(_fire(blind, "Asteroid") == 100, "no shooting at an enemy nobody on the team sees")


func _test_shields() -> void:
	# Standing still behind a shield: Full Guard (defense x1.5 all round).
	_check(_shot("Asteroid", Vector2(5, 10), Vector2(10, 10), PI, "shield_still") == 97, "a standing shield is a Full Guard (10 - 7.5)")
	# Walking away with the shield up: hit from behind, no protection.
	_check(_shot("Asteroid", Vector2(5, 10), Vector2(7, 10), 0.0, "shield_away") == 90, "a shield doesn't cover your back")
	# Walking but watching the shooter: the front shield holds.
	_check(_shot("Asteroid", Vector2(5, 10), Vector2(10, 10), 0.0, "shield_watch") == 95, "a front shield on the move stops 5")
	# A raised front shield (not a Full Guard) against a blade that bends around it.
	var ms := _arena()
	_duel(ms, Vector2(5, 10), Vector2(6.5, 10), 3, 1)
	var guard: UnitState = ms.teams[1][0]
	guard.shield_active = true
	guard.full_guard = false
	var engine := TurnEngine.new()
	engine.begin(ms, _plan_for(ms, 0), _plan_for(ms, 1))
	guard.shield_active = true
	_check(is_equal_approx(engine._mitigation(guard, Vector2(5, 10), TriggerLibrary.get_card("Asteroid")), 5.0)
		and is_equal_approx(engine._mitigation(guard, Vector2(5, 10), TriggerLibrary.get_card("Scorpion")), 0.0),
		"Scorpion strikes around a front shield")
	_check(_shot("Ibis", Vector2(2, 10), Vector2(10, 10), PI, "shield_still") == 91, "Ibis pierces: Full Guard only halves (13 - 3.75)")
	var u := UnitState.new(TestUnits.legacy()[0], 0, Vector2.ZERO, 0.0)
	_check(TurnEngine.in_shield_arc(u, Vector2(3, 1)) and not TurnEngine.in_shield_arc(u, Vector2(-3, 0.5)), "a shield covers the front half")


func _test_triggers() -> void:
	# Lead Bullet: no damage, but the target can't move or dodge.
	var ms := _arena()
	_duel(ms, Vector2(5, 10), Vector2(10, 10), 3, 1)
	ms.teams[0][0].facing = 0.0
	ms.teams[1][0].facing = PI
	var p0 := _plan_for(ms, 0)
	var tag := PlanAction.new(TriggerLibrary.get_card("Lead Bullet"))
	tag.target_unit = 0
	p0.add(0, tag)
	var p1 := _plan_for(ms, 1)
	p1.add(0, _hold("Wait", 1.5), TurnPlan.MOVE_LANE)
	p1.add(0, _point("Move", Vector2(10, 20)))
	var engine := TurnEngine.new()
	engine.always_hit = true
	engine.resolve(ms, p0, p1)
	var b: UnitState = ms.teams[1][0]
	_check(b.trion_hp == 100 and b.pos.distance_to(Vector2(10, 10)) < 6.0, "Lead Bullet roots the target (moved %.1f m)" % b.pos.distance_to(Vector2(10, 10)))

	# Bagworm: hidden beyond the reveal range, revealed by attacking.
	ms = _arena()
	_duel(ms, Vector2(4, 10), Vector2(11, 10), 1, 3)
	ms.teams[0][0].facing = 0.0
	ms.teams[1][0].facing = PI
	p1 = _plan_for(ms, 1)
	p1.add(0, PlanAction.new(TriggerLibrary.get_card("Bagworm")))
	var p0b := _plan_for(ms, 0)
	var shot := PlanAction.new(TriggerLibrary.get_card("Asteroid"))
	shot.target_unit = 0
	p0b.add(0, _hold("Wait", 1.0))
	p0b.add(0, shot)
	engine = TurnEngine.new()
	engine.always_hit = true
	engine.resolve(ms, p0b, p1)
	_check(ms.teams[1][0].trion_hp == 100 and ms.teams[1][0].stealth_active, "Bagworm hides a character beyond the reveal range")
	_check(Visibility.enemy_states(ms, 0)[ms.teams[1][0]] == Visibility.State.HIDDEN, "a Bagworm user is off radar")

	# Spider wire: the deploying team gets defense and dodge on it.
	ms = _arena()
	_duel(ms, Vector2(5, 10), Vector2(12, 10), 3, 1)
	var scout: UnitState = ms.teams[0][0]
	var enemy: UnitState = ms.teams[1][0]
	var e2 := TurnEngine.new()
	e2.begin(ms, _plan_for(ms, 0), _plan_for(ms, 1))
	var before := e2.hit_chance(enemy, scout, TriggerLibrary.get_card("Asteroid"))
	ms.wires.append({ "pos": scout.pos, "team": 0 })
	var after := e2.hit_chance(enemy, scout, TriggerLibrary.get_card("Asteroid"))
	_check(after < before, "standing on your own Spider wire makes you harder to hit")
	ms.wires[0]["team"] = 1
	_check(is_equal_approx(e2.hit_chance(enemy, scout, TriggerLibrary.get_card("Asteroid")), before), "the enemy's wire gives no bonus")
	enemy.moving = true
	_check(e2.hit_chance(enemy, scout, TriggerLibrary.get_card("Asteroid")) < before, "shooting on the move is less accurate")
	enemy.moving = false
	scout.moving = true
	_check(e2.hit_chance(enemy, scout, TriggerLibrary.get_card("Asteroid")) < before
		and is_equal_approx(e2.hit_chance(enemy, scout, TriggerLibrary.get_card("Hound")), before + 0.15),
		"a moving target dodges straight shots, but not Hound")

	# Spider placement range.
	ms = _arena()
	_duel(ms, Vector2(5, 10), Vector2(20, 20), 3, 1)
	p0 = _plan_for(ms, 0)
	p0.add(0, _point("Spider", Vector2(7, 10)))
	p0.add(0, _point("Spider", Vector2(14, 10)))
	TurnEngine.new().resolve(ms, p0, _plan_for(ms, 1))
	_check(ms.wires.size() == 1 and (ms.wires[0]["pos"] as Vector2).distance_to(Vector2(7, 10)) < 0.01, "Spider wires go only within reach")


func _test_simultaneity() -> void:
	# Both 1 HP, both swing at the same moment: both bail out, a draw.
	var ms := _arena()
	_duel(ms, Vector2(5, 10), Vector2(6.5, 10), 0, 0)
	for u in ms.all_units():
		u.trion_hp = 1
	var plans := [_plan_for(ms, 0), _plan_for(ms, 1)]
	for team in 2:
		var hit := PlanAction.new(TriggerLibrary.get_card("Kogetsu"))
		hit.target_unit = 0
		plans[team].add(0, hit)
	var engine := TurnEngine.new()
	engine.always_hit = true
	engine.resolve(ms, plans[0], plans[1])
	_check(ms.teams[0][0].is_bailed and ms.teams[1][0].is_bailed and MatchRunner.winner(ms) == MatchRunner.DRAW,
		"blows landing at the same moment knock both out (draw)")
	# A faster character (Stamina) lands first.
	ms = _arena()
	_duel(ms, Vector2(5, 10), Vector2(6.5, 10), 0, 0)
	ms.teams[0][0].unit_data.talent_stamina = 4
	Talents.apply(ms.teams[0][0].unit_data)
	for u in ms.all_units():
		u.trion_hp = 1
	plans = [_plan_for(ms, 0), _plan_for(ms, 1)]
	for team in 2:
		var hit := PlanAction.new(TriggerLibrary.get_card("Kogetsu"))
		hit.target_unit = 0
		plans[team].add(0, hit)
	engine = TurnEngine.new()
	engine.always_hit = true
	engine.resolve(ms, plans[0], plans[1])
	_check(not ms.teams[0][0].is_bailed and ms.teams[1][0].is_bailed, "with more Stamina your blow lands first")


# --- Vision ---------------------------------------------------------------------

func _test_visibility() -> void:
	var ms := _arena()
	var viewer := UnitState.new(TestUnits.legacy()[0], 0, Vector2(10, 10), 0.0)
	var sniper := UnitState.new(TestUnits.legacy()[2], 0, Vector2(10, 10), 0.0)
	var pa := Visibility.profile(viewer)
	var ps := Visibility.profile(sniper)
	_check(is_equal_approx(float(ps["sight_range"]), float(pa["sight_range"]) + Visibility.SCOPE_BONUS), "a sniper scope extends the sight range")
	sniper.level = 3
	_check(is_equal_approx(float(Visibility.profile(sniper)["sight_range"]), float(ps["sight_range"]) + 3 * Visibility.LEVEL_SIGHT_BONUS), "height extends sight")
	var o := viewer.pos
	_check(Visibility.in_view(viewer, o + Vector2(Visibility.SIGHT_RANGE - 0.1, 0)), "sees far straight ahead (sight cone)")
	_check(not Visibility.in_view(viewer, o + Vector2(Visibility.SIGHT_RANGE + 0.5, 0)), "not past the sight range")
	_check(not Visibility.in_view(viewer, o + Vector2(0, Visibility.DETECT_RANGE + 1.0)), "doesn't see past the detection radius to the side")
	var all_round := true
	for k in 8:
		all_round = all_round and Visibility.in_view(viewer, o + Vector2.from_angle(TAU * k / 8.0) * (Visibility.DETECT_RANGE - 0.1))
	_check(all_round, "detects within %.1f m in every direction" % Visibility.DETECT_RANGE)

	ms = _arena(_block(6, 7, 5, 10, 2))
	var box := _box(ms)
	var y := box.get_center().y
	var a := Vector2(box.position.x - 1.0, y)
	var b := Vector2(box.end.x + 1.0, y)
	_check(not Visibility.has_los(ms, a, 0, b, 0), "nobody sees through a building")
	_check(Visibility.has_los(ms, a, 0, Vector2(a.x, y - 4.0), 0), "open street lines are clear")
	var deep := box.get_center()
	var window := Vector2(box.position.x + 0.4, y)
	var street := Vector2(box.position.x - 4.0, y)
	_check(not Visibility.has_los(ms, street, 0, deep, 1), "a character deep inside a building is hidden from the street")
	_check(Visibility.has_los(ms, street, 0, window, 1), "a character at the window can be seen")


# --- Map, spawns, sections ------------------------------------------------------

func _test_city_map() -> void:
	var map := MapData.city()
	_check(map.tiles.size() == MapData.COLS * MapData.ROWS, "city map is %dx%d hexes" % [MapData.COLS, MapData.ROWS])
	_check(map.buildings.size() == 472, "building footprint traced from the reference sheet (472 hexes)")
	var floors := [0, 0]
	for row in MapData.ROWS:
		for ch in MapData.LAYOUT[row]:
			if ch in ["1", "2", "3", "4"]:
				floors[0 if row >= MapData.ROWS / 2 else 1] += int(ch)
	_check(floors[0] == floors[1] and floors[0] > 0, "both halves have identical building mass (point-symmetric sheet)")


func _test_city_rects() -> void:
	var map := MapData.city()
	var rects := BuildingRects.compute(map.buildings)
	var covered := true
	var street_clear := true
	for hex in map.tiles:
		var p := HexCoord.axial_to_world(hex, 1.0)
		var hit: Dictionary = {}
		for r in rects:
			if BuildingRects.bounds(r).has_point(Vector2(p.x, p.z)):
				hit = r
				break
		if map.buildings.has(hex):
			covered = covered and not hit.is_empty() and int(hit["floors"]) == int(map.buildings[hex])
		elif not hit.is_empty():
			street_clear = false
	_check(covered, "every building hex sits inside a 3D building of its height")
	_check(street_clear, "no street hex is covered by a building")


func _test_spawns() -> void:
	var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 4242, MapData.random_section(4242))
	var geo := ms.geometry()
	var ok := true
	for u in ms.all_units():
		ok = ok and geo.ground_ok(u.pos) and u.level == 0
		ok = ok and geo.ground_clear(u.pos, u.pos + u.forward() * 1.0)
	_check(ok, "spawns are on open street, each facing open street")
	var again := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 4242, MapData.random_section(4242))
	_check(again.teams[1][2].pos == ms.teams[1][2].pos, "the same seed gives the same spawns")
	var closest := INF
	var differs := false
	for seed in 60:
		var m := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), seed, MapData.random_section(seed))
		var units := m.all_units()
		for i in units.size():
			for j in range(i + 1, units.size()):
				closest = minf(closest, units[i].pos.distance_to(units[j].pos))
		differs = differs or (seed > 0 and m.teams[0][0].pos != ms.teams[0][0].pos)
	_check(closest >= MatchRunner.SPAWN_MIN_DISTANCE - 0.001, "nobody spawns within 3 hexes of anyone else (closest pair over 60 maps: %.2f m)" % closest)
	_check(differs, "different seeds give different spawns")


func _test_map_sections() -> void:
	var full := MapData.COLS * MapData.ROWS
	var shapes := {}
	var all_ok := true
	for seed in 40:
		var r := MapData.random_section(seed)
		var share := float(r.size.x * r.size.y) / full
		all_ok = all_ok and MapData.valid_section(r) and share > 0.42 and share < 0.58
		shapes[r] = true
	_check(all_ok, "map sections are about half the city and inside it")
	_check(shapes.size() > 20, "map sections differ from match to match (%d/40 distinct)" % shapes.size())
	var sec := MapData.random_section(3)
	var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 3, sec)
	_check(ms.tiles.size() == sec.size.x * sec.size.y, "the match board is exactly the section")
	var inside := true
	for u in ms.all_units():
		inside = inside and ms.bounds().has_point(u.pos)
	_check(inside and ms.building_rects().size() > 0, "spawns lie inside the section, which has buildings")
	_check(MapData.section_from([0, 0, 5, 5]) == Rect2i() and MapData.section_from("x") == Rect2i(), "malformed sections are rejected")
	_check(MapData.section_from(MapData.section_to_array(sec)) == sec, "sections survive JSON encoding")

	var server := MatchServer.new()
	server.persist = false
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var id := str(server._create_match({ "squad": squad })["body"]["match_id"])
	server._join_match(id, { "squad": squad })
	var m: Dictionary = server._matches[id]
	var area: Rect2i = m["map"]
	_check(MapData.valid_section(area) and (m["ms"] as MatchState).tiles.size() == area.size.x * area.size.y,
		"server matches are played on a random section")
	_check(MapData.section_from(server._get_match(id, "")["body"].get("map")) == area, "clients are told the section")
	var restored := server._deserialize(JSON.parse_string(JSON.stringify(server._serialize(m))))
	_check(restored["map"] == area, "the section survives a server restart")
	server.free()


# --- Plans and squads -----------------------------------------------------------

func _test_plan_codec() -> void:
	var ms := _arena()
	_duel(ms, Vector2(5, 10), Vector2(12, 10), 1, 1)
	var units: Array[UnitData] = [ms.teams[0][0].unit_data]
	var plan := TurnPlan.new(units)
	plan.add(0, _point("Move", Vector2(7, 12)))
	plan.add(0, _hold("Wait", 0.5), TurnPlan.MOVE_LANE)
	var shot := PlanAction.new(TriggerLibrary.get_card("Asteroid"))
	shot.target_unit = 0
	plan.add(0, shot)
	plan.add(0, _hold("Shield", 2.0))
	plan.add(0, _point("Look", Vector2(12, 10)))
	var round := PlanCodec.decode_plan_checked(JSON.parse_string(JSON.stringify(PlanCodec.encode_plan(plan))), units, ms, ms.teams[0])
	_check(str(round["error"]) == "" and (round["plan"] as TurnPlan).lane(0, TurnPlan.ACT_LANE).size() == 3
		and (round["plan"] as TurnPlan).lane(0, TurnPlan.MOVE_LANE).size() == 2, "a plan survives JSON and the server's checks")

	var base := PlanCodec.encode_plan(plan)
	var cases := {
		"rejects an unequipped card": func(d: Dictionary) -> void: d["units"][0]["act"][0]["card"] = "Ibis",
		"rejects an action in the wrong lane": func(d: Dictionary) -> void: d["units"][0]["move"].append({ "card": "Asteroid", "unit": 0 }),
		"rejects a target off the map": func(d: Dictionary) -> void: d["units"][0]["move"][0]["to"] = [5000, 10],
		"rejects a non-number target": func(d: Dictionary) -> void: d["units"][0]["move"][0]["to"] = ["5", 10],
		"rejects an infinite target": func(d: Dictionary) -> void: d["units"][0]["move"][0]["to"] = [1e300, 10],
		"rejects a missing target": func(d: Dictionary) -> void: d["units"][0]["act"][0].erase("unit"),
		"rejects a bad enemy index": func(d: Dictionary) -> void: d["units"][0]["act"][0]["unit"] = 7,
		"rejects a negative hold": func(d: Dictionary) -> void: d["units"][0]["act"][1]["hold"] = -3,
		"rejects a lane longer than the turn": func(d: Dictionary) -> void: d["units"][0]["act"][1]["hold"] = 6.0,
		"rejects an unreachable move": func(d: Dictionary) -> void: d["units"][0]["move"][0]["level"] = 3,
		"rejects too many actions": func(d: Dictionary) -> void:
			for _i in 20:
				d["units"][0]["act"].append({ "card": "Wait", "hold": 0.25 }),
		"rejects a malformed row": func(d: Dictionary) -> void: d["units"][0] = [1, 2],
	}
	for label in cases:
		var d: Dictionary = base.duplicate(true)
		(cases[label] as Callable).call(d)
		_check(str(PlanCodec.decode_plan_checked(d, units, ms, ms.teams[0])["error"]) != "", label)

	var fallback := MatchRunner.build_fallback_plan(TriggerLibrary.sample_units())
	_check(is_equal_approx(fallback.act_used(0), TurnPlan.TURN_SECONDS), "the AFK fallback holds a shield all turn")


func _test_squad_validation() -> void:
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	_check(PlanCodec.validate_squad(squad) == "", "sample squad is valid")
	var buffed := squad.duplicate(true)
	buffed[0]["trion_hp"] = 9999
	_check(PlanCodec.validate_squad(buffed) != "", "rejects inflated Trion HP")
	var bad_sub := squad.duplicate(true)
	bad_sub[0]["sub"] = ["Kogetsu", null, null, null]
	_check(PlanCodec.validate_squad(bad_sub) != "", "rejects non-dual trigger in sub slot")
	var over := squad.duplicate(true)
	over[0]["main"] = ["Ibis", "Ibis", "Ibis", "Ibis"]
	over[0]["sub"] = ["Shield", null, null, null]
	_check(PlanCodec.validate_squad(over) != "", "rejects loadout over Trion budget")
	_check(PlanCodec.validate_squad(squad.slice(0, 2)) != "", "rejects wrong squad size")

	var units := TriggerLibrary.sample_units()
	_check(Talents.squad_total(units) == Talents.POINTS, "default squad spends the whole talent pool")
	_check(units.size() == 3 and units[0].unit_name == "Assassin" and units[1].unit_name == "Sniper"
		and units[2].unit_name == "Scout", "three playable characters")
	var u := UnitData.new()
	Talents.set_points(u, "stamina", 2)
	Talents.set_points(u, "hp", 1)
	Talents.set_points(u, "atk", 3)
	_check(is_equal_approx(u.tempo, 1.0 + 2 * Talents.TEMPO_PER_POINT)
		and u.base_trion_hp == TriggerLibrary.STANDARD_TRION_HP + Talents.HP_PER_POINT
		and u.attack_rating == TriggerLibrary.STANDARD_RATING + 3 * Talents.ATK_PER_POINT, "talents raise tempo, HP and ATK")
	var greedy := squad.duplicate(true)
	greedy[0]["talents"] = { "stamina": 4, "hp": 4, "atk": 4 }
	_check(PlanCodec.validate_squad(greedy) != "", "rejects a squad over the talent pool")
	var forged := squad.duplicate(true)
	forged[0]["attack"] = int(forged[0]["attack"]) + 3
	_check(PlanCodec.validate_squad(forged) != "", "rejects stats that don't match the talents")


# --- Server ---------------------------------------------------------------------

func _test_elo() -> void:
	var server := MatchServer.new()
	server.persist = false
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var a: Dictionary = server._register({ "name": "A" })["body"]
	var b: Dictionary = server._register({ "name": "B" })["body"]
	var ta: Dictionary = server._enqueue({ "player_id": a["player_id"], "secret": a["secret"], "squad": squad })["body"]
	var tb: Dictionary = server._enqueue({ "player_id": b["player_id"], "secret": b["secret"], "squad": squad })["body"]
	server._accept_ticket(str(ta["ticket"]), a["secret"])
	var matched: Dictionary = server._accept_ticket(str(tb["ticket"]), b["secret"])["body"]
	var m: Dictionary = server._matches[str(matched["match_id"])]
	for u in (m["ms"] as MatchState).teams[1]:
		(u as UnitState).is_bailed = true
	for team in 2:
		m["plans"][team] = MatchRunner.build_fallback_plan(m["teams"][team])
	server._resolve_turn(m)
	var acc_a: Dictionary = server._accounts[a["player_id"]]
	var acc_b: Dictionary = server._accounts[b["player_id"]]
	_check(int(m["winner"]) == 0 and roundi(acc_a["rating"]) == 1162 and roundi(acc_b["rating"]) == 838
		and m["rating_change"] == [162, -162],
		"ranked result updates Glicko-2 ratings (%d / %d)" % [roundi(acc_a["rating"]), roundi(acc_b["rating"])])
	_check(float(acc_a["rd"]) < Matchmaker.START_RD and float(acc_b["rd"]) < Matchmaker.START_RD,
		"a rated match makes both ratings more certain")
	server.free()


func _test_server_persistence() -> void:
	var server := MatchServer.new()
	server.persist = false
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var id := str(server._create_match({ "squad": squad })["body"]["match_id"])
	server._join_match(id, { "squad": squad })
	var m: Dictionary = server._matches[id]
	var ms: MatchState = m["ms"]
	ms.teams[0][0].trion_hp = 61
	ms.teams[0][1].pos += Vector2(0.37, 0.0)
	for team in 2:
		m["plans"][team] = MatchRunner.build_fallback_plan(m["teams"][team])
	server._resolve_turn(m)
	var frames: Array = m["history"][0]["frames"][0]
	_check(frames.size() >= 2 and float(frames[0]["t"]) == 0.0 and absf(float(frames.back()["t"]) - TurnEngine.TURN_SECONDS) < 0.01,
		"a turn records a replay frame every %.2f s" % MatchRunner.FRAME_SECONDS)
	var restored := server._deserialize(JSON.parse_string(JSON.stringify(server._serialize(m))))
	var back: MatchState = restored["ms"]
	_check(back.teams[0][0].trion_hp == 61 and back.teams[0][1].pos.distance_to(ms.teams[0][1].pos) < 0.001
		and restored["tokens"] == m["tokens"] and int(restored["turn"]) == 2, "server match survives save/load (state, tokens, turn)")
	server.free()


func _test_state_snapshot() -> void:
	var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 777)
	ms.teams[0][0].trion_hp = 42
	ms.teams[0][1].level = 2
	ms.wires.append({ "pos": Vector2(3.5, 4.25), "team": 1 })
	ms.rng.randf()
	var snap: Variant = JSON.parse_string(JSON.stringify(PlanCodec.encode_state(ms)))
	_check(PlanCodec.state_matches(ms, snap), "state matches its own JSON snapshot")
	var other := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 1)
	_check(not PlanCodec.state_matches(other, snap), "a different state is detected as a desync")
	PlanCodec.apply_state(other, snap)
	_check(PlanCodec.state_matches(other, snap), "apply_state resyncs units, wires, and RNG")
	_check(is_equal_approx(other.rng.randf(), ms.rng.randf()), "RNG continues identically after resync")


# --- Helpers --------------------------------------------------------------------

## An open 16 x 16-hex square of street (about 24 x 28 m), with optional
## buildings (map hex -> floors).
func _arena(buildings: Dictionary = {}) -> MatchState:
	var ms := MatchState.new(1)
	for col in 16:
		for row in 16:
			ms.tiles[MapData.offset_to_axial(col, row)] = true
	ms.buildings = buildings
	return ms


## A solid building block over offset columns c0..c1, rows r0..r1.
func _block(c0: int, c1: int, r0: int, r1: int, floors: int) -> Dictionary:
	var out := {}
	for c in range(c0, c1 + 1):
		for r in range(r0, r1 + 1):
			out[MapData.offset_to_axial(c, r)] = floors
	return out


func _box(ms: MatchState) -> Rect2:
	var box := BuildingRects.bounds(ms.building_rects()[0])
	for r in ms.building_rects():
		box = box.merge(BuildingRects.bounds(r))
	return box


func _typed(list: Array) -> Array[UnitState]:
	var out: Array[UnitState] = []
	out.assign(list)
	return out


## One character per team (legacy fixtures, standard stats).
func _duel(ms: MatchState, a: Vector2, b: Vector2, a_kind: int, b_kind: int) -> void:
	ms.setup_team(0, _typed([UnitState.new(TestUnits.legacy()[a_kind], 0, a, (b - a).angle())]))
	ms.setup_team(1, _typed([UnitState.new(TestUnits.legacy()[b_kind], 1, b, (a - b).angle())]))


func _plan_for(ms: MatchState, team: int) -> TurnPlan:
	var units: Array[UnitData] = []
	for u in ms.teams[team]:
		units.append((u as UnitState).unit_data)
	return TurnPlan.new(units)


func _point(card_name: String, p: Vector2, level: int = 0) -> PlanAction:
	var a := PlanAction.new(TriggerLibrary.get_card(card_name))
	a.set_point(p, level)
	return a


func _hold(card_name: String, seconds: float) -> PlanAction:
	var a := PlanAction.new(TriggerLibrary.get_card(card_name))
	a.hold = seconds
	return a


func _clone(ms: MatchState) -> MatchState:
	var c := MatchState.new(1)
	c.tiles = ms.tiles
	c.buildings = ms.buildings
	for team in 2:
		var list: Array = []
		for u in ms.teams[team]:
			var copy := UnitState.new(u.unit_data, u.team, u.pos, u.facing)
			copy.level = u.level
			list.append(copy)
		c.setup_team(team, _typed(list))
	return c


## Team 0's only character fires `card_name` at team 1's (always hits);
## returns the target's HP.
func _fire(ms: MatchState, card_name: String) -> int:
	var p0 := _plan_for(ms, 0)
	var a := PlanAction.new(TriggerLibrary.get_card(card_name))
	a.target_unit = 0
	p0.add(0, a)
	var engine := TurnEngine.new()
	engine.always_hit = true
	engine.resolve(ms, p0, _plan_for(ms, 1))
	return ms.teams[1][0].trion_hp


## A shooter (facing the target) at `from` fires `card_name` at a target at
## `to` facing `target_facing`; `defense` sets up the target:
##   "shield_still"  holds a shield standing still (Full Guard)
##   "shield_away"   shield up, walking straight away from the shooter
##   "shield_watch"  shield up, walking sideways while watching the shooter
## Returns the target's HP after the turn.
func _shot(card_name: String, from: Vector2, to: Vector2, target_facing: float = PI, defense: String = "") -> int:
	var ms := _arena()
	var card := TriggerLibrary.get_card(card_name)
	var kind := 0 if card.card_type == TriggerCard.CardType.MELEE else (2 if card.attack_range >= 15.0 else 1)
	if card_name == "Scorpion":
		kind = 3
	ms.setup_team(0, _typed([UnitState.new(TestUnits.legacy()[kind], 0, from, (to - from).angle())]))
	ms.setup_team(1, _typed([UnitState.new(TestUnits.legacy()[1], 1, to, target_facing)]))
	var p1 := _plan_for(ms, 1)
	match defense:
		"shield_still":
			p1.add(0, _hold("Shield", TurnPlan.TURN_SECONDS))
		"shield_away":
			p1.add(0, _hold("Shield", TurnPlan.TURN_SECONDS))
			p1.add(0, _point("Move", to + (to - from).normalized() * 12.0))
		"shield_watch":
			p1.add(0, _point("Look", from))
			p1.add(0, _hold("Shield", TurnPlan.TURN_SECONDS - 0.5))
			p1.add(0, _point("Move", to + Vector2(0, 6.0)))
	var p0 := _plan_for(ms, 0)
	var a := PlanAction.new(card)
	a.target_unit = 0
	p0.add(0, a)
	var engine := TurnEngine.new()
	engine.always_hit = true
	engine.resolve(ms, p0, p1)
	return ms.teams[1][0].trion_hp


func _check(cond: bool, label: String) -> void:
	if label == "-":
		return
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
