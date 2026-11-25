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
##   TT_STORE             persistence backend: json (default) | dir | postgrest | mongo (GameStore)
##   TT_DATA_FILE         json store file (default user://matches.json)
##   TT_DATA_DIR          dir store root (default user://store)
##   TT_DB_URL            postgrest store base URL, e.g. http://postgrest:3000
##   TT_DB_TOKEN          optional PostgREST JWT
##   TT_MONGO_GATEWAY_URL mongo store: the gateway (deploy/mongo-gateway), e.g. http://127.0.0.1:8090
##   TT_MONGO_GATEWAY_TOKEN  mongo store: the gateway's shared secret
##   TT_PASSWORD_ITERATIONS  PBKDF2 iterations for new email-account passwords (default 60000)
##   TT_AUTH0_DOMAIN      Auth0 tenant (e.g. your-tenant.us.auth0.com): email sign-in goes through Auth0
##   TT_AUTH0_CLIENT_ID / TT_AUTH0_CLIENT_SECRET   the Auth0 application (Password grant enabled)
##   TT_AUTH0_CONNECTION  Auth0 database connection (default Username-Password-Authentication)
##   TT_ENV_FILE          settings file read at startup when run as server.tscn (default deploy/.env);
##                        real environment variables win over the file
##   TT_MATCH_RETENTION_SEC  finished matches stay in memory this long (default 24h)
##   TT_TRUST_PROXY       1 = use X-Forwarded-For for rate limits (behind Caddy)
##   TT_ADMIN_KEY         enables /admin endpoints (at least 24 characters)
##
## Credentials (match tokens, account secrets, the admin key) travel in the
## JSON body or as "Authorization: Bearer <value>", never in the URL.
##
## Endpoints:
##   GET  /health                                     -> {ok, protocol, min_protocol, server_time, live_url, season}
##   POST /match/create      {squad, mode?}           -> {match_id, team, token}
##   POST /match/{id}/join   {squad}                  -> {status, team, token, mode}
##   POST /match/{id}/submit {token, turn, plan}
##   GET  /match/{id}[?since=<turn>]   (Bearer token) -> public info; with a player token also the fogged view + history
##   POST /account/matches   {player_id, secret}      -> {matches: [{match_id, team, token, mode, turn}]}  (resume after a restart)
##
## Accounts, matchmaking, and rating:
##   POST /account/register  {name}                   -> {player_id, secret, name, rating}   (guest: lives on one device)
##   POST /account/signup    {email, password, name, player_id?, secret?} -> session (below)
##        with a guest's player_id + secret, the guest account gets the email and keeps its progress
##   POST /account/login     {email, password}        -> session: {player_id, secret, name, email, rating, trophies}
##   POST /account/logout    {player_id, secret}      ends this device's session (email accounts)
##   POST /account/profile   {player_id, secret}      -> private profile: ranks, stats, favorite move, match history
##   POST /account/password_reset {email}             Auth0 emails a reset link (Auth0 only)
##   GET  /account/{id}                               -> {name, rating, wins, losses}
##   GET  /leaderboard                                -> {players: [...top 20 by trophies]}
##   POST /queue             {player_id, secret, squad, mode} -> ticket view (below)
##   GET  /queue/{ticket}    (Bearer secret)          -> ticket view; also the ticket's heartbeat
##   POST /queue/{ticket}/accept {secret}             -> confirm a found match (ready check)
##   POST /queue/{ticket}/cancel {secret}
##   ticket view: {ticket, status, mode, wait_sec, searching, estimated_wait,
##                 accept_sec_left (found), match_id/team/token/live_url (matched)}
##
## Matchmaking (Matchmaker): a ticket goes queued -> found -> matched.
##   - Tickets must be polled (QUEUE_HEARTBEAT): one not seen for
##     TICKET_STALE_SEC is skipped by the matchmaker, and expires after
##     TICKET_EXPIRE_SEC (a closed tab never gets matched).
##   - Every MATCHMAKER_INTERVAL the matchmaker scores every acceptable pair
##     (Glicko-2 win probability incl. both players' uncertainty; the accepted
##     unfairness widens with waiting) and takes the best pairs first.
##   - A found pair must both accept within ACCEPT_SEC (clients do it
##     automatically, proving they are still there). If one doesn't, the
##     other goes back into the queue keeping its place, and the no-show's
##     ticket expires.
## Finished ranked matches update both players' Glicko-2 ratings.
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
## Email accounts: with Auth0 configured (TT_AUTH0_*), Auth0 holds the
## passwords: sign-up, sign-in, verification and reset emails go through it
## (Auth0Client) and an account is linked to its Auth0 user id (`auth0_sub`).
## Without Auth0 (local development, tests), passwords are stored here as
## PBKDF2 hashes (PasswordHash), computed on WorkerThreadPool so a login never
## stalls the match clocks. Either way the HTTP answer is deferred until done. Each signed-in device gets
## its own session secret (up to SESSIONS_MAX). Emails are never shown to
## other players.
##
## Profiles: every finished match with an account in a seat (ranked, or a
## friendly room created / joined with player_id + secret) is added to that
## account's history (last HISTORY_MAX), totals, streaks, and per-action usage
## (favorite move; auto-filled turns don't count).
##
## Each player receives a secret token on create/join. Submissions are
## attributed to a team by token only, and GET returns only what that team
## may know (Visibility): its own units, enemies in sight, radar pings for
## the rest, and per-tick replay frames filtered the same way. The opponent's
## plans, the match seed (it drives every hit roll), and the full match state
## never leave the server.

const DEFAULT_PORT := 8080
const DEFAULT_TURN_TIMEOUT_SEC := 12 * 60 * 60  # auto-fill deadline (GDD 3.1)
const DEFAULT_DATA_FILE := "user://matches.json"
const MATCHMAKER_INTERVAL := 1.0
const PRUNE_INTERVAL := 60.0
## Matched / cancelled tickets are dropped this long after queueing.
const TICKET_TTL_SEC := 60 * 60
## Hosted matches nobody joined are dropped after this long.
const UNJOINED_TTL_SEC := 24 * 60 * 60
const DEFAULT_MATCH_RETENTION_SEC := 24 * 60 * 60

## Set false before adding to the tree to disable persistence (tests).
var persist := true
## Persistence backend; null = chosen from the environment (GameStore.from_env).
## Set before adding to the tree to inject one (tests).
var store: GameStore = null
## Finished matches are kept in memory (for GET / replays) this long, then
## evicted; they stay in the store.
var match_retention_sec := DEFAULT_MATCH_RETENTION_SEC
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
## Tests only: >= 0 makes every new match use this seed (reproducible rolls).
var fixed_seed := -1
var data_file := DEFAULT_DATA_FILE
## Required for /admin endpoints (TT_ADMIN_KEY); empty disables them.
var admin_key := ""

const START_RATING := 1000
## Queue liveness (see the header): clients poll their ticket every second.
const TICKET_STALE_SEC := 6.0
const TICKET_EXPIRE_SEC := 20.0
## Time both players have to confirm a found match.
const ACCEPT_SEC := 10.0
## Weight of the newest sample in the per-mode average wait (estimated_wait).
const WAIT_EWMA := 0.3
const NAME_MAX := NameRules.PLAYER_NAME_MAX
## Correspondence matches end by tiebreak after this many turns, so a match
## (and its stored history) can't grow without bound.
const ASYNC_MAX_TURNS := 40
const MIN_ADMIN_KEY_LENGTH := 24

# Per-client abuse limits: [max events, window seconds]. Loopback is exempt
# (local dev, tests). Mobile carriers put many players behind one address,
# so these are generous; they stop scripts, not people.
const LIMIT_REGISTER := [20, 3600]
const LIMIT_CREATE := [60, 3600]
const LIMIT_AUTH_FAIL := [30, 300]
## Unjoined hosted matches kept at once (memory bound for /match/create).
const MAX_OPEN_MATCHES := 5000
## Matches kept in each account's history (newest first).
const HISTORY_MAX := 50
## Signed-in devices per email account; the oldest session ends beyond this.
const SESSIONS_MAX := 10
## Password hashes being computed at once; more gets 503 (CPU bound).
const MAX_HASH_JOBS := 4
## Auth0 requests in flight at once; more gets 503.
const MAX_AUTH_JOBS := 16
const LIMIT_RESET := [10, 3600]
const EMAIL_MAX := 254
## Plan actions that say nothing about a player's style (favorite move).
const PLAIN_ACTIONS: Array[String] = ["Move", "Wait"]

var _http := HttpServer.new()
var _hub := LiveHub.new()
var _matches: Dictionary = {}     # id -> match dict
var _accounts: Dictionary = {}    # player_id -> {id, name, secret, rating, trophies, best_trophies, wins, losses, draws}
## ticket -> {ticket, player_id, status, mode, squad, queued_at, last_seen,
##            partner, seat, found_at, accepted, match_id, team, token}
var _tickets: Dictionary = {}
## mode -> average seconds from queueing to a confirmed match.
var _avg_wait: Dictionary = {}
var _season := 1
var _mm_timer := 0.0
var _prune_timer := 0.0
## Records changed since the last flush: kind -> {id: true (write) / false (delete)}.
var _dirty := { "accounts": {}, "tickets": {}, "matches": {}, "meta": {} }
var _crypto := Crypto.new()
var _limits: Dictionary = {}      # "bucket|ip" -> {count, reset_at}
var _email_index: Dictionary = {} # lowercase email -> player_id
## Password hashes running on WorkerThreadPool: {task, out, done, reply}.
var _hash_jobs: Array = []
## PBKDF2 iterations for new passwords (TT_PASSWORD_ITERATIONS; tests lower it).
var password_iterations := PasswordHash.DEFAULT_ITERATIONS
## Auth0 (TT_AUTH0_*; tests set these before adding the server). Empty
## domain = local passwords.
var auth0_domain := ""
var auth0_client_id := ""
var auth0_client_secret := ""
var auth0_connection := ""
## server.tscn sets this: read TT_ENV_FILE / deploy/.env before starting.
@export var load_env_file := false
var _auth0 := Auth0Client.new()
var _auth_jobs := 0
var _sub_index: Dictionary = {}   # Auth0 user id -> player_id


func _ready() -> void:
	if load_env_file:
		var path := OS.get_environment("TT_ENV_FILE")
		if path == "":
			path = ProjectSettings.globalize_path("res://deploy/.env")
		var n := MatchServer.load_env(path)
		if n >= 0:
			print("Loaded %d setting(s) from %s" % [n, path])
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
	if admin_key != "" and admin_key.length() < MIN_ADMIN_KEY_LENGTH:
		push_warning("TT_ADMIN_KEY is shorter than %d characters: /admin endpoints stay disabled." % MIN_ADMIN_KEY_LENGTH)
		admin_key = ""
	if OS.get_environment("TT_MATCH_RETENTION_SEC") != "":
		match_retention_sec = int(OS.get_environment("TT_MATCH_RETENTION_SEC"))
	_http.trust_proxy = OS.get_environment("TT_TRUST_PROXY") == "1"
	var iter_env := OS.get_environment("TT_PASSWORD_ITERATIONS")
	if iter_env.is_valid_int():
		password_iterations = maxi(PasswordHash.MIN_ITERATIONS, int(iter_env))
	if auth0_domain == "":
		auth0_domain = OS.get_environment("TT_AUTH0_DOMAIN")
		auth0_client_id = OS.get_environment("TT_AUTH0_CLIENT_ID")
		auth0_client_secret = OS.get_environment("TT_AUTH0_CLIENT_SECRET")
		auth0_connection = OS.get_environment("TT_AUTH0_CONNECTION")
	_auth0.configure(auth0_domain, auth0_client_id, auth0_client_secret, auth0_connection)
	_auth0.name = "Auth0"
	add_child(_auth0)
	if auth0_domain != "" and not _auth0.enabled():
		push_warning("TT_AUTH0_DOMAIN is set but the client id / secret are missing: using local passwords.")
	if persist:
		if store == null:
			store = GameStore.from_env(data_file)
		if not await _open_store():
			# Refuse to serve players without working persistence.
			push_error("Store %s unavailable; shutting down." % store.describe())
			get_tree().quit(1)
			return
	var ok := _http.start(port, _handle_request)
	var live_ok := _hub.start(live_port, _on_live_message, _on_live_close)
	print("Trion Tactics server listening on :%d (start=%s), live :%d (start=%s), turn timeout %ds, store %s, sign-in %s, %d matches / %d accounts loaded" % [
		port, ok, live_port, live_ok, turn_timeout_sec, store.describe() if store != null else "none",
		"Auth0 (%s)" % _auth0.base_url() if _auth0.enabled() else "local passwords",
		_matches.size(), _accounts.size()])


## Reads KEY=VALUE lines (# comments, optional quotes) from `path` into the
## environment, skipping keys that are already set. Returns how many were
## set, or -1 if there is no such file.
static func load_env(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var n := 0
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line := raw.strip_edges()
		if line == "" or line.begins_with("#") or not line.contains("="):
			continue
		if line.begins_with("export "):
			line = line.substr(7).strip_edges()
		var key := line.get_slice("=", 0).strip_edges()
		var value := line.substr(line.find("=") + 1).strip_edges()
		if value.length() >= 2 and ((value.begins_with("\"") and value.ends_with("\""))
				or (value.begins_with("'") and value.ends_with("'"))):
			value = value.substr(1, value.length() - 2)
		if key == "" or not key.is_valid_identifier() or OS.has_environment(key):
			continue
		OS.set_environment(key, value)
		n += 1
	return n


func _exit_tree() -> void:
	# Worker tasks must be waited on; their answers go nowhere now.
	for job in _hash_jobs:
		WorkerThreadPool.wait_for_task_completion(job["task"])
	_hash_jobs.clear()
	_save()
	_hub.stop()
	_http.stop()


func _process(delta: float) -> void:
	_poll_hash_jobs()
	_http.poll()
	_hub.poll()
	_check_timeouts()
	_mm_timer += delta
	if _mm_timer >= MATCHMAKER_INTERVAL:
		_mm_timer = 0.0
		if _run_matchmaker() > 0:
			_save()
	_prune_timer += delta
	if _prune_timer >= PRUNE_INTERVAL:
		_prune_timer = 0.0
		_prune()


func _handle_request(method: String, path: String, body: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var ip := str(ctx.get("ip", ""))
	var bearer := str(ctx.get("bearer", ""))
	if method == "GET" and path == "/health":
		var health := { "ok": true, "protocol": NetProtocol.VERSION, "min_protocol": NetProtocol.MIN_SUPPORTED,
			"server_time": Time.get_unix_time_from_system(), "season": _season,
			"auth": "auth0" if _auth0.enabled() else "local" }
		if public_live_url != "":
			health["live_url"] = public_live_url
		return _ok(health)
	if _limited(ip, "auth_fail", LIMIT_AUTH_FAIL, false):
		return _err(429, "too many failed attempts; try again later")
	var res := _dispatch(method, path, body, ip, bearer)
	if int(res["status"]) == 403:
		_limited(ip, "auth_fail", LIMIT_AUTH_FAIL)
	return res


func _dispatch(method: String, path: String, body: Dictionary, ip: String, bearer: String) -> Dictionary:
	if method == "POST" and path == "/match/create":
		if _limited(ip, "create", LIMIT_CREATE):
			return _err(429, "too many matches created; try again later")
		return _create_match(_with_cred(body, "secret", bearer))
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/join"):
		return _join_match(_path_id(path), _with_cred(body, "secret", bearer))
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/submit"):
		return _submit(_path_id(path), _with_cred(body, "token", bearer))
	if method == "POST" and path.begins_with("/match/") and path.ends_with("/forfeit"):
		return _forfeit(_path_id(path), _cred(body, "token", bearer))
	if method == "GET" and path.begins_with("/match/") and path.split("/", false).size() == 2:
		return _get_match(_path_id(path), _cred(body, "token", bearer), _int(body.get("since"), 0))
	if method == "POST" and path == "/account/register":
		if _limited(ip, "register", LIMIT_REGISTER):
			return _err(429, "too many accounts created; try again later")
		return _register(body)
	if method == "POST" and path == "/account/signup":
		if _limited(ip, "register", LIMIT_REGISTER):
			return _err(429, "too many accounts created; try again later")
		return _signup(_with_cred(body, "secret", bearer), ip)
	if method == "POST" and path == "/account/login":
		return _login(body, ip)
	if method == "POST" and path == "/account/password_reset":
		if _limited(ip, "reset", LIMIT_RESET):
			return _err(429, "too many requests; try again later")
		return _password_reset(body)
	if method == "POST" and path == "/account/logout":
		return _logout(_with_cred(body, "secret", bearer))
	if method == "POST" and path == "/account/profile":
		return _profile(_with_cred(body, "secret", bearer))
	if method == "POST" and path == "/account/delete":
		return _delete_account(_with_cred(body, "secret", bearer))
	if method == "POST" and path == "/account/matches":
		return _account_matches(_with_cred(body, "secret", bearer))
	if method == "POST" and path == "/admin/season/reset":
		return _season_reset(_with_cred(body, "admin_key", bearer))
	if method == "GET" and path.begins_with("/account/"):
		return _get_account(_path_id(path))
	if method == "GET" and path == "/leaderboard":
		return _leaderboard()
	if method == "POST" and path == "/queue":
		return _enqueue(_with_cred(body, "secret", bearer))
	if method == "POST" and path.begins_with("/queue/") and path.ends_with("/cancel"):
		return _cancel_ticket(_path_id(path), _cred(body, "secret", bearer))
	if method == "POST" and path.begins_with("/queue/") and path.ends_with("/accept"):
		return _accept_ticket(_path_id(path), _cred(body, "secret", bearer))
	if method == "GET" and path.begins_with("/queue/"):
		return _poll_ticket(_path_id(path), _cred(body, "secret", bearer))
	return _err(404, "not found")


## A credential from the JSON body, or else the Authorization bearer token.
func _cred(body: Dictionary, key: String, bearer: String) -> String:
	var v: Variant = body.get(key)
	if v is String and v != "":
		return v
	return bearer


func _with_cred(body: Dictionary, key: String, bearer: String) -> Dictionary:
	body[key] = _cred(body, key, bearer)
	return body


## Counts an event for (bucket, client) and reports whether the client is
## over `limit` ([max, window seconds]). With `count` false it only checks.
func _limited(ip: String, bucket: String, limit: Array, count := true) -> bool:
	if ip == "" or HttpServer.is_loopback(ip):
		return false
	var now := Time.get_unix_time_from_system()
	var key := "%s|%s" % [bucket, ip]
	var e: Dictionary = _limits.get(key, {})
	if e.is_empty() or now >= float(e["reset_at"]):
		e = { "count": 0, "reset_at": now + float(limit[1]) }
	if count:
		e["count"] = int(e["count"]) + 1
		_limits[key] = e
		return int(e["count"]) > int(limit[0])
	return int(e["count"]) >= int(limit[0])


## Request fields are untrusted JSON: anything but a number becomes `fallback`
## (int() on an Array or Dictionary is a script error).
static func _int(v: Variant, fallback: int) -> int:
	if typeof(v) == TYPE_INT:
		return v
	if typeof(v) == TYPE_FLOAT:
		return int(v) if is_finite(v) and absf(v) < 9.0e15 else fallback
	if v is String and (v as String).is_valid_int():
		return int(v)
	return fallback


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
	var open_matches := 0
	for other in _matches.values():
		if other["ms"] == null:
			open_matches += 1
	if open_matches >= MAX_OPEN_MATCHES:
		return _err(503, "server is busy; try again later")
	# Friendly battles may opt into the live clock; they never affect rating.
	var mode := "live" if str(body.get("mode", "async")) == "live" else "async"
	# The seed is always the server's: a player who knew it could predict
	# every hit roll. (`fixed_seed` is a test hook.)
	var m := _new_match(squad, fixed_seed if fixed_seed >= 0 else _new_seed(), false, mode)
	_attach_player(m, 0, body)
	_save()
	return _ok({ "match_id": m["id"], "team": 0, "token": m["tokens"][0] })


## Friendly rooms are anonymous unless the player sends their account
## (player_id + secret): then the match goes into that account's profile.
## Wrong credentials just leave the seat anonymous.
func _attach_player(m: Dictionary, seat: int, body: Dictionary) -> void:
	var pid := str(body.get("player_id", ""))
	if pid == "" or not _authed(pid, str(body.get("secret", ""))):
		return
	if (m["players"] as Array).has(pid):
		return   # playing yourself counts for nobody
	m["players"][seat] = pid
	_touch("matches", m["id"])


## Creates a match with team 0's (validated, encoded) squad. `mode` is
## "async" (long turn timer, no cap) or "live" (Ladder clock, turn cap).
func _new_match(squad: Array, seed: int, ranked := false, mode := "async") -> Dictionary:
	var id := _new_id()
	var m := {
		"id": id,
		"seed": seed,
		"mode": mode,
		"max_turns": Ladder.LIVE_MAX_TURNS if mode == "live" else ASYNC_MAX_TURNS,
		"radar_key": _new_secret_int(),
		# The play area: a random part of the city (public, unlike the seed).
		"map": MapData.random_section(_new_seed()),
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
		"created_at": Time.get_unix_time_from_system(),
		"ended_at": 0.0,
		"history": [],
	}
	_matches[id] = m
	_touch("matches", id)
	return m


## Seats team 1 and starts the match. Returns team 1's token.
func _seat_second(m: Dictionary, squad: Array) -> String:
	var token := _new_token()
	m["teams"][1] = PlanCodec.decode_squad(squad)
	m["tokens"][1] = token
	m["ms"] = MatchRunner.build_match(m["teams"][0], m["teams"][1], m["seed"], m.get("map", Rect2i()))
	_start_turn_clock(m, Ladder.LIVE_LOAD_GRACE_SEC)
	return token


## Starts the planning clock for the match's current turn. Live matches get
## Ladder's short planning window (plus `extra` for loading / replay time).
func _start_turn_clock(m: Dictionary, extra := 0.0) -> void:
	_touch("matches", m["id"])
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
	_attach_player(m, 1, body)
	_save()
	return _ok({ "status": "ready", "team": 1, "token": token, "mode": m["mode"] })


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
	# The turn is mandatory: a delayed or replayed request must never count
	# as the plan for a later turn.
	if _int(body.get("turn"), -1) != int(m["turn"]):
		return _err(409, "stale turn (server is on turn %d)" % int(m["turn"]))
	if bool(m["submitted"][team]):
		return _ok({ "status": "pending" })
	var plan_dict: Variant = body.get("plan", {})
	if not (plan_dict is Dictionary):
		return _err(400, "plan required")
	var ms_now: MatchState = m["ms"]
	var decoded := PlanCodec.decode_plan_checked(plan_dict, m["teams"][team], ms_now, ms_now.teams[team])
	if str(decoded["error"]) != "":
		return _err(400, "invalid plan: %s" % decoded["error"])
	m["plans"][team] = decoded["plan"]
	m["submitted"][team] = true
	m["missed"][team] = 0
	_touch("matches", m["id"])
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
func _get_match(id: String, token: String, since := 0) -> Dictionary:
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return _err(404, "match not found")
	var body := {
		"id": id,
		"mode": m.get("mode", "async"),
		"turn": m["turn"],
		"max_turns": m.get("max_turns", 0),
		"map": _map_array(m),
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
	body["teams"] = [
		PlanCodec.encode_squad(m["teams"][0]) if m["teams"][0] != null else null,
		PlanCodec.encode_squad(m["teams"][1]) if m["teams"][1] != null else null,
	]
	if m["ms"] != null:
		body["view"] = Visibility.encode_view(m["ms"], team, _view_salt(m, int(m["turn"])), true)
	# `since` lets a polling client fetch only the turns it has not replayed.
	var history: Array = []
	for entry in m["history"]:
		if int(entry["turn"]) >= since:
			history.append(_filter_entry(entry, team))
	body["history"] = history
	body["result"] = _result_for(m, team)
	return _ok(body)


# --- Resolution -------------------------------------------------------------

## Resolves the turn in continuous time (TurnEngine), recording a
## fog-filtered replay frame for each team every FRAME_SECONDS. `auto` marks
## the teams whose plan the server filled in (they missed the deadline).
func _resolve_turn(m: Dictionary, auto: Array = [false, false]) -> void:
	_touch("matches", m["id"])
	var ms: MatchState = m["ms"]
	var turn := int(m["turn"])
	var frames := MatchRunner.record_turn(ms, m["plans"][0], m["plans"][1],
		func(frame: int) -> int: return _radar_salt(m, turn * 1000 + frame))
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
		# Server-side only (never sent): keeps auto-filled turns out of the
		# players' move statistics.
		"auto": [bool(auto[0]), bool(auto[1])],
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
	m["ended_at"] = Time.get_unix_time_from_system()
	_touch("matches", m["id"])
	if m.get("ranked", false):
		_apply_rating(m, winner)
		if m.get("mode", "async") == "live":
			_apply_trophies(m, winner)
	_record_history(m, winner, reason)
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


## Radar salt for the planning-phase view.
func _view_salt(m: Dictionary, turn: int) -> int:
	# The same salt as the turn's first replay frame (frame 0 of turn * 1000).
	return _radar_salt(m, turn * 1000)


## Radar pings are offset pseudo-randomly from an unseen enemy's true hex.
## The offset is keyed with a per-match secret: with a guessable salt a
## client could run the same generator and undo the offset.
func _radar_salt(m: Dictionary, step: int) -> int:
	var digest := ("%d:%d" % [int(m.get("radar_key", 0)), step]).sha256_buffer()
	return digest.decode_s64(0) & 0xFFFFFFFFFF


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
		var auto := [false, false]
		for team in 2:
			if not bool(m["submitted"][team]):
				m["plans"][team] = MatchRunner.build_fallback_plan(m["teams"][team])
				m["submitted"][team] = true
				m["missed"][team] = int(m["missed"][team]) + 1
				auto[team] = true
		_resolve_turn(m, auto)
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
# Live state lives in memory; the store (GameStore) gets only the records that
# changed. Mutations call _touch()/_drop(); _save() hands those records to the
# store and flushes.

func _touch(kind: String, id: String) -> void:
	if persist:
		_dirty[kind][id] = true


func _drop(kind: String, id: String) -> void:
	if persist:
		_dirty[kind][id] = false


## Writes changed records to the store.
func _save() -> void:
	if store == null:
		return
	for kind in _dirty:
		for id in _dirty[kind]:
			if not _dirty[kind][id]:
				store.remove(kind, id)
				continue
			# Only _drop() deletes: a record that is no longer in memory was
			# evicted (see _prune), not deleted.
			var record := _record(kind, id)
			if not record.is_empty():
				store.put(kind, id, record)
		_dirty[kind].clear()
	store.flush()


## The JSON-ready record for (kind, id), or {} if it no longer exists.
func _record(kind: String, id: String) -> Dictionary:
	match kind:
		"matches":
			return _serialize(_matches[id]) if _matches.has(id) else {}
		"accounts":
			return _accounts.get(id, {})
		"tickets":
			return _tickets.get(id, {})
		"meta":
			return { "season": _season } if id == "server" else {}
	return {}


## Adds the store to the tree, opens it, and loads every record into memory.
func _open_store() -> bool:
	if store.get_parent() == null:
		add_child(store)
	if not await store.open():
		return false
	var cutoff := Time.get_unix_time_from_system() - match_retention_sec
	var data: Dictionary = await store.load_all(cutoff)
	for id in data.get("matches", {}):
		var d: Dictionary = data["matches"][id]
		if int(d.get("winner", -1)) != -1 and float(d.get("ended_at", 0.0)) < cutoff:
			continue
		# One unreadable record must not keep the whole server from starting.
		var loaded: Variant = _deserialize(d) if _record_ok(d) else null
		if not (loaded is Dictionary):
			push_warning("Skipping unreadable match record %s" % str(id))
			continue
		_matches[id] = loaded
		# Live clocks kept running while the server was down: give both
		# players a fresh turn instead of timing everyone out at once.
		if int(loaded["winner"]) == -1 and loaded["ms"] != null and loaded["mode"] == "live":
			_start_turn_clock(loaded, Ladder.LIVE_LOAD_GRACE_SEC)
	for id in data.get("accounts", {}):
		if not (data["accounts"][id] is Dictionary):
			continue
		var had_plain_secret: bool = data["accounts"][id].has("secret")
		_accounts[id] = _normalize_account(data["accounts"][id])
		_accounts[id]["id"] = str(id)
		if had_plain_secret:
			_touch("accounts", id)   # rewrite it hashed
		var email := str(_accounts[id]["email"])
		if email != "":
			if _email_index.has(email):
				push_warning("Email used by two accounts (%s, %s); keeping the first" % [_email_index[email], id])
			else:
				_email_index[email] = str(id)
		var sub := str(_accounts[id]["auth0_sub"])
		if sub != "":
			_sub_index[sub] = str(id)
	var now := Time.get_unix_time_from_system()
	for id in data.get("tickets", {}):
		var ticket: Dictionary = data["tickets"][id]
		ticket["team"] = int(ticket.get("team", -1))
		ticket["mode"] = str(ticket.get("mode", "async"))
		ticket["queued_at"] = float(ticket.get("queued_at", now))
		ticket["seat"] = int(ticket.get("seat", -1))
		ticket["accepted"] = bool(ticket.get("accepted", false))
		ticket["partner"] = str(ticket.get("partner", ""))
		ticket["found_at"] = float(ticket.get("found_at", 0.0))
		# Searches that were open during the restart: give their clients a
		# fresh heartbeat window, and re-run any unconfirmed pairing.
		if ticket["status"] == "queued" or ticket["status"] == "found":
			ticket["status"] = "queued"
			ticket["partner"] = ""
			ticket["accepted"] = false
			ticket["last_seen"] = now
		_tickets[id] = ticket
	_season = int(data.get("meta", {}).get("server", {}).get("season", 1))
	_save()
	return true


## Minimal shape check for a stored match before _deserialize touches it.
func _record_ok(d: Dictionary) -> bool:
	for key in ["id", "seed", "turn", "squads", "tokens", "plans", "submitted", "turn_started", "winner", "history"]:
		if not d.has(key):
			return false
	for key in ["squads", "tokens", "plans", "submitted"]:
		if not (d[key] is Array) or (d[key] as Array).size() != 2:
			return false
	return d["squads"][0] is Array and d["history"] is Array


## Keeps memory bounded: drops old tickets (from the store too), hosted
## matches nobody joined, and finished matches past the retention window
## (those stay in the store as history).
func _prune() -> void:
	_save()   # write anything pending before evicting it from memory
	var now := Time.get_unix_time_from_system()
	for id in _tickets.keys():
		var t: Dictionary = _tickets[id]
		if not (t["status"] in ["queued", "found"]) and now - float(t["queued_at"]) > TICKET_TTL_SEC:
			_tickets.erase(id)
			_drop("tickets", id)
	for id in _matches.keys():
		var m: Dictionary = _matches[id]
		if m["ms"] == null and now - float(m.get("created_at", now)) > UNJOINED_TTL_SEC:
			_matches.erase(id)
			_drop("matches", id)
		elif int(m["winner"]) != -1 and now - float(m.get("ended_at", now)) > match_retention_sec:
			_matches.erase(id)
	_save()


## Fills fields that older stores lack and fixes JSON number types.
func _normalize_account(a: Dictionary) -> Dictionary:
	# Secrets are stored hashed; older stores kept them in the clear.
	if a.has("secret"):
		a["secret_hash"] = _hash_secret(str(a["secret"]))
		a.erase("secret")
	a["secret_hash"] = str(a.get("secret_hash", ""))
	a["name"] = str(a.get("name", "Player"))
	# Glicko-2 skill (Matchmaker). Accounts from the Elo era keep their
	# rating but start fully uncertain, so it settles again quickly.
	a["rating"] = float(a.get("rating", START_RATING))
	a["rd"] = float(a.get("rd", Matchmaker.START_RD))
	a["volatility"] = float(a.get("volatility", Matchmaker.START_VOLATILITY))
	a["rated_at"] = float(a.get("rated_at", 0.0))
	a["last_opponent"] = str(a.get("last_opponent", ""))
	a["trophies"] = int(a.get("trophies", 0))
	a["best_trophies"] = maxi(int(a.get("best_trophies", 0)), int(a["trophies"]))
	a["wins"] = int(a.get("wins", 0))
	a["losses"] = int(a.get("losses", 0))
	a["draws"] = int(a.get("draws", 0))
	a["best_rating"] = maxf(float(a.get("best_rating", 0.0)), float(a["rating"]))
	a["created_at"] = float(a.get("created_at", 0.0))
	# Email sign-in (guests have neither). Sessions are hashed secrets, one
	# per signed-in device.
	a["email"] = str(a.get("email", ""))
	a["password_hash"] = str(a.get("password_hash", ""))
	a["auth0_sub"] = str(a.get("auth0_sub", ""))
	a["email_verified"] = bool(a.get("email_verified", false))
	var sessions: Array = []
	for s in (a.get("sessions", []) if a.get("sessions") is Array else []):
		sessions.append(str(s))
	a["sessions"] = sessions
	# Profile. Wins / losses / draws above are ranked only (the ladder);
	# `stats` counts every recorded match. Accounts from before profiles
	# start from their ranked record.
	var st: Dictionary = a.get("stats") if a.get("stats") is Dictionary else {
		"played": a["wins"] + a["losses"] + a["draws"],
		"wins": a["wins"], "losses": a["losses"], "draws": a["draws"] }
	for key in ["played", "wins", "losses", "draws", "streak", "best_streak"]:
		st[key] = int(st.get(key, 0))
	a["stats"] = st
	var moves := {}
	if a.get("move_counts") is Dictionary:
		for card in a["move_counts"]:
			moves[str(card)] = int(a["move_counts"][card])
	a["move_counts"] = moves
	a["history"] = (a["history"] as Array).filter(func(e: Variant) -> bool: return e is Dictionary) \
		if a.get("history") is Array else []
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
		# 64-bit: as a string so JSON doubles can't round it.
		"radar_key": str(m.get("radar_key", 0)),
		"map": _map_array(m),
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
		"created_at": m.get("created_at", 0.0),
		"ended_at": m.get("ended_at", 0.0),
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
		ms = MatchRunner.build_match(teams[0], teams[1], seed, MapData.section_from(d.get("map")))
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
		"radar_key": str(d["radar_key"]).to_int() if d.has("radar_key") else _new_secret_int(),
		# Older records were played on the whole city.
		"map": MapData.section_from(d.get("map")),
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
		"created_at": float(d.get("created_at", 0.0)),
		"ended_at": float(d.get("ended_at", 0.0)),
		"players": [str(d.get("players", ["", ""])[0]), str(d.get("players", ["", ""])[1])],
		"ranked": bool(d.get("ranked", false)),
		"rating_change": [int(d.get("rating_change", [0, 0])[0]), int(d.get("rating_change", [0, 0])[1])],
		"trophy_change": [int(d.get("trophy_change", [0, 0])[0]), int(d.get("trophy_change", [0, 0])[1])],
		"history": d["history"],
	}


# --- Accounts, Matchmaking, Rating -----------------------------------------

## A display name from a request: {name} or {error}.
static func _check_name(raw: Variant) -> Dictionary:
	if not (raw is String):
		return { "error": "name must be text" }
	var player_name := NameRules.clean(raw)
	if player_name == "" or player_name.length() > NAME_MAX:
		return { "error": "name must be 1-%d characters" % NAME_MAX }
	if not NameRules.is_allowed(player_name):
		return { "error": "that name is not allowed" }
	return { "name": player_name }


func _register(body: Dictionary) -> Dictionary:
	var checked := _check_name(body.get("name", ""))
	if checked.has("error"):
		return _err(400, checked["error"])
	var player_name: String = checked["name"]
	var id := _new_id()
	var secret := _new_token()
	_accounts[id] = _normalize_account({ "id": id, "name": player_name, "secret_hash": _hash_secret(secret),
		"created_at": Time.get_unix_time_from_system() })
	_touch("accounts", id)
	_save()
	var a: Dictionary = _accounts[id]
	# The only time the secret is ever sent; the server keeps just its hash.
	return _ok({ "player_id": id, "secret": secret, "name": player_name, "rating": roundi(float(a["rating"])),
		"trophies": a["trophies"] })


# --- Email accounts -----------------------------------------------------------

## A normalized email address, or "" if `raw` isn't a plausible one.
static func _clean_email(raw: Variant) -> String:
	if not (raw is String):
		return ""
	var email := (raw as String).strip_edges().to_lower()
	if email.length() < 3 or email.length() > EMAIL_MAX:
		return ""
	var at := email.find("@")
	if at < 1 or at != email.rfind("@") or at == email.length() - 1:
		return ""
	var domain := email.substr(at + 1)
	if not domain.contains(".") or domain.begins_with(".") or domain.ends_with(".") or domain.contains(".."):
		return ""
	for c in email:
		if c.unicode_at(0) <= 32 or c in ["<", ">", "(", ")", "[", "]", ",", ";", ":", "\\", "\""]:
			return ""
	return email


## Creates an email account, or gives the email to the caller's guest account
## (player_id + secret) so its trophies and history carry over.
func _signup(body: Dictionary, ip := "") -> Dictionary:
	var email := _clean_email(body.get("email"))
	if email == "":
		return _err(400, "enter a valid email address")
	var password: Variant = body.get("password")
	if not (password is String):
		return _err(400, "password must be text")
	var weak := PasswordHash.check_strength(password)
	if weak != "":
		return _err(400, weak)
	# With Auth0, an email held by a pre-Auth0 (local password) account may
	# still sign up there; the account moves over once the email is verified.
	var holder: Dictionary = _accounts.get(_email_index.get(email, ""), {})
	if not holder.is_empty() and not (_auth0.enabled() and str(holder["auth0_sub"]) == ""):
		return _err(409, "an account with this email already exists; sign in instead")
	var pid := str(body.get("player_id", ""))
	var guest_secret := str(body.get("secret", ""))
	var upgrade := pid != ""
	if upgrade:
		if not _authed(pid, guest_secret):
			return _err(403, "invalid player credentials")
		if str(_accounts[pid]["email"]) != "":
			return _err(409, "this account already has an email")
	var player_name := ""
	var raw_name: Variant = body.get("name", "")
	if not upgrade or (raw_name is String and (raw_name as String).strip_edges() != ""):
		var checked := _check_name(raw_name)
		if checked.has("error"):
			return _err(400, checked["error"])
		player_name = checked["name"]
	if _auth0.enabled():
		return _defer_auth(_auth0_signup.bind(email, password, player_name, pid if upgrade else "", guest_secret, ip))
	var salt := PasswordHash.new_salt()
	var iterations := password_iterations
	return _hash_async(password, salt, iterations, func(key: PackedByteArray) -> Dictionary:
		# Hashing took a moment: re-check what may have changed meanwhile.
		if _email_index.has(email):
			return _err(409, "an account with this email already exists; sign in instead")
		var stored := PasswordHash.encode(iterations, salt, key)
		var acc: Dictionary
		var secret := ""
		if upgrade:
			if not _accounts.has(pid) or str(_accounts[pid]["email"]) != "":
				return _err(409, "this account can no longer be upgraded")
			acc = _accounts[pid]
			if player_name != "":
				acc["name"] = player_name
			secret = guest_secret   # this device stays signed in as before
		else:
			var id := _new_id()
			secret = _new_token()
			acc = _normalize_account({ "id": id, "name": player_name, "secret_hash": _hash_secret(secret),
				"created_at": Time.get_unix_time_from_system() })
			_accounts[id] = acc
		acc["email"] = email
		acc["password_hash"] = stored
		_email_index[email] = acc["id"]
		_touch("accounts", acc["id"])
		_save()
		return _ok(_session_body(acc, secret)))


## Email + password -> a new session secret for this device.
func _login(body: Dictionary, ip: String) -> Dictionary:
	var email := _clean_email(body.get("email"))
	var password: Variant = body.get("password")
	if email == "" or not (password is String) or password == "" \
			or (password as String).length() > PasswordHash.MAX_LENGTH:
		return _err(400, "enter your email and password")
	if _auth0.enabled():
		return _defer_auth(_auth0_login.bind(email, password, ip))
	var pid: String = _email_index.get(email, "")
	var params := PasswordHash.parse(str(_accounts[pid]["password_hash"])) if _accounts.has(pid) else {}
	var known := not params.is_empty()
	if not known:
		# Same work either way, so response time doesn't reveal which emails exist.
		params = { "iterations": password_iterations, "salt": PasswordHash.new_salt(), "key": PackedByteArray() }
	var expected: String = (params["key"] as PackedByteArray).hex_encode()
	return _hash_async(password, params["salt"], int(params["iterations"]), func(key: PackedByteArray) -> Dictionary:
		if not known or _email_index.get(email, "") != pid or not _same(key.hex_encode(), expected):
			_limited(ip, "auth_fail", LIMIT_AUTH_FAIL)
			return _err(403, "wrong email or password")
		var acc: Dictionary = _accounts[pid]
		var secret := _new_token()
		var sessions: Array = acc["sessions"]
		sessions.append(_hash_secret(secret))
		while sessions.size() > SESSIONS_MAX:
			sessions.pop_front()
		_touch("accounts", pid)
		_save()
		return _ok(_session_body(acc, secret)))


## Ends this device's session. Guests can't sign out: their account exists
## only on their device, so signing out would lose it.
func _logout(body: Dictionary) -> Dictionary:
	var pid := str(body.get("player_id", ""))
	var secret := str(body.get("secret", ""))
	if not _authed(pid, secret):
		return _err(403, "invalid player credentials")
	var acc: Dictionary = _accounts[pid]
	if str(acc["email"]) == "":
		return _err(400, "guest accounts can't sign out")
	var h := _hash_secret(secret)
	(acc["sessions"] as Array).erase(h)
	if _same(str(acc["secret_hash"]), h):
		acc["secret_hash"] = ""
	_touch("accounts", pid)
	_save()
	return _ok({ "signed_out": true })


func _profile(body: Dictionary) -> Dictionary:
	var pid := str(body.get("player_id", ""))
	if not _authed(pid, str(body.get("secret", ""))):
		return _err(403, "invalid player credentials")
	return _ok(_profile_body(_accounts[pid]))


## What a signed-in client keeps (AccountStore) plus its ladder standing.
func _session_body(acc: Dictionary, secret: String) -> Dictionary:
	return { "player_id": acc["id"], "secret": secret, "name": acc["name"], "email": acc["email"],
		"rating": roundi(float(acc["rating"])), "trophies": acc["trophies"],
		"arena": Ladder.arena_name(int(acc["best_trophies"])) }


## The player's own profile: ranks, totals, favorite move, recent matches.
func _profile_body(acc: Dictionary) -> Dictionary:
	var st: Dictionary = acc["stats"]
	var played := int(st["played"])
	var moves: Array = []
	for card in acc["move_counts"]:
		moves.append({ "card": card, "count": int(acc["move_counts"][card]) })
	moves.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["count"] > b["count"] if a["count"] != b["count"] else str(a["card"]) < str(b["card"]))
	# Ladder position, ordered like /leaderboard (trophies, then hidden rating).
	var position := 1
	for other in _accounts.values():
		if other["id"] != acc["id"] and (int(other["trophies"]) > int(acc["trophies"]) or (int(other["trophies"]) == int(acc["trophies"])
				and float(other["rating"]) > float(acc["rating"]))):
			position += 1
	return {
		"player_id": acc["id"],
		"name": acc["name"],
		"email": acc["email"],
		# Only Auth0 verifies emails; null = not applicable (guests, local passwords).
		"email_verified": bool(acc["email_verified"]) if str(acc["auth0_sub"]) != "" else null,
		"guest": str(acc["email"]) == "",
		"created_at": acc["created_at"],
		"season": _season,
		"rank": {
			"trophies": acc["trophies"],
			"arena": Ladder.arena_name(int(acc["trophies"])),
			"best_trophies": acc["best_trophies"],
			"best_arena": Ladder.arena_name(int(acc["best_trophies"])),
			"rating": roundi(float(acc["rating"])),
			"best_rating": roundi(float(acc["best_rating"])),
			"position": position,
			"players": _accounts.size(),
		},
		"stats": {
			"played": played,
			"wins": st["wins"],
			"losses": st["losses"],
			"draws": st["draws"],
			"win_rate": float(st["wins"]) / played if played > 0 else 0.0,
			"streak": st["streak"],
			"best_streak": st["best_streak"],
			"ranked": { "wins": acc["wins"], "losses": acc["losses"], "draws": acc["draws"] },
			"favorite_move": moves[0]["card"] if not moves.is_empty() else "",
			"top_moves": moves.slice(0, 5),
		},
		"history": acc["history"],
	}


# --- Auth0 -------------------------------------------------------------------------

## Runs `job` (a coroutine taking the Deferred to resolve) and answers the
## HTTP request when it resolves.
func _defer_auth(job: Callable) -> Dictionary:
	if _auth_jobs >= MAX_AUTH_JOBS:
		return _err(503, "server busy; try again in a moment")
	var reply := HttpServer.Deferred.new()
	_auth_jobs += 1
	_run_auth(job, reply)
	return { "status": 0, "deferred": reply }


func _run_auth(job: Callable, reply: HttpServer.Deferred) -> void:
	var res: Variant = await job.call()
	_auth_jobs -= 1
	reply.resolve(res if res is Dictionary and (res as Dictionary).has("status") else _err(500, "internal error"))


func _auth0_signup(email: String, password: String, player_name: String, guest_pid: String,
		guest_secret: String, ip: String) -> Dictionary:
	var created := await _auth0.sign_up(email, password, player_name)
	if not created["ok"]:
		return _err(int(created["status"]), str(created["error"]))
	var who := await _auth0.sign_in(email, password, ip)
	if not who["ok"]:
		return _err(int(who["status"]), str(who["error"]))
	var sub := str(who["sub"])
	if _sub_index.has(sub) and _accounts.has(_sub_index[sub]):
		return _ok(_session_body(_accounts[_sub_index[sub]], _new_session(_accounts[_sub_index[sub]])))
	var holder: Dictionary = _accounts.get(_email_index.get(str(who["email"]), ""), {})
	if not holder.is_empty():
		if str(holder["auth0_sub"]) == "" and bool(who["email_verified"]):
			_link_auth0(holder, who)   # verified: the old account is theirs
			var moved := _new_session(holder)
			_touch("accounts", holder["id"])
			_save()
			return _ok(_session_body(holder, moved))
		if str(holder["auth0_sub"]) == "":
			return _err(409, "check your inbox and verify your email, then sign in: your existing account moves over")
		return _err(409, "an account with this email already exists; sign in instead")
	var acc: Dictionary
	var secret := ""
	if guest_pid != "":
		if not _accounts.has(guest_pid) or str(_accounts[guest_pid]["email"]) != "":
			return _err(409, "this account can no longer be upgraded")
		acc = _accounts[guest_pid]
		if player_name != "":
			acc["name"] = player_name
		secret = guest_secret   # this device stays signed in as before
	else:
		acc = _new_email_account(player_name)
		secret = _new_session(acc)
	_link_auth0(acc, who)
	_touch("accounts", acc["id"])
	_save()
	return _ok(_session_body(acc, secret))


func _auth0_login(email: String, password: String, ip: String) -> Dictionary:
	var who := await _auth0.sign_in(email, password, ip)
	if not who["ok"]:
		if int(who["status"]) == 403:
			_limited(ip, "auth_fail", LIMIT_AUTH_FAIL)
		return _err(int(who["status"]), str(who["error"]))
	var sub := str(who["sub"])
	var pid: String = _sub_index.get(sub, "")
	var acc: Dictionary = _accounts.get(pid, {})
	if acc.is_empty():
		# A local-password account with this (Auth0-verified) email moves to
		# Auth0; otherwise it's an Auth0 user new to the game (e.g. created in
		# the Auth0 dashboard, or sign-up finished there but not here).
		var by_email: Dictionary = _accounts.get(_email_index.get(str(who["email"]), ""), {})
		if by_email.is_empty():
			acc = _new_email_account(_name_for(who))
		elif str(by_email["auth0_sub"]) == "" and bool(who["email_verified"]):
			acc = by_email
		elif str(by_email["auth0_sub"]) == "":
			return _err(403, "verify your email first (check your inbox), then sign in")
		else:
			# Another Auth0 user already has this email here (Auth0 allows that
			# across connections): don't mix the accounts.
			return _err(409, "this email belongs to another account")
	_link_auth0(acc, who)
	var secret := _new_session(acc)
	_touch("accounts", acc["id"])
	_save()
	return _ok(_session_body(acc, secret))


func _password_reset(body: Dictionary) -> Dictionary:
	if not _auth0.enabled():
		return _err(501, "password reset isn't available on this server")
	var email := _clean_email(body.get("email"))
	if email == "":
		return _err(400, "enter a valid email address")
	return _defer_auth(func() -> Dictionary:
		var res := await _auth0.request_password_reset(email)
		if not res["ok"]:
			return _err(int(res["status"]), str(res["error"]))
		return _ok({ "sent": true }))


func _new_email_account(player_name: String) -> Dictionary:
	var id := _new_id()
	var acc := _normalize_account({ "id": id, "name": player_name if player_name != "" else "Player",
		"created_at": Time.get_unix_time_from_system() })
	_accounts[id] = acc
	return acc


## Points the account at its Auth0 user and keeps its email up to date.
func _link_auth0(acc: Dictionary, who: Dictionary) -> void:
	var email := str(who["email"])
	var old := str(acc["email"])
	if old != email and old != "" and _email_index.get(old, "") == acc["id"]:
		_email_index.erase(old)
	if _email_index.get(email, acc["id"]) == acc["id"]:
		acc["email"] = email
		_email_index[email] = acc["id"]
	acc["auth0_sub"] = str(who["sub"])
	acc["email_verified"] = bool(who["email_verified"])
	_sub_index[str(who["sub"])] = acc["id"]


## A new session secret for one more device (its hash is kept).
func _new_session(acc: Dictionary) -> String:
	var secret := _new_token()
	var sessions: Array = acc["sessions"]
	sessions.append(_hash_secret(secret))
	while sessions.size() > SESSIONS_MAX:
		sessions.pop_front()
	return secret


## A display name for an Auth0 user new to the game.
func _name_for(who: Dictionary) -> String:
	for candidate in [str(who.get("name", "")), str(who["email"]).get_slice("@", 0)]:
		var checked := _check_name(candidate.left(NAME_MAX))
		if checked.has("name") and not str(checked["name"]).contains("@"):
			return checked["name"]
	return "Player"


# --- Password hashing off the main loop -----------------------------------------

## Runs PasswordHash.derive on a worker thread and answers the HTTP request
## once `done` (called on the main thread with the derived key) returns.
func _hash_async(password: String, salt: PackedByteArray, iterations: int, done: Callable) -> Dictionary:
	if _hash_jobs.size() >= MAX_HASH_JOBS:
		return _err(503, "server busy; try again in a moment")
	var out := [PackedByteArray()]   # shared with the task (Arrays are references)
	var task := WorkerThreadPool.add_task(func() -> void:
		out[0] = PasswordHash.derive(password, salt, iterations))
	var reply := HttpServer.Deferred.new()
	_hash_jobs.append({ "task": task, "out": out, "done": done, "reply": reply })
	return { "status": 0, "deferred": reply }


func _poll_hash_jobs() -> void:
	for i in range(_hash_jobs.size() - 1, -1, -1):
		var job: Dictionary = _hash_jobs[i]
		if not WorkerThreadPool.is_task_completed(job["task"]):
			continue
		WorkerThreadPool.wait_for_task_completion(job["task"])
		_hash_jobs.remove_at(i)
		var res: Variant = (job["done"] as Callable).call(job["out"][0])
		(job["reply"] as HttpServer.Deferred).resolve(
			res if res is Dictionary and (res as Dictionary).has("status") else _err(500, "internal error"))


# --- Profiles: match history and stats ------------------------------------------

## Adds a finished match to both players' profiles (seats with an account).
func _record_history(m: Dictionary, winner: int, reason: String) -> void:
	var ms: MatchState = m["ms"]
	if ms == null:
		return   # nobody ever joined
	var players: Array = m.get("players", ["", ""])
	var standing := [0, 0]
	for team in 2:
		for u in ms.teams[team]:
			if not u.is_bailed:
				standing[team] += 1
	for seat in 2:
		var pid := str(players[seat])
		if pid == "" or not _accounts.has(pid):
			continue
		var acc: Dictionary = _accounts[pid]
		var result := "draw"
		if winner == 0 or winner == 1:
			result = "win" if winner == seat else "loss"
		var st: Dictionary = acc["stats"]
		st["played"] = int(st["played"]) + 1
		match result:
			"win":
				st["wins"] = int(st["wins"]) + 1
				st["streak"] = int(st["streak"]) + 1
				st["best_streak"] = maxi(int(st["best_streak"]), int(st["streak"]))
			"loss":
				st["losses"] = int(st["losses"]) + 1
				st["streak"] = 0
			_:
				st["draws"] = int(st["draws"]) + 1
				st["streak"] = 0
		var used := _moves_used(m, seat)
		var totals: Dictionary = acc["move_counts"]
		var top_move := ""
		for card in used:
			totals[card] = int(totals.get(card, 0)) + int(used[card])
			if top_move == "" or int(used[card]) > int(used[top_move]) \
					or (int(used[card]) == int(used[top_move]) and str(card) < top_move):
				top_move = card
		var opp := str(players[1 - seat])
		var history: Array = acc["history"]
		history.push_front({
			"match_id": m["id"],
			"ended_at": m["ended_at"],
			"mode": m.get("mode", "async"),
			"ranked": bool(m.get("ranked", false)),
			"result": result,
			"reason": reason,
			"turns": int(m["turn"]),
			"opponent": str(_accounts[opp]["name"]) if _accounts.has(opp) else "",
			"units_left": [standing[seat], standing[1 - seat]],
			"trophy_change": int(m.get("trophy_change", [0, 0])[seat]),
			"rating_change": int(m.get("rating_change", [0, 0])[seat]),
			"trophies": int(acc["trophies"]),
			"top_move": top_move,
		})
		while history.size() > HISTORY_MAX:
			history.pop_back()
		_touch("accounts", pid)


## How often `seat` used each action this match: {card name: count}. Plain
## moves and waits, and turns the server auto-filled, don't count.
func _moves_used(m: Dictionary, seat: int) -> Dictionary:
	var out := {}
	for entry in m["history"]:
		var auto: Variant = entry.get("auto")
		if auto is Array and (auto as Array).size() == 2 and bool(auto[seat]):
			continue
		var plan: Variant = (entry.get("plans", [null, null]) as Array)[seat]
		if not (plan is Dictionary) or not (plan.get("units") is Array):
			continue
		for row in plan["units"]:
			if not (row is Dictionary):
				continue
			for lane in ["move", "act"]:
				var actions: Variant = row.get(lane, [])
				if not (actions is Array):
					continue
				for a in actions:
					var card := str(a.get("card", "")) if a is Dictionary else ""
					if card != "" and not (card in PLAIN_ACTIONS):
						out[card] = int(out.get(card, 0)) + 1
	return out


## The player's unfinished matches with their seat tokens, so a client that
## was closed mid-match (or reinstalled) can get back in.
func _account_matches(body: Dictionary) -> Dictionary:
	var pid := str(body.get("player_id", ""))
	if not _authed(pid, str(body.get("secret", ""))):
		return _err(403, "invalid player credentials")
	var out: Array = []
	for m in _matches.values():
		var seat: int = (m.get("players", ["", ""]) as Array).find(pid)
		if seat != -1 and int(m["winner"]) == -1 and m["ms"] != null:
			out.append(_resume_info(m, seat))
	return _ok({ "matches": out })


func _resume_info(m: Dictionary, seat: int) -> Dictionary:
	var info := { "match_id": m["id"], "team": seat, "token": m["tokens"][seat],
		"mode": m.get("mode", "async"), "turn": m["turn"] }
	if public_live_url != "":
		info["live_url"] = public_live_url
	return info


## Permanently deletes an account (App Store Guideline 5.1.1(v): apps with
## account creation must offer in-app deletion). Its open tickets are
## cancelled and unfinished matches are forfeited; finished matches keep only
## the anonymous player id.
func _delete_account(body: Dictionary) -> Dictionary:
	var pid := str(body.get("player_id", ""))
	if not _authed(pid, str(body.get("secret", ""))):
		return _err(403, "invalid player credentials")
	for t in _tickets.values():
		if t["player_id"] == pid and (t["status"] == "queued" or t["status"] == "found"):
			_end_search(t, "cancelled")
	for m in _matches.values():
		var seat: int = (m.get("players", ["", ""]) as Array).find(pid)
		if seat != -1 and int(m["winner"]) == -1 and m["ms"] != null:
			_end_match(m, 1 - seat, "forfeit")
	var email := str(_accounts[pid].get("email", ""))
	if email != "" and _email_index.get(email, "") == pid:
		_email_index.erase(email)
	var sub := str(_accounts[pid].get("auth0_sub", ""))
	if sub != "":
		_sub_index.erase(sub)
		_auth0.delete_user(sub)   # in the background; logged if it fails
	_accounts.erase(pid)
	_drop("accounts", pid)
	_save()
	return _ok({ "deleted": pid })


## Season end: soft-resets everyone's trophies (Ladder.season_reset).
func _season_reset(body: Dictionary) -> Dictionary:
	if admin_key == "" or not _same(str(body.get("admin_key", "")), admin_key):
		return _err(403, "forbidden")
	for a in _accounts.values():
		a["trophies"] = Ladder.season_reset(int(a["trophies"]))
		_touch("accounts", a["id"])
	_season += 1
	_touch("meta", "server")
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
		return float(a["rating"]) > float(b["rating"]))
	var top: Array = []
	for a in players.slice(0, 20):
		top.append(_public_account(a))
	return _ok({ "season": _season, "players": top })


## Joins the ranked queue (`mode`: "async" or "live") and returns the ticket
## view. The client then polls it (its heartbeat) and accepts when it turns
## "found"; see the header for the whole flow.
func _enqueue(body: Dictionary) -> Dictionary:
	var pid := str(body.get("player_id", ""))
	if not _authed(pid, str(body.get("secret", ""))):
		return _err(403, "invalid player credentials")
	var mode := str(body.get("mode", "async"))
	if not (mode in ["async", "live"]):
		return _err(400, "mode must be async or live")
	# One live match at a time: hand back the one in progress instead of
	# starting a second (the client rejoins it).
	if mode == "live":
		for m in _matches.values():
			var seat: int = (m.get("players", ["", ""]) as Array).find(pid)
			if seat != -1 and int(m["winner"]) == -1 and m["ms"] != null and m.get("mode", "async") == "live":
				var res := _err(409, "you are already in a live match")
				res["body"]["active"] = _resume_info(m, seat)
				return res
	var squad: Variant = body.get("squad", [])
	if not (squad is Array):
		return _err(400, "squad required")
	var err := PlanCodec.validate_squad(squad)
	if err != "":
		return _err(400, "invalid squad: %s" % err)

	# One search per player: end any other search of ours.
	for t in _tickets.values():
		if t["player_id"] == pid and (t["status"] == "queued" or t["status"] == "found"):
			_end_search(t, "cancelled")
	var now := Time.get_unix_time_from_system()
	var ticket := { "ticket": _new_id(), "player_id": pid, "status": "queued", "mode": mode, "squad": squad,
		"queued_at": now, "last_seen": now, "partner": "", "seat": -1, "found_at": 0.0, "accepted": false,
		"match_id": "", "team": -1, "token": "" }
	_tickets[ticket["ticket"]] = ticket
	_touch("tickets", ticket["ticket"])
	_run_matchmaker()
	_save()
	return _ok(_ticket_view(ticket))


## One matchmaker tick: expires abandoned searches, times out unconfirmed
## pairs, and pairs fresh tickets (Matchmaker.pair). Returns the number of
## changes (the caller saves when > 0).
func _run_matchmaker() -> int:
	var now := Time.get_unix_time_from_system()
	var changes := 0
	var fresh: Array = []
	for t in _tickets.values():
		var status := str(t["status"])
		var seen := float(t.get("last_seen", t["queued_at"]))
		if status == "found" and now - float(t["found_at"]) > ACCEPT_SEC:
			var partner: Dictionary = _tickets.get(str(t["partner"]), {})
			# Whoever confirmed goes back to the queue, keeping their place;
			# whoever didn't is gone.
			for side in [t, partner]:
				if side.is_empty() or side["status"] != "found":
					continue
				if bool(side["accepted"]):
					_requeue(side)
				else:
					_end_search(side, "expired")
			changes += 1
		elif status == "queued" and now - seen > TICKET_EXPIRE_SEC:
			_end_search(t, "expired")
			changes += 1
		elif status == "queued" and now - seen <= TICKET_STALE_SEC and _accounts.has(t["player_id"]):
			var acc: Dictionary = _accounts[t["player_id"]]
			fresh.append({ "ticket": t["ticket"], "player_id": t["player_id"], "mode": t["mode"],
				"rating": float(acc["rating"]), "rd": _current_rd(acc),
				"wait": now - float(t["queued_at"]), "last_opponent": str(acc.get("last_opponent", "")) })
	for p in Matchmaker.pair(fresh):
		var a: Dictionary = _tickets[p[0]["ticket"]]
		var b: Dictionary = _tickets[p[1]["ticket"]]
		# The player who waited longer hosts (team 0).
		a.merge({ "status": "found", "partner": b["ticket"], "seat": 0, "found_at": now, "accepted": false }, true)
		b.merge({ "status": "found", "partner": a["ticket"], "seat": 1, "found_at": now, "accepted": false }, true)
		_touch("tickets", a["ticket"])
		_touch("tickets", b["ticket"])
		changes += 1
	return changes


## Ready check: the client confirms a found match (proving it's still
## there). When both have, the match is created.
func _accept_ticket(id: String, secret: String) -> Dictionary:
	var t: Dictionary = _tickets.get(id, {})
	if t.is_empty() or not _authed(str(t["player_id"]), secret):
		return _err(404, "ticket not found")
	t["last_seen"] = Time.get_unix_time_from_system()
	if t["status"] != "found":
		return _ok(_ticket_view(t))
	t["accepted"] = true
	_touch("tickets", id)
	var partner: Dictionary = _tickets.get(str(t["partner"]), {})
	if not partner.is_empty() and partner["status"] == "found" and bool(partner["accepted"]):
		if int(t["seat"]) == 0:
			_start_found_match(t, partner)
		else:
			_start_found_match(partner, t)
	_save()
	return _ok(_ticket_view(t))


## Creates the ranked match for a confirmed pair (`host` is team 0).
func _start_found_match(host: Dictionary, guest: Dictionary) -> void:
	var now := Time.get_unix_time_from_system()
	var mode := str(host["mode"])
	var m := _new_match(host["squad"], fixed_seed if fixed_seed >= 0 else _new_seed(), true, mode)
	var token1 := _seat_second(m, guest["squad"])
	m["players"] = [host["player_id"], guest["player_id"]]
	host.merge({ "status": "matched", "match_id": m["id"], "team": 0, "token": m["tokens"][0] }, true)
	guest.merge({ "status": "matched", "match_id": m["id"], "team": 1, "token": token1 }, true)
	for t in [host, guest]:
		_touch("tickets", t["ticket"])
		var waited := now - float(t["queued_at"])
		_avg_wait[mode] = waited if not _avg_wait.has(mode) \
			else lerpf(float(_avg_wait[mode]), waited, WAIT_EWMA)


## Puts a found ticket back in the queue (its partner didn't confirm). It
## keeps its original queue time, so it's first in line.
func _requeue(t: Dictionary) -> void:
	t.merge({ "status": "queued", "partner": "", "seat": -1, "found_at": 0.0, "accepted": false }, true)
	_touch("tickets", t["ticket"])


## Ends a search (`status` "cancelled" or "expired"). A found partner goes
## back to the queue.
func _end_search(t: Dictionary, status: String) -> void:
	if t["status"] == "found":
		var partner: Dictionary = _tickets.get(str(t["partner"]), {})
		if not partner.is_empty() and partner["status"] == "found":
			_requeue(partner)
	t["status"] = status
	t["partner"] = ""
	_touch("tickets", t["ticket"])


## The player's current rating deviation, grown back over idle time.
func _current_rd(acc: Dictionary) -> float:
	var rated_at := float(acc.get("rated_at", 0.0))
	var idle_days := 0.0 if rated_at <= 0.0 else (Time.get_unix_time_from_system() - rated_at) / 86400.0
	return Matchmaker.decayed_rd(float(acc["rd"]), idle_days)


## Polling a ticket is also its heartbeat.
func _poll_ticket(id: String, secret: String) -> Dictionary:
	var t: Dictionary = _tickets.get(id, {})
	if t.is_empty() or not _authed(str(t["player_id"]), secret):
		return _err(404, "ticket not found")
	t["last_seen"] = Time.get_unix_time_from_system()
	return _ok(_ticket_view(t))


func _cancel_ticket(id: String, secret: String) -> Dictionary:
	var t: Dictionary = _tickets.get(id, {})
	if t.is_empty() or not _authed(str(t["player_id"]), secret):
		return _err(404, "ticket not found")
	if t["status"] == "queued" or t["status"] == "found":
		_end_search(t, "cancelled")
		_save()
	return _ok(_ticket_view(t))


func _ticket_view(t: Dictionary) -> Dictionary:
	var now := Time.get_unix_time_from_system()
	var mode := str(t.get("mode", "async"))
	var searching := 0
	for other in _tickets.values():
		if other["mode"] == mode and (other["status"] == "queued" or other["status"] == "found") \
				and now - float(other.get("last_seen", 0.0)) <= TICKET_STALE_SEC:
			searching += 1
	var out := { "ticket": t["ticket"], "status": t["status"], "mode": mode,
		"wait_sec": snappedf(now - float(t["queued_at"]), 0.1), "searching": searching,
		"estimated_wait": snappedf(float(_avg_wait.get(mode, -1.0)), 0.1) }
	if t["status"] == "found":
		out["accept_sec_left"] = snappedf(maxf(0.0, ACCEPT_SEC - (now - float(t["found_at"]))), 0.1)
		out["accepted"] = bool(t["accepted"])
	if t["status"] == "matched":
		out.merge({ "match_id": t["match_id"], "team": int(t["team"]), "token": t["token"] })
		if public_live_url != "":
			out["live_url"] = public_live_url
	return out


## Glicko-2 update for a finished ranked match (one rating period each).
func _apply_rating(m: Dictionary, winner: int) -> void:
	var players: Array = m.get("players", ["", ""])
	if not (_accounts.has(players[0]) and _accounts.has(players[1])):
		return
	var accs: Array = [_accounts[players[0]], _accounts[players[1]]]
	var before: Array = []
	for acc in accs:
		before.append({ "rating": float(acc["rating"]), "rd": _current_rd(acc), "volatility": float(acc["volatility"]) })
	var now := Time.get_unix_time_from_system()
	var deltas := [0, 0]
	for i in 2:
		var score := 0.5
		if winner == 0 or winner == 1:
			score = 1.0 if winner == i else 0.0
		var after := Matchmaker.rate(before[i], before[1 - i], score)
		var acc: Dictionary = accs[i]
		acc["rating"] = float(after["rating"])
		acc["best_rating"] = maxf(float(acc.get("best_rating", 0.0)), float(after["rating"]))
		acc["rd"] = clampf(float(after["rd"]), Matchmaker.MIN_RD, Matchmaker.MAX_RD)
		acc["volatility"] = float(after["volatility"])
		acc["rated_at"] = now
		acc["last_opponent"] = str(players[1 - i])
		deltas[i] = roundi(float(after["rating"])) - roundi(float(before[i]["rating"]))
		_touch("accounts", acc["id"])
	if winner == 0 or winner == 1:
		accs[winner]["wins"] = int(accs[winner]["wins"]) + 1
		accs[1 - winner]["losses"] = int(accs[1 - winner]["losses"]) + 1
	else:
		for acc in accs:
			acc["draws"] = int(acc["draws"]) + 1
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
		_touch("accounts", accs[i]["id"])
	m["trophy_change"] = deltas


## Whether `secret` is this account's device secret (guests, and the device
## that signed up) or one of its signed-in sessions.
func _authed(pid: String, secret: String) -> bool:
	if not _accounts.has(pid) or secret == "":
		return false
	var acc: Dictionary = _accounts[pid]
	var h := _hash_secret(secret)
	var ok := false
	var stored := str(acc.get("secret_hash", ""))
	if stored != "" and _same(h, stored):
		ok = true
	for s in acc.get("sessions", []):
		if _same(h, str(s)):
			ok = true
	return ok


## Account secrets are 128-bit random tokens, so a plain SHA-256 is enough
## (no password stretching needed): a leaked store can't be used to log in.
static func _hash_secret(secret: String) -> String:
	return secret.sha256_text()


## String equality that takes the same time wherever the strings differ.
static func _same(a: String, b: String) -> bool:
	var ba := a.to_utf8_buffer()
	var bb := b.to_utf8_buffer()
	var diff := ba.size() ^ bb.size()
	for i in mini(ba.size(), bb.size()):
		diff |= ba[i] ^ bb[i]
	return diff == 0


func _public_account(a: Dictionary) -> Dictionary:
	return { "player_id": a["id"], "name": a["name"], "rating": roundi(float(a["rating"])), "trophies": a["trophies"],
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
		# Clients older than the protocol field count as version 1.
		if not NetProtocol.is_supported(_int(msg.get("protocol"), 1)):
			_hub.send(conn, { "type": "error", "code": "outdated",
				"error": "This version of the game is out of date. Please update." })
			_hub.kick(conn)
			return
		var id := str(msg.get("match_id", ""))
		var m: Dictionary = _matches.get(id, {})
		var team := _team_for_token(m, str(msg.get("token", ""))) if not m.is_empty() else -1
		if team == -1:
			_hub.send(conn, { "type": "error", "code": "rejected", "error": "unknown match or token" })
			_hub.kick(conn)
			return
		conn["match_id"] = id
		conn["team"] = team
		conn["token"] = m["tokens"][team]
		_hub.kick_others(conn)
		var state: Dictionary = _get_match(id, conn["token"], _int(msg.get("since"), 0))["body"]
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
	var team := -1
	for i in 2:
		var seat_token := str(m["tokens"][i])
		if seat_token != "" and _same(seat_token, token):
			team = i
	return team


func _new_id() -> String:
	return _crypto.generate_random_bytes(6).hex_encode()


func _new_token() -> String:
	return _crypto.generate_random_bytes(16).hex_encode()


## [col, row, w, h] of the match's play area, or null for the whole city.
func _map_array(m: Dictionary) -> Variant:
	var r: Rect2i = m.get("map", Rect2i())
	return MapData.section_to_array(r) if r.has_area() else null


func _new_seed() -> int:
	return int(_crypto.generate_random_bytes(4).decode_u32(0) & 0x7FFFFFFF)


## A positive 62-bit secret (kept in memory and the store, never sent).
func _new_secret_int() -> int:
	return _crypto.generate_random_bytes(8).decode_s64(0) & 0x3FFFFFFFFFFFFFFF


func _ok(body: Dictionary) -> Dictionary:
	return { "status": 200, "body": body }


func _err(status: int, msg: String) -> Dictionary:
	return { "status": status, "body": { "error": msg } }
