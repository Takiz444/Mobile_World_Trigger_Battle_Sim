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
	p0.set_target(0, 0, Vector2i(0, 1))
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

	# 6 x Kogetsu (3 AT each) blows the 10 AT penchant pool.
	var overrun := PlanCodec.encode_plan(TurnPlan.new(units))
	for t in TurnPlan.TICKS_PER_TURN:
		overrun["units"][0][t]["main"] = "Kogetsu"
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

## Builds a cover-free MatchState. Each spec is [team, hex, facing].
func _match(specs: Array) -> MatchState:
	var ms := MatchState.new(1)
	var teams: Array = [[], []]
	var data := TriggerLibrary.sample_units()
	for i in specs.size():
		var spec: Array = specs[i]
		teams[spec[0]].append(UnitState.new(data[i], spec[0], spec[1], spec[2]))
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
