extends Node
## Headless smoke test for the local match flow.
##
## Builds a full board + timeline + event log + MatchController, checks that
## the rendered city agrees with the sight rules, drives the planning UI
## (cards, aiming on the board, selecting characters, the lock), then plays
## several turns against the AI through the same record-and-replay pipeline
## online matches use.
##
## Run:
##   godot --headless --path . res://test/smoke_test.tscn

var _board: CityBoard
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
	_board = CityBoard.new()
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
	var hidden_ok := true
	for e in _controller._enemy_states:
		if e.fog != Visibility.State.SIGHT:
			hidden_ok = hidden_ok and e.pos == MatchController.OFFBOARD
	_check(hidden_ok, "enemies we can't see aren't anywhere on our board")
	await _check_physics_matches_rules()
	_check_planning_ui()

	for turn in range(3):
		if _controller._overlay.visible:
			break
		_check(_controller._turn == turn + 1, "turn index is %d" % (turn + 1))
		_controller._build_enemy_plan()
		var ai_team := 1 - _controller._team
		_check(_controller._enemy_plan.is_all_valid(_controller._truth, _controller._truth.teams[ai_team]),
			"enemy plan valid (turn %d)" % (turn + 1))
		_plan_simple_turn()
		await _controller._on_plan_submitted()
		_check(_controller._turn == turn + 2 or _controller._overlay.visible,
			"turn advanced or match over after submit %d" % (turn + 1))
		var synced := true
		for i in _controller._player_states.size():
			var mine: UnitState = _controller._player_states[i]
			var real: UnitState = _controller._truth.teams[_controller._team][i]
			synced = synced and mine.pos.distance_to(real.pos) < 0.01 and mine.trion_hp == real.trion_hp
		_check(synced, "our view of our squad matches the real match after turn %d" % (turn + 1))

	if not _controller._overlay.visible:
		_check_submit_feedback()
	print("SMOKE TEST %s" % ("PASS" if not _failed else "FAIL"))
	get_tree().quit(1 if _failed else 0)


## Gives every character a short walk and a shield, so turns move things.
func _plan_simple_turn() -> void:
	var plan := _timeline.get_plan()
	var ms := _controller._ms
	var geo := ms.geometry()
	for i in _controller._player_states.size():
		var u: UnitState = _controller._player_states[i]
		if u.is_bailed:
			continue
		plan.clear_unit(i)
		for k in 8:
			var dest := u.pos + Vector2.from_angle(TAU * k / 8.0) * 3.0
			if geo.ground_ok(dest) and geo.ground_clear(u.pos, dest):
				var mv := PlanAction.new(TriggerLibrary.get_move_card())
				mv.set_point(dest, 0)
				plan.add(i, mv)
				break
		var shield := PlanAction.new(TriggerLibrary.get_card("Shield"))
		shield.hold = 2.0
		plan.add(i, shield)
	_check(plan.is_all_valid(ms, _controller._player_states), "a simple walk-and-shield plan is valid")


## Round 2+: the plan from the bug report (Assassin: a move, two blade
## strikes, two waits) is fine, but a forgotten unaimed attack on another
## character used to grey out Submit with no explanation. Now Submit names
## the problem, jumps to it, and a second press goes without it.
func _check_submit_feedback() -> void:
	var tl := TimelineUI.new()
	_layer.add_child(tl)
	var units: Array[UnitData] = []
	for u in _controller._player_states:
		units.append((u as UnitState).unit_data)
	tl.setup(units)
	tl.bind(_controller._ms, _controller._player_states)
	var plan := tl.get_plan()
	var ms := _controller._ms
	var geo := ms.geometry()
	var alive := -1
	for i in _controller._player_states.size():
		if not _controller._player_states[i].is_bailed:
			alive = i
			break
	var other := -1
	for i in _controller._player_states.size():
		if i != alive and not _controller._player_states[i].is_bailed:
			other = i
			break
	if alive == -1 or other == -1:
		tl.queue_free()
		return
	var me: UnitState = _controller._player_states[alive]
	for k in 16:
		var dest := me.pos + Vector2.from_angle(TAU * k / 16.0) * 3.0
		if geo.ground_ok(dest) and bool(geo.route(me.pos, me.level, dest, 0)["ok"]):
			var mv := PlanAction.new(TriggerLibrary.get_move_card())
			mv.set_point(dest, 0)
			plan.add(alive, mv)
			break
	for card_name in ["Kogetsu", "Scorpion"]:
		var card := TriggerLibrary.get_card(card_name)
		if plan.get_available_actions(alive).has(card):
			var hit := PlanAction.new(card)
			hit.target_unit = 0
			plan.add(alive, hit)
	for _w in 2:
		plan.add(alive, PlanAction.new(TriggerLibrary.get_wait_card()), TurnPlan.ACT_LANE)
	tl.plan_edited()
	_check(tl.squad_problem().is_empty() and not tl._submit_button.disabled, "round 2: the reported plan can be submitted")
	var submitted := [0]
	tl.plan_submitted.connect(func() -> void: submitted[0] += 1)
	# A forgotten unaimed attack on another character.
	var weapon: TriggerCard = null
	for c in plan.get_available_actions(other):
		if c.card_type == TriggerCard.CardType.RANGED or c.card_type == TriggerCard.CardType.MELEE:
			weapon = c
			break
	plan.add(other, PlanAction.new(weapon))
	tl.plan_edited()
	var problem := tl.squad_problem()
	_check(int(problem.get("unit", -1)) == other and str(problem.get("text", "")).contains("no target"),
		"an unaimed attack on another character is found (%s)" % str(problem))
	_check(not tl._submit_button.disabled and tl._submit_button.tooltip_text.contains(units[other].unit_name),
		"Submit stays pressable and its tooltip names the character")
	_check(tl._guide.text.contains(units[other].unit_name), "the guide line names the character to fix")
	tl._on_submit_pressed()
	_check(submitted[0] == 0 and tl.get_current_unit() == other and tl.get_selected_action() != null
		and tl.get_selected_action().needs_target(), "first Submit jumps to the unfinished action instead of failing silently")
	tl._on_submit_pressed()
	_check(submitted[0] == 1 and plan.is_all_valid(ms, _controller._player_states) and plan.lane(alive, TurnPlan.ACT_LANE).size() >= 2,
		"second Submit goes without the unfinished action and keeps the rest")
	tl.queue_free()


## Tap a card, aim it on the board, the time it takes, tapping a character,
## refusing bad spots, and the lock.
func _check_planning_ui() -> void:
	_check(_controller._spotlight.is_active(), "the commanded character is spotlit")
	var plan := _timeline.get_plan()
	var u: UnitState = _controller._player_states[0]
	var geo := _controller._ms.geometry()
	_timeline._on_card_tapped(TriggerLibrary.get_move_card())
	var a := _timeline.get_selected_action()
	_check(a != null and a.card.card_name == "Move" and plan.lane(0, TurnPlan.MOVE_LANE).size() == 1,
		"tapping Move adds it to the Movement lane and selects it")
	_check(_timeline._missing_targets() == 1, "an unaimed move is counted as needing a target")
	var dest := Vector2.INF
	for k in 16:
		var p := u.pos + Vector2.from_angle(TAU * k / 16.0) * 4.0
		if geo.ground_ok(p) and geo.ground_clear(u.pos, p):
			dest = p
			break
	_controller._on_point_selected(dest, 0, -1)
	_check(a.has_point and a.point.distance_to(dest) < 0.02, "tapping the street aims the move")
	var t := plan.move_used(_controller._ms, u, 0)
	_check(absf(t - 4.0 / TurnPlan.speed(u.unit_data)) < 0.05, "the move takes distance / speed (%.2f s)" % t)
	_controller._on_point_selected(Vector2(9999, 9999), 0, -1)
	_check(a.point.distance_to(dest) < 0.02, "an impossible spot is refused (the old target stays)")
	_timeline._on_card_tapped(TriggerLibrary.get_look_card())
	_check(plan.lane(0, TurnPlan.ACT_LANE).size() == 1, "Look goes in the Actions lane")
	_timeline._add_wait(TurnPlan.MOVE_LANE)
	_check(plan.lane(0, TurnPlan.MOVE_LANE).size() == 2, "+ Wait adds a pause to the chosen lane")
	_timeline._on_block_remove(TurnPlan.MOVE_LANE, 1)
	_check(plan.lane(0, TurnPlan.MOVE_LANE).size() == 1, "removing a block takes it out of the lane")

	var ally: UnitState = _controller._player_states[1]
	_timeline._clear_selection()
	_controller._on_point_selected(ally.pos, ally.level, -1)
	_check(_timeline.get_current_unit() == 1, "tapping a character on the board commands it")
	_timeline.select_unit(0)
	_check_tap_enemy_label()

	# The live buzzer submits whatever is planned: half-made plans get cleaned.
	_timeline.begin_new_turn()
	plan = _timeline.get_plan()
	plan.add(0, PlanAction.new(TriggerLibrary.get_move_card()))   # never aimed
	for _k in 5:
		var swing := PlanAction.new(TriggerLibrary.get_card("Kogetsu"))
		swing.target_unit = 0
		plan.add(0, swing)                                         # too long
	_controller._sanitize_plan()
	_check(plan.is_all_valid(_controller._ms, _controller._player_states) and plan.lane(0, TurnPlan.ACT_LANE).size() >= 1,
		"the buzzer drops unaimed actions and trims lanes to fit the turn")

	_timeline.begin_new_turn()
	plan = _timeline.get_plan()
	_timeline.set_locked(true)
	_timeline._on_card_tapped(TriggerLibrary.get_move_card())
	_check(plan.lane(0, TurnPlan.MOVE_LANE).is_empty(), "a locked plan can't be edited")
	_timeline.set_locked(false)
	_timeline.begin_new_turn()


## Aiming an attack by tapping the enemy as drawn: its name label and its
## chest, not just the ground under its feet (the camera ray behind a
## standing figure lands meters away from its feet).
func _check_tap_enemy_label() -> void:
	var ei := -1
	for i in _controller._enemy_states.size():
		if not _controller._enemy_states[i].is_bailed:
			ei = i
			break
	_check(ei != -1, "an enemy is still in play to target")
	if ei == -1:
		return
	var enemy: UnitState = _controller._enemy_states[ei]
	var saved_fog := enemy.fog
	var saved_pos := enemy.pos
	var saved_level := enemy.level
	# Fogged enemies have no position in our view: put this one in sight
	# where it really stands.
	var real: UnitState = _controller._truth.teams[1 - _controller._team][ei]
	enemy.fog = Visibility.State.SIGHT
	enemy.pos = real.pos
	enemy.level = real.level
	var foot := Vector3(enemy.pos.x, HexCoord.GROUND_Y + enemy.level * HexCoord.FLOOR_HEIGHT, enemy.pos.y)
	# The game's view: orthographic, looking down the map at 50 degrees.
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 24.0
	add_child(cam)
	cam.look_at_from_position(foot + Vector3(0, sin(deg_to_rad(50.0)), cos(deg_to_rad(50.0))) * 40.0, foot)
	cam.make_current()
	for spot in [["name label", 2.3], ["chest", 0.95]]:
		_timeline.begin_new_turn()
		var weapon: TriggerCard = null
		for c in _controller._player_states[0].unit_data.main_trigger_slots:
			if c != null and (c as TriggerCard).card_type in [TriggerCard.CardType.MELEE, TriggerCard.CardType.RANGED]:
				weapon = c
				break
		_timeline._on_card_tapped(weapon)
		var a := _timeline.get_selected_action()
		var screen := cam.unproject_position(foot + Vector3(0, spot[1], 0))
		var hit := _board.pick(screen)
		var ground: Vector2 = hit.get("point", CityBoard.OFF_BOARD)
		_board.last_tap_screen = screen
		_controller._on_point_selected(ground, int(hit.get("level", 0)), int(hit.get("building", -1)))
		_board.last_tap_screen = Vector2.INF
		_check(a != null and a.is_attack() and a.target_unit == ei,
			"tapping an enemy's %s targets it (ground point %.1f m from its feet)" % [spot[0], ground.distance_to(enemy.pos)])
	enemy.fog = saved_fog
	enemy.pos = saved_pos
	enemy.level = saved_level
	cam.queue_free()
	_timeline.begin_new_turn()


## The rendered city's physics solids and the engine's line-of-sight rules
## must agree: fire real physics rays between random street points (eye
## height to body height) and compare with Visibility.has_los.
func _check_physics_matches_rules() -> void:
	for _i in 3:
		await get_tree().physics_frame
	var ms := _controller._ms
	var geo := ms.geometry()
	var space := _board.get_world_3d().direct_space_state
	var b := ms.bounds()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var tested := 0
	var agree := 0
	var mismatch := ""
	for _i in 4000:
		var a := Vector2(rng.randf_range(b.position.x, b.end.x), rng.randf_range(b.position.y, b.end.y))
		var c := Vector2(rng.randf_range(b.position.x, b.end.x), rng.randf_range(b.position.y, b.end.y))
		if not geo.ground_ok(a) or not geo.ground_ok(c) or a.distance_to(c) > 20.0:
			continue
		var pa := Vector3(a.x, HexCoord.GROUND_Y + Visibility.EYE_HEIGHT * HexCoord.FLOOR_HEIGHT, a.y)
		var pb := Vector3(c.x, HexCoord.GROUND_Y + Visibility.BODY_HEIGHT * HexCoord.FLOOR_HEIGHT, c.y)
		var los := Visibility.has_los(ms, a, 0, c, 0)
		tested += 1
		if _ray_clear(space, pa, pb) == los:
			agree += 1
		else:
			# Lines through a wall's exact corner are a coin toss for any two
			# implementations: accept it if a 3 cm nudge gives the rules' answer.
			var side := (pb - pa).cross(Vector3.UP).normalized() * 0.03
			if _ray_clear(space, pa + side, pb + side) == los or _ray_clear(space, pa - side, pb - side) == los:
				agree += 1
			elif mismatch == "":
				mismatch = " first: %s->%s rules_los=%s" % [a, c, los]
	_check(tested > 200 and agree == tested, "3D physics raycasts agree with the sight rules (%d/%d)%s" % [agree, tested, mismatch])


func _ray_clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b, CityBuildings.COLLISION_LAYER)).is_empty()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok: ", label)
	else:
		_failed = true
		printerr("  FAIL: ", label)
