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

	var created := await b0.create_match(12345, PlanCodec.encode_squad(squad0))
	_check(created.get("success", false), "create match")
	var match_id := str(created["body"].get("match_id", ""))
	_check(match_id != "", "got match id")

	var joined := await b1.join_match(match_id, PlanCodec.encode_squad(squad1))
	_check(joined.get("success", false), "join match")

	var plan0 := _shield_plan(squad0)
	var plan1 := _shield_plan(squad1)

	var sub0 := await b0.submit_plan(match_id, 0, PlanCodec.encode_plan(plan0))
	_check(sub0.get("success", false), "submit team 0")
	var sub1 := await b1.submit_plan(match_id, 1, PlanCodec.encode_plan(plan1))
	_check(sub1.get("success", false), "submit team 1")

	var info := await b0.get_match(match_id)
	_check(info.get("success", false), "get match")
	var body: Dictionary = info["body"]
	var result: Variant = body.get("result")
	_check(result is Dictionary, "turn result produced")
	if result is Dictionary:
		_check(result.get("plans") != null, "result contains both plans")
		_check(int(result.get("winner", -2)) in [-1, 0, 1], "winner field valid")

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
