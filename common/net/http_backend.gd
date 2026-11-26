class_name HttpBackend
extends Node
## Godot HTTP client for the match backend (the transport under
## GameConnection). All request helpers are awaitable and return
## {success: bool, status: int, body: Dictionary, error?: String}.
## status 0 means the server was never reached (offline, DNS, timeout).
##
## Each call uses its own HTTPRequest, so calls may overlap. GETs are retried
## on transport failures and 5xx/429 (mobile networks blip); POSTs are not,
## since the server may have applied them.
##
## Credentials (`auth`: a match token or account secret) are sent as an
## "Authorization: Bearer" header or in the JSON body, never in the URL.
## In release builds only https:// servers are accepted (see ServerConfig).

const TIMEOUT_SEC := 10.0
## Sign-up / sign-in may wait on the server's identity provider (Auth0).
const AUTH_TIMEOUT_SEC := 30.0
const GET_RETRY_DELAYS := [0.5, 1.5]

var server_url: String = "http://127.0.0.1:8080"
## Emitted after every request: whether the server answered at all.
signal reachability_changed(reachable: bool)
var _reachable := true


func request(method: String, path: String, body: Dictionary = {}, auth: String = "",
		timeout_sec: float = TIMEOUT_SEC) -> Dictionary:
	if not ServerConfig.url_allowed(server_url):
		return { "success": false, "status": 0, "body": {}, "error": "insecure server address (https required)" }
	var out := await _request_once(method, path, body, auth, timeout_sec)
	if method == "GET":
		for delay in GET_RETRY_DELAYS:
			var status := int(out.get("status", 0))
			if status != 0 and status != 429 and status < 500:
				break
			await get_tree().create_timer(delay).timeout
			out = await _request_once(method, path, body, auth, timeout_sec)
	var reachable := int(out.get("status", 0)) != 0
	if reachable != _reachable:
		_reachable = reachable
		reachability_changed.emit(reachable)
	return out


func _request_once(method: String, path: String, body: Dictionary, auth: String = "",
		timeout_sec: float = TIMEOUT_SEC) -> Dictionary:
	var url := server_url.rstrip("/") + path
	var http_method := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var data := JSON.stringify(body) if not body.is_empty() else ""
	var http := HTTPRequest.new()
	http.timeout = timeout_sec
	add_child(http)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if auth != "":
		headers.append("Authorization: Bearer %s" % auth)
	var err := http.request(url, headers, http_method, data)
	if err != OK:
		http.queue_free()
		return { "success": false, "status": 0, "body": {}, "error": "request failed (%d)" % err }
	var resp: Array = await http.request_completed
	http.queue_free()
	var result: int = resp[0]
	var code: int = resp[1]
	var resp_body: PackedByteArray = resp[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return { "success": false, "status": 0, "body": {}, "error": "can't reach server (%d)" % result }
	var parsed: Variant = JSON.parse_string(resp_body.get_string_from_utf8())
	var body_out: Dictionary = parsed if parsed is Dictionary else {}
	var out := { "success": code >= 200 and code < 300, "status": code, "body": body_out }
	if not out["success"]:
		out["error"] = str(body_out.get("error", "HTTP %d" % code))
	return out


func health() -> Dictionary:
	return await request("GET", "/health")


## The server picks the match seed; `mode` is "async" or "live". With an
## `account` ({player_id, secret}) the match goes into that player's profile.
func create_match(squad: Array, mode: String = "async", account: Dictionary = {}) -> Dictionary:
	return await request("POST", "/match/create", _with_account({ "squad": squad, "mode": mode }, account))


func join_match(match_id: String, squad: Array, account: Dictionary = {}) -> Dictionary:
	return await request("POST", "/match/%s/join" % match_id, _with_account({ "squad": squad }, account))


static func _with_account(body: Dictionary, account: Dictionary) -> Dictionary:
	if str(account.get("player_id", "")) != "" and str(account.get("secret", "")) != "":
		body["player_id"] = str(account["player_id"])
		body["secret"] = str(account["secret"])
	return body


## `token` is the secret returned by create/join; it identifies the team.
func submit_plan(match_id: String, token: String, turn: int, plan: Dictionary) -> Dictionary:
	return await request("POST", "/match/%s/submit" % match_id, { "token": token, "turn": turn, "plan": plan })


# --- Accounts & ranked matchmaking -------------------------------------------

func register_account(player_name: String) -> Dictionary:
	return await request("POST", "/account/register", { "name": player_name })


func get_account(player_id: String) -> Dictionary:
	return await request("GET", "/account/%s" % player_id)


## Creates an email account. Passing the device's guest account (player_id +
## secret) upgrades it instead, keeping its trophies and match history.
func sign_up(email: String, password: String, player_name: String, guest: Dictionary = {}) -> Dictionary:
	return await request("POST", "/account/signup",
		_with_account({ "email": email, "password": password, "name": player_name }, guest), "", AUTH_TIMEOUT_SEC)


## {player_id, secret, name, email, ...}: a new session for this device.
func sign_in(email: String, password: String) -> Dictionary:
	return await request("POST", "/account/login", { "email": email, "password": password }, "", AUTH_TIMEOUT_SEC)


## Asks the server to email a password-reset link (servers using Auth0).
func request_password_reset(email: String) -> Dictionary:
	return await request("POST", "/account/password_reset", { "email": email }, "", AUTH_TIMEOUT_SEC)


func sign_out(player_id: String, secret: String) -> Dictionary:
	return await request("POST", "/account/logout", { "player_id": player_id, "secret": secret })


## The private profile: ranks, stats, favorite move, recent matches.
func profile(player_id: String, secret: String) -> Dictionary:
	return await request("POST", "/account/profile", { "player_id": player_id, "secret": secret })


## Permanently deletes the account (required in-app by the App Store).
func delete_account(player_id: String, secret: String) -> Dictionary:
	return await request("POST", "/account/delete", { "player_id": player_id, "secret": secret })


func forfeit(match_id: String, token: String) -> Dictionary:
	return await request("POST", "/match/%s/forfeit" % match_id, { "token": token })


func leaderboard() -> Dictionary:
	return await request("GET", "/leaderboard")


## Joins the ranked queue and returns the ticket to poll (MatchServer header).
## `mode` is "async" (correspondence) or "live" (trophy ladder).
func queue_ranked(player_id: String, secret: String, squad: Array, mode := "async") -> Dictionary:
	return await request("POST", "/queue", { "player_id": player_id, "secret": secret, "squad": squad, "mode": mode })


## Polls a ticket; this is also its heartbeat, so poll about once a second.
func poll_queue(ticket: String, secret: String) -> Dictionary:
	return await request("GET", "/queue/%s" % ticket, {}, secret)


## Confirms a "found" match (the ready check).
func accept_queue(ticket: String, secret: String) -> Dictionary:
	return await request("POST", "/queue/%s/accept" % ticket, { "secret": secret })


## The account's unfinished matches ({matches: [{match_id, team, token, mode,
## turn, live_url?}]}), for getting back into a match after a restart.
func active_matches(player_id: String, secret: String) -> Dictionary:
	return await request("POST", "/account/matches", { "player_id": player_id, "secret": secret })


func cancel_queue(ticket: String, secret: String) -> Dictionary:
	return await request("POST", "/queue/%s/cancel" % ticket, { "secret": secret })


## With a player token the response includes that team's fogged view,
## replay frames, and own plans; without one only public match info.
## `since` limits the returned history to turns >= since (polling clients
## only need the turns they have not replayed yet).
func get_match(match_id: String, token: String = "", since: int = 0) -> Dictionary:
	var path := "/match/%s" % match_id
	if since > 0:
		path += "?since=%d" % since
	return await request("GET", path, {}, token)
