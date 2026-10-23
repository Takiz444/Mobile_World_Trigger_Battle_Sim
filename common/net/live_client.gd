class_name LiveClient
extends Node
## Client side of the live channel (see LiveHub / MatchServer): one WebSocket
## to the server for a live match. Says hello with the match token, then
## turns pushed messages into signals. Reconnects with backoff and says hello
## again, and the server answers every hello with the full fogged state, so a
## dropped connection (subway, app backgrounded) resyncs on its own.

signal state_received(body: Dictionary)
signal turn_resolved(result: Dictionary, turn: int, seconds_left: float)
signal opponent_locked(turn: int)
signal submit_acked(msg: Dictionary)
signal match_over(msg: Dictionary)
signal presence_changed(connected: Array)
signal connection_changed(connected: bool)

const RECONNECT_DELAYS := [0.5, 1.0, 2.0, 4.0, 8.0]

var url := ""
var match_id := ""
var token := ""

var _ws: WebSocketPeer
var _open := false
var _attempt := 0
var _retry_at := -1.0
var _closed_by_us := false


## Derives the live URL from the REST server URL when the server doesn't
## advertise one: http(s)://host:port -> ws(s)://host:(port + 1).
static func derive_url(server_url: String) -> String:
	var s := server_url.strip_edges().rstrip("/")
	var secure := s.begins_with("https://")
	var rest := s.trim_prefix("https://").trim_prefix("http://")
	var host := rest.get_slice("/", 0)
	var port := 443 if secure else 80
	if host.contains(":"):
		port = int(host.get_slice(":", 1))
		host = host.get_slice(":", 0)
		return "%s://%s:%d" % ["wss" if secure else "ws", host, port + 1]
	# Default ports usually mean a reverse proxy: use its /live route.
	return "%s://%s/live" % ["wss" if secure else "ws", host]


func open(p_url: String, p_match_id: String, p_token: String) -> void:
	url = p_url
	match_id = p_match_id
	token = p_token
	_closed_by_us = false
	_attempt = 0
	_connect()


func close() -> void:
	_closed_by_us = true
	if _ws != null:
		_ws.close()


func is_open() -> bool:
	return _open


func submit(turn: int, plan: Dictionary) -> void:
	_send({ "type": "submit", "turn": turn, "plan": plan })


func forfeit() -> void:
	_send({ "type": "forfeit" })


func _connect() -> void:
	_ws = WebSocketPeer.new()
	# Replay frames for a full turn can be large.
	_ws.inbound_buffer_size = 4 * 1024 * 1024
	if _ws.connect_to_url(url) != OK:
		_schedule_retry()


func _schedule_retry() -> void:
	if _closed_by_us:
		return
	var delay: float = RECONNECT_DELAYS[mini(_attempt, RECONNECT_DELAYS.size() - 1)]
	_attempt += 1
	_retry_at = Time.get_ticks_msec() / 1000.0 + delay


func _send(msg: Dictionary) -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))


func _process(_delta: float) -> void:
	if _retry_at >= 0.0 and Time.get_ticks_msec() / 1000.0 >= _retry_at:
		_retry_at = -1.0
		_connect()
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not _open:
		_open = true
		_attempt = 0
		_send({ "type": "hello", "match_id": match_id, "token": token })
		connection_changed.emit(true)
	elif state == WebSocketPeer.STATE_CLOSED:
		_ws = null
		if _open:
			_open = false
			connection_changed.emit(false)
		_schedule_retry()
		return
	while _ws.get_available_packet_count() > 0:
		var parsed: Variant = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if parsed is Dictionary:
			_dispatch(parsed)


func _dispatch(msg: Dictionary) -> void:
	match str(msg.get("type", "")):
		"state":
			state_received.emit(msg)
		"turn_resolved":
			turn_resolved.emit(msg.get("result", {}), int(msg.get("turn", 0)), float(msg.get("seconds_left", -1.0)))
		"opponent_locked":
			opponent_locked.emit(int(msg.get("turn", 0)))
		"submit_ack":
			submit_acked.emit(msg)
		"match_over":
			match_over.emit(msg)
		"presence":
			presence_changed.emit(msg.get("connected", [false, false]))
		"error":
			push_warning("Live server error: %s" % str(msg.get("error", "?")))
