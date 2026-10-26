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
	_check(_controller._ms.buildings.size() > 0, "city map buildings placed on board")

	_controller._update_targeting()
	await _check_physics_matches_rules()
	_check_preview()

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


## Preview layers follow the design doc: blue origin, yellow base area /
## trajectory, orange choices, plus a looping FX preview for attacks.
func _check_preview() -> void:
	var plan := _timeline.get_plan()
	var slot: TimelineSlot = _timeline._current_slots[0][0]
	var u: UnitState = _controller._player_states[0]

	plan.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Kogetsu"))
	_timeline._on_slot_selected(slot)
	_controller._update_targeting()
	_check(_board._origin_hex == u.hex, "preview marks the acting unit's hex (blue)")
	var arc_ok := _board._highlighted.size() >= 2
	for h in _board._highlighted.keys():
		if HexCoord.distance(h, u.hex) != 1:
			arc_ok = false
	_check(arc_ok, "melee preview shows an adjacent front arc (yellow, got %d)" % _board._highlighted.size())
	_check(_controller._fx._preview != null and _controller._fx._preview_kind == "slash",
		"melee preview animates a slash arc")

	plan.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_card("Asteroid"))
	_controller._update_targeting()
	_check(_board._highlighted.is_empty(), "ranged preview fills no tiles")
	_check(_controller._fx._preview != null and _controller._fx._preview_kind == "line",
		"ranged preview draws a bullet line")
	_check(_controller._fx._preview_hexes.size() >= 3, "bullet line marks each hex it crosses")

	# Straight shots (Asteroid) fly one true straight line to the aimed hex.
	var aim := HexCoord.neighbor(HexCoord.neighbor(u.hex, u.facing), posmod(u.facing + 1, 6))
	if _board.has_tile(aim):
		_controller._hovered_hex = aim
		_controller._update_targeting()
		_check(_controller._fx._preview_points.size() == 2, "straight shot is one straight line (2 points)")
		_check(_controller._fx._preview_hexes.has(aim), "straight shot marks the aimed hex")
		var p0: Vector3 = _controller._fx._preview_points[0]
		var p1: Vector3 = _controller._fx._preview_points[1]
		var aim_world := _board.hex_to_world_at(aim, u.floor)
		_check(absf(p0.distance_to(p1) - p0.distance_to(aim_world)) < 0.01,
			"straight line ends exactly at the aimed hex centre (no hex snapping)")
		_controller._hovered_hex = HexBoard.INVALID_HEX

	plan.assign(0, 0, TurnPlan.MAIN_SLOT, TriggerLibrary.get_move_card())
	_controller._update_targeting()
	_check(_board._effect_hexes.size() > 0, "move preview shows reachable hexes (orange)")
	_check(_controller._fx._preview == null, "move preview has no attack animation")

	# Empty slot: clicking a hex sets the look direction (no edge clicking).
	plan.clear(0, 0, TurnPlan.MAIN_SLOT)
	_timeline._on_slot_selected(slot)
	_controller._update_targeting()
	var ahead := HexCoord.neighbor(u.hex, u.facing)
	_controller._on_tile_selected(ahead)
	_check(plan.slot_has_facing(0, 0, TurnPlan.MAIN_SLOT),
		"empty slot: clicking a hex sets a look direction")
	_check(plan.slot_facing(0, 0, TurnPlan.MAIN_SLOT) == u.facing,
		"look direction points at the clicked hex")
	plan.clear_facing(0, 0, TurnPlan.MAIN_SLOT)
	_controller._update_targeting()


## The rendered city's physics solids and the engine's line-of-sight rules
## must agree: fire real physics rays between random street positions (eye
## height to body height) and compare with Visibility.has_los.
func _check_physics_matches_rules() -> void:
	for _i in 3:
		await get_tree().physics_frame
	var ms := _controller._ms
	var space := _board.get_world_3d().direct_space_state
	var streets: Array = ms.tiles.keys().filter(func(h: Vector2i) -> bool: return not ms.buildings.has(h))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var tested := 0
	var agree := 0
	for _i in 800:
		var a: Vector2i = streets[rng.randi_range(0, streets.size() - 1)]
		var b: Vector2i = streets[rng.randi_range(0, streets.size() - 1)]
		if a == b or HexCoord.distance(a, b) > 12:
			continue
		var pa := HexCoord.axial_to_world(a, _board.hex_size)
		var pb := HexCoord.axial_to_world(b, _board.hex_size)
		pa.y = HexCoord.GROUND_Y + Visibility.EYE_HEIGHT * HexCoord.FLOOR_HEIGHT
		pb.y = HexCoord.GROUND_Y + Visibility.BODY_HEIGHT * HexCoord.FLOOR_HEIGHT
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(pa, pb, CityBuildings.COLLISION_LAYER))
		tested += 1
		if hit.is_empty() == Visibility.has_los(ms, a, 0, b, 0):
			agree += 1
	_check(tested > 100 and agree == tested, "3D physics raycasts agree with the sight rules (%d/%d)" % [agree, tested])


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
