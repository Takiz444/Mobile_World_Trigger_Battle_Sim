extends Node
## Headless tests for live competitive play: ladder rules (trophies, arena
## floors, season reset, search window), the turn-cap tiebreak, and the live
## WebSocket flow against an in-process MatchServer running a sped-up clock —
## live queue, pushed results, opponent lock-in, AFK forfeit, turn cap,
## surrender, account deletion, and the battle controller auto-locking its
## plan when the clock runs out.
##
## Run:
##   godot --headless --path . res://test/live_test.tscn

const PORT := 18090
const URL := "http://127.0.0.1:18090"
const LIVE_URL := "ws://127.0.0.1:18091"

var _server: MatchServer
var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_ladder()
	_test_tiebreak()

	_server = MatchServer.new()
	_server.persist = false
	_server.port = PORT
	_server.live_clock_scale = 0.04   # turn 1 = (15 + 60) * 0.04 = 3 s
	add_child(_server)
	await get_tree().create_timer(0.3).timeout

	await _test_live_ranked_flow()
	await _test_turn_cap()
	await _test_forfeit_and_delete()
	await _test_controller_buzzer()

	print("LIVE TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


# --- Pure rules ---------------------------------------------------------------

func _test_ladder() -> void:
	_check(Ladder.trophy_stake(1000, 1000) == 30, "even trophies: stake 30")
	_check(Ladder.trophy_stake(1000, 1600) == 40 and Ladder.trophy_stake(1600, 1000) == 20,
		"upsets pay more, stomps less (clamped 20..40)")
	_check(Ladder.trophy_deltas([500, 500], [500, 500], 0) == [30, -30], "winner +30, loser -30")
	_check(Ladder.trophy_deltas([310, 310], [310, 310], 1) == [-10, 30], "arena floor (300) caps the loss")
	_check(Ladder.trophy_deltas([0, 0], [0, 0], 0) == [30, 0], "new players can't go below 0")
	_check(Ladder.trophy_deltas([500, 500], [500, 500], MatchRunner.DRAW) == [0, 0], "draw: no trophies")
	_check(Ladder.arena_index(0) == 0 and Ladder.arena_index(299) == 0 and Ladder.arena_index(300) == 1,
		"arena thresholds")
	_check(Ladder.season_reset(4500) == 4000 and Ladder.season_reset(1200) == 1200, "season soft reset")
	_check(Ladder.search_window(0) == 100 and Ladder.search_window(100) == Ladder.MM_WINDOW_MAX,
		"search window widens and caps")
	_check(Ladder.can_pair(1000, 0, 1090, 0) and not Ladder.can_pair(1000, 0, 1300, 0)
		and Ladder.can_pair(1000, 10, 1300, 10), "wide gaps pair only after waiting")
	_check(MatchServer.elo_deltas(1000, 1000, MatchRunner.DRAW) == [0, 0], "even draw: no rating change")


func _test_tiebreak() -> void:
	var a := TriggerLibrary.sample_units()
	var ms := MatchRunner.build_match(a, TriggerLibrary.sample_units(), 1)
	_check(MatchRunner.tiebreak_winner(ms) == MatchRunner.DRAW, "untouched squads draw")
	(ms.teams[1][0] as UnitState).trion_hp -= 5
	_check(MatchRunner.tiebreak_winner(ms) == 0, "more Trion left wins")
	(ms.teams[0][2] as UnitState).is_bailed = true
	_check(MatchRunner.tiebreak_winner(ms) == 1, "more units standing beats Trion")


# --- Live flow ----------------------------------------------------------------

func _test_live_ranked_flow() -> void:
	var b := _backend()
	var acc0: Dictionary = (await b.register_account("Osamu"))["body"]
	var acc1: Dictionary = (await b.register_account("Yuma"))["body"]
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var q0 := await b.queue_ranked(acc0["player_id"], acc0["secret"], squad, "live")
	var q_async := await b.queue_ranked(acc1["player_id"], acc1["secret"], squad, "async")
	_check(str(q_async["body"].get("status")) == "queued", "live and async queues don't mix")
	var q1 := await b.queue_ranked(acc1["player_id"], acc1["secret"], squad, "live")
	_check(str(q1["body"].get("status")) == "matched" and str(q1["body"].get("mode")) == "live", "live queue pairs")
	var p0 := await b.poll_queue(q0["body"]["ticket"], acc0["secret"])
	var match_id := str(p0["body"]["match_id"])

	var c0 := _client(match_id, str(p0["body"]["token"]))
	var c1 := _client(match_id, str(q1["body"]["token"]))
	await _wait(func() -> bool: return c0["state"].size() > 0 and c1["state"].size() > 0, 3.0)
	var st: Dictionary = c0["state"].back() if c0["state"].size() > 0 else {}
	_check(str(st.get("mode")) == "live" and int(st.get("max_turns", 0)) == Ladder.LIVE_MAX_TURNS, "hello returns live state")
	_check(float(st.get("seconds_left", -1)) > 0.0, "turn clock is running")
	_check(st.get("view") is Dictionary and not st.has("state"), "live state is fogged")
	await _wait(func() -> bool: return c0["presence"].size() > 0 and c0["presence"].back() == [true, true], 2.0)
	_check(c0["presence"].size() > 0 and c0["presence"].back() == [true, true], "presence shows both connected")

	# Turn 1: team 0 locks in, team 1 hears about it, then team 1 locks in.
	var plan := PlanCodec.encode_plan(MatchRunner.build_fallback_plan(TriggerLibrary.sample_units()))
	c0["live"].submit(1, plan)
	await _wait(func() -> bool: return c1["locked"].size() > 0, 2.0)
	_check(c1["locked"] == [1], "opponent sees the lock-in (not the plan)")
	c1["live"].submit(1, plan)
	await _wait(func() -> bool: return c0["resolved"].size() > 0 and c1["resolved"].size() > 0, 2.0)
	_check(c0["resolved"].size() == 1 and c1["resolved"].size() == 1, "both players get the result pushed")
	if c0["resolved"].size() > 0:
		var r: Dictionary = c0["resolved"][0]
		_check(int(r["result"]["turn"]) == 1 and r["result"].has("plan") and not r["result"].has("plans"),
			"pushed result carries only our own plan")
		_check(int(r["turn"]) == 2 and float(r["seconds_left"]) > 0.0, "next turn's clock starts")

	# Team 0 keeps playing, team 1 goes AFK: forfeits after 2 missed turns.
	for turn in [2, 3]:
		c0["live"].submit(turn, plan)
		await _wait(func() -> bool: return c0["resolved"].size() >= turn, 4.0)
	await _wait(func() -> bool: return c0["over"].size() > 0, 2.0)
	var over: Dictionary = c0["over"][0] if c0["over"].size() > 0 else {}
	_check(int(over.get("winner", -1)) == 0 and str(over.get("reason")) == "afk", "AFK player forfeits")
	_check(_ints(over.get("trophy_change", [])) == [30, 0], "winner +30 trophies, loser floored at 0")
	var acc := await b.get_account(acc0["player_id"])
	_check(int(acc["body"].get("trophies", 0)) == 30 and int(acc["body"].get("wins", 0)) == 1, "trophies saved to account")
	var board := await b.leaderboard()
	_check(str((board["body"]["players"] as Array)[0].get("name")) == "Osamu", "leaderboard ranks by trophies")
	c0["live"].close()
	c1["live"].close()
	await b.cancel_queue(q_async["body"]["ticket"], acc1["secret"])


func _test_turn_cap() -> void:
	var b := _backend()
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var created := await b.request("POST", "/match/create", { "seed": 7, "squad": squad, "mode": "live" })
	var match_id := str(created["body"]["match_id"])
	var joined := await b.join_match(match_id, squad)
	_check(str(joined["body"].get("mode")) == "live", "friendly live battle: joiner learns the mode")
	_server._matches[match_id]["max_turns"] = 2
	var plan := PlanCodec.encode_plan(MatchRunner.build_fallback_plan(TriggerLibrary.sample_units()))
	var c0 := _client(match_id, str(created["body"]["token"]))
	await _wait(func() -> bool: return c0["state"].size() > 0, 2.0)
	for turn in [1, 2]:
		await b.submit_plan(match_id, str(joined["body"]["token"]), turn, plan)
		await b.submit_plan(match_id, str(created["body"]["token"]), turn, plan)
	await _wait(func() -> bool: return c0["over"].size() > 0, 2.0)
	var over: Dictionary = c0["over"][0] if c0["over"].size() > 0 else {}
	_check(str(over.get("reason")) == "turn_cap" and int(over.get("winner", -1)) == MatchRunner.DRAW,
		"turn cap ends the match (even squads draw)")
	_check(_ints(over.get("trophy_change", [])) == [0, 0], "friendly battles never move trophies")
	c0["live"].close()


func _test_forfeit_and_delete() -> void:
	var b := _backend()
	var acc0: Dictionary = (await b.register_account("Chika"))["body"]
	var acc1: Dictionary = (await b.register_account("Kuga"))["body"]
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var q0 := await b.queue_ranked(acc0["player_id"], acc0["secret"], squad, "live")
	var q1 := await b.queue_ranked(acc1["player_id"], acc1["secret"], squad, "live")
	var match_id := str(q1["body"].get("match_id", ""))
	var c0 := _client(match_id, str((await b.poll_queue(q0["body"]["ticket"], acc0["secret"]))["body"]["token"]))
	await _wait(func() -> bool: return c0["state"].size() > 0, 2.0)
	c0["live"].forfeit()
	await _wait(func() -> bool: return c0["over"].size() > 0, 2.0)
	_check(c0["over"].size() > 0 and int(c0["over"][0].get("winner", -1)) == 1
		and str(c0["over"][0].get("reason")) == "forfeit", "surrender over the live channel")
	c0["live"].close()

	var bad := await b.delete_account(acc1["player_id"], "nope")
	_check(int(bad.get("status", 0)) == 403, "delete needs the account secret")
	var del := await b.delete_account(acc1["player_id"], acc1["secret"])
	var gone := await b.get_account(acc1["player_id"])
	_check(del.get("success", false) and int(gone.get("status", 0)) == 404, "account deleted")


## The real battle controller in live mode: the player never presses Submit;
## the clock runs out and the plan is locked in automatically.
func _test_controller_buzzer() -> void:
	_server.live_clock_scale = 0.08   # turn 1 = 6 s, auto-lock at 1.5 s left
	var b := _backend()
	var squad0 := TriggerLibrary.sample_units()
	var squad1 := TriggerLibrary.sample_units()
	var created := await b.request("POST", "/match/create", { "seed": 3, "squad": PlanCodec.encode_squad(squad0), "mode": "live" })
	var match_id := str(created["body"]["match_id"])
	var joined := await b.join_match(match_id, PlanCodec.encode_squad(squad1))

	MatchSession.mode = MatchSession.Mode.ONLINE
	MatchSession.live = true
	MatchSession.live_url = LIVE_URL
	MatchSession.server_url = URL
	MatchSession.match_id = match_id
	MatchSession.team = 0
	MatchSession.token = str(created["body"]["token"])
	MatchSession.squad = squad0

	var layer := CanvasLayer.new()
	add_child(layer)
	var board := HexBoard.new()
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

	await _wait(func() -> bool: return controller._live != null and controller._live.is_open(), 3.0)
	_check(controller._clock_label != null and controller._clock_label.text.begins_with("Turn 1/"), "live clock shown")
	var plan1 := PlanCodec.encode_plan(MatchRunner.build_fallback_plan(squad1))
	await b.submit_plan(match_id, str(joined["body"]["token"]), 1, plan1)
	var m: Dictionary = _server._matches[match_id]
	await _wait(func() -> bool: return (m["history"] as Array).size() >= 1, 10.0)
	_check((m["history"] as Array).size() >= 1 and int(m["missed"][0]) == 0,
		"buzzer auto-locked the plan (a real submit, not an AFK fallback)")
	# (The sped-up clock is shorter than the real-time replay animation, so
	# only turn 1 is checked; at real speed the next turn adds LIVE_REPLAY_SEC.)
	await _wait(func() -> bool: return controller._turn >= 2, 10.0)
	_check(controller._turn >= 2, "pushed result replayed and the next turn began")
	controller._live.close()
	MatchSession.live = false


# --- Helpers ------------------------------------------------------------------

func _backend() -> HttpBackend:
	var b := HttpBackend.new()
	b.server_url = URL
	add_child(b)
	return b


## A LiveClient whose pushed messages are collected into arrays.
func _client(match_id: String, token: String) -> Dictionary:
	var live := LiveClient.new()
	add_child(live)
	var c := { "live": live, "state": [], "resolved": [], "locked": [], "over": [], "presence": [] }
	live.state_received.connect(func(body: Dictionary) -> void: c["state"].append(body))
	live.turn_resolved.connect(func(result: Dictionary, turn: int, left: float) -> void:
		c["resolved"].append({ "result": result, "turn": turn, "seconds_left": left }))
	live.opponent_locked.connect(func(turn: int) -> void: c["locked"].append(turn))
	live.match_over.connect(func(msg: Dictionary) -> void: c["over"].append(msg))
	live.presence_changed.connect(func(connected: Array) -> void: c["presence"].append(connected))
	live.open(LIVE_URL, match_id, token)
	return c


## JSON numbers arrive as floats.
func _ints(arr: Array) -> Array:
	return arr.map(func(v: Variant) -> int: return int(v))


func _wait(cond: Callable, timeout_sec: float) -> void:
	var end := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await get_tree().process_frame


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
