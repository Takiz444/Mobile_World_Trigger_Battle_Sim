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
## Each connection is a Dictionary {id, ws, match_id, team, token, seen} that
## the message handler may fill in (on "hello") to subscribe it to a match.
##
## Mobile networks often drop TCP silently, so clients ping every
## LiveClient.PING_INTERVAL; a connection quiet for IDLE_TIMEOUT_MS is closed
## (and its player shown as reconnecting).

## Full-state messages (a reconnect late in a match carries every turn's
## replay frames) exceed WebSocketPeer's 64 KB default.
const OUTBOUND_BUFFER := 4 * 1024 * 1024
const INBOUND_BUFFER := 256 * 1024
const IDLE_TIMEOUT_MS := 45000
const MAX_CONNECTIONS := 4096
## A connection must identify itself (a "hello" the server accepts) this soon
## after connecting, or it is closed: anonymous sockets can't pile up.
const HELLO_TIMEOUT_MS := 10000
## Messages a connection may send per second (burst MSG_BURST). A live client
## sends a ping every 15 s and one submit per turn; anything faster is abuse.
const MSG_RATE := 5.0
const MSG_BURST := 20.0
## A kicked connection is given this long to receive the close reason.
const KICK_LINGER_MS := 2000
const KICK_CLOSE_DELAY_MS := 250

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
		if _conns.size() >= MAX_CONNECTIONS:
			stream.disconnect_from_host()
			continue
		var ws := WebSocketPeer.new()
		ws.outbound_buffer_size = OUTBOUND_BUFFER
		ws.inbound_buffer_size = INBOUND_BUFFER
		if ws.accept_stream(stream) != OK:
			continue
		_conns.append({ "id": _next_id, "ws": ws, "match_id": "", "team": -1, "token": "",
			"seen": Time.get_ticks_msec(), "opened": Time.get_ticks_msec(),
			"budget": MSG_BURST, "budget_at": Time.get_ticks_msec() })
		_next_id += 1

	var closed: Array[Dictionary] = []
	var now := Time.get_ticks_msec()
	for c in _conns:
		var ws: WebSocketPeer = c["ws"]
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			closed.append(c)
			continue
		if c.get("kicked", false):
			# Never read from it again. The close frame goes out a moment
			# later: control frames overtake queued messages, and the client
			# should get the reason we sent first.
			if not c.get("closing", false) and now - int(c["kicked_at"]) > KICK_CLOSE_DELAY_MS:
				c["closing"] = true
				ws.close(int(c["kick_code"]), str(c["kick_reason"]))
			if now - int(c["kicked_at"]) > KICK_LINGER_MS:
				closed.append(c)
			continue
		if now - int(c["seen"]) > IDLE_TIMEOUT_MS:
			# Dead link: drop it now rather than waiting for TCP to notice.
			ws.close(4000, "idle")
			closed.append(c)
			continue
		if int(c["team"]) == -1 and now - int(c["opened"]) > HELLO_TIMEOUT_MS:
			ws.close(4001, "hello timeout")
			closed.append(c)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		if ws.get_available_packet_count() > 0:
			c["seen"] = now
		while ws.get_available_packet_count() > 0:
			var packet := ws.get_packet()
			c["budget"] = minf(MSG_BURST, float(c["budget"]) + (now - int(c["budget_at"])) / 1000.0 * MSG_RATE)
			c["budget_at"] = now
			if float(c["budget"]) < 1.0:
				ws.close(4008, "too many messages")
				closed.append(c)
				break
			c["budget"] = float(c["budget"]) - 1.0
			var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
			if c.get("kicked", false):
				break
			if parsed is Dictionary:
				_on_message.call(c, parsed)
			else:
				send(c, { "type": "error", "error": "expected a JSON object" })
	for c in closed:
		_conns.erase(c)
		if _on_close.is_valid():
			_on_close.call(c)


## Closes a connection after the current poll (e.g. a rejected hello).
func kick(conn: Dictionary, code := 4003, reason := "rejected") -> void:
	conn["kicked"] = true
	conn["kicked_at"] = Time.get_ticks_msec()
	conn["kick_code"] = code
	conn["kick_reason"] = reason


## A player has one live connection per match: a new hello replaces any
## older socket for the same seat (a reconnect, or a second device).
func kick_others(conn: Dictionary) -> void:
	for c in _conns:
		if int(c["id"]) != int(conn["id"]) and c["match_id"] == conn["match_id"] and int(c["team"]) == int(conn["team"]):
			c["team"] = -1
			c["match_id"] = ""
			kick(c, 4002, "replaced by a newer connection")


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
