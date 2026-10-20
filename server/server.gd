class_name MatchServer
extends Node
## Headless backend: JSON REST API + server-authoritative deterministic turn
## resolution (GDD Phase 3) with server-enforced fog of war.
##
## Run:
##   godot --headless --path . res://server/server.tscn
## Env vars:
##   TT_PORT              port to listen on (default 8080)
##   TT_TURN_TIMEOUT_SEC  turn timer before auto-fill (default 12h, GDD 3.1)
##   TT_DATA_FILE         where matches are persisted (default user://matches.json)
##
## Endpoints:
##   GET  /health
##   POST /match/create      {seed, squad}            -> {match_id, team, token}
##   POST /match/{id}/join   {squad}                  -> {status, seed, team, token}
##   POST /match/{id}/submit {token, turn, plan}
##   GET  /match/{id}?token=<token>
##
## Accounts, matchmaking, and rating:
##   POST /account/register  {name}                   -> {player_id, secret, name, rating}
##   GET  /account/{id}                               -> {name, rating, wins, losses}
##   GET  /leaderboard                                -> {players: [...top 20 by rating]}
##   POST /queue             {player_id, secret, squad} -> {status: queued|matched, ticket, ...}
##   GET  /queue/{ticket}?secret=<secret>             -> {status, match_id, team, token}
##   POST /queue/{ticket}/cancel {secret}
## Ranked matches pair the waiting player closest in rating, and update both
## players' Elo ratings when the match ends.
##
## Each player receives a secret token on create/join. Submissions are
## attributed to a team by token only, and GET returns only what that team
## may know (Visibility): its own units, enemies in sight, radar pings for
## the rest, and per-tick replay frames filtered the same way. The opponent's
## plans and the full match state never leave the server.

const DEFAULT_PORT := 8080
const DEFAULT_TURN_TIMEOUT_SEC := 12 * 60 * 60  # auto-fill deadline (GDD 3.1)
const DEFAULT_DATA_FILE := "user://matches.json"

## Set false before adding to the tree to disable disk persistence (tests).
var persist := true
## Listening port; TT_PORT overrides it. Tests use their own port so they
## never collide with a server you are running.
var port := DEFAULT_PORT
var turn_timeout_sec := DEFAULT_TURN_TIMEOUT_SEC
var data_file := DEFAULT_DATA_FILE

const START_RATING := 1000
const ELO_K := 32
const NAME_MAX := 20

var _http := HttpServer.new()
var _matches: Dictionary = {}     # id -> match dict
var _accounts: Dictionary = {}    # player_id -> {id, name, secret, rating, wins, losses}
var _tickets: Dictionary = {}     # ticket -> {ticket, player_id, status, squad, rating, match_id, team, token}
var _crypto := Crypto.new()


func _ready() -> void:
	var env := OS.get_environment("TT_PORT")
	if env != "":
		port = int(env)
	var timeout_env := OS.get_environment("TT_TURN_TIMEOUT_SEC")
	if timeout_env != "":
		turn_timeout_sec = int(timeout_env)
	var file_env := OS.get_environment("TT_DATA_FILE")
	if file_env != "":
		data_file = file_env
	if persist:
		_load()
	var ok := _http.start(port, _handle_request)
	print("Trion Tactics server listening on :%d (start=%s, turn timeout %ds, %d matches loaded)" % [
		port, ok, turn_timeout_sec, _matches.size()])


func _process(_delta: float) -> void:
	_http.poll()
	_check_timeouts()


func _handle_request(method: String, path: String, body: Dictionary) -> Dictionary:
	if method == "GET" and path == "/health":
		return _ok({ "ok": true, "matches": _matches.size() })
	if method == "POST" and path == "/match/create":
		return _create_match(body)
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/join"):
		return _join_match(_path_id(path), body)
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/submit"):
		return _submit(_path_id(path), body)
	if method == "GET" and path.begins_with("/match/") and path.split("/", false).size() == 2:
		return _get_match(_path_id(path), str(body.get("token", "")))
	if method == "POST" and path == "/account/register":
		return _register(body)
	if method == "GET" and path.begins_with("/account/"):
		return _get_account(_path_id(path))
	if method == "GET" and path == "/leaderboard":
		return _leaderboard()
	if method == "POST" and path == "/queue":
		return _enqueue(body)
	if method == "POST" and path.begins_with("/queue/") and path.ends_with("/cancel"):
		return _cancel_ticket(_path_id(path), str(body.get("secret", "")))
	if method == "GET" and path.begins_with("/queue/"):
		return _poll_ticket(_path_id(path), str(body.get("secret", "")))
	return _err(404, "not found")


func _path_id(path: String) -> String:
	# split(..., false) drops the leading empty segment: "/match/<id>/join"
	# becomes ["match", "<id>", "join"].
	var parts := path.split("/", false)
	return parts[1] if parts.size() > 1 else ""


# --- Endpoints --------------------------------------------------------------

func _create_match(body: Dictionary) -> Dictionary:
	var squad: Variant = body.get("squad", [])
	if not (squad is Array):
		return _err(400, "squad required")
	var err := PlanCodec.validate_squad(squad)
	if err != "":
		return _err(400, "invalid squad: %s" % err)
	var m := _new_match(squad, int(body.get("seed", MatchRunner.DEFAULT_SEED)))
	_save()
	return _ok({ "match_id": m["id"], "team": 0, "token": m["tokens"][0] })


## Creates a match with team 0's (validated, encoded) squad.
func _new_match(squad: Array, seed: int, ranked := false) -> Dictionary:
	var id := _new_id()
	var m := {
		"id": id,
		"seed": seed,
		"turn": 1,
		"teams": [PlanCodec.decode_squad(squad), null],
		"tokens": [_new_token(), ""],
		"players": ["", ""],
		"ranked": ranked,
		"rating_change": [0, 0],
		"ms": null,
		"plans": [null, null],
		"submitted": [false, false],
		"turn_started": -1.0,
		"winner": -1,
		"history": [],
	}
	_matches[id] = m
	return m


## Seats team 1 and starts the match. Returns team 1's token.
func _seat_second(m: Dictionary, squad: Array) -> String:
	var token := _new_token()
	m["teams"][1] = PlanCodec.decode_squad(squad)
	m["tokens"][1] = token
	m["ms"] = MatchRunner.build_match(m["teams"][0], m["teams"][1], m["seed"])
	m["turn_started"] = Time.get_unix_time_from_system()
	return token


func _join_match(id: String, body: Dictionary) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	if m["teams"][1] != null:
		return _err(409, "match already full")
	var squad: Variant = body.get("squad", [])
	if not (squad is Array):
		return _err(400, "squad required")
	var err := PlanCodec.validate_squad(squad)
	if err != "":
		return _err(400, "invalid squad: %s" % err)
	var token := _seat_second(m, squad)
	_save()
	return _ok({ "status": "ready", "seed": m["seed"], "team": 1, "token": token })


func _submit(id: String, body: Dictionary) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	var team := _team_for_token(m, str(body.get("token", "")))
	if team == -1:
		return _err(403, "invalid token")
	if int(m["winner"]) != -1:
		return _err(409, "match over")
	if m["ms"] == null:
		return _err(409, "match not ready (waiting for opponent)")
	if body.get("turn") != null and int(body["turn"]) != int(m["turn"]):
		return _err(409, "stale turn (server is on turn %d)" % int(m["turn"]))
	if bool(m["submitted"][team]):
		return _ok({ "status": "pending" })
	var plan_dict: Variant = body.get("plan", {})
	if not (plan_dict is Dictionary):
		return _err(400, "plan required")
	var decoded := PlanCodec.decode_plan_checked(plan_dict, m["teams"][team])
	if str(decoded["error"]) != "":
		return _err(400, "invalid plan: %s" % decoded["error"])
	m["plans"][team] = decoded["plan"]
	m["submitted"][team] = true
	if bool(m["submitted"][0]) and bool(m["submitted"][1]):
		_resolve_turn(m)
		_save()
		return _ok({ "status": "resolved", "result": _result_for(m, team) })
	_save()
	return _ok({ "status": "pending" })


## Public info for anyone; the fogged board, replay frames, and own plans
## only for a valid player token.
func _get_match(id: String, token: String) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	var body := {
		"id": id,
		"turn": m["turn"],
		"ready": m["ms"] != null,
		"submitted": m["submitted"],
		"winner": m["winner"],
		"ranked": m.get("ranked", false),
		"players": _player_names(m),
		"rating_change": m.get("rating_change", [0, 0]),
	}
	var team := _team_for_token(m, token)
	if team == -1:
		return _ok(body)
	body["team"] = team
	body["seed"] = m["seed"]
	body["teams"] = [
		PlanCodec.encode_squad(m["teams"][0]) if m["teams"][0] != null else null,
		PlanCodec.encode_squad(m["teams"][1]) if m["teams"][1] != null else null,
	]
	if m["ms"] != null:
		body["view"] = Visibility.encode_view(m["ms"], team, _view_salt(int(m["turn"])))
	var history: Array = []
	for entry in m["history"]:
		history.append(_filter_entry(entry, team))
	body["history"] = history
	body["result"] = history.back() if not history.is_empty() else null
	return _ok(body)


# --- Resolution -------------------------------------------------------------

## Resolves the turn tick by tick, recording a fog-filtered replay frame per
## tick for each team.
func _resolve_turn(m: Dictionary) -> void:
	var ms: MatchState = m["ms"]
	var turn := int(m["turn"])
	var engine := TickEngine.new()
	var frames: Array = [[], []]
	for tick in TurnPlan.TICKS_PER_TURN:
		var events := engine.resolve_tick(ms, m["plans"][0], m["plans"][1], tick)
		for team in 2:
			var states := Visibility.enemy_states(ms, team)
			var seen: Array[CombatEvent] = []
			for ev in events:
				if Visibility.event_visible(ev, team, states):
					seen.append(ev)
			frames[team].append({
				"tick": tick,
				"events": PlanCodec.encode_events(seen),
				"view": Visibility.encode_view(ms, team, turn * 10 + tick),
			})
	var winner := MatchRunner.winner(ms)
	m["history"].append({
		"turn": turn,
		"winner": winner,
		"plans": [PlanCodec.encode_plan(m["plans"][0]), PlanCodec.encode_plan(m["plans"][1])],
		"frames": frames,
	})
	if winner != -1:
		m["winner"] = winner
		if m.get("ranked", false):
			_apply_elo(m, winner)
	else:
		m["turn"] = turn + 1
	m["plans"] = [null, null]
	m["submitted"] = [false, false]
	m["turn_started"] = Time.get_unix_time_from_system()


## A history entry as `team` may see it: its own plan and its own frames.
func _filter_entry(entry: Dictionary, team: int) -> Dictionary:
	return {
		"turn": entry["turn"],
		"winner": entry["winner"],
		"plan": entry["plans"][team],
		"frames": entry["frames"][team],
	}


func _result_for(m: Dictionary, team: int) -> Variant:
	if m["history"].is_empty():
		return null
	return _filter_entry(m["history"].back(), team)


## Radar salt for the planning-phase view. Matches the last replay frame of
## the previous turn (turn * 10 + 5) so pings don't jump between the two.
func _view_salt(turn: int) -> int:
	return turn * 10 - 5


func _check_timeouts() -> void:
	var now := Time.get_unix_time_from_system()
	for id in _matches.keys():
		var m: Dictionary = _matches[id]
		if int(m["winner"]) != -1 or m["ms"] == null or float(m["turn_started"]) < 0.0:
			continue
		if now - float(m["turn_started"]) < turn_timeout_sec:
			continue
		for team in 2:
			if not bool(m["submitted"][team]):
				m["plans"][team] = MatchRunner.build_fallback_plan(m["teams"][team])
				m["submitted"][team] = true
		_resolve_turn(m)
		_save()
		print("Timeout auto-resolved match %s" % id)


# --- Persistence ------------------------------------------------------------

func _save() -> void:
	if not persist:
		return
	var matches := {}
	for id in _matches:
		matches[id] = _serialize(_matches[id])
	var out := { "matches": matches, "accounts": _accounts, "tickets": _tickets }
	var f := FileAccess.open(data_file, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write %s (error %d)" % [data_file, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(out))


func _load() -> void:
	if not FileAccess.file_exists(data_file):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(data_file))
	if not (parsed is Dictionary):
		push_warning("Ignoring unreadable match store %s" % data_file)
		return
	# Older stores were a bare {match_id: match} dictionary.
	var matches: Dictionary = parsed["matches"] if parsed.has("matches") else parsed
	for id in matches:
		_matches[id] = _deserialize(matches[id])
	for id in parsed.get("accounts", {}):
		var a: Dictionary = parsed["accounts"][id]
		a["rating"] = int(a.get("rating", START_RATING))
		a["wins"] = int(a.get("wins", 0))
		a["losses"] = int(a.get("losses", 0))
		_accounts[id] = a
	for t in parsed.get("tickets", {}):
		var ticket: Dictionary = parsed["tickets"][t]
		ticket["team"] = int(ticket.get("team", -1))
		ticket["rating"] = int(ticket.get("rating", START_RATING))
		_tickets[t] = ticket


func _serialize(m: Dictionary) -> Dictionary:
	var plans: Array = []
	for p in m["plans"]:
		plans.append(PlanCodec.encode_plan(p) if p != null else null)
	return {
		"id": m["id"],
		"seed": m["seed"],
		"turn": m["turn"],
		"squads": [
			PlanCodec.encode_squad(m["teams"][0]),
			PlanCodec.encode_squad(m["teams"][1]) if m["teams"][1] != null else null,
		],
		"tokens": m["tokens"],
		"plans": plans,
		"submitted": m["submitted"],
		"turn_started": m["turn_started"],
		"winner": m["winner"],
		"players": m.get("players", ["", ""]),
		"ranked": m.get("ranked", false),
		"rating_change": m.get("rating_change", [0, 0]),
		"history": m["history"],
		"state": PlanCodec.encode_state(m["ms"]) if m["ms"] != null else null,
	}


func _deserialize(d: Dictionary) -> Dictionary:
	var squads: Array = d["squads"]
	var teams: Array = [
		PlanCodec.decode_squad(squads[0]),
		PlanCodec.decode_squad(squads[1]) if squads[1] != null else null,
	]
	var seed := int(d["seed"])
	var ms: MatchState = null
	if teams[1] != null:
		ms = MatchRunner.build_match(teams[0], teams[1], seed)
		if d.get("state") is Dictionary:
			PlanCodec.apply_state(ms, d["state"])
	var plans: Array = [null, null]
	for team in 2:
		var p: Variant = d["plans"][team]
		if p is Dictionary and teams[team] != null:
			plans[team] = PlanCodec.decode_plan(p, teams[team])
	return {
		"id": str(d["id"]),
		"seed": seed,
		"turn": int(d["turn"]),
		"teams": teams,
		"tokens": [str(d["tokens"][0]), str(d["tokens"][1])],
		"ms": ms,
		"plans": plans,
		"submitted": [bool(d["submitted"][0]), bool(d["submitted"][1])],
		"turn_started": float(d["turn_started"]),
		"winner": int(d["winner"]),
		"players": [str(d.get("players", ["", ""])[0]), str(d.get("players", ["", ""])[1])],
		"ranked": bool(d.get("ranked", false)),
		"rating_change": [int(d.get("rating_change", [0, 0])[0]), int(d.get("rating_change", [0, 0])[1])],
		"history": d["history"],
	}


# --- Accounts, Matchmaking, Rating -----------------------------------------

func _register(body: Dictionary) -> Dictionary:
	var player_name := str(body.get("name", "")).strip_edges()
	if player_name == "" or player_name.length() > NAME_MAX:
		return _err(400, "name must be 1-%d characters" % NAME_MAX)
	var id := _new_id()
	_accounts[id] = { "id": id, "name": player_name, "secret": _new_token(), "rating": START_RATING, "wins": 0, "losses": 0 }
	_save()
	var a: Dictionary = _accounts[id]
	return _ok({ "player_id": id, "secret": a["secret"], "name": player_name, "rating": a["rating"] })


func _get_account(id: String) -> Dictionary:
	if not _accounts.has(id):
		return _err(404, "player not found")
	return _ok(_public_account(_accounts[id]))


func _leaderboard() -> Dictionary:
	var players: Array = _accounts.values()
	players.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["rating"]) > int(b["rating"]))
	var top: Array = []
	for a in players.slice(0, 20):
		top.append(_public_account(a))
	return _ok({ "players": top })


## Joins the ranked queue. Pairs immediately with the waiting player closest
## in rating; otherwise returns a ticket to poll.
func _enqueue(body: Dictionary) -> Dictionary:
	var pid := str(body.get("player_id", ""))
	if not _authed(pid, str(body.get("secret", ""))):
		return _err(403, "invalid player credentials")
	var squad: Variant = body.get("squad", [])
	if not (squad is Array):
		return _err(400, "squad required")
	var err := PlanCodec.validate_squad(squad)
	if err != "":
		return _err(400, "invalid squad: %s" % err)
	var rating := int(_accounts[pid]["rating"])

	# Drop any stale ticket of ours, then look for the closest opponent.
	var best: Dictionary = {}
	for t in _tickets.values():
		if t["status"] != "queued":
			continue
		if t["player_id"] == pid:
			t["status"] = "cancelled"
			continue
		if best.is_empty() or absi(int(t["rating"]) - rating) < absi(int(best["rating"]) - rating):
			best = t
	var ticket := { "ticket": _new_id(), "player_id": pid, "status": "queued", "squad": squad, "rating": rating,
		"match_id": "", "team": -1, "token": "" }
	_tickets[ticket["ticket"]] = ticket
	if not best.is_empty():
		# The player who waited hosts (team 0).
		var m := _new_match(best["squad"], int(_crypto.generate_random_bytes(4).decode_u32(0) & 0x7FFFFFFF), true)
		var token1 := _seat_second(m, squad)
		m["players"] = [best["player_id"], pid]
		best.merge({ "status": "matched", "match_id": m["id"], "team": 0, "token": m["tokens"][0] }, true)
		ticket.merge({ "status": "matched", "match_id": m["id"], "team": 1, "token": token1 }, true)
	_save()
	return _ok(_ticket_view(ticket))


func _poll_ticket(id: String, secret: String) -> Dictionary:
	var t: Dictionary = _tickets.get(id, {})
	if t.is_empty() or not _authed(str(t["player_id"]), secret):
		return _err(404, "ticket not found")
	return _ok(_ticket_view(t))


func _cancel_ticket(id: String, secret: String) -> Dictionary:
	var t: Dictionary = _tickets.get(id, {})
	if t.is_empty() or not _authed(str(t["player_id"]), secret):
		return _err(404, "ticket not found")
	if t["status"] == "queued":
		t["status"] = "cancelled"
		_save()
	return _ok(_ticket_view(t))


func _ticket_view(t: Dictionary) -> Dictionary:
	var out := { "ticket": t["ticket"], "status": t["status"] }
	if t["status"] == "matched":
		out.merge({ "match_id": t["match_id"], "team": int(t["team"]), "token": t["token"] })
	return out


## Elo update for a finished ranked match (K = ELO_K).
func _apply_elo(m: Dictionary, winner: int) -> void:
	var players: Array = m.get("players", ["", ""])
	if not (_accounts.has(players[0]) and _accounts.has(players[1])):
		return
	var a: Dictionary = _accounts[players[0]]
	var b: Dictionary = _accounts[players[1]]
	var deltas := elo_deltas(int(a["rating"]), int(b["rating"]), winner)
	a["rating"] = int(a["rating"]) + deltas[0]
	b["rating"] = int(b["rating"]) + deltas[1]
	var winner_acc: Dictionary = a if winner == 0 else b
	var loser_acc: Dictionary = b if winner == 0 else a
	winner_acc["wins"] = int(winner_acc["wins"]) + 1
	loser_acc["losses"] = int(loser_acc["losses"]) + 1
	m["rating_change"] = deltas


## Rating changes [team0, team1] when `winner` (0 or 1) wins.
static func elo_deltas(r0: int, r1: int, winner: int) -> Array:
	var expected0 := 1.0 / (1.0 + pow(10.0, (r1 - r0) / 400.0))
	var score0 := 1.0 if winner == 0 else 0.0
	var d0 := roundi(ELO_K * (score0 - expected0))
	return [d0, -d0]


func _authed(pid: String, secret: String) -> bool:
	return _accounts.has(pid) and secret != "" and str(_accounts[pid]["secret"]) == secret


func _public_account(a: Dictionary) -> Dictionary:
	return { "player_id": a["id"], "name": a["name"], "rating": a["rating"], "wins": a["wins"], "losses": a["losses"] }


func _player_names(m: Dictionary) -> Array:
	var out: Array = []
	for pid in m.get("players", ["", ""]):
		out.append(str(_accounts[pid]["name"]) if _accounts.has(pid) else "")
	return out


# --- Helpers ----------------------------------------------------------------

func _team_for_token(m: Dictionary, token: String) -> int:
	if token == "":
		return -1
	return m["tokens"].find(token)


func _new_id() -> String:
	return _crypto.generate_random_bytes(6).hex_encode()


func _new_token() -> String:
	return _crypto.generate_random_bytes(16).hex_encode()


func _ok(body: Dictionary) -> Dictionary:
	return { "status": 200, "body": body }


func _err(status: int, msg: String) -> Dictionary:
	return { "status": status, "body": { "error": msg } }
