extends Node
## Headless tests for the persistence layer (GameStore): DirStore and
## JsonFileStore round trips, a full server restart on DirStore (accounts,
## a live match mid-game, retention, pruning), and PostgrestStore against an
## in-process fake PostgREST — including writes surviving a database outage.
## MongoStore runs against a fake Mongo gateway, and against the real one
## (with MongoDB behind it) when TT_TEST_MONGO_GATEWAY_URL is set.
##
## Run:
##   godot --headless --path . res://test/store_test.tscn
## With the real gateway (deploy/mongo-gateway: npm ci, then `npm run dev`):
##   TT_TEST_MONGO_GATEWAY_URL=http://127.0.0.1:8095 TT_TEST_MONGO_GATEWAY_TOKEN=dev-token \
##     godot --headless --path . res://test/store_test.tscn

const SERVER_PORT := 18110
const FAKE_PG_PORT := 18120
const FAKE_MONGO_PORT := 18125
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
	await _test_mongo_fake()
	# The real gateway + MongoDB, when one is running (CI starts one with
	# deploy/mongo-gateway/dev.js; so can you).
	var real := OS.get_environment("TT_TEST_MONGO_GATEWAY_URL")
	if real != "":
		await _test_mongo(real, OS.get_environment("TT_TEST_MONGO_GATEWAY_TOKEN"), "real gateway")
	else:
		print("  (skipped: real Mongo gateway; set TT_TEST_MONGO_GATEWAY_URL to run it)")
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
	await b.accept_queue(q0["body"]["ticket"], a0["secret"])
	q1 = await b.accept_queue(q1["body"]["ticket"], a1["secret"])
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
	var created := await b.create_match(squad)
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


# --- MongoStore ----------------------------------------------------------------------

func _test_mongo_fake() -> void:
	var fake := FakeMongoGateway.new()
	add_child(fake)
	fake.start(FAKE_MONGO_PORT)
	var url := "http://127.0.0.1:%d" % FAKE_MONGO_PORT
	await _test_mongo(url, FakeMongoGateway.TOKEN, "fake gateway", fake)
	var wrong := MongoStore.new(url, "wrong-token")
	add_child(wrong)
	var res := await wrong._http(HTTPClient.METHOD_GET, "/health")
	_check(int(res["status"]) == 401 and not (await wrong.open()), "mongo store refuses a gateway with the wrong token")
	wrong.queue_free()
	fake.stop()
	fake.queue_free()


## Accounts (with an email login and match history), a match, an outage
## (fake only), deletion, and a reload, against the gateway at `url`.
func _test_mongo(url: String, token: String, label: String, fake: FakeMongoGateway = null) -> void:
	var s1 := await _start_server(MongoStore.new(url, token))
	s1.password_iterations = 2000
	var b := _backend()
	var reg := await b.register_account("Chika")
	var pid := str(reg["body"]["player_id"])
	var email := "chika-%s@example.com" % pid
	var up := await b.sign_up(email, "trion-cube-42", "", { "player_id": pid, "secret": reg["body"]["secret"] })
	_check(up.get("success", false), "%s: guest upgraded to an email account" % label)
	await _wait(func() -> bool: return s1.store.pending() == 0, 5.0)
	if fake != null:
		_check(str(fake.collections["accounts"].get(pid, {}).get("email")) == email, "%s: account stored with its email" % label)

	var squad := PlanCodec.encode_squad(TriggerLibrary.sample_units())
	var friend := await b.register_account("Kuga")
	var created := await b.create_match(squad, "async", { "player_id": pid, "secret": reg["body"]["secret"] })
	var match_id := str(created["body"]["match_id"])
	if fake != null:
		# Database outage: writes queue up and drain once it's back.
		fake.stop()
	var joined := await b.join_match(match_id, squad, friend["body"])
	await b.forfeit(match_id, str(joined["body"]["token"]))
	if fake != null:
		await get_tree().create_timer(0.8).timeout
		_check(s1.store.pending() > 0, "%s: writes wait while the database is down" % label)
		fake.start(FAKE_MONGO_PORT)
	await _wait(func() -> bool: return s1.store.pending() == 0, 12.0)
	_check(s1.store.pending() == 0, "%s: queued writes drain" % label)
	var gone := await b.register_account("Gone")
	await b.delete_account(str(gone["body"]["player_id"]), str(gone["body"]["secret"]))
	await _wait(func() -> bool: return s1.store.pending() == 0, 5.0)
	await _stop_server(s1)

	var s2 := await _start_server(MongoStore.new(url, token))
	s2.password_iterations = 2000
	_check(s2._matches.has(match_id), "%s: server reloads matches from MongoDB" % label)
	_check(not s2._accounts.has(str(gone["body"]["player_id"])), "%s: deleted accounts stay deleted" % label)
	var login := await b.sign_in(email, "trion-cube-42")
	_check(login.get("success", false) and str(login["body"]["player_id"]) == pid, "%s: email sign-in after reload" % label)
	var prof := await b.profile(pid, str(login["body"].get("secret", "")))
	var hist: Array = prof.get("body", {}).get("history", [])
	_check(hist.size() == 1 and str(hist[0]["result"]) == "win", "%s: match history reloaded" % label)
	await _stop_server(s2)


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


## The Mongo gateway's API (deploy/mongo-gateway/server.js) over in-memory
## collections: health, paged records, and batches. ended_after is ignored.
class FakeMongoGateway extends Node:
	const TOKEN := "fake-gateway-token"
	var collections := { "accounts": {}, "tickets": {}, "matches": {}, "meta": {} }
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

	func _handle(method: String, path: String, body: Dictionary, ctx: Dictionary = {}) -> Dictionary:
		if str(ctx.get("bearer", "")) != TOKEN:
			return { "status": 401, "body": { "error": "unauthorized" } }
		if method == "GET" and path == "/health":
			return { "status": 200, "body": { "ok": true } }
		if method == "GET" and path.begins_with("/records/"):
			var kind := path.trim_prefix("/records/")
			if not collections.has(kind):
				return { "status": 404, "body": {} }
			var ids: Array = collections[kind].keys()
			ids.sort()
			var after := str(body.get("after", ""))
			var limit := int(body.get("limit", "500"))
			var page: Array = ids.filter(func(id: String) -> bool: return after == "" or id > after).slice(0, limit)
			var rows: Array = []
			for id in page:
				rows.append({ "id": id, "doc": collections[kind][id] })
			return { "status": 200, "body": { "records": rows, "next": page.back() if page.size() == limit else null } }
		if method == "POST" and path == "/batch":
			for op in body.get("ops", []):
				if op["op"] == "put":
					collections[op["kind"]][op["id"]] = op["doc"]
				else:
					collections[op["kind"]].erase(op["id"])
			return { "status": 200, "body": { "ok": true, "failed": [] } }
		return { "status": 404, "body": {} }


## Just enough of PostgREST's API for PostgrestStore: upsert, delete by id,
## and paged select. Filters other than id are ignored.
class FakePostgrest extends Node:
	var tables := { "accounts": {}, "tickets": {}, "matches": {}, "meta": {} }
	var _http: HttpServer

	func start(port: int) -> void:
		_http = HttpServer.new()
		_http.allowed_methods = ["GET", "POST", "DELETE"]
		_http.start(port, _handle)

	func stop() -> void:
		if _http != null:
			_http.stop()
			_http = null

	func _process(_delta: float) -> void:
		if _http != null:
			_http.poll()

	func _handle(method: String, path: String, body: Dictionary, _ctx: Dictionary = {}) -> Dictionary:
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
