extends Node
## Headless smoke test for the local match flow.
##
## Builds a full board + timeline + event log + MatchController, then simulates
## several plan submissions to exercise the multi-turn lifecycle, the enemy AI
## planner, tick resolution, and the replay animation path.
##
## Run:
##   godot --headless --path . res://test/smoke_test.tscn

var _board: HexBoard
var _timeline: TimelineUI
var _event_log: EventLogUI
var _controller: MatchController
var _layer: CanvasLayer
var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_layer = CanvasLayer.new()
	add_child(_layer)

	_board = HexBoard.new()
	_board.board_radius = 6
	_board.hex_size = 1.0
	add_child(_board)

	_timeline = TimelineUI.new()
	_layer.add_child(_timeline)
	_timeline.setup(SquadStore.get_squad())

	_event_log = EventLogUI.new()
	_layer.add_child(_event_log)

	_controller = MatchController.new()
	add_child(_controller)
	_controller.setup(_board, _timeline, _event_log, _layer)

	_check(_controller._ms.all_units().size() == 8, "8 units placed on board")
	_check(not _controller._overlay.visible, "overlay hidden at match start")
	_check(_controller._ms.cover.size() > 0, "cover generated on board")
	_controller._update_targeting()

	for turn in range(3):
		if _controller._overlay.visible:
			break
		_check(_controller._turn == turn + 1, "turn index is %d" % (turn + 1))
		_controller._build_enemy_plan()
		_check(_controller._enemy_plan.is_all_valid(), "enemy plan valid (turn %d)" % (turn + 1))
		await _controller._on_plan_submitted()
		_check(_controller._turn == turn + 2 or _controller._overlay.visible,
			"turn advanced or match over after submit %d" % (turn + 1))

	print("SMOKE TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
