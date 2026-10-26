extends Node
## Headless unit tests for combat rules and server-side validation: ranged
## shield arcs, simultaneous movement, Grasshopper sub-slot movement, squad /
## plan validation, and state snapshots.
##
## Run:
##   godot --headless --path . res://test/rules_test.tscn

var _failed := false


func _ready() -> void:
	_test_ranged_shield()
	_test_contested_move()
	_test_swap_move()
	_test_chain_move()
	_test_grasshopper_sub()
	_test_elevation_chain()
	_test_elevation_contest()
	_test_elevation_rules()
	_test_ranged_at_elevated_target()
	_test_split_targets()
	_test_bagworm_cost()
	_test_bagworm_toggle()
	_test_building_blocks_shot()
	_test_line_of_sight()
	_test_fog_states()
	_test_city_map()
	_test_server_persistence()
	_test_trigger_traits()
	_test_lead_bullet()
	_test_grasshopper_jump()
	_test_wire_penchant()
	_test_melee_assist()
	_test_crossfire_assist()
	_test_elo()
	_test_vision_profiles()
	_test_los_3d()
	_test_interior_vision()
	_test_look_and_attack_facing()
	_test_city_rects()
	_test_no_seeing_through_buildings()
	_test_squad_validation()
	_test_plan_validation()
	_test_state_snapshot()
	print("RULES TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


# --- Combat -----------------------------------------------------------------

func _test_ranged_shield() -> void:
	var shooter_hex := Vector2i(0, 0)
	var target_hex := Vector2i(0, 3)
	var front := TickEngine.attack_direction(target_hex, shooter_hex)
	_check(front != -1, "attack direction resolves at range 3")

	# Shield facing the shooter mitigates (5 atk + 5 power - 5 def = 5).
	var hp_front := _shoot(shooter_hex, target_hex, front, true)
	_check(hp_front == 95, "ranged hit on front shield mitigated (hp %d)" % hp_front)

	# Same shot into the unshielded rear bypasses defense (10 damage).
	var hp_rear := _shoot(shooter_hex, target_hex, posmod(front + 3, 6), true)
	_check(hp_rear == 90, "ranged hit on rear flank unmitigated (hp %d)" % hp_rear)

	# No shield at all: full damage.
	var hp_none := _shoot(shooter_hex, target_hex, front, false)
	_check(hp_none == 90, "ranged hit without shield unmitigated (hp %d)" % hp_none)


## One Asteroid shot from team 0 at a team-1 target; returns the target's HP.
func _shoot(from: Vector2i, to: Vector2i, target_facing: int, shield: bool) -> int:
	var ms := _match([[0, from, 0], [1, to, target_facing]])
	var p0 := _plan(ms, 0)
	var p1 := _plan(ms, 1)
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Asteroid"))
	p0.set_target(0, 0, to)
	if shield:
		p1.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Shield"))
	var engine := TickEngine.new()
	engine.always_hit = true
	engine.resolve_tick(ms, p0, p1, 0)
	return (ms.teams[1][0] as UnitState).trion_hp


func _test_contested_move() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(2, 0), 0]])
	var p0 := _move_plan(ms, 0, Vector2i(1, 0))
	var p1 := _move_plan(ms, 1, Vector2i(1, 0))
	TickEngine.new().resolve_tick(ms, p0, p1, 0)
	_check(ms.teams[0][0].hex == Vector2i(0, 0) and ms.teams[1][0].hex == Vector2i(2, 0),
		"contested hex: both units bounce (no team-0 priority)")


func _test_swap_move() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(1, 0), 0]])
	var p0 := _move_plan(ms, 0, Vector2i(1, 0))
	var p1 := _move_plan(ms, 1, Vector2i(0, 0))
	TickEngine.new().resolve_tick(ms, p0, p1, 0)
	_check(ms.teams[0][0].hex == Vector2i(0, 0) and ms.teams[1][0].hex == Vector2i(1, 0),
		"swap: units cannot pass through each other")


func _test_chain_move() -> void:
	# Team 1 vacates (1,0) in the same tick team 0 enters it.
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(1, 0), 0]])
	var p0 := _move_plan(ms, 0, Vector2i(1, 0))
	var p1 := _move_plan(ms, 1, Vector2i(2, 0))
	TickEngine.new().resolve_tick(ms, p0, p1, 0)
	_check(ms.teams[0][0].hex == Vector2i(1, 0) and ms.teams[1][0].hex == Vector2i(2, 0),
		"chain: follow into a hex vacated the same tick")


func _test_grasshopper_sub() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(4, 0), 0]])
	var p0 := _plan(ms, 0)
	var ok := p0.assign(0, 0, TurnPlan.SUB_SLOT, TriggerLibrary.get_card("Grasshopper"))
	p0.set_target(0, 0, Vector2i(0, 1), 0, TurnPlan.SUB_SLOT)
	TickEngine.new().resolve_tick(ms, p0, _plan(ms, 1), 0)
	_check(ok and ms.teams[0][0].hex == Vector2i(0, 1), "Grasshopper in sub slot moves the unit")


func _test_elevation_chain() -> void:
	# A climbs from floor 1 to floor 2 while B enters floor 1 from the street.
	var ms := _match([[0, Vector2i(1, 0), 0], [1, Vector2i(0, 0), 0]])
	ms.buildings[Vector2i(1, 0)] = 2
	ms.teams[0][0].floor = 1
	var p0 := _move_plan(ms, 0, Vector2i(1, 0), 2)
	var p1 := _move_plan(ms, 1, Vector2i(1, 0), 1)
	TickEngine.new().resolve_tick(ms, p0, p1, 0)
	_check(ms.teams[0][0].floor == 2 and ms.teams[1][0].hex == Vector2i(1, 0) and ms.teams[1][0].floor == 1,
		"elevation: climb + enter below resolve together")


func _test_elevation_contest() -> void:
	# Both teams try to enter floor 1 of the same building in the same tick.
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(2, 0), 0]])
	ms.buildings[Vector2i(1, 0)] = 1
	var p0 := _move_plan(ms, 0, Vector2i(1, 0), 1)
	var p1 := _move_plan(ms, 1, Vector2i(1, 0), 1)
	TickEngine.new().resolve_tick(ms, p0, p1, 0)
	_check(ms.teams[0][0].hex == Vector2i(0, 0) and ms.teams[1][0].hex == Vector2i(2, 0),
		"elevation: contested floor bounces both units")


func _test_elevation_rules() -> void:
	var ms := MatchState.new(1)
	ms.buildings[Vector2i(1, 0)] = 3
	ms.buildings[Vector2i(2, 0)] = 1
	_check(TickEngine.is_valid_move(ms, Vector2i(0, 0), 0, Vector2i(1, 0), 1), "enter building from street")
	_check(not TickEngine.is_valid_move(ms, Vector2i(0, 0), 0, Vector2i(1, 0), 0), "cannot walk into a building at ground level")
	_check(not TickEngine.is_valid_move(ms, Vector2i(1, 0), 1, Vector2i(1, 0), 3), "climb only one floor per move")
	_check(not TickEngine.is_valid_move(ms, Vector2i(1, 0), 1, Vector2i(2, 0), 0), "cannot exit onto another building's ground")
	_check(TickEngine.is_valid_move(ms, Vector2i(1, 0), 1, Vector2i(2, 0), 1), "cross between equal-height floors")


func _test_ranged_at_elevated_target() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(0, 3), 0]])
	ms.buildings[Vector2i(0, 3)] = 2
	ms.teams[1][0].floor = 2
	var p0 := _plan(ms, 0)
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Asteroid"))
	p0.set_target(0, 0, Vector2i(0, 3))
	var engine := TickEngine.new()
	engine.always_hit = true
	engine.resolve_tick(ms, p0, _plan(ms, 1), 0)
	_check(ms.teams[1][0].trion_hp == 90, "ranged attack reaches a unit on an upper floor")


func _test_split_targets() -> void:
	# Main moves one way while Sub (Viper) shoots a different hex, same tick.
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(0, 3), 0]])
	var p0 := _plan(ms, 0)
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_move_card())
	p0.set_target(0, 0, Vector2i(-1, 0), 0, TurnPlan.MAIN_SLOT)
	var ok := p0.assign(0, 0, TurnPlan.SUB_SLOT, TriggerLibrary.get_card("Viper"))
	p0.set_target(0, 0, Vector2i(0, 3), 0, TurnPlan.SUB_SLOT)
	var engine := TickEngine.new()
	engine.always_hit = true
	engine.resolve_tick(ms, p0, _plan(ms, 1), 0)
	_check(ok and ms.teams[0][0].hex == Vector2i(-1, 0) and ms.teams[1][0].trion_hp < 100,
		"Main and Sub slots aim at different targets")

	var round_trip := PlanCodec.decode_plan(PlanCodec.encode_plan(p0), p0.units)
	var ta := round_trip.get_tick(0, 0)
	_check(ta.slot_target(TurnPlan.SUB_SLOT) == Vector2i(0, 3) and ta.slot_target(TurnPlan.MAIN_SLOT) == Vector2i(-1, 0),
		"per-slot targets survive JSON encoding")
	p0.set_facing(0, 0, TurnPlan.SUB_SLOT, 2)
	var rt2 := PlanCodec.decode_plan(PlanCodec.encode_plan(p0), p0.units).get_tick(0, 0)
	_check(rt2.slot_facing(TurnPlan.SUB_SLOT) == 2 and not rt2.slot_has_facing(TurnPlan.MAIN_SLOT),
		"per-slot facing overrides survive JSON encoding")


func _test_bagworm_cost() -> void:
	var units := TriggerLibrary.sample_units()
	var plan := TurnPlan.new(units)
	var bag := TriggerLibrary.get_card("Bagworm")
	for t in 3:
		plan.assign(0, t, TurnPlan.MAIN_SLOT, bag)
	_check(plan.get_at_spent(0) == bag.action_at_cost, "Bagworm costs 1 AT per turn, not per tick")


func _test_bagworm_toggle() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(6, 0), 0]])
	var p0 := _plan(ms, 0)
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Bagworm"))
	var engine := TickEngine.new()
	for t in TurnPlan.TICKS_PER_TURN:
		engine.resolve_tick(ms, p0, _plan(ms, 1), t)
	_check(ms.teams[0][0].stealth_active, "Bagworm stays on for the rest of the turn")
	engine.resolve_tick(ms, _plan(ms, 0), _plan(ms, 1), 0)
	_check(not ms.teams[0][0].stealth_active, "Bagworm drops at the next turn unless maintained")


func _test_building_blocks_shot() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(0, 3), 0]])
	ms.buildings[Vector2i(0, 1)] = 3
	var p0 := _plan(ms, 0)
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Asteroid"))
	p0.set_target(0, 0, Vector2i(0, 3))
	var engine := TickEngine.new()
	engine.always_hit = true
	engine.resolve_tick(ms, p0, _plan(ms, 1), 0)
	_check(ms.teams[1][0].trion_hp == 100, "a building between shooter and target blocks the shot")


func _test_line_of_sight() -> void:
	var ms := MatchState.new(1)
	ms.buildings[Vector2i(0, 1)] = 2
	_check(not Visibility.has_los(ms, Vector2i(0, 0), 0, Vector2i(0, 3), 0), "building blocks ground-level sight")
	_check(Visibility.has_los(ms, Vector2i(0, 0), 3, Vector2i(0, 3), 0), "a viewer above the building sees over it")
	ms.cover[Vector2i(0, 2)] = 2
	ms.buildings.clear()
	_check(not Visibility.has_los(ms, Vector2i(0, 0), 0, Vector2i(0, 3), 0), "full cover blocks ground-level sight")


func _test_fog_states() -> void:
	# Viewer at (0,0) faces E (+q). Enemies: ahead in the cone, behind it far
	# away, and a Bagworm user nearby.
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(5, 0), 3], [1, Vector2i(-5, 0), 0], [1, Vector2i(3, 0), 0]])
	ms.teams[1][2].stealth_active = true
	var states := Visibility.enemy_states(ms, 0)
	_check(int(states[ms.teams[1][0]]) == Visibility.State.SIGHT, "enemy in the vision cone is in direct sight")
	_check(int(states[ms.teams[1][1]]) == Visibility.State.RADAR, "enemy behind the viewer shows only on radar")
	_check(int(states[ms.teams[1][2]]) == Visibility.State.SIGHT, "Bagworm user within 3 hexes is revealed")
	ms.teams[1][2].hex = Vector2i(6, -3)
	states = Visibility.enemy_states(ms, 0)
	_check(int(states[ms.teams[1][2]]) == Visibility.State.HIDDEN, "distant Bagworm user is removed from radar")

	var view := Visibility.encode_view(ms, 0, 5)
	var behind: Dictionary = view["units"][2]
	_check(int(behind["vis"]) == Visibility.State.RADAR and not behind.has("hp") and behind.has("ping"),
		"radar entries carry a ping but no identity or HP")
	var ping := Vector2i(int(behind["ping"][0]), int(behind["ping"][1]))
	var off := HexCoord.distance(ping, Vector2i(-5, 0))
	_check(off >= 1 and off <= 2, "radar ping is offset 1-2 hexes from the true position")


func _test_city_map() -> void:
	var map := MapData.city()
	_check(map.tiles.size() == MapData.COLS * MapData.ROWS, "city map is %dx%d hexes" % [MapData.COLS, MapData.ROWS])
	_check(map.spawns[0].size() == 4 and map.spawns[1].size() == 4, "four spawn hexes per team")
	var spawns_clear := true
	for team in 2:
		for hex in map.spawns[team]:
			if map.buildings.has(hex) or map.cover.has(hex):
				spawns_clear = false
	_check(spawns_clear, "spawns are on open street")
	_check(map.buildings.size() == 472, "building footprint traced from the reference sheet (472 hexes)")
	var floors := [0, 0]
	for row in MapData.ROWS:
		for ch in MapData.LAYOUT[row]:
			if ch in ["1", "2", "3", "4"]:
				floors[0 if row >= MapData.ROWS / 2 else 1] += int(ch)
	_check(floors[0] == floors[1] and floors[0] > 0, "both halves have identical building mass (point-symmetric sheet)")

	var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units())
	_check(not ms.has_tile(Vector2i(500, 500)) and not TickEngine.is_valid_move(ms, ms.teams[0][0].hex, 0, Vector2i(500, 500), 0),
		"moves off the map are rejected")


func _test_server_persistence() -> void:
	var server := MatchServer.new()
	server.persist = false
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var created := server._create_match({ "squad": squad, "seed": 99 })
	var id := str(created["body"]["match_id"])
	server._join_match(id, { "squad": squad })
	var m: Dictionary = server._matches[id]
	(m["ms"] as MatchState).teams[0][0].trion_hp = 61
	var stored: Variant = JSON.parse_string(JSON.stringify(server._serialize(m)))
	var restored := server._deserialize(stored)
	var ms: MatchState = restored["ms"]
	_check(ms != null and ms.teams[0][0].trion_hp == 61 and restored["tokens"] == m["tokens"] and int(restored["turn"]) == 1,
		"server match survives save/load (state, tokens, turn)")
	server.free()


# --- Trigger traits & combos -----------------------------------------------

## Team 0 unit `idx` fires `card_name` at `target_hex` on tick 0 (always hits).
func _fire(ms: MatchState, card_name: String, target_hex: Vector2i, p1: TurnPlan = null, idx: int = 0) -> void:
	var p0 := _plan(ms, 0)
	p0.assign(idx, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card(card_name))
	p0.set_target(idx, 0, target_hex)
	var engine := TickEngine.new()
	engine.always_hit = true
	engine.resolve_tick(ms, p0, p1 if p1 != null else _plan(ms, 1), 0)


## HP of a team-1 target at range 3 after one shot (target faces the shooter).
func _shot_hp(card_name: String, setup: Callable = Callable(), shield := 0, target := Vector2i(0, 3)) -> int:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, target, TickEngine.attack_direction(target, Vector2i(0, 0))]])
	if setup.is_valid():
		setup.call(ms)
	var p1 := _plan(ms, 1)
	if shield >= 1:
		p1.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Shield"))
	if shield >= 2:
		p1.assign(0, 0, TurnPlan.SUB_SLOT, TriggerLibrary.get_card("Shield"))
	_fire(ms, card_name, target, p1)
	return (ms.teams[1][0] as UnitState).trion_hp


func _test_trigger_traits() -> void:
	var half_cover := func(ms: MatchState) -> void: ms.cover[Vector2i(0, 1)] = 1
	_check(_shot_hp("Asteroid", half_cover) == 95, "Asteroid is halved by half cover")
	_check(_shot_hp("Hound", half_cover) == 91, "Hound homes past half cover")

	var tower := func(ms: MatchState) -> void: ms.buildings[Vector2i(0, 1)] = 3
	_check(_shot_hp("Asteroid", tower) == 100, "Asteroid is stopped by a building")
	_check(_shot_hp("Viper", tower) == 91, "Viper curves around a building")

	_check(_shot_hp("Asteroid", Callable(), 1) == 95, "Shield mitigates Asteroid")
	_check(_shot_hp("Ibis", Callable(), 1) == 87, "Ibis pierces a Shield")
	_check(_shot_hp("Ibis", Callable(), 2) == 91, "Full Guard only halves Ibis")

	_check(_shot_hp("Egret", Callable(), 0, Vector2i(0, 9)) == 90, "Egret snipes at range 9")
	_check(_shot_hp("Asteroid", Callable(), 0, Vector2i(0, 9)) == 100, "Asteroid can't reach range 9")

	_check(_shot_hp("Kogetsu", Callable(), 1, Vector2i(0, 1)) == 94, "Kogetsu is mitigated by a front Shield")
	_check(_shot_hp("Scorpion", Callable(), 1, Vector2i(0, 1)) == 91, "Scorpion strikes around a Shield")

	# Raygust: the wielder's own strike raises a front shield that tick.
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(0, 3), TickEngine.attack_direction(Vector2i(0, 3), Vector2i(0, 0))]])
	var p1 := _plan(ms, 1)
	p1.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Raygust"))
	p1.set_target(0, 0, Vector2i(0, 4))
	_fire(ms, "Asteroid", Vector2i(0, 3), p1)
	_check(ms.teams[1][0].trion_hp == 95, "Raygust blocks like a Shield while swinging")


func _test_lead_bullet() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(0, 3), 0]])
	_fire(ms, "Lead Bullet", Vector2i(0, 3))
	var target: UnitState = ms.teams[1][0]
	_check(target.trion_hp == 100 and target.weight_ticks == TickEngine.WEIGHT_TICKS, "Lead Bullet weighs the target down without damage")
	var p1 := _plan(ms, 1)
	p1.assign(0, 1, TurnPlan.MAIN_SLOT, TriggerLibrary.get_move_card())
	p1.set_target(0, 1, Vector2i(0, 4))
	TickEngine.new().resolve_tick(ms, _plan(ms, 0), p1, 1)
	_check(target.hex == Vector2i(0, 3), "a weighed-down unit cannot move")


func _test_grasshopper_jump() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(6, 0), 0], [0, Vector2i(0, 1), 0]])
	ms.buildings[Vector2i(0, 2)] = 3
	var hopper := TriggerLibrary.get_card("Grasshopper")
	_check(TickEngine.is_valid_move(ms, Vector2i(0, 0), 0, Vector2i(0, 2), 3, hopper, 0), "Grasshopper jumps 2 hexes onto a rooftop")
	_check(not TickEngine.is_valid_move(ms, Vector2i(0, 0), 0, Vector2i(0, 2), 3, TriggerLibrary.get_move_card(), 0), "a plain Move can't")
	var p0 := _plan(ms, 0)
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, hopper)
	p0.set_target(0, 0, Vector2i(0, 2), 3)
	TickEngine.new().resolve_tick(ms, p0, _plan(ms, 1), 0)
	_check(ms.teams[0][0].hex == Vector2i(0, 2) and ms.teams[0][0].floor == 3, "Grasshopper leaps over an ally onto the roof")


func _test_wire_penchant() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(6, 0), 0]])
	ms.wires[Vector2i(0, 0)] = 0
	ms.wires[Vector2i(0, 1)] = 0
	var move := TriggerLibrary.get_move_card()
	_check(TickEngine.is_valid_move(ms, Vector2i(0, 0), 0, Vector2i(0, 2), 0, move, 0), "own wires allow a 2-hex dash")
	_check(not TickEngine.is_valid_move(ms, Vector2i(0, 0), 0, Vector2i(0, 2), 0, move, 1), "enemy wires don't")

	# +20% defense on own wire: Shield mitigates 6 instead of 5.
	var own := func(m: MatchState) -> void: m.wires[Vector2i(0, 3)] = 1
	var enemy := func(m: MatchState) -> void: m.wires[Vector2i(0, 3)] = 0
	_check(_shot_hp("Asteroid", own, 1) == 96, "own wire boosts defense")
	_check(_shot_hp("Asteroid", enemy, 1) == 95, "enemy wire gives no bonus")


func _test_melee_assist() -> void:
	# Attacker strikes (0,1); the Scout stands next to the target and follows up.
	var ms := _match([[0, Vector2i(0, 0), 0, 0], [0, Vector2i(1, 0), 0, 3], [1, Vector2i(0, 1), 0, 1]])
	_fire(ms, "Kogetsu", Vector2i(0, 1))
	_check(ms.teams[1][0].trion_hp == 80, "Melee Assist: adjacent ally follows up for free (hp %d)" % ms.teams[1][0].trion_hp)


func _test_crossfire_assist() -> void:
	var target := Vector2i(0, 4)
	var ally_hex := Vector2i(2, 0)
	var specs := [[0, Vector2i(0, 0), 0, 0], [0, ally_hex, TickEngine.attack_direction(ally_hex, target), 1], [1, target, 0, 2]]
	var ms := _match(specs)
	_fire(ms, "Asteroid", target)
	_check(ms.teams[1][0].trion_hp == 80, "Crossfire Assist: ally with the target in its arc fires too (hp %d)" % ms.teams[1][0].trion_hp)

	# Same setup, but the ally has spent all its AT: no follow-up. Across a
	# 3-tick turn the Shooter spends its full 8 AT: Full Guard on tick 0 (4 AT)
	# plus Shield on ticks 1 and 2 (2 AT each).
	ms = _match(specs)
	var p0 := _plan(ms, 0)
	p0.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Asteroid"))
	p0.set_target(0, 0, target)
	p0.assign(1, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Shield"))
	p0.assign(1, 0, TurnPlan.SUB_SLOT, TriggerLibrary.get_card("Shield"))
	p0.assign(1, 1, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Shield"))
	p0.assign(1, 2, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Shield"))
	var engine := TickEngine.new()
	engine.always_hit = true
	engine.resolve_tick(ms, p0, _plan(ms, 1), 0)
	_check(ms.teams[1][0].trion_hp == 90, "Crossfire Assist needs unspent AT")


# --- Vision & city -------------------------------------------------------------

func _test_vision_profiles() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0, 0], [0, Vector2i(3, 0), 0, 2]])
	var attacker: UnitState = ms.teams[0][0]
	var sniper: UnitState = ms.teams[0][1]
	var pa := Visibility.profile(attacker)
	var ps := Visibility.profile(sniper)
	_check(int(ps["focus_range"]) == int(pa["focus_range"]) + Visibility.SCOPE_BONUS, "sniper scope extends focus range")
	sniper.floor = 3
	_check(int(Visibility.profile(sniper)["focus_range"]) == int(ps["focus_range"]) + 3, "elevation extends vision")

	# Focus cone is long and narrow; peripheral is wide and short.
	var viewer := attacker
	var far_ahead := HexCoord.neighbor(Vector2i(0, 0), 0) * 7
	_check(Visibility.in_view(viewer, far_ahead), "sees far straight ahead (focus cone)")
	var side := Vector2i(0, 0) + HexCoord.AXIAL_DIRECTIONS[1] * 7
	_check(not Visibility.in_view(viewer, side), "doesn't see far off to the side")
	var near_side := Vector2i(0, 0) + HexCoord.AXIAL_DIRECTIONS[1] * 4
	_check(Visibility.in_view(viewer, near_side), "peripheral vision catches nearby flanks")
	var behind := Vector2i(0, 0) + HexCoord.AXIAL_DIRECTIONS[3] * 4
	_check(not Visibility.in_view(viewer, behind), "can't see behind")
	_check(Visibility.sees_position(ms, viewer, HexCoord.neighbor(Vector2i(0, 0), 3), 0), "hears an adjacent enemy behind it")


func _test_los_3d() -> void:
	var ms := MatchState.new(1)
	ms.buildings[Vector2i(0, 1)] = 1
	# Ground to ground at range 4 over a 1-floor building right next to the viewer: blocked.
	_check(not Visibility.has_los(ms, Vector2i(0, 0), 0, Vector2i(0, 4), 0), "low building blocks a ground-level line")
	# From floor 2 the line clears the 1-floor roof.
	_check(Visibility.has_los(ms, Vector2i(0, 0), 2, Vector2i(0, 4), 0), "shooting down from floor 2 clears a lower roof")
	# A tall building far away still blocks a high line where it rises above it.
	ms.buildings[Vector2i(0, 3)] = 4
	_check(not Visibility.has_los(ms, Vector2i(0, 0), 2, Vector2i(0, 5), 0), "a taller tower in the way blocks")


func _test_interior_vision() -> void:
	# A 3-hex building at (0,2),(0,3),(0,4); a unit on floor 1 inside.
	var ms := _match([[0, Vector2i(0, 0), 5, 0], [1, Vector2i(0, 3), 0]])
	for r in [2, 3, 4]:
		ms.buildings[Vector2i(0, r)] = 3
	var watcher: UnitState = ms.teams[0][0]
	var inside: UnitState = ms.teams[1][0]
	inside.floor = 1
	watcher.facing = TickEngine.attack_direction(watcher.hex, inside.hex)
	_check(not Visibility.sees_position(ms, watcher, inside.hex, 1), "a unit deep inside a building is hidden from the street")
	inside.hex = Vector2i(0, 2)
	_check(Visibility.sees_position(ms, watcher, inside.hex, 1), "a unit at the window (outer wall) can be seen")


func _test_look_and_attack_facing() -> void:
	var ms := _match([[0, Vector2i(0, 0), 0], [1, Vector2i(0, 4), 0]])
	var plan := _plan(ms, 0)
	var ok_move := plan.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_move_card())
	plan.set_target(0, 0, Vector2i(1, 0))
	# Facing override on the Sub slot (no card needed) replaces the old Look.
	plan.set_facing(0, 0, TurnPlan.SUB_SLOT, TickEngine.attack_direction(Vector2i(1, 0), Vector2i(-3, 0)))
	_check(ok_move and plan.get_at_spent(0) == 1, "facing override is free and adds no AT")
	TickEngine.new().resolve_tick(ms, plan, _plan(ms, 1), 0)
	var u: UnitState = ms.teams[0][0]
	_check(u.hex == Vector2i(1, 0) and u.facing == TickEngine.attack_direction(Vector2i(1, 0), Vector2i(-3, 0)),
		"move, then facing override turns to watch the chosen edge")

	ms = _match([[0, Vector2i(0, 0), 0], [1, Vector2i(0, 3), 0]])
	_fire(ms, "Asteroid", Vector2i(0, 3))
	_check(ms.teams[0][0].facing == TickEngine.attack_direction(Vector2i(0, 0), Vector2i(0, 3)), "attacking turns the unit toward its target")


func _test_city_rects() -> void:
	var map := MapData.city()
	var rects := CityBuildings.compute_rects(map.buildings)
	var covered := true
	var street_clear := true
	var heights_match := true
	for hex in map.tiles:
		var p := HexCoord.axial_to_world(hex, 1.0)
		var hit: Dictionary = {}
		for r in rects:
			var x0 := 1.5 * int(r["c0"]) - 0.75
			var x1 := 1.5 * int(r["c1"]) + 0.75
			if p.x > x0 and p.x < x1 and p.z > float(r["top"]) and p.z < float(r["bot"]):
				hit = r
				break
		if map.buildings.has(hex):
			if hit.is_empty():
				covered = false
			elif int(hit["floors"]) != int(map.buildings[hex]):
				heights_match = false
		elif not hit.is_empty():
			street_clear = false
	_check(covered, "every building hex sits inside a 3D building")
	_check(street_clear, "no street hex is covered by a building")
	_check(heights_match, "3D building heights match the gameplay floors")


func _test_no_seeing_through_buildings() -> void:
	# An enemy on the far side of a building, inside awareness range: unseen.
	var ms := _match([[0, Vector2i(0, 0), 5], [1, Vector2i(0, 2), 0]])
	ms.buildings[Vector2i(0, 1)] = 3
	_check(not Visibility.sees_position(ms, ms.teams[0][0], Vector2i(0, 2), 0), "can't see an adjacent-range enemy through a building")

	# On the real city: whenever a sight line counts as clear, it really
	# misses every building box (validates the nearby-building shortcut).
	var city := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units())
	var hexes: Array = city.tiles.keys().filter(func(h: Vector2i) -> bool: return not city.buildings.has(h))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var leaks := 0
	var clear := 0
	for _i in 400:
		var a: Vector2i = hexes[rng.randi_range(0, hexes.size() - 1)]
		var b: Vector2i = hexes[rng.randi_range(0, hexes.size() - 1)]
		if HexCoord.distance(a, b) > 12 or not Visibility.has_los(city, a, 0, b, 0):
			continue
		clear += 1
		var pa := HexCoord.axial_to_world(a, 1.0)
		var pb := HexCoord.axial_to_world(b, 1.0)
		pa.y = Visibility.EYE_HEIGHT
		pb.y = Visibility.BODY_HEIGHT
		for r in city.building_rects():
			if not Visibility._segment_box(pa, pb, r).is_empty():
				leaks += 1
				break
	_check(clear > 20 and leaks == 0, "no clear sight line passes through any building (%d clear, %d leaks)" % [clear, leaks])


func _test_elo() -> void:
	_check(MatchServer.elo_deltas(1000, 1000, 0) == [16, -16], "even match: winner +16, loser -16")
	var upset := MatchServer.elo_deltas(1000, 1400, 0)
	_check(int(upset[0]) > 16, "beating a stronger player gains more")

	# A ranked match that ends updates both accounts.
	var server := MatchServer.new()
	server.persist = false
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var a: Dictionary = server._register({ "name": "A" })["body"]
	var b: Dictionary = server._register({ "name": "B" })["body"]
	server._enqueue({ "player_id": a["player_id"], "secret": a["secret"], "squad": squad })
	var matched: Dictionary = server._enqueue({ "player_id": b["player_id"], "secret": b["secret"], "squad": squad })["body"]
	var m: Dictionary = server._matches[str(matched["match_id"])]
	for u in (m["ms"] as MatchState).teams[1]:
		(u as UnitState).is_bailed = true
	for team in 2:
		m["plans"][team] = MatchRunner.build_fallback_plan(m["teams"][team])
	server._resolve_turn(m)
	var acc_a: Dictionary = server._accounts[a["player_id"]]
	var acc_b: Dictionary = server._accounts[b["player_id"]]
	_check(int(m["winner"]) == 0 and int(acc_a["rating"]) == 1016 and int(acc_b["rating"]) == 984,
		"ranked result updates Elo (%d / %d)" % [acc_a["rating"], acc_b["rating"]])
	_check(int(acc_a["wins"]) == 1 and int(acc_b["losses"]) == 1, "ranked result records win/loss")
	server.free()


# --- Validation -------------------------------------------------------------

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

	var unknown := squad.duplicate(true)
	unknown[0]["main"] = ["Black Trigger", null, null, null]
	_check(PlanCodec.validate_squad(unknown) != "", "rejects unknown trigger")

	_check(PlanCodec.validate_squad(squad.slice(0, 3)) != "", "rejects wrong squad size")


func _test_plan_validation() -> void:
	var units := TriggerLibrary.sample_units()
	for u in units:
		u.ensure_slot_arrays()

	var good := TurnPlan.new(units)
	good.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Shield"))
	var res := PlanCodec.decode_plan_checked(PlanCodec.encode_plan(good), units)
	_check(str(res["error"]) == "", "valid plan accepted")

	# Ibis is not in any sample loadout.
	var cheat := PlanCodec.encode_plan(TurnPlan.new(units))
	cheat["units"][0][0]["main"] = "Ibis"
	res = PlanCodec.decode_plan_checked(cheat, units)
	_check(str(res["error"]) != "", "rejects card the unit has not equipped")

	# Kogetsu (3 AT) + Raygust (2 AT) in every tick, plus 1 AT Mental Load
	# per dual tick = 6 AT/tick: 18 AT blows the 10 AT penchant pool.
	var overrun := PlanCodec.encode_plan(TurnPlan.new(units))
	for t in TurnPlan.TICKS_PER_TURN:
		overrun["units"][0][t]["main"] = "Kogetsu"
		overrun["units"][0][t]["sub"] = "Raygust"
	res = PlanCodec.decode_plan_checked(overrun, units)
	_check(str(res["error"]) != "", "rejects AT overrun")


func _test_state_snapshot() -> void:
	var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 777)
	ms.teams[0][0].trion_hp = 42
	ms.teams[0][1].floor = 2
	ms.wires[Vector2i(1, 1)] = true
	ms.rng.randf()
	var snap: Variant = JSON.parse_string(JSON.stringify(PlanCodec.encode_state(ms)))
	_check(PlanCodec.state_matches(ms, snap), "state matches its own JSON snapshot")

	var other := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 1)
	_check(not PlanCodec.state_matches(other, snap), "different state detected as desync")
	PlanCodec.apply_state(other, snap)
	_check(PlanCodec.state_matches(other, snap), "apply_state resyncs units, wires, and RNG")
	_check(other.rng.randf() == ms.rng.randf(), "RNG continues identically after resync")


# --- Helpers ----------------------------------------------------------------

## Builds a cover-free MatchState. Each spec is [team, hex, facing] plus an
## optional sample-unit index (0 Attacker, 1 Shooter, 2 Sniper, 3 Scout;
## defaults to the spec's position).
func _match(specs: Array) -> MatchState:
	var ms := MatchState.new(1)
	var teams: Array = [[], []]
	var data := TriggerLibrary.sample_units()
	for i in specs.size():
		var spec: Array = specs[i]
		var unit_data: UnitData = data[spec[3]] if spec.size() > 3 else data[i]
		teams[spec[0]].append(UnitState.new(unit_data, spec[0], spec[1], spec[2]))
	for team in 2:
		var typed: Array[UnitState] = []
		typed.assign(teams[team])
		ms.setup_team(team, typed)
	return ms


func _plan(ms: MatchState, team: int) -> TurnPlan:
	var units: Array[UnitData] = []
	for u in ms.teams[team]:
		units.append((u as UnitState).unit_data)
	return TurnPlan.new(units)


func _move_plan(ms: MatchState, team: int, target: Vector2i, target_floor: int = 0) -> TurnPlan:
	var plan := _plan(ms, team)
	plan.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_move_card())
	plan.set_target(0, 0, target, target_floor)
	return plan


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
