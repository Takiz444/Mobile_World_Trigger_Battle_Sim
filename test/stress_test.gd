extends Node
## Headless stress test: many matches, many turns, random plans made the way
## a player makes them (from their team's fogged view of the match, timed
## and checked on the client), then resolved on the real match.
##
## Checks, every turn:
##   - a plan the client thinks is valid is accepted by the server's check
##     (the "Submit is enabled but the server refuses" / "can't submit" class
##     of bugs),
##   - every character stands somewhere it legally can, in the real match and
##     in each team's view (after the view's rounding),
##   - an empty plan and a plan with a fresh move are valid for everyone.
##
## Run:
##   godot --headless --path . res://test/stress_test.tscn [-- matches turns]

var _failed := false
var _checks := 0
var _problems: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var matches := int(args[0]) if args.size() > 0 else 12
	var turns := int(args[1]) if args.size() > 1 else 8
	for m in matches:
		_play(1000 + m, turns)
	for p in _problems.slice(0, 12):
		printerr("  ", p)
	_check(_problems.is_empty(), "%d matches x %d turns: client and server agree, everyone stands somewhere legal (%d checks, %d problems)" % [matches, turns, _checks, _problems.size()])
	print("STRESS TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


func _play(seed: int, turns: int) -> void:
	var squads := [TriggerLibrary.sample_units(), TriggerLibrary.sample_units()]
	var section := TokyoMap.random_section(seed)
	var truth := MatchRunner.build_match(squads[0], squads[1], seed, section)
	var views := [MatchRunner.build_match(squads[0], squads[1], seed, section),
		MatchRunner.build_match(squads[0], squads[1], seed, section)]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for turn in turns:
		if MatchRunner.winner(truth) != -1:
			return
		var plans := []
		for team in 2:
			_apply_view(views[team], Visibility.encode_view(truth, team, turn, true))
			_check_positions(truth, "truth", seed, turn)
			_check_positions(views[team], "view%d" % team, seed, turn)
			var plan := _random_plan(views[team], team, rng)
			var view: MatchState = views[team]
			_checks += 1
			if not plan.is_all_valid(view, view.teams[team]):
				_problems.append("seed %d turn %d team %d: generated plan invalid on the client: %s" % [seed, turn, team, _errors(plan, view, team)])
			var wire: Variant = JSON.parse_string(JSON.stringify(PlanCodec.encode_plan(plan)))
			var res := PlanCodec.decode_plan_checked(wire, squads[team], truth, truth.teams[team])
			_checks += 1
			if str(res["error"]) != "":
				_problems.append("seed %d turn %d team %d: client-valid plan refused by the server: %s" % [seed, turn, team, res["error"]])
				plans.append(MatchRunner.build_fallback_plan(squads[team]))
			else:
				plans.append(res["plan"])
		MatchRunner.record_turn(truth, plans[0], plans[1], func(n: int) -> int: return n)


## A random plan built like the planning UI builds one: moves to random
## spots (street, floors, roofs), jumps, Look, Shield, Wait, attacks on known
## enemies — each kept only if the plan stays valid on the client.
func _random_plan(ms: MatchState, team: int, rng: RandomNumberGenerator) -> TurnPlan:
	var units: Array[UnitData] = []
	for u in ms.teams[team]:
		units.append((u as UnitState).unit_data)
	var plan := TurnPlan.new(units)
	var geo := ms.geometry()
	var b := ms.bounds()
	var known: Array[int] = []
	for i in ms.teams[1 - team].size():
		var e: UnitState = ms.teams[1 - team][i]
		if not e.is_bailed and e.fog != Visibility.State.HIDDEN:
			known.append(i)
	for i in units.size():
		var us: UnitState = ms.teams[team][i]
		if us.is_bailed:
			continue
		# Every character must always be able to plan an empty turn and a move.
		_checks += 1
		if not plan.is_unit_valid(ms, us, i):
			_problems.append("an empty plan is invalid for %s at %s level %d" % [us.display_name(), us.pos, us.level])
		for _k in rng.randi_range(1, 6):
			var cards := plan.get_available_actions(i)
			var card: TriggerCard = cards[rng.randi_range(0, cards.size() - 1)]
			var a := PlanAction.new(card)
			var lane_id := TurnPlan.lane_for(card)
			if card.card_name == "Wait":
				lane_id = rng.randi_range(0, 1)
				a.hold = rng.randf_range(0.25, 1.5)
			if a.uses_hold() and card.card_name != "Wait":
				a.hold = rng.randf_range(0.5, 2.5)
			if TurnPlan.is_move_card(card) or card.card_name == "Look" or card.card_name == "Spider":
				var p := Vector2.ZERO
				var lvl := 0
				for _try in 20:
					if card.jump or rng.randf() < 0.6:
						p = us.pos + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.5, CityGeometry.JUMP_RANGE if card.jump else 9.0)
					else:
						p = Vector2(rng.randf_range(b.position.x, b.end.x), rng.randf_range(b.position.y, b.end.y))
					var floors := geo.floors_at(p)
					lvl = 0 if floors == 0 else (floors if card.jump or rng.randf() < 0.5 else rng.randi_range(1, floors))
					if geo.level_ok(p, lvl):
						break
				a.set_point(p, lvl if TurnPlan.is_move_card(card) else 0)
			if a.is_attack():
				if known.is_empty():
					continue
				a.target_unit = known[rng.randi_range(0, known.size() - 1)]
			plan.add(i, a, lane_id)
			if not plan.is_unit_valid(ms, us, i):
				plan.remove(i, lane_id, plan.lane(i, lane_id).size() - 1)
		# A fresh short move from wherever it stands must be plannable.
		if us.level == 0 and not plan.lane(i, TurnPlan.MOVE_LANE).is_empty() == false:
			var ok := false
			for k in 16:
				var dest := us.pos + Vector2.from_angle(TAU * k / 16.0) * 1.5
				if geo.ground_ok(dest) and bool(geo.route(us.pos, 0, dest, 0)["ok"]):
					ok = true
					break
			_checks += 1
			if not ok:
				_problems.append("%s at %s can't route a short step anywhere" % [us.display_name(), us.pos])
	return plan


func _check_positions(ms: MatchState, where: String, seed: int, turn: int) -> void:
	var geo := ms.geometry()
	for u in ms.all_units():
		if u.is_bailed or u.pos.x > 50000.0:
			continue
		_checks += 1
		if not geo.level_ok(u.pos, u.level):
			_problems.append("seed %d turn %d %s: %s stands at an illegal spot %s level %d" % [seed, turn, where, u.display_name(), u.pos, u.level])


## The client's way of applying a fogged view (MatchController._apply_view).
func _apply_view(ms: MatchState, view: Dictionary) -> void:
	var units := ms.all_units()
	var rows: Array = view.get("units", [])
	for i in mini(units.size(), rows.size()):
		var u: UnitState = units[i]
		var row: Dictionary = rows[i]
		u.fog = int(row.get("vis", Visibility.State.SIGHT))
		match u.fog:
			Visibility.State.SIGHT:
				var pos: Array = row["pos"]
				u.pos = Vector2(float(pos[0]), float(pos[1]))
				u.level = int(row.get("level", 0))
				u.facing = float(row.get("facing", u.facing))
				u.trion_hp = int(row.get("hp", u.trion_hp))
				u.is_bailed = bool(row.get("bailed", false))
			Visibility.State.RADAR:
				var ping: Array = row["ping"]
				u.ping_pos = Vector2(float(ping[0]), float(ping[1]))
				u.pos = MatchController.OFFBOARD
			_:
				u.pos = MatchController.OFFBOARD
	ms.wires.clear()
	for w in view.get("wires", []):
		ms.wires.append({ "pos": Vector2(float(w[0]), float(w[1])), "team": int(w[2]) })


func _errors(plan: TurnPlan, ms: MatchState, team: int) -> String:
	var out: Array[String] = []
	for i in plan.units.size():
		var e := plan.unit_error(ms, ms.teams[team][i], i)
		if e != "":
			out.append("%d: %s" % [i, e])
	return ", ".join(out)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
