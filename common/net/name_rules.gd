class_name NameRules
extends RefCounted
## Rules for player-chosen text (account names, unit names). These strings are
## shown to other players, so the server cleans and checks every one:
##   - control characters and markup characters are removed (the combat log
##     renders BBCode; a name must never be able to inject tags),
##   - whitespace is collapsed and trimmed, and the length is capped,
##   - names containing a blocked word are refused (is_allowed).
##
## The blocked-word list is deliberately not in the code: it is read from
## BLOCKLIST_PATH (one lowercase word or phrase per line, '#' comments), or
## from the file named by TT_BLOCKLIST_FILE on the server. The shipped file is
## empty: fill it before opening the game to the public (App Store Guideline
## 1.2 requires filtering objectionable user-generated content).

const PLAYER_NAME_MAX := 20
const UNIT_NAME_MAX := 16
const BLOCKLIST_PATH := "res://common/net/blocked_names.txt"
## Characters that could be read as markup by a text renderer.
const FORBIDDEN := "[]<>{}\\"

static var _blocked: Array[String] = []
static var _loaded := false


## `text` with control/markup characters removed and whitespace collapsed.
static func clean(text: String) -> String:
	var out := ""
	var last_space := true
	for ch in text:
		var code := ch.unicode_at(0)
		# C0/C1 controls, zero-width and bidi-override characters.
		if code < 32 or (code >= 127 and code < 160) or (code >= 0x200B and code <= 0x200F) \
				or (code >= 0x202A and code <= 0x202E) or (code >= 0x2066 and code <= 0x2069) or code == 0xFEFF:
			continue
		if FORBIDDEN.contains(ch):
			continue
		if ch == " " or code == 0xA0:
			if last_space:
				continue
			last_space = true
			out += " "
			continue
		last_space = false
		out += ch
	return out.strip_edges()


## Whether `text` is already clean and no longer than `max_length`.
static func is_clean(text: String, max_length: int) -> bool:
	return text != "" and text.length() <= max_length and clean(text) == text


## False when `text` contains a blocked word (case-insensitive).
static func is_allowed(text: String) -> bool:
	_load()
	var lowered := text.to_lower()
	for word in _blocked:
		if lowered.contains(word):
			return false
	return true


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var path := OS.get_environment("TT_BLOCKLIST_FILE")
	if path == "":
		path = BLOCKLIST_PATH
	if not FileAccess.file_exists(path):
		return
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var word := line.strip_edges().to_lower()
		if word != "" and not word.begins_with("#"):
			_blocked.append(word)
