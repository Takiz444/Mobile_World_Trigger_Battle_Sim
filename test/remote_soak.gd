extends "res://test/matchmaking_test.gd"
## Soak test against a running server (e.g. production): two separate clients
## queue for Live Battle together, get matched, and play whole live matches,
## `rounds` times in a row; then their test accounts are deleted.
##
## Run (debug build, so http:// works too):
##   godot --headless --path . res://test/remote_soak.tscn -- https://play.example.com [rounds]


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: ... res://test/remote_soak.tscn -- <server url> [rounds]")
		get_tree().quit(2)
		return
	server_url = args[0].rstrip("/")
	var rounds := int(args[1]) if args.size() > 1 else 5
	print("Soak: %d live matches between two clients on %s" % [rounds, server_url])
	var started := Time.get_ticks_msec()
	await _test_two_clients(null, rounds)
	print("  took %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	# Leave no test accounts on the ladder.
	for conn in find_children("*", "GameConnection", false, false):
		if not (conn as GameConnection).account.is_empty():
			await (conn as GameConnection).delete_account()
	print("REMOTE SOAK %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)
