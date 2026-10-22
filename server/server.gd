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
##   POST /match/create      {seed, squad, mode?}     -> {match_id, team, token}
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
## Ranked matches pair waiting players by hidden rating (the accepted gap
## widens the longer they wait, Ladder.search_window), and update both
## players' Elo ratings when the match ends.
##
## Live ranked play (the competitive ladder, `mode: "live"` on /queue):
##   Short simultaneous turns on a server clock (Ladder.LIVE_*), a turn cap
##   with a tiebreak (MatchRunner.tiebreak_winner), AFK forfeit after
##   consecutive auto-filled turns, and trophies/arenas (Ladder) on top of
##   the hidden rating. Clients connect to the live WebSocket (LiveHub, port
##   TT_LIVE_PORT, default TT_PORT + 1) and get events pushed:
##     -> {type: "hello", match_id, token}       <- {type: "state", ...GET body}
##     -> {type: "submit", turn, plan}           <- {type: "submit_ack", status}
##     -> {type: "forfeit"}                      <- {type: "opponent_locked", turn}
##     -> {type: "ping"}                         <- {type: "pong", server_time}
##                                               <- {type: "turn_resolved", result, turn, seconds_left}
##                                               <- {type: "match_over", winner, reason, ...}
##                                               <- {type: "presence", connected: [bool, bool]}
##   POST /match/{id}/forfeit {token}             concede (REST fallback)
##
## Account lifecycle:
##   POST /account/delete    {player_id, secret}  delete account (App Store 5.1.1(v))
##   POST /admin/season/reset {admin_key}         soft-reset trophies (TT_ADMIN_KEY)
##
## Each player receives a secret token on create/join. Submissions are
## attributed to a team by token only, and GET returns only what that team
## may know (Visibility): its own units, enemies in sight, radar pings for
## the rest, and per-tick replay frames filtered the same way. The opponent's
## plans and the full match state never leave the server.

const DEFAULT_PORT := 8080
const DEFAULT_TURN_TIMEOUT_SEC := 12 * 60 * 60  # auto-fill deadline (GDD 3.1)
const DEFAULT_DATA_FILE := "user://matches.json"
const MATCHMAKER_INTERVAL := 1.0

## Set false before adding to the tree to disable disk persistence (tests).
var persist := true
## Listening port; TT_PORT overrides it. Tests use their own port so they
## never collide with a server you are running.
var port := DEFAULT_PORT
## Live WebSocket port; TT_LIVE_PORT overrides it. -1 = port + 1.
var live_port := -1
## Public wss:// URL of the live channel handed to clients (TT_PUBLIC_LIVE_URL),
## e.g. "wss://play.example.com/live". Empty = clients derive it.
var public_live_url := ""
var turn_timeout_sec := DEFAULT_TURN_TIMEOUT_SEC
## Multiplies every live clock (tests run live matches in seconds).
var live_clock_scale := 1.0
var data_file := DEFAULT_DATA_FILE
## Required for /admin endpoints (TT_ADMIN_KEY); empty disables them.
var admin_key := ""

const START_RATING := 1000
const ELO_K := 32
const NAME_MAX := 20

var _http := HttpServer.new()
var _hub := LiveHub.new()
var _matches: Dictionary = {}     # id -> match dict
var _accounts: Dictionary = {}    # player_id -> {id, name, secret, rating, trophies, best_trophies, wins, losses, draws}
var _tickets: Dictionary = {}     # ticket -> {ticket, player_id, status, mode, squad, rating, queued_at, match_id, team, token}
var _season := 1
var _mm_timer := 0.0
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
	var live_env := OS.get_environment("TT_LIVE_PORT")
	if live_env != "":
		live_port = int(live_env)
	if live_port < 0:
		live_port = port + 1
	if OS.get_environment("TT_PUBLIC_LIVE_URL") != "":
		public_live_url = OS.get_environment("TT_PUBLIC_LIVE_URL")
	if OS.get_environment("TT_ADMIN_KEY") != "":
		admin_key = OS.get_environment("TT_ADMIN_KEY")
	if persist:
		_load()
	var ok := _http.start(port, _handle_request)
	var live_ok := _hub.start(live_port, _on_live_message, _on_live_close)
	print("Trion Tactics server listening on :%d (start=%s), live :%d (start=%s), turn timeout %ds, %d matches loaded" % [
		port, ok, live_port, live_ok, turn_timeout_sec, _matches.size()])


func _exit_tree() -> void:
	_hub.stop()


func _process(delta: float) -> void:
	_http.poll()
	_hub.poll()
	_check_timeouts()
	_mm_timer += delta
	if _mm_timer >= MATCHMAKER_INTERVAL:
		_mm_timer = 0.0
		if _run_matchmaker() > 0:
			_save()


func _handle_request(method: String, path: String, body: Dictionary) -> Dictionary:
	if method == "GET" and path == "/health":
		return _ok({ "ok": true, "matches": _matches.size() })
	if method == "POST" and path == "/match/create":
		return _create_match(body)
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/join"):
		return _join_match(_path_id(path), body)
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/submit"):
		return _submit(_path_id(path), body)
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/forfeit"):
		return _forfeit(_path_id(path), str(body.get("token", "")))
	if method == "GET" and path.begins_with("/match/") and path.split("/", false).size() == 2:
		return _get_match(_path_id(path), str(body.get("token", "")))
	if method == "POST" and path == "/account/register":
		return _register(body)
	if method == "POST" and path == "/account/delete":
		return _delete_account(body)
	if method == "POST" and path == "/admin/season/reset":
		return _season_reset(body)
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
	# Friendly battles may opt into the live clock; they never affect rating.
	var mode := "live" if str(body.get("mode", "async")) == "live" else "async"
	var m := _new_match(squad, int(body.get("seed", MatchRunner.DEFAULT_SEED)), false, mode)
	_save()
	return _ok({ "match_id": m["id"], "team": 0, "token": m["tokens"][0] })


## Creates a match with team 0's (validated, encoded) squad. `mode` is
## "async" (long turn timer, no cap) or "live" (Ladder clock, turn cap).
func _new_match(squad: Array, seed: int, ranked := false, mode := "async") -> Dictionary:
	var id := _new_id()
	var m := {
		"id": id,
		"seed": seed,
		"mode": mode,
		"max_turns": Ladder.LIVE_MAX_TURNS if mode == "live" else 0,
		"turn": 1,
		"teams": [PlanCodec.decode_squad(squad), null],
		"tokens": [_new_token(), ""],
		"players": ["", ""],
		"ranked": ranked,
		"rating_change": [0, 0],
		"trophy_change": [0, 0],
		"ms": null,
		"plans": [null, null],
		"submitted": [false, false],
		"missed": [0, 0],
		"turn_started": -1.0,
		"deadline": -1.0,
		"winner": -1,
		"end_reason": "",
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
	_start_turn_clock(m, Ladder.LIVE_LOAD_GRACE_SEC)
	return token


## Starts the planning clock for the match's current turn. Live matches get
## Ladder's short planning window (plus `extra` for loading / replay time).
func _start_turn_clock(m: Dictionary, extra := 0.0) -> void:
	var now := Time.get_unix_time_from_system()
	m["turn_started"] = now
	if m.get("mode", "async") == "live":
		m["deadline"] = now + (extra + Ladder.live_turn_sec(int(m["turn"]))) * live_clock_scale
	else:
		m["deadline"] = now + turn_timeout_sec


func _seconds_left(m: Dictionary) -> float:
	if float(m.get("deadline", -1.0)) < 0.0 or int(m["winner"]) != -1:
		return -1.0
	return maxf(0.0, float(m["deadline"]) - Time.get_unix_time_from_system())


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
	return _ok({ "status": "ready", "seed": m["seed"], "team": 1, "token": token, "mode": m["mode"] })


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
	m["missed"][team] = 0
	if bool(m["submitted"][0]) and bool(m["submitted"][1]):
		_resolve_turn(m)
		_save()
		return _ok({ "status": "resolved", "result": _result_for(m, team) })
	_hub.send_to(m["id"], 1 - team, { "type": "opponent_locked", "turn": m["turn"] })
	_save()
	return _ok({ "status": "pending" })


func _forfeit(id: String, token: String) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	var team := _team_for_token(m, token)
	if team == -1:
		return _err(403, "invalid token")
	if int(m["winner"]) != -1:
		return _err(409, "match over")
	_end_match(m, 1 - team, "forfeit")
	_save()
	return _ok({ "status": "forfeited", "winner": m["winner"] })


## Public info for anyone; the fogged board, replay frames, and own plans
## only for a valid player token.
func _get_match(id: String, token: String) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	var body := {
		"id": id,
		"mode": m.get("mode", "async"),
		"turn": m["turn"],
		"max_turns": m.get("max_turns", 0),
		"seconds_left": _seconds_left(m),
		"ready": m["ms"] != null,
		"submitted": m["submitted"],
		"winner": m["winner"],
		"end_reason": m.get("end_reason", ""),
		"ranked": m.get("ranked", false),
		"players": _player_names(m),
		"rating_change": m.get("rating_change", [0, 0]),
		"trophy_change": m.get("trophy_change", [0, 0]),
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
	var reason := "elimination"
	var max_turns := int(m.get("max_turns", 0))
	if winner == -1 and max_turns > 0 and turn >= max_turns:
		winner = MatchRunner.tiebreak_winner(ms)
		reason = "turn_cap"
	m["history"].append({
		"turn": turn,
		"winner": winner,
		"plans": [PlanCodec.encode_plan(m["plans"][0]), PlanCodec.encode_plan(m["plans"][1])],
		"frames": frames,
	})
	m["plans"] = [null, null]
	m["submitted"] = [false, false]
	if winner == -1:
		m["turn"] = turn + 1
		_start_turn_clock(m, Ladder.LIVE_REPLAY_SEC)
	for team in 2:
		_hub.send_to(m["id"], team, {
			"type": "turn_resolved",
			"result": _filter_entry(m["history"].back(), team),
			"turn": m["turn"],
			"seconds_left": _seconds_left(m),
		})
	if winner != -1:
		_end_match(m, winner, reason)


## Ends a match: records the result, applies rating (ranked) and trophies
## (ranked live), and pushes match_over to both players.
func _end_match(m: Dictionary, winner: int, reason: String) -> void:
	m["winner"] = winner
	m["end_reason"] = reason
	m["deadline"] = -1.0
	if m.get("ranked", false):
		_apply_elo(m, winner)
		if m.get("mode", "async") == "live":
			_apply_trophies(m, winner)
	for team in 2:
		_hub.send_to(m["id"], team, {
			"type": "match_over",
			"winner": winner,
			"reason": reason,
			"rating_change": m.get("rating_change", [0, 0]),
			"trophy_change": m.get("trophy_change", [0, 0]),
		})


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


## Auto-fills missing plans once a turn's deadline passes (GDD 3.1) and
## resolves. In live matches, a player auto-filled LIVE_AFK_FORFEIT_TURNS
## turns in a row forfeits (both AFK = draw).
func _check_timeouts() -> void:
	var now := Time.get_unix_time_from_system()
	for id in _matches.keys():
		var m: Dictionary = _matches[id]
		if int(m["winner"]) != -1 or m["ms"] == null or float(m.get("deadline", -1.0)) < 0.0:
			continue
		if now < float(m["deadline"]):
			continue
		for team in 2:
			if not bool(m["submitted"][team]):
				m["plans"][team] = MatchRunner.build_fallback_plan(m["teams"][team])
				m["submitted"][team] = true
				m["missed"][team] = int(m["missed"][team]) + 1
		_resolve_turn(m)
		if int(m["winner"]) == -1 and m.get("mode", "async") == "live":
			var afk := [int(m["missed"][0]) >= Ladder.LIVE_AFK_FORFEIT_TURNS,
				int(m["missed"][1]) >= Ladder.LIVE_AFK_FORFEIT_TURNS]
			if afk[0] and afk[1]:
				_end_match(m, MatchRunner.DRAW, "afk")
			elif afk[0] or afk[1]:
				_end_match(m, 1 if afk[0] else 0, "afk")
		_save()
		print("Timeout auto-resolved match %s" % id)


# --- Persistence ------------------------------------------------------------

func _save() -> void:
	if not persist:
		return
	var matches := {}
	for id in _matches:
		matches[id] = _serialize(_matches[id])
	var out := { "matches": matches, "accounts": _accounts, "tickets": _tickets, "season": _season }
	# Write a temp file and rename it over the store, so a crash mid-write
	# can't leave a truncated store behind.
	var tmp := data_file + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write %s (error %d)" % [tmp, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(out))
	f.close()
	var err := DirAccess.rename_absolute(tmp, data_file)
	if err != OK:
		push_warning("Could not replace %s (error %d)" % [data_file, err])


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
		_accounts[id] = _normalize_account(a)
	for t in parsed.get("tickets", {}):
		var ticket: Dictionary = parsed["tickets"][t]
		ticket["team"] = int(ticket.get("team", -1))
		ticket["rating"] = int(ticket.get("rating", START_RATING))
		ticket["mode"] = str(ticket.get("mode", "async"))
		ticket["queued_at"] = float(ticket.get("queued_at", Time.get_unix_time_from_system()))
		_tickets[t] = ticket
	_season = int(parsed.get("season", 1))


## Fills fields that older stores lack and fixes JSON number types.
func _normalize_account(a: Dictionary) -> Dictionary:
	a["rating"] = int(a.get("rating", START_RATING))
	a["trophies"] = int(a.get("trophies", 0))
	a["best_trophies"] = maxi(int(a.get("best_trophies", 0)), int(a["trophies"]))
	a["wins"] = int(a.get("wins", 0))
	a["losses"] = int(a.get("losses", 0))
	a["draws"] = int(a.get("draws", 0))
	return a


func _serialize(m: Dictionary) -> Dictionary:
	var plans: Array = []
	for p in m["plans"]:
		plans.append(PlanCodec.encode_plan(p) if p != null else null)
	return {
		"id": m["id"],
		"seed": m["seed"],
		"mode": m.get("mode", "async"),
		"max_turns": m.get("max_turns", 0),
		"turn": m["turn"],
		"squads": [
			PlanCodec.encode_squad(m["teams"][0]),
			PlanCodec.encode_squad(m["teams"][1]) if m["teams"][1] != null else null,
		],
		"tokens": m["tokens"],
		"plans": plans,
		"submitted": m["submitted"],
		"missed": m.get("missed", [0, 0]),
		"turn_started": m["turn_started"],
		"deadline": m.get("deadline", -1.0),
		"winner": m["winner"],
		"end_reason": m.get("end_reason", ""),
		"players": m.get("players", ["", ""]),
		"ranked": m.get("ranked", false),
		"rating_change": m.get("rating_change", [0, 0]),
		"trophy_change": m.get("trophy_change", [0, 0]),
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
	var turn_started := float(d["turn_started"])
	# Older stores had no deadline: it was always turn_started + timeout.
	var deadline := float(d.get("deadline", turn_started + turn_timeout_sec if turn_started >= 0.0 else -1.0))
	return {
		"id": str(d["id"]),
		"seed": seed,
		"mode": str(d.get("mode", "async")),
		"max_turns": int(d.get("max_turns", 0)),
		"turn": int(d["turn"]),
		"teams": teams,
		"tokens": [str(d["tokens"][0]), str(d["tokens"][1])],
		"ms": ms,
		"plans": plans,
		"submitted": [bool(d["submitted"][0]), bool(d["submitted"][1])],
		"missed": [int(d.get("missed", [0, 0])[0]), int(d.get("missed", [0, 0])[1])],
		"turn_started": turn_started,
		"deadline": deadline,
		"winner": int(d["winner"]),
		"end_reason": str(d.get("end_reason", "")),
		"players": [str(d.get("players", ["", ""])[0]), str(d.get("players", ["", ""])[1])],
		"ranked": bool(d.get("ranked", false)),
		"rating_change": [int(d.get("rating_change", [0, 0])[0]), int(d.get("rating_change", [0, 0])[1])],
		"trophy_change": [int(d.get("trophy_change", [0, 0])[0]), int(d.get("trophy_change", [0, 0])[1])],
		"history": d["history"],
	}


# --- Accounts, Matchmaking, Rating -----------------------------------------

func _register(body: Dictionary) -> Dictionary:
	var player_name := str(body.get("name", "")).strip_edges()
	if player_name == "" or player_name.length() > NAME_MAX:
		return _err(400, "name must be 1-%d characters" % NAME_MAX)
	var id := _new_id()
	_accounts[id] = _normalize_account({ "id": id, "name": player_name, "secret": _new_token() })
	_save()
	var a: Dictionary = _accounts[id]
	return _ok({ "player_id": id, "secret": a["secret"], "name": player_name, "rating": a["rating"],
		"trophies": a["trophies"] })


## Permanently deletes an account (App Store Guideline 5.1.1(v): apps with
## account creation must offer in-app deletion). Its open tickets are
## cancelled and unfinished matches are forfeited; finished matches keep only
## the anonymous player id.
func _delete_account(body: Dictionary) -> Dictionary:
	var pid := str(body.get("player_id", ""))
	if not _authed(pid, str(body.get("secret", ""))):
		return _err(403, "invalid player credentials")
	for t in _tickets.values():
		if t["player_id"] == pid and t["status"] == "queued":
			t["status"] = "cancelled"
	for m in _matches.values():
		var seat: int = (m.get("players", ["", ""]) as Array).find(pid)
		if seat != -1 and int(m["winner"]) == -1 and m["ms"] != null:
			_end_match(m, 1 - seat, "forfeit")
	_accounts.erase(pid)
	_save()
	return _ok({ "deleted": pid })


## Season end: soft-resets everyone's trophies (Ladder.season_reset).
func _season_reset(body: Dictionary) -> Dictionary:
	if admin_key == "" or str(body.get("admin_key", "")) != admin_key:
		return _err(403, "forbidden")
	for a in _accounts.values():
		a["trophies"] = Ladder.season_reset(int(a["trophies"]))
	_season += 1
	_save()
	return _ok({ "season": _season, "players": _accounts.size() })


func _get_account(id: String) -> Dictionary:
	if not _accounts.has(id):
		return _err(404, "player not found")
	return _ok(_public_account(_accounts[id]))


func _leaderboard() -> Dictionary:
	# The visible ladder: trophies first, hidden rating breaks ties.
	var players: Array = _accounts.values()
	players.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["trophies"]) != int(b["trophies"]):
			return int(a["trophies"]) > int(b["trophies"])
		return int(a["rating"]) > int(b["rating"]))
	var top: Array = []
	for a in players.slice(0, 20):
		top.append(_public_account(a))
	return _ok({ "season": _season, "players": top })


## Joins the ranked queue (`mode`: "async" or "live"). Returns the ticket,
## already matched if a compatible opponent was waiting; otherwise poll it
## (the matchmaker re-runs every second as search windows widen).
func _enqueue(body: Dictionary) -> Dictionary:
	var pid := str(body.get("player_id", ""))
	if not _authed(pid, str(body.get("secret", ""))):
		return _err(403, "invalid player credentials")
	var mode := str(body.get("mode", "async"))
	if not (mode in ["async", "live"]):
		return _err(400, "mode must be async or live")
	var squad: Variant = body.get("squad", [])
	if not (squad is Array):
		return _err(400, "squad required")
	var err := PlanCodec.validate_squad(squad)
	if err != "":
		return _err(400, "invalid squad: %s" % err)

	# One search per player: drop any stale ticket of ours.
	for t in _tickets.values():
		if t["player_id"] == pid and t["status"] == "queued":
			t["status"] = "cancelled"
	var ticket := { "ticket": _new_id(), "player_id": pid, "status": "queued", "mode": mode, "squad": squad,
		"rating": int(_accounts[pid]["rating"]), "queued_at": Time.get_unix_time_from_system(),
		"match_id": "", "team": -1, "token": "" }
	_tickets[ticket["ticket"]] = ticket
	_run_matchmaker()
	_save()
	return _ok(_ticket_view(ticket))


## Pairs queued tickets of the same mode whose search windows both accept
## the rating gap, oldest ticket first, each with its closest candidate.
## Returns the number of matches made.
func _run_matchmaker() -> int:
	var now := Time.get_unix_time_from_system()
	var queued: Array = []
	for t in _tickets.values():
		if t["status"] == "queued":
			queued.append(t)
	queued.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["queued_at"]) < float(b["queued_at"]))
	var made := 0
	for a in queued:
		if a["status"] != "queued":
			continue
		var best: Dictionary = {}
		for b in queued:
			if b == a or b["status"] != "queued" or b["mode"] != a["mode"] or b["player_id"] == a["player_id"]:
				continue
			if not Ladder.can_pair(int(a["rating"]), now - float(a["queued_at"]),
					int(b["rating"]), now - float(b["queued_at"])):
				continue
			if best.is_empty() or absi(int(b["rating"]) - int(a["rating"])) < absi(int(best["rating"]) - int(a["rating"])):
				best = b
		if best.is_empty():
			continue
		# The player who waited longer hosts (team 0).
		var seed := int(_crypto.generate_random_bytes(4).decode_u32(0) & 0x7FFFFFFF)
		var m := _new_match(a["squad"], seed, true, str(a["mode"]))
		var token1 := _seat_second(m, best["squad"])
		m["players"] = [a["player_id"], best["player_id"]]
		a.merge({ "status": "matched", "match_id": m["id"], "team": 0, "token": m["tokens"][0] }, true)
		best.merge({ "status": "matched", "match_id": m["id"], "team": 1, "token": token1 }, true)
		made += 1
	return made


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
	var out := { "ticket": t["ticket"], "status": t["status"], "mode": t.get("mode", "async") }
	if t["status"] == "matched":
		out.merge({ "match_id": t["match_id"], "team": int(t["team"]), "token": t["token"] })
		if public_live_url != "":
			out["live_url"] = public_live_url
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
	if winner == 0 or winner == 1:
		var winner_acc: Dictionary = a if winner == 0 else b
		var loser_acc: Dictionary = b if winner == 0 else a
		winner_acc["wins"] = int(winner_acc["wins"]) + 1
		loser_acc["losses"] = int(loser_acc["losses"]) + 1
	else:
		a["draws"] = int(a["draws"]) + 1
		b["draws"] = int(b["draws"]) + 1
	m["rating_change"] = deltas


## Trophy update for a finished live ranked match (Ladder.trophy_deltas).
func _apply_trophies(m: Dictionary, winner: int) -> void:
	var players: Array = m.get("players", ["", ""])
	if not (_accounts.has(players[0]) and _accounts.has(players[1])):
		return
	var accs: Array = [_accounts[players[0]], _accounts[players[1]]]
	var deltas := Ladder.trophy_deltas(
		[int(accs[0]["trophies"]), int(accs[1]["trophies"])],
		[int(accs[0]["best_trophies"]), int(accs[1]["best_trophies"])], winner)
	for i in 2:
		accs[i]["trophies"] = int(accs[i]["trophies"]) + int(deltas[i])
		accs[i]["best_trophies"] = maxi(int(accs[i]["best_trophies"]), int(accs[i]["trophies"]))
	m["trophy_change"] = deltas


## Rating changes [team0, team1] when `winner` (0, 1, or MatchRunner.DRAW) wins.
static func elo_deltas(r0: int, r1: int, winner: int) -> Array:
	var expected0 := 1.0 / (1.0 + pow(10.0, (r1 - r0) / 400.0))
	var score0 := 1.0 if winner == 0 else (0.0 if winner == 1 else 0.5)
	var d0 := roundi(ELO_K * (score0 - expected0))
	return [d0, -d0]


func _authed(pid: String, secret: String) -> bool:
	return _accounts.has(pid) and secret != "" and str(_accounts[pid]["secret"]) == secret


func _public_account(a: Dictionary) -> Dictionary:
	return { "player_id": a["id"], "name": a["name"], "rating": a["rating"], "trophies": a["trophies"],
		"best_trophies": a["best_trophies"], "arena": Ladder.arena_name(int(a["best_trophies"])),
		"wins": a["wins"], "losses": a["losses"], "draws": a["draws"] }


func _player_names(m: Dictionary) -> Array:
	var out: Array = []
	for pid in m.get("players", ["", ""]):
		out.append(str(_accounts[pid]["name"]) if _accounts.has(pid) else "")
	return out


# --- Live channel (LiveHub) -------------------------------------------------

## A live client message. "hello" subscribes the connection to its match
## (by player token); everything else acts as that player.
func _on_live_message(conn: Dictionary, msg: Dictionary) -> void:
	var type := str(msg.get("type", ""))
	if type == "ping":
		_hub.send(conn, { "type": "pong", "server_time": Time.get_unix_time_from_system() })
		return
	if type == "hello":
		var id := str(msg.get("match_id", ""))
		var m: Dictionary = _matches.get(id, {})
		var team := _team_for_token(m, str(msg.get("token", ""))) if not m.is_empty() else -1
		if team == -1:
			_hub.send(conn, { "type": "error", "error": "unknown match or token" })
			return
		conn["match_id"] = id
		conn["team"] = team
		conn["token"] = m["tokens"][team]
		var state: Dictionary = _get_match(id, conn["token"])["body"]
		state["type"] = "state"
		_hub.send(conn, state)
		_push_presence(id)
		return
	if int(conn["team"]) == -1:
		_hub.send(conn, { "type": "error", "error": "say hello first" })
		return
	match type:
		"submit":
			var plan: Variant = msg.get("plan", {})
			var res := _submit(conn["match_id"], { "token": conn["token"], "turn": msg.get("turn"), "plan": plan })
			var ack := { "type": "submit_ack", "turn": msg.get("turn"), "status": res["body"].get("status", "error") }
			if int(res["status"]) != 200:
				ack["error"] = res["body"].get("error", "?")
				ack["code"] = res["status"]
			_hub.send(conn, ack)
		"forfeit":
			_forfeit(conn["match_id"], conn["token"])
		_:
			_hub.send(conn, { "type": "error", "error": "unknown message type '%s'" % type })


func _on_live_close(conn: Dictionary) -> void:
	if conn["match_id"] != "":
		_push_presence(conn["match_id"])


## Tells both players who is connected (for the "opponent reconnecting" UI).
func _push_presence(match_id: String) -> void:
	var connected := _hub.presence(match_id)
	for team in 2:
		_hub.send_to(match_id, team, { "type": "presence", "connected": connected })


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
