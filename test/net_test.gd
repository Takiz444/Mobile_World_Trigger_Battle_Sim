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
	_server.port = 18080
	add_child(_server)
	await get_tree().create_timer(0.5).timeout

	var b0 := HttpBackend.new()
	b0.server_url = "http://127.0.0.1:18080"
	add_child(b0)
	var b1 := HttpBackend.new()
	b1.server_url = "http://127.0.0.1:18080"
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

	# --- Accounts + ranked matchmaking ---
	var acc_a := await b0.register_account("Mikumo")
	var acc_b := await b1.register_account("Kuga")
	_check(acc_a.get("success", false) and acc_b.get("success", false), "register two accounts")
	var a: Dictionary = acc_a["body"]
	var b: Dictionary = acc_b["body"]
	_check(int(a.get("rating", 0)) == 1000, "new accounts start at rating 1000")
	var bad := await b0.queue_ranked(str(a["player_id"]), "wrong-secret", PlanCodec.encode_squad(squad0))
	_check(int(bad.get("status", 0)) == 403, "queue rejects bad credentials")

	var qa := await b0.queue_ranked(str(a["player_id"]), str(a["secret"]), PlanCodec.encode_squad(squad0))
	_check(qa.get("success", false) and str(qa["body"].get("status")) == "queued", "first player waits in queue")
	var qb := await b1.queue_ranked(str(b["player_id"]), str(b["secret"]), PlanCodec.encode_squad(squad1))
	_check(str(qb["body"].get("status")) == "matched" and int(qb["body"].get("team", -1)) == 1, "second player is matched as team 1")
	var pa := await b0.poll_queue(str(qa["body"]["ticket"]), str(a["secret"]))
	_check(str(pa["body"].get("status")) == "matched" and str(pa["body"].get("match_id")) == str(qb["body"].get("match_id")),
		"waiting player's ticket resolves to the same match")
	var ranked := await b0.get_match(str(pa["body"]["match_id"]), str(pa["body"]["token"]))
	_check(bool(ranked["body"].get("ranked", false)) and bool(ranked["body"].get("ready", false)), "ranked match is ready to play")
	_check(ranked["body"].get("players", []) == ["Mikumo", "Kuga"], "match lists both players")
	var board := await b0.leaderboard()
	_check((board["body"].get("players", []) as Array).size() == 2, "leaderboard lists registered players")

	await _test_connection_layer(b0)

	print("NET TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


## Version handshake, offline/outdated status, request limits, overlapping
## requests, account recovery, and the live channel's version check.
func _test_connection_layer(b: HttpBackend) -> void:
	var health := await b.health()
	_check(int(health["body"].get("protocol", 0)) == NetProtocol.VERSION
		and health["body"].has("server_time"), "health reports the protocol version")

	var conn := GameConnection.new()
	add_child(conn)
	_check(await conn.connect_to("http://127.0.0.1:18080") == GameConnection.Status.ONLINE, "connection goes online")
	var old := GameConnection.new()
	old.client_protocol = NetProtocol.MIN_SUPPORTED - 1
	add_child(old)
	_check(await old.connect_to("http://127.0.0.1:18080") == GameConnection.Status.OUTDATED, "an old build is told to update")
	var nowhere := GameConnection.new()
	add_child(nowhere)
	_check(await nowhere.connect_to("http://127.0.0.1:1") == GameConnection.Status.OFFLINE, "unreachable server reads as offline")

	# Account recovery: a server that forgot the account gets a fresh one.
	AccountStore.clear_for(conn.server_url)
	var acc := await conn.ensure_account("Hyuse")
	_check(not acc.is_empty() and str(acc.get("name")) == "Hyuse", "connection registers an account")
	_server._accounts.erase(acc["player_id"])
	var again := await conn.ensure_account("Hyuse")
	_check(not again.is_empty() and again["player_id"] != acc["player_id"], "forgotten account is re-registered")
	AccountStore.clear_for(conn.server_url)

	# Overlapping calls on one backend (used to fail with ERR_BUSY).
	var results: Array = []
	var fire := func() -> void: results.append(await b.leaderboard())
	fire.call()
	fire.call()
	var end := Time.get_ticks_msec() + 3000
	while results.size() < 2 and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	_check(results.size() == 2 and results.all(func(r: Dictionary) -> bool: return r.get("success", false)),
		"overlapping requests both succeed")

	var huge := "x".repeat(HttpServer.MAX_BODY_BYTES + 10)
	var big := await b.request("POST", "/account/register", { "name": huge })
	_check(int(big.get("status", 0)) == 413, "oversized request bodies are refused")

	var limiter := HttpServer.new()
	limiter.rate_burst = 3.0
	limiter.rate_per_sec = 0.001
	var allowed := [limiter._allow("203.0.113.5"), limiter._allow("203.0.113.5"),
		limiter._allow("203.0.113.5"), limiter._allow("203.0.113.5")]
	_check(allowed == [true, true, true, false] and limiter._allow("203.0.113.9"),
		"per-client rate limit (other clients unaffected)")
	_check(limiter._allow("127.0.0.1") and limiter._allow("127.0.0.1"), "loopback is exempt (local dev)")

	# Live hello from an old build gets "outdated", not a session.
	var ws := LiveClient.new()
	add_child(ws)
	var got := [false]
	ws.outdated.connect(func() -> void: got[0] = true)
	ws.open("ws://127.0.0.1:18081", "nope", "nope")
	end = Time.get_ticks_msec() + 3000
	while not ws.is_open() and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	ws._send({ "type": "hello", "match_id": "x", "token": "y", "protocol": 1 })
	end = Time.get_ticks_msec() + 3000
	while not got[0] and Time.get_ticks_msec() < end:
		await get_tree().process_frame
	_check(got[0], "live channel rejects an outdated client")
	ws.close()


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
