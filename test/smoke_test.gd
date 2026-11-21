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
	SquadStore.persist = false   # never touch the player's saved squad
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

	_check(_controller._ms.all_units().size() == 2 * PlanCodec.SQUAD_SIZE, "both squads placed on the board")
	_check(not _controller._overlay.visible, "overlay hidden at match start")
	_check(_controller._ms.buildings.size() > 0, "city map buildings placed on board")
	_controller._update_targeting()
	await _check_physics_matches_rules()
	_check_planning_ui()

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


## Tap-to-place, aiming, tapping a character on the board, the spotlight,
## and the plan lock.
func _check_planning_ui() -> void:
	_check(_controller._spotlight.is_active(), "the commanded character is spotlit")
	var move := TriggerLibrary.get_move_card()
	_timeline._on_card_tapped(move)
	var plan := _timeline.get_plan()
	_check(plan.get_card(0, 0, TurnPlan.MAIN_SLOT) == move and _timeline.has_selected_slot(),
		"tapping a card places it in the first free tick and selects it")
	_check(_timeline._missing_targets() == 1, "an unaimed move is counted as needing a target")
	var me: UnitState = _controller._player_states[0]
	var dest := Vector2i.ZERO
	for n in HexCoord.neighbors(me.hex):
		if _controller._ms.floor_legal(n, 0) and _controller._known_unit_at(n, 0) == null:
			dest = n
			break
	_controller._on_tile_selected(dest)
	_check(plan.get_tick(0, 0).has_target and plan.get_tick(0, 0).target_hex == dest, "tapping a hex aims the selected action")
	# The next tap goes to the next free tick, not over the one just placed.
	_timeline._on_card_tapped(TriggerLibrary.get_look_card())
	_check(plan.get_card(0, 0, TurnPlan.MAIN_SLOT) == move and plan.get_card(0, 0, TurnPlan.SUB_SLOT) != null
		or plan.get_card(0, 1, TurnPlan.MAIN_SLOT) != null, "tapping another card adds it after the first")
	# Dropping a different card on a filled tick replaces it and drops the old target.
	_timeline._on_slot_dropped(_timeline._current_slots[0][0], { "card": TriggerLibrary.get_look_card(), "from_slot": false })
	_check(plan.get_card(0, 0, TurnPlan.MAIN_SLOT).card_name == "Look" and not plan.get_tick(0, 0).has_target,
		"a replaced action loses its old target")
	_timeline.begin_new_turn()

	var ally: UnitState = _controller._player_states[1]
	_controller._on_tile_selected(ally.hex)
	_check(_timeline.get_current_unit() == 1, "tapping a character on the board commands it")
	_timeline.select_unit(0)

	_timeline.begin_new_turn()
	plan = _timeline.get_plan()
	_timeline.set_locked(true)
	_timeline._on_card_tapped(move)
	_check(plan.get_card(0, 0, TurnPlan.MAIN_SLOT) == null, "a locked plan can't be edited")
	_timeline.set_locked(false)
	_timeline.begin_new_turn()


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
	var mismatch := ""
	for _i in 800:
		var a: Vector2i = streets[rng.randi_range(0, streets.size() - 1)]
		var b: Vector2i = streets[rng.randi_range(0, streets.size() - 1)]
		if a == b or HexCoord.distance(a, b) > 12:
			continue
		var pa := HexCoord.axial_to_world(a, _board.hex_size)
		var pb := HexCoord.axial_to_world(b, _board.hex_size)
		pa.y = HexCoord.GROUND_Y + Visibility.EYE_HEIGHT * HexCoord.FLOOR_HEIGHT
		pb.y = HexCoord.GROUND_Y + Visibility.BODY_HEIGHT * HexCoord.FLOOR_HEIGHT
		var los := Visibility.has_los(ms, a, 0, b, 0)
		tested += 1
		if _ray_clear(space, pa, pb) == los:
			agree += 1
		else:
			# Lines through a wall's exact corner are a coin toss for any two
			# implementations: accept it if a 3 cm nudge gives the rules' answer.
			var side := (pb - pa).cross(Vector3.UP).normalized() * 0.03
			if _ray_clear(space, pa + side, pb + side) == los or _ray_clear(space, pa - side, pb - side) == los 					or (los and _hits_corner(space, pa, pb, ms)):
				agree += 1
			elif mismatch == "":
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(pa, pb, CityBuildings.COLLISION_LAYER))
				mismatch = " first: %s->%s rules_los=%s hit=%s on %s" % [a, b, los, hit.get("position", "-"),
					(hit["collider"] as Node).name if hit.has("collider") else "-"]
	_check(tested > 100 and agree == tested, "3D physics raycasts agree with the sight rules (%d/%d)%s" % [agree, tested, mismatch])


## Whether the physics ray stops exactly on a building's vertical corner
## edge (a zero-clearance pass: the rules call it clear).
func _hits_corner(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, ms: MatchState) -> bool:
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b, CityBuildings.COLLISION_LAYER))
	if hit.is_empty():
		return false
	var p := Vector2((hit["position"] as Vector3).x, (hit["position"] as Vector3).z)
	for r in ms.building_rects():
		var box := BuildingRects.bounds(r, _board.hex_size)
		for corner in [box.position, Vector2(box.end.x, box.position.y), box.end, Vector2(box.position.x, box.end.y)]:
			if p.distance_to(corner) < 0.02:
				return true
	return false


func _ray_clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b, CityBuildings.COLLISION_LAYER)).is_empty()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
