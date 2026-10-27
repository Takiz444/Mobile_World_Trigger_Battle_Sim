class_name GameConnection
extends Node
## Client-side connection layer: one object per screen that talks to the
## game server. It owns
##   - the server choice and a version handshake (GET /health vs NetProtocol),
##   - connection status (OFFLINE / CONNECTING / ONLINE / OUTDATED) for the UI,
##   - the player's account on that server (AccountStore; registers or
##     re-registers when the server no longer knows it),
##   - the matchmaking flow (queue -> poll -> matched / cancelled).
## Requests go through HttpBackend (`backend`); live matches use LiveClient.

enum Status { OFFLINE, CONNECTING, ONLINE, OUTDATED }

signal status_changed(status: int)

const QUEUE_POLL_SEC := 1.0

## The protocol this build speaks (tests lower it to simulate an old build).
var client_protocol := NetProtocol.VERSION
var status: int = Status.OFFLINE
var server_url := ""
## Live WebSocket URL advertised by the server ("" = derive from server_url).
var live_url := ""
var server_info: Dictionary = {}
var account: Dictionary = {}
var backend: HttpBackend
var last_error := ""


func _ready() -> void:
	backend = HttpBackend.new()
	backend.name = "HttpBackend"
	add_child(backend)
	backend.reachability_changed.connect(func(reachable: bool) -> void:
		if not reachable and status == Status.ONLINE:
			_set_status(Status.OFFLINE)
		elif reachable and status == Status.OFFLINE and not server_info.is_empty():
			_set_status(Status.ONLINE))


## Connects to `url`: checks the server is up and speaks a protocol this
## build supports. Returns the new status.
func connect_to(url: String) -> int:
	server_url = url.strip_edges().rstrip("/")
	backend.server_url = server_url
	server_info = {}
	account = {}
	_set_status(Status.CONNECTING)
	var res := await backend.health()
	if not res.get("success", false):
		last_error = str(res.get("error", "server unavailable"))
		_set_status(Status.OFFLINE)
		return status
	server_info = res["body"]
	# Servers from before the handshake report no protocol: treat as 1.
	var min_protocol := int(server_info.get("min_protocol", 1))
	if not NetProtocol.is_supported(client_protocol, min_protocol):
		last_error = "This version of the game is out of date. Please update."
		_set_status(Status.OUTDATED)
		return status
	live_url = str(server_info.get("live_url", ""))
	_set_status(Status.ONLINE)
	return status


func is_online() -> bool:
	return status == Status.ONLINE


## The player's account on this server, registering `player_name` if there
## is none (or the server has forgotten it). {} on failure (see last_error).
func ensure_account(player_name: String) -> Dictionary:
	account = AccountStore.load_for(server_url)
	if not account.is_empty():
		var check := await backend.get_account(account["player_id"])
		if check.get("success", false):
			account.merge(check["body"], true)
			return account
		if int(check.get("status", 0)) != 404:
			last_error = str(check.get("error", "?"))
			return {}
		AccountStore.clear_for(server_url)   # e.g. a wiped dev server
	var res := await backend.register_account(player_name if player_name != "" else "Player")
	if not res.get("success", false):
		last_error = "Could not create account: %s" % str(res.get("error", "?"))
		return {}
	AccountStore.save_for(server_url, res["body"])
	account = AccountStore.load_for(server_url)
	account.merge(res["body"], true)
	return account


## Queues `squad` (encoded) in `mode` ("live" / "async") and waits for an
## opponent. `keep_waiting` is polled each second; returning false cancels.
## Returns the matched ticket ({match_id, team, token, live_url?}), or {}.
func find_match(squad: Array, mode: String, keep_waiting: Callable) -> Dictionary:
	if account.is_empty():
		last_error = "no account"
		return {}
	var res := await backend.queue_ranked(account["player_id"], account["secret"], squad, mode)
	if not res.get("success", false):
		last_error = "Matchmaking failed: %s" % str(res.get("error", "?"))
		return {}
	var ticket: Dictionary = res["body"]
	while str(ticket.get("status", "")) == "queued" and keep_waiting.call():
		await get_tree().create_timer(QUEUE_POLL_SEC).timeout
		var poll := await backend.poll_queue(str(ticket["ticket"]), account["secret"])
		if poll.get("success", false):
			ticket = poll["body"]
	if str(ticket.get("status", "")) == "matched":
		if str(ticket.get("live_url", "")) == "" and live_url != "":
			ticket["live_url"] = live_url
		return ticket
	await backend.cancel_queue(str(ticket.get("ticket", "")), account["secret"])
	last_error = "Search cancelled."
	return {}


## Deletes the account on the server and forgets it locally.
func delete_account() -> bool:
	if account.is_empty():
		return false
	var res := await backend.delete_account(account["player_id"], account["secret"])
	if res.get("success", false):
		AccountStore.clear_for(server_url)
		account = {}
		return true
	last_error = str(res.get("error", "?"))
	return false


static func status_text(s: int) -> String:
	match s:
		Status.CONNECTING:
			return "Connecting…"
		Status.ONLINE:
			return "Online"
		Status.OUTDATED:
			return "Update required"
	return "Offline"


func _set_status(s: int) -> void:
	if s != status:
		status = s
		status_changed.emit(s)
