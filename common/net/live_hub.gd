class_name LiveHub
extends RefCounted
## Server side of the live channel: a WebSocket server that keeps one
## connection per online player and pushes match events (turn resolved,
## opponent locked in, match over) the moment they happen, so live matches
## don't poll. Messages are JSON text frames: {"type": "...", ...}.
##
## Runs on its own port (MatchServer.live_port); in production a reverse
## proxy terminates TLS and routes wss://<host>/live to it (deploy/Caddyfile).
##
## Each connection is a Dictionary {id, ws, match_id, team, token} that the
## message handler may fill in (on "hello") to subscribe it to a match.

var _tcp := TCPServer.new()
var _on_message: Callable   # (conn: Dictionary, msg: Dictionary) -> void
var _on_close: Callable     # (conn: Dictionary) -> void
var _conns: Array[Dictionary] = []
var _next_id := 1


func start(port: int, on_message: Callable, on_close: Callable = Callable()) -> bool:
	_on_message = on_message
	_on_close = on_close
	return _tcp.listen(port) == OK


func stop() -> void:
	for c in _conns:
		(c["ws"] as WebSocketPeer).close()
	_conns.clear()
	_tcp.stop()


func poll() -> void:
	while _tcp.is_connection_available():
		var stream := _tcp.take_connection()
		if stream == null:
			continue
		var ws := WebSocketPeer.new()
		if ws.accept_stream(stream) != OK:
			continue
		_conns.append({ "id": _next_id, "ws": ws, "match_id": "", "team": -1, "token": "" })
		_next_id += 1

	var closed: Array[Dictionary] = []
	for c in _conns:
		var ws: WebSocketPeer = c["ws"]
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			closed.append(c)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		while ws.get_available_packet_count() > 0:
			var parsed: Variant = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if parsed is Dictionary:
				_on_message.call(c, parsed)
			else:
				send(c, { "type": "error", "error": "expected a JSON object" })
	for c in closed:
		_conns.erase(c)
		if _on_close.is_valid():
			_on_close.call(c)


func send(conn: Dictionary, msg: Dictionary) -> void:
	var ws: WebSocketPeer = conn["ws"]
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(msg))


## Sends `msg` to every connection subscribed to `match_id` as `team`.
func send_to(match_id: String, team: int, msg: Dictionary) -> void:
	for c in _conns:
		if c["match_id"] == match_id and int(c["team"]) == team:
			send(c, msg)


## [team0 connected, team1 connected] for a match.
func presence(match_id: String) -> Array:
	var out := [false, false]
	for c in _conns:
		if c["match_id"] == match_id and int(c["team"]) in [0, 1]:
			out[int(c["team"])] = true
	return out
