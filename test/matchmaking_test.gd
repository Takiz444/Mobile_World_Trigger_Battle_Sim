extends Node
## Headless tests for ranked matchmaking:
##   - Glicko-2 math (against the worked example in Glickman's paper),
##   - pairing rules (fairness window, uncertainty, rematch avoidance, best
##     pairs first),
##   - the server's ticket lifecycle: queued -> found -> matched, the ready
##     check, no-shows, heartbeats/expiry, cancels,
##   - two independent clients (two "desktops": separate accounts and
##     connections) finding each other through GameConnection.find_match and
##     playing a whole live match over the WebSocket, several times in a row.
##
## Run:
##   godot --headless --path . res://test/matchmaking_test.tscn

const PORT := 18190
const URL := "http://127.0.0.1:18190"

var _failed := false
## The server the network tests talk to (remote_soak.gd points it elsewhere).
var server_url := URL


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_glicko()
	_test_pairing_rules()
	_test_ticket_lifecycle()

	var server := MatchServer.new()
	server.persist = false
	server.port = PORT
	server.live_clock_scale = 0.04
	add_child(server)
	await get_tree().create_timer(0.3).timeout
	await _test_two_clients(server, 3)
	await _test_search_survives_expiry(server)

	print("MATCHMAKING TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


# --- Pure rules -------------------------------------------------------------------

func _test_glicko() -> void:
	# Glickman's example, shifted from his 1500 centre to ours (1000).
	var r := Matchmaker.rate_period({ "rating": 1000.0, "rd": 200.0, "volatility": 0.06 }, [
		[{ "rating": 900.0, "rd": 30.0 }, 1.0],
		[{ "rating": 1050.0, "rd": 100.0 }, 0.0],
		[{ "rating": 1200.0, "rd": 300.0 }, 0.0]])
	_check(absf(float(r["rating"]) - 964.06) < 0.1 and absf(float(r["rd"]) - 151.52) < 0.1
		and absf(float(r["volatility"]) - 0.05999) < 0.0001, "Glicko-2 matches the published example (%s)" % r)
	var fresh := Matchmaker.new_rating()
	var win := Matchmaker.rate(fresh, fresh, 1.0)
	var loss := Matchmaker.rate(fresh, fresh, 0.0)
	_check(float(win["rating"]) > 1100.0 and absf(float(win["rating"]) + float(loss["rating"]) - 2000.0) < 0.01,
		"new players move fast, symmetrically")
	var vet := { "rating": 1000.0, "rd": 50.0, "volatility": 0.06 }
	_check(float(Matchmaker.rate(vet, vet, 1.0)["rating"]) - 1000.0 < 15.0, "established players move slowly")
	_check(Matchmaker.decayed_rd(50.0, 0.0) == 50.0 and Matchmaker.decayed_rd(50.0, 30.0) > 150.0
		and Matchmaker.decayed_rd(50.0, 10000.0) == Matchmaker.MAX_RD, "uncertainty grows back while idle")
	_check(absf(Matchmaker.win_probability(1000, 350, 1000, 50) - 0.5) < 0.0001
		and Matchmaker.win_probability(1100, 50, 1000, 50) > Matchmaker.win_probability(1100, 350, 1000, 350),
		"uncertain ratings predict closer games")


func _test_pairing_rules() -> void:
	var t := func(id: String, rating: float, rd: float, wait: float, last := "") -> Dictionary:
		return { "ticket": id, "player_id": id, "mode": "live", "rating": rating, "rd": rd, "wait": wait, "last_opponent": last }
	_check(not Matchmaker.can_pair(t.call("a", 1000, 50, 99), t.call("a", 1000, 50, 99)), "never pairs a player with themselves")
	var async_b: Dictionary = t.call("b", 1000, 50, 99)
	async_b["mode"] = "async"
	_check(not Matchmaker.can_pair(t.call("a", 1000, 50, 99), async_b), "live and async queues don't mix")
	_check(Matchmaker.can_pair(t.call("a", 1000, 50, 0), t.call("b", 1080, 50, 0)), "close ratings pair at once")
	_check(not Matchmaker.can_pair(t.call("a", 1000, 50, 0), t.call("b", 1400, 50, 0))
		and not Matchmaker.can_pair(t.call("a", 1000, 50, 60), t.call("b", 1400, 50, 0))
		and Matchmaker.can_pair(t.call("a", 1000, 50, 60), t.call("b", 1400, 50, 60)),
		"a wide gap needs both players to have waited")
	_check(Matchmaker.can_pair(t.call("a", 1000, 350, 0), t.call("b", 1150, 350, 0))
		and not Matchmaker.can_pair(t.call("a", 1000, 50, 0), t.call("b", 1150, 50, 0)),
		"unknown players pair more widely than established ones")
	_check(not Matchmaker.can_pair(t.call("a", 1000, 50, 2, "b"), t.call("b", 1000, 50, 2, "a"))
		and Matchmaker.can_pair(t.call("a", 1000, 50, Matchmaker.REMATCH_AVOID_SEC + 1, "b"), t.call("b", 1000, 50, 0, "a")),
		"an instant rematch waits a few seconds (then is allowed)")
	var pairs := Matchmaker.pair([t.call("a", 1000, 50, 50), t.call("c", 1500, 50, 50), t.call("b", 1010, 50, 0), t.call("d", 1490, 50, 0)])
	var names := pairs.map(func(p: Array) -> String: return "%s-%s" % [p[0]["ticket"], p[1]["ticket"]])
	_check(names.size() == 2 and names.has("a-b") and names.has("c-d"), "best pairs first, longest waiter hosts (%s)" % [names])


# --- Ticket lifecycle (in-process server, no network) ------------------------------

func _test_ticket_lifecycle() -> void:
	var s := MatchServer.new()
	s.persist = false
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var acc := func(n: String) -> Dictionary: return s._register({ "name": n })["body"]
	var q := func(a: Dictionary, mode := "live") -> Dictionary:
		return s._enqueue({ "player_id": a["player_id"], "secret": a["secret"], "squad": squad, "mode": mode })["body"]
	var a: Dictionary = acc.call("Ana")
	var b: Dictionary = acc.call("Ben")
	var c: Dictionary = acc.call("Cat")

	# Found -> both accept -> matched.
	var ta: Dictionary = q.call(a)
	_check(str(ta["status"]) == "queued" and int(ta["searching"]) == 1, "alone in the queue")
	var tb: Dictionary = q.call(b)
	_check(str(tb["status"]) == "found" and float(tb["accept_sec_left"]) > 0.0, "a pair is found, pending the ready check")
	var acc_a: Dictionary = s._accept_ticket(ta["ticket"], a["secret"])["body"]
	_check(str(acc_a["status"]) == "found" and bool(acc_a["accepted"]), "one accept is not enough")
	var acc_b: Dictionary = s._accept_ticket(tb["ticket"], b["secret"])["body"]
	var pa: Dictionary = s._poll_ticket(ta["ticket"], a["secret"])["body"]
	_check(str(acc_b["status"]) == "matched" and str(pa["status"]) == "matched" and pa["match_id"] == acc_b["match_id"]
		and int(pa["team"]) == 0 and int(acc_b["team"]) == 1, "both accepted: one match, longest waiter hosts")
	_check(float(s._ticket_view(s._tickets[tb["ticket"]])["estimated_wait"]) >= 0.0, "wait estimate is learned")
	_check(int(s._accept_ticket(ta["ticket"], b["secret"]).get("status", 0)) == 404, "accept needs the ticket owner's secret")
	_finish(s, str(pa["match_id"]))

	# No-show: the one who accepted goes back in line, keeping their place.
	# (Dee, not Ben: Ana and Ben just played, so they'd wait out the rematch rule.)
	var d: Dictionary = acc.call("Dee")
	ta = q.call(a, "async")
	tb = q.call(d, "async")
	_check(str(tb["status"]) == "found", "a different opponent is found right away")
	s._accept_ticket(ta["ticket"], a["secret"])
	var queued_at := float(s._tickets[ta["ticket"]]["queued_at"])
	s._tickets[ta["ticket"]]["found_at"] -= MatchServer.ACCEPT_SEC + 1.0
	s._tickets[tb["ticket"]]["found_at"] -= MatchServer.ACCEPT_SEC + 1.0
	s._run_matchmaker()
	_check(str(s._tickets[ta["ticket"]]["status"]) == "queued" and float(s._tickets[ta["ticket"]]["queued_at"]) == queued_at
		and str(s._tickets[tb["ticket"]]["status"]) == "expired", "no-show: accepter requeued at the front, no-show dropped")
	var tc: Dictionary = q.call(c, "async")
	_check(str(tc["status"]) == "found" and str(s._tickets[ta["ticket"]]["partner"]) == str(tc["ticket"]),
		"the requeued player gets the next opponent")

	# Cancelling a found match puts the partner back in the queue.
	s._cancel_ticket(tc["ticket"], c["secret"])
	_check(str(s._tickets[tc["ticket"]]["status"]) == "cancelled" and str(s._tickets[ta["ticket"]]["status"]) == "queued",
		"cancel during the ready check requeues the partner")

	# Heartbeats: a silent ticket is never matched, then expires.
	s._tickets[ta["ticket"]]["last_seen"] -= MatchServer.TICKET_STALE_SEC + 1.0
	tb = q.call(b, "async")
	_check(str(tb["status"]) == "queued", "a ticket that stopped polling is not matched (closed tab)")
	s._tickets[ta["ticket"]]["last_seen"] -= MatchServer.TICKET_EXPIRE_SEC
	s._run_matchmaker()
	_check(str(s._tickets[ta["ticket"]]["status"]) == "expired", "a silent ticket expires")
	s._poll_ticket(tb["ticket"], b["secret"])
	_check(int(s._ticket_view(s._tickets[tb["ticket"]])["searching"]) == 1, "expired tickets don't count as searching")

	# One search per player.
	var tb2: Dictionary = q.call(b, "async")
	_check(str(s._tickets[tb["ticket"]]["status"]) == "cancelled" and str(tb2["status"]) == "queued",
		"searching again replaces the old search")
	s.free()


## Ends a match in `s` with team 0 winning (rating side effects included).
func _finish(s: MatchServer, match_id: String) -> void:
	var m: Dictionary = s._matches[match_id]
	s._end_match(m, 0, "test")
	_check(int(m["rating_change"][0]) > 0 and int(m["rating_change"][1]) < 0, "the winner gains rating, the loser loses it")


# --- Two clients over the network ----------------------------------------------------

## Two separate clients (accounts, connections) queue for Live Battle at the
## same time, find each other, and play live matches to the end, `rounds`
## times in a row (rematches included).
func _test_two_clients(server: MatchServer, rounds: int) -> void:
	var p1 := await _player("Desk One")
	var p2 := await _player("Desk Two")
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	for round in rounds:
		var results := [{}, {}]
		var updates := [[], []]
		var find := func(i: int, p: GameConnection) -> void:
			results[i] = await p.find_match(squad, "live", func() -> bool: return true,
				func(t: Dictionary) -> void: updates[i].append(str(t.get("status", ""))))
		find.call(0, p1)
		await get_tree().create_timer(0.4).timeout
		find.call(1, p2)
		await _wait(func() -> bool: return not results[0].is_empty() and not results[1].is_empty(), 20.0)
		var t1: Dictionary = results[0]
		var t2: Dictionary = results[1]
		_check(not t1.is_empty() and not t2.is_empty() and t1.get("match_id") == t2.get("match_id")
			and int(t1["team"]) + int(t2["team"]) == 1, "round %d: both desktops land in the same match" % (round + 1))
		if t1.is_empty() or t2.is_empty():
			return
		_check(updates[0].has("found") or updates[1].has("found"), "round %d: the ready check ran" % (round + 1))
		var over := await _play_live(t1, t2)
		_check(over[0].size() > 0 and over[1].size() > 0 and over[0]["winner"] == over[1]["winner"],
			"round %d: the live match finishes, both see the same result (%s)" % [round + 1, over[0].get("reason", "?")])
	var a1: Dictionary = (await p1.backend.get_account(p1.account["player_id"]))["body"]
	var a2: Dictionary = (await p2.backend.get_account(p2.account["player_id"]))["body"]
	_check(int(a1["wins"]) + int(a1["losses"]) + int(a1["draws"]) == rounds
		and int(a2["wins"]) + int(a2["losses"]) + int(a2["draws"]) == rounds, "every match was recorded for both players")


## A client whose ticket expires mid-search (e.g. its tab was hidden) searches
## again on its own and still gets matched.
func _test_search_survives_expiry(server: MatchServer) -> void:
	var p1 := await _player("Sleepy")
	var p2 := await _player("Awake")
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var results := [{}, {}]
	var go := func(i: int, p: GameConnection) -> void:
		results[i] = await p.find_match(squad, "async", func() -> bool: return true)
	go.call(0, p1)
	await get_tree().create_timer(0.3).timeout
	var first := ""
	for t in server._tickets.values():
		if t["player_id"] == p1.account["player_id"] and t["status"] == "queued":
			first = t["ticket"]
			t["last_seen"] -= MatchServer.TICKET_EXPIRE_SEC + 1.0
	server._run_matchmaker()
	_check(first != "" and str(server._tickets[first]["status"]) == "expired", "the sleepy client's ticket expired")
	await get_tree().create_timer(1.5).timeout
	go.call(1, p2)
	await _wait(func() -> bool: return not results[0].is_empty() and not results[1].is_empty(), 15.0)
	_check(not results[0].is_empty() and results[0].get("match_id") == results[1].get("match_id"),
		"it searched again by itself and was matched")


## Plays a live match between two matched tickets: each side submits a plan
## as soon as each turn opens. Returns both match_over messages.
func _play_live(t1: Dictionary, t2: Dictionary) -> Array:
	var over := [{}, {}]
	var clients: Array = []
	for i in 2:
		var t: Dictionary = [t1, t2][i]
		var live := LiveClient.new()
		add_child(live)
		var squad := TriggerLibrary.sample_units()
		var plan := PlanCodec.encode_plan(MatchRunner.build_fallback_plan(squad))
		live.state_received.connect(func(body: Dictionary) -> void:
			if int(body.get("winner", -1)) == -1:
				live.submit(int(body["turn"]), plan))
		live.turn_resolved.connect(func(_r: Dictionary, turn: int, _left: float) -> void: live.submit(turn, plan))
		live.match_over.connect(func(msg: Dictionary) -> void: over[i] = msg)
		var url := str(t.get("live_url", "")) if str(t.get("live_url", "")) != "" else LiveClient.derive_url(server_url)
		live.open(url, str(t["match_id"]), str(t["token"]))
		clients.append(live)
	await _wait(func() -> bool: return not over[0].is_empty() and not over[1].is_empty(), 30.0)
	for live in clients:
		live.close()
		live.queue_free()
	return over


## A connected client with its own account (like a separate desktop).
func _player(player_name: String) -> GameConnection:
	var conn := GameConnection.new()
	add_child(conn)
	await conn.connect_to(server_url)
	var reg := await conn.backend.register_account(player_name)
	conn.account = reg["body"]
	return conn


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
