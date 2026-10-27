class_name GameStore
extends Node
## Persistence interface for the game server. The server keeps live state in
## memory (it is authoritative per match) and writes changed records behind
## itself: put()/remove() queue a change, flush() writes what's queued.
##
## Records are JSON-ready Dictionaries grouped by kind:
##   "accounts"  player_id -> account
##   "tickets"   ticket id -> matchmaking ticket
##   "matches"   match id  -> serialized match (MatchServer._serialize)
##   "meta"      key       -> server-wide values ("server": {season})
##
## Implementations:
##   JsonFileStore   one JSON file, rewritten on flush (dev; the old format)
##   DirStore        one file per record (single-server production)
##   PostgrestStore  Postgres via a PostgREST HTTP API (multi-server path)
##
## Stores are Nodes so network-backed ones can run HTTP requests; the server
## adds its store as a child. open() and load_all() may be coroutines:
## always `await` them.

const KINDS: Array[String] = ["accounts", "tickets", "matches", "meta"]


## Builds the store selected by the environment (TT_STORE = json | dir |
## postgrest; default json for local dev).
static func from_env(default_file: String) -> GameStore:
	match OS.get_environment("TT_STORE"):
		"dir":
			var dir := OS.get_environment("TT_DATA_DIR")
			return DirStore.new(dir if dir != "" else "user://store")
		"postgrest":
			return PostgrestStore.new(OS.get_environment("TT_DB_URL"), OS.get_environment("TT_DB_TOKEN"))
		_:
			var file := OS.get_environment("TT_DATA_FILE")
			return JsonFileStore.new(file if file != "" else default_file)


## Short description for the startup log.
func describe() -> String:
	return "none"


## Connects / prepares the backing storage. Returns false if unusable.
func open() -> bool:
	return true


## Every stored record: {kind: {id: record}}. `match_cutoff` (unix time)
## lets a store skip matches that ended before it; the server filters too.
func load_all(_match_cutoff: float) -> Dictionary:
	return _empty()


func put(_kind: String, _id: String, _record: Dictionary) -> void:
	pass


func remove(_kind: String, _id: String) -> void:
	pass


## Writes queued changes (synchronously for file stores; network stores
## start sending and finish in the background).
func flush() -> void:
	pass


## Changes not yet confirmed written.
func pending() -> int:
	return 0


static func _empty() -> Dictionary:
	var out := {}
	for kind in KINDS:
		out[kind] = {}
	return out


## Ids become file names / URL filters: allow only what the server generates.
static func valid_id(id: String) -> bool:
	if id == "" or id.length() > 64:
		return false
	for c in id:
		if not (c.is_valid_identifier() or c.is_valid_int()):
			return false
	return true


## Writes `text` to `path` via a temp file + rename, so a crash mid-write
## never leaves a truncated file.
static func write_atomic(path: String, text: String) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write %s (error %d)" % [tmp, FileAccess.get_open_error()])
		return false
	f.store_string(text)
	f.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_warning("Could not replace %s (error %d)" % [path, err])
		return false
	return true
