extends Node
## Headless integration test for the async backend. Starts the MatchServer
## in-process, then drives two HttpBackend clients through create → join →
## submit → resolution → fetch.
##
## Run:
##   godot --headless --path . res://test/net_test.tscn

var _server: MatchServer
var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_server = MatchServer.new()
	_server.persist = false
	add_child(_server)
	await get_tree().create_timer(0.5).timeout

	var b0 := HttpBackend.new()
	b0.server_url = "http://127.0.0.1:8080"
	add_child(b0)
	var b1 := HttpBackend.new()
	b1.server_url = "http://127.0.0.1:8080"
	add_child(b1)

	var squad0 := TriggerLibrary.sample_units()
	var squad1 := TriggerLibrary.sample_units()

	# Cheated squad (inflated HP) is rejected at create time.
	var cheat_squad := PlanCodec.encode_squad(squad0)
	cheat_squad[0]["trion_hp"] = 9999
	var cheat := await b0.create_match(12345, cheat_squad)
	_check(int(cheat.get("status", 0)) == 400, "create rejects invalid squad")

	var created := await b0.create_match(12345, PlanCodec.encode_squad(squad0))
	_check(created.get("success", false), "create match")
	var match_id := str(created["body"].get("match_id", ""))
	var token0 := str(created["body"].get("token", ""))
	_check(match_id != "", "got match id")
	_check(token0 != "", "got host token")

	var joined := await b1.join_match(match_id, PlanCodec.encode_squad(squad1))
	_check(joined.get("success", false), "join match")
	var token1 := str(joined["body"].get("token", ""))
	_check(token1 != "" and token1 != token0, "got distinct joiner token")

	var plan0 := _shield_plan(squad0)
	var plan1 := _shield_plan(squad1)

	var forged := await b1.submit_plan(match_id, "not-a-token", 1, PlanCodec.encode_plan(plan0))
	_check(int(forged.get("status", 0)) == 403, "submit rejects unknown token")

	var bad_plan := PlanCodec.encode_plan(plan0)
	bad_plan["units"][0][0]["main"] = "Ibis"  # not equipped
	var illegal := await b0.submit_plan(match_id, token0, 1, bad_plan)
	_check(int(illegal.get("status", 0)) == 400, "submit rejects unequipped card")

	var stale := await b0.submit_plan(match_id, token0, 7, PlanCodec.encode_plan(plan0))
	_check(int(stale.get("status", 0)) == 409, "submit rejects wrong turn")

	var sub0 := await b0.submit_plan(match_id, token0, 1, PlanCodec.encode_plan(plan0))
	_check(sub0.get("success", false), "submit team 0")
	var sub1 := await b1.submit_plan(match_id, token1, 1, PlanCodec.encode_plan(plan1))
	_check(sub1.get("success", false), "submit team 1")

	var public := await b1.get_match(match_id)
	_check(public.get("success", false) and not public["body"].has("view") and not public["body"].has("history"),
		"GET without token reveals no board or history")

	var info := await b0.get_match(match_id, token0)
	_check(info.get("success", false), "get match")
	var body: Dictionary = info["body"]
	var result: Variant = body.get("result")
	_check(result is Dictionary, "turn result produced")
	if result is Dictionary:
		_check(result.get("plan") is Dictionary, "result contains our own plan")
		_check(not result.has("plans"), "opponent plan not leaked")
		_check((result.get("frames", []) as Array).size() == TurnPlan.TICKS_PER_TURN, "one fog-filtered frame per tick")
		_check(int(result.get("winner", -2)) in [-1, 0, 1], "winner field valid")
	_check(body.get("view") is Dictionary, "player receives a fogged board view")
	_check(not body.has("state"), "full match state not exposed")
	_check((body.get("history", []) as Array).size() == 1, "history has one turn")
	_check(int(body.get("turn", 0)) == 2, "server advanced to turn 2")

	# At spawn the squads are far apart: enemies must not appear in sight.
	var view: Dictionary = body.get("view", {})
	var enemy_exact := 0
	var units: Array = view.get("units", [])
	for i in range(4, units.size()):
		if int(units[i].get("vis", -1)) == Visibility.State.SIGHT:
			enemy_exact += 1
	_check(units.size() == 8 and enemy_exact == 0, "distant enemies hidden by fog of war")

	print("NET TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


func _shield_plan(units: Array[UnitData]) -> TurnPlan:
	var plan := TurnPlan.new(units)
	var shield := TriggerLibrary.get_card("Shield")
	for i in units.size():
		plan.assign(i, 0, TurnPlan.MAIN_SLOT, shield)
	return plan


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
