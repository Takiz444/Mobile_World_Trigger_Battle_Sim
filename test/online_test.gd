extends Node
## Headless integration test for the ONLINE client flow: MatchController talks
## to an in-process MatchServer, waits for an opponent, submits a plan, and
## replays the server-resolved turn.
##
## Run:
##   godot --headless --path . res://test/online_test.tscn

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var server := MatchServer.new()
	server.persist = false
	add_child(server)
	await get_tree().create_timer(0.5).timeout

	var squad0 := TriggerLibrary.sample_units()
	var squad1 := TriggerLibrary.sample_units()

	var b0 := HttpBackend.new()
	b0.server_url = "http://127.0.0.1:8080"
	add_child(b0)
	var b1 := HttpBackend.new()
	b1.server_url = "http://127.0.0.1:8080"
	add_child(b1)

	var created := await b0.create_match(12345, PlanCodec.encode_squad(squad0))
	_check(created.get("success", false), "create match")
	var match_id := str(created["body"].get("match_id", ""))

	MatchSession.mode = MatchSession.Mode.ONLINE
	MatchSession.match_id = match_id
	MatchSession.team = 0
	MatchSession.token = str(created["body"].get("token", ""))
	MatchSession.server_url = "http://127.0.0.1:8080"
	MatchSession.squad = squad0

	var layer := CanvasLayer.new()
	add_child(layer)
	var board := HexBoard.new()
	board.board_radius = 6
	board.hex_size = 1.0
	add_child(board)
	var timeline := TimelineUI.new()
	layer.add_child(timeline)
	timeline.setup(squad0)
	var event_log := EventLogUI.new()
	layer.add_child(event_log)

	var controller := MatchController.new()
	add_child(controller)
	controller.setup(board, timeline, event_log, layer)

	# Opponent joins -> controller's poll detects the match is ready.
	var joined := await b1.join_match(match_id, PlanCodec.encode_squad(squad1))
	_check(joined.get("success", false), "join match")
	await get_tree().create_timer(1.5).timeout
	_check(controller._ms != null, "online board built")
	_check(controller._turn == 1, "online turn is 1")
	_check(not controller._overlay.visible, "waiting overlay cleared")

	# Opponent pre-submits; our submit then triggers server resolution.
	var plan1 := _shield_plan(squad1)
	var token1 := str(joined["body"].get("token", ""))
	await b1.submit_plan(match_id, token1, 1, PlanCodec.encode_plan(plan1))
	await controller._on_plan_submitted()
	_check(controller._turn == 2, "online turn advanced after resolution")

	# Client's own units must match the server's authoritative view.
	var info := await b0.get_match(match_id, str(created["body"].get("token", "")))
	var units: Array = info["body"].get("view", {}).get("units", [])
	var synced := units.size() == 8
	for i in 4:
		if not synced:
			break
		var u: UnitState = controller._ms.teams[0][i]
		var hex: Array = units[i].get("hex", [])
		synced = hex.size() == 2 and Vector2i(int(hex[0]), int(hex[1])) == u.hex
	_check(synced, "client units match server view after replay")

	print("ONLINE TEST %s" % ("PASS" if not _failed else "FAIL"))
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
