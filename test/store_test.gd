extends Node
## Headless tests for the persistence layer (GameStore): DirStore and
## JsonFileStore round trips, a full server restart on DirStore (accounts,
## a live match mid-game, retention, pruning), and PostgrestStore against an
## in-process fake PostgREST — including writes surviving a database outage.
##
## Run:
##   godot --headless --path . res://test/store_test.tscn

const SERVER_PORT := 18110
const FAKE_PG_PORT := 18120
const DIR := "user://test_store"
const JSON_PATH := "user://test_store.json"

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_wipe(DIR)
	_test_dir_store()
	_test_json_legacy()
	_wipe(DIR)
	await _test_server_restart()
	await _test_postgrest()
	_wipe(DIR)
	print("STORE TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


# --- Stores on their own ----------------------------------------------------------

func _test_dir_store() -> void:
	var s := DirStore.new(DIR)
	_check(s.open(), "dir store opens")
	s.put("accounts", "abc123", { "id": "abc123", "name": "Osamu" })
	s.put("matches", "old1", { "id": "old1", "winner": 0, "ended_at": 100.0 })
	s.put("matches", "live1", { "id": "live1", "winner": -1 })
	s.put("accounts", "../evil", { "id": "x" })
	_check(s.pending() == 3, "unsafe ids are refused")
	s.flush()
	_check(s.pending() == 0, "flush writes everything")
	var data := s.load_all(1000.0)
	_check(str(data["accounts"].get("abc123", {}).get("name")) == "Osamu", "record round-trips")
	_check(data["matches"].has("live1") and not data["matches"].has("old1"), "finished matches past the cutoff are skipped")
	s.remove("accounts", "abc123")
	s.flush()
	_check(not s.load_all(0.0)["accounts"].has("abc123"), "remove deletes the file")
	s.free()


func _test_json_legacy() -> void:
	var f := FileAccess.open(JSON_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({ "matches": {}, "accounts": { "p1": { "id": "p1", "name": "A" } }, "tickets": {}, "season": 3 }))
	f.close()
	var s := JsonFileStore.new(JSON_PATH)
	var data := s.load_all(0.0)
	_check(data["accounts"].has("p1") and int(data["meta"]["server"]["season"]) == 3, "json store reads the old file format")
	s.put("accounts", "p2", { "id": "p2", "name": "B" })
	s.flush()
	var reader := JsonFileStore.new(JSON_PATH)
	var again := reader.load_all(0.0)
	_check(again["accounts"].size() == 2 and int(again["meta"]["server"]["season"]) == 3, "json store keeps the format on write")
	reader.free()
	s.free()
	DirAccess.remove_absolute(JSON_PATH)


# --- Server restart on DirStore ------------------------------------------------------

func _test_server_restart() -> void:
	var s1 := await _start_server(DirStore.new(DIR))
	var b := _backend()
	var a0: Dictionary = (await b.register_account("Osamu"))["body"]
	var a1: Dictionary = (await b.register_account("Yuma"))["body"]
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var q0 := await b.queue_ranked(a0["player_id"], a0["secret"], squad, "live")
	var q1 := await b.queue_ranked(a1["player_id"], a1["secret"], squad, "live")
	var match_id := str(q1["body"]["match_id"])
	var token0 := str((await b.poll_queue(q0["body"]["ticket"], a0["secret"]))["body"]["token"])
	var plan := PlanCodec.encode_plan(MatchRunner.build_fallback_plan(TriggerLibrary.sample_units()))
	await b.submit_plan(match_id, token0, 1, plan)
	await b.submit_plan(match_id, str(q1["body"]["token"]), 1, plan)

	# A match that ended long ago: kept in the store, not reloaded.
	var old := s1._new_match(squad, 1)
	s1._seat_second(old, squad)
	s1._end_match(old, 0, "elimination")
	old["ended_at"] = 1000.0
	s1._touch("matches", old["id"])
	# A ticket matched long ago: pruned from memory and the store.
	var stale: Dictionary = s1._tickets[str(q0["body"]["ticket"])]
	stale["queued_at"] = 1000.0
	s1._prune()
	_check(not s1._tickets.has(stale["ticket"]), "old tickets are pruned")
	var files := DirAccess.get_files_at(DIR + "/matches").size()
	_check(files == 2, "each match is its own record (%d files)" % files)
	await _stop_server(s1)

	var s2 := await _start_server(DirStore.new(DIR))
	var acc := await b.get_account(a0["player_id"])
	_check(acc.get("success", false) and str(acc["body"].get("name")) == "Osamu", "accounts survive a restart")
	var info := await b.get_match(match_id, token0)
	var body: Dictionary = info.get("body", {})
	_check(int(body.get("turn", 0)) == 2 and (body.get("history", []) as Array).size() == 1
		and str(body.get("mode")) == "live", "a live match resumes on its next turn after a restart")
	_check(not s2._matches.has(old["id"]), "matches past retention aren't reloaded")
	_check(not s2._tickets.has(stale["ticket"]), "pruned tickets stay deleted")
	var sub := await b.submit_plan(match_id, token0, 2, plan)
	_check(sub.get("success", false), "play continues after the restart")
	await _stop_server(s2)


# --- PostgrestStore ------------------------------------------------------------------

func _test_postgrest() -> void:
	var fake := FakePostgrest.new()
	add_child(fake)
	fake.start(FAKE_PG_PORT)
	var url := "http://127.0.0.1:%d" % FAKE_PG_PORT

	var s1 := await _start_server(PostgrestStore.new(url))
	var b := _backend()
	var reg := await b.register_account("Chika")
	var pid := str(reg["body"]["player_id"])
	await _wait(func() -> bool: return s1.store.pending() == 0, 3.0)
	_check(fake.tables["accounts"].has(pid), "account upserted into Postgres")

	# Database outage: writes queue up and drain once it's back.
	fake.stop()
	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var created := await b.create_match(5, squad)
	var match_id := str(created["body"]["match_id"])
	await get_tree().create_timer(0.8).timeout
	_check(s1.store.pending() > 0, "writes wait while the database is down")
	fake.start(FAKE_PG_PORT)
	await _wait(func() -> bool: return s1.store.pending() == 0, 8.0)
	_check(fake.tables["matches"].has(match_id), "queued writes drain after the outage")

	var del := await b.delete_account(pid, str(reg["body"]["secret"]))
	await _wait(func() -> bool: return s1.store.pending() == 0, 3.0)
	_check(del.get("success", false) and not fake.tables["accounts"].has(pid), "account deletion reaches Postgres")
	await _stop_server(s1)

	var s2 := await _start_server(PostgrestStore.new(url))
	_check(s2._matches.has(match_id), "server reloads its state from Postgres")
	await _stop_server(s2)
	fake.stop()
	fake.queue_free()


# --- Helpers -------------------------------------------------------------------------

func _start_server(store: GameStore) -> MatchServer:
	var s := MatchServer.new()
	s.store = store
	s.port = SERVER_PORT
	add_child(s)
	await _wait(func() -> bool: return s._http._tcp.is_listening(), 5.0)
	return s


func _stop_server(s: MatchServer) -> void:
	remove_child(s)   # _exit_tree flushes and closes the ports
	s.queue_free()
	await get_tree().create_timer(0.2).timeout


func _backend() -> HttpBackend:
	var b := HttpBackend.new()
	b.server_url = "http://127.0.0.1:%d" % SERVER_PORT
	add_child(b)
	return b


func _wait(cond: Callable, timeout_sec: float) -> void:
	var end := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await get_tree().process_frame


func _wipe(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for kind in GameStore.KINDS:
		var dir := "%s/%s" % [path, kind]
		for f in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute("%s/%s" % [dir, f])
		DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute(path)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)


## Just enough of PostgREST's API for PostgrestStore: upsert, delete by id,
## and paged select. Filters other than id are ignored.
class FakePostgrest extends Node:
	var tables := { "accounts": {}, "tickets": {}, "matches": {}, "meta": {} }
	var _http: HttpServer

	func start(port: int) -> void:
		_http = HttpServer.new()
		_http.start(port, _handle)

	func stop() -> void:
		if _http != null:
			_http.stop()
			_http = null

	func _process(_delta: float) -> void:
		if _http != null:
			_http.poll()

	func _handle(method: String, path: String, body: Dictionary) -> Dictionary:
		var kind := path.trim_prefix("/")
		if not tables.has(kind):
			return { "status": 404, "body": { "message": "no table" } }
		var table: Dictionary = tables[kind]
		match method:
			"GET":
				var ids := table.keys()
				ids.sort()
				var offset := int(body.get("offset", "0"))
				var limit := int(body.get("limit", "1000"))
				var rows: Array = []
				for id in ids.slice(offset, offset + limit):
					rows.append({ "id": id, "doc": table[id] })
				return { "status": 200, "body": rows }
			"POST":
				table[str(body["id"])] = body["doc"]
				return { "status": 201, "body": {} }
			"DELETE":
				table.erase(str(body.get("id", "")).trim_prefix("eq."))
				return { "status": 204, "body": {} }
		return { "status": 405, "body": {} }
