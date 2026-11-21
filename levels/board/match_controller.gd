class_name MatchController
extends Node
## Orchestrates a match in two modes:
##   LOCAL  — vs the built-in enemy AI. The real match lives in `_truth`, a
##            copy the player never sees; each turn is recorded exactly like
##            the server does (MatchRunner.record_turn) and only our team's
##            fog-filtered frames reach the board. So local play and online
##            play run the same pipeline, and the planning UI can't leak
##            hidden enemies in either.
##   ONLINE — the server resolves turns; we submit plans and replay the
##            frames it sends (async polling, or pushed over the live channel
##            with a short turn clock: whatever is planned when it runs out is
##            locked in automatically).
##
## `_ms` is always our team's view: our characters exactly, enemies where we
## see them, radar ghosts for the rest (unseen enemies are parked OFFBOARD).

const POLL_INTERVAL := 1.0
const MATCH_SEED := 12345
## Where hidden enemies are parked in the client's MatchState, so nothing in
## the planning UI can use their real position.
const OFFBOARD := Vector2(100000, 100000)
## Tapping within this distance of a character picks it.
const PICK_RADIUS := 0.9

var _board: CityBoard
var _timeline: TimelineUI
var _event_log: EventLogUI
var _units_view: BoardUnits
var _camera: BoardCamera

var _player_states: Array[UnitState] = []
var _enemy_states: Array[UnitState] = []
var _enemy_data: Array[UnitData] = []
var _data_teams: Array = []   # [team 0 UnitData squad, team 1 UnitData squad]
var _ms: MatchState           # our view of the match
var _truth: MatchState        # local mode: the real match (never shown)
var _truth_turn_salt := 0
var _enemy_plan: TurnPlan
var _resolving := false
var _turn := 1
var _hover_point := Vector2.INF
var _hover_level := 0

# Online mode
var _online := false
var _backend: HttpBackend
var _match_id := ""
var _team := 0
var _token := ""

# Live mode (ONLINE + MatchSession.live)
## Seconds before the server deadline at which the current plan auto-locks.
const LIVE_AUTO_LOCK_SEC := 1.5
var _live: LiveClient
var _live_deadline_ms := -1
var _live_queue: Array[Dictionary] = []
var _live_replaying := false
var _live_over: Dictionary = {}
var _opponent_online := true
var _opponent_locked := false
var _over_shown := false
var _clock_label: Label

# Surrender (all modes): two taps within SURRENDER_CONFIRM_MS.
const SURRENDER_CONFIRM_MS := 3000
var _surrender_btn: Button
var _surrender_armed_until := 0

# Match-over / waiting overlay
var _overlay: Control
var _result_label: Label
var _turn_info: Label
var _btn_row: HBoxContainer
var _rematch_btn: Button
var _hangar_btn: Button
var _prediction_label: Label

# Focus on the character being commanded.
## Camera zoom (ortho size) when a character is selected.
const FOCUS_SIZE := 13.0
var _spotlight: Spotlight
var _markers: SquadMarkers


func setup(board: CityBoard, timeline: TimelineUI, event_log: EventLogUI, ui_layer: CanvasLayer, camera: BoardCamera = null) -> void:
	_board = board
	_timeline = timeline
	_event_log = event_log
	_camera = camera

	_units_view = BoardUnits.new()
	_units_view.name = "BoardUnits"
	_board.add_child(_units_view)

	_spotlight = Spotlight.new()
	_spotlight.name = "Spotlight"
	_spotlight.camera = camera
	ui_layer.add_child(_spotlight)
	ui_layer.move_child(_spotlight, 0)   # under every HUD panel
	_markers = SquadMarkers.new()
	_markers.name = "SquadMarkers"
	_markers.camera = camera
	ui_layer.add_child(_markers)
	ui_layer.move_child(_markers, 1)     # over the spotlight, under the HUD
	_markers.unit_tapped.connect(func(i: int) -> void:
		if not _resolving and not _over_shown:
			_timeline.select_unit(i)
		else:
			_focus_camera_only(i))

	_build_prediction_label(ui_layer)
	_build_overlay(ui_layer)
	_build_surrender_button(ui_layer)

	_board.point_selected.connect(_on_point_selected)
	_board.point_hovered.connect(_on_point_hovered)
	_timeline.plan_submitted.connect(_on_plan_submitted)
	_timeline.unit_selected.connect(_on_unit_selected)
	_timeline.selection_changed.connect(_update_targeting)

	_online = MatchSession.mode == MatchSession.Mode.ONLINE
	if _online:
		_setup_online()
	else:
		_start_match()


# --- Match Setup ------------------------------------------------------------

## Resets to a fresh local match (also used by the Rematch button).
func _start_match() -> void:
	var player_data := SquadStore.get_squad()
	_enemy_data = TriggerLibrary.sample_units()
	for u in _enemy_data:
		u.ensure_slot_arrays()
	_data_teams = [player_data, _enemy_data]
	# A new seed every match: the play area, start positions, and hit rolls
	# all differ each time.
	var seed := randi() & 0x7FFFFFFF
	var section := MapData.random_section(seed)
	_truth = MatchRunner.build_match(player_data, _enemy_data, seed, section)
	_truth_turn_salt = randi()
	_build_view(player_data, _enemy_data, seed, section)
	_apply_view(Visibility.encode_view(_truth, _team, _salt(0), true))
	_build_board_view()
	_board.clear_overlays()
	_units_view.clear_ghost()
	if _prediction_label != null:
		_prediction_label.visible = false
	_turn = 1
	_over_shown = false
	_live_over = {}
	_reset_surrender_button()
	_overlay.visible = false
	_btn_row.visible = true
	_event_log.set_turn(_turn)
	_event_log.clear()
	_event_log.add_message("Match started — plan your turn (%.0f seconds per character)." % TurnPlan.TURN_SECONDS, Color(0.6, 0.9, 0.6))
	_timeline.setup(_data_teams[_team])
	_timeline.bind(_ms, _player_states)
	_timeline.set_locked(false)
	_sync_unit_status()
	_timeline.begin_new_turn()
	_focus_unit(_timeline.get_current_unit())


## Our view of a match built from the same squads, map and seed (positions
## are then overwritten by the views we receive).
func _build_view(squad0: Array, squad1: Array, seed: int, section: Rect2i) -> void:
	var a: Array[UnitData] = []
	a.assign(squad0)
	var b: Array[UnitData] = []
	b.assign(squad1)
	_ms = MatchRunner.build_match(a, b, seed, section)
	_player_states = _ms.teams[_team]
	_enemy_states = _ms.teams[1 - _team]


## Local radar salt for frame `n` of the current turn (secret, like the server's).
func _salt(n: int) -> int:
	return hash([_truth_turn_salt, _turn, n])


## Builds the map, props, and unit markers for _ms and frames the camera.
func _build_board_view() -> void:
	_board.set_map(_ms.tiles, _ms.bounds())
	_board.set_buildings(_ms.buildings)
	_board.set_wires(_ms.wires)
	_units_view.setup(_ms.all_units(), _board.hex_size)
	_units_view.set_map_bounds(_ms.bounds())
	_units_view.refresh()
	_markers.view = _units_view
	_markers.set_units(_player_states)
	_markers.visible = true
	if _camera != null:
		_camera.set_bounds(_board.get_bounds())


func _setup_online() -> void:
	_match_id = MatchSession.match_id
	_team = MatchSession.team
	_token = MatchSession.token
	_backend = HttpBackend.new()
	_backend.name = "HttpBackend"
	_backend.server_url = MatchSession.server_url
	add_child(_backend)

	_show_waiting("Connecting to server…")
	var info := await _backend.get_match(_match_id, _token)
	if not info.get("success", false):
		_show_waiting("Could not reach server:\n%s" % str(info.get("error", "?")))
		return
	var body: Dictionary = info["body"]
	# Host waits for an opponent to join.
	if not bool(body.get("ready", false)):
		_show_waiting("Waiting for opponent to join…\nMatch ID: %s" % _match_id)
		while true:
			await get_tree().create_timer(POLL_INTERVAL).timeout
			var poll := await _backend.get_match(_match_id, _token)
			if poll.get("success", false) and bool(poll["body"].get("ready", false)):
				body = poll["body"]
				break

	var teams: Array = body.get("teams", [])
	var squad0 := PlanCodec.decode_squad(teams[0]) if teams.size() > 0 and teams[0] != null else []
	var squad1 := PlanCodec.decode_squad(teams[1]) if teams.size() > 1 and teams[1] != null else []
	_data_teams = [squad0, squad1]
	# The server sends the play area; positions come from the fogged view.
	_build_view(squad0, squad1, MATCH_SEED, MapData.section_from(body.get("map")))
	var view: Variant = body.get("view")
	if view is Dictionary:
		_apply_view(view)
	_build_board_view()

	_timeline.setup(_data_teams[_team])
	_timeline.bind(_ms, _player_states)
	_sync_unit_status()
	_turn = int(body.get("turn", 1))
	_overlay.visible = false
	_btn_row.visible = true
	_event_log.set_turn(_turn)
	_event_log.clear()
	_event_log.add_message("Online match %s — you are team %d." % [_match_id, _team], Color(0.6, 0.9, 0.6))
	var winner := int(body.get("winner", -1))
	if winner != -1:
		_show_match_over(winner)
		return
	_timeline.set_locked(false)
	_timeline.begin_new_turn()
	_focus_unit(_timeline.get_current_unit())
	if MatchSession.live:
		_start_live(body)


# --- Targeting from the board --------------------------------------------------

func _on_point_selected(p: Vector2, level: int, building: int) -> void:
	if _resolving or _over_shown:
		return
	var sel := _timeline.get_selection()
	var a: PlanAction = sel.get("action")
	# Attacks: tap an enemy (one we know about).
	if a != null and a.is_attack():
		var enemy := _enemy_near(p)
		if enemy != -1:
			a.target_unit = enemy
			_timeline.plan_edited()
			return
	# Tapping one of your characters commands it (unless placing a point).
	var own := _own_near(p)
	if own != -1 and (a == null or not (a.needs_target() and _wants_point(a))):
		if own != _timeline.get_current_unit():
			_timeline.select_unit(own)
		else:
			_focus_unit(own)
		return
	if a == null or not _wants_point(a):
		if a != null and a.is_attack():
			_timeline.flash("Tap an enemy you can see (or a radar ping) to target it.")
		return
	_place_point(a, p, level, building)


## Sets a Move / Jump / Look / Spider target, refusing spots it can't use.
func _place_point(a: PlanAction, p: Vector2, level: int, building: int) -> void:
	var unit := _timeline.get_current_unit()
	var us := _player_states[unit]
	var geo := _ms.geometry()
	var target_level := 0
	if TurnPlan.is_move_card(a.card):
		target_level = level
		# Tapping the same building again walks down its floors (Move only).
		if not a.card.jump and building >= 0 and a.has_point and a.level > 1 \
				and geo.rect_at(a.point) == geo.rect_at(p) and geo.rect_at(p) != -1:
			target_level = a.level - 1
		if not geo.level_ok(p, target_level):
			_timeline.flash("Nobody can stand there.")
			return
	else:
		target_level = 0
	if a.card.card_name == "Spider" and not geo.ground_ok(p):
		_timeline.flash("Spider wires go on the street.")
		return
	var old := a.duplicate_action()
	a.set_point(p, target_level)
	var plan := _timeline.get_plan()
	if TurnPlan.is_move_card(a.card):
		for e in plan.move_schedule(_ms, us, unit):
			if e["action"] == a and not bool(e["ok"]):
				_restore(a, old)
				_timeline.flash("Can't get there%s." % (" (jumps reach %.1f m)" % CityGeometry.JUMP_RANGE if a.card.jump else ""))
				return
		if plan.move_used(_ms, us, unit) > TurnPlan.TURN_SECONDS + TurnPlan.TIME_EPSILON:
			var need := plan.move_used(_ms, us, unit)
			_restore(a, old)
			_timeline.flash("Too far for this turn (needs %.1f s of %.0f)." % [need, TurnPlan.TURN_SECONDS])
			return
	_timeline.plan_edited()


func _restore(a: PlanAction, old: PlanAction) -> void:
	a.point = old.point
	a.level = old.level
	a.has_point = old.has_point


static func _wants_point(a: PlanAction) -> bool:
	return TurnPlan.is_move_card(a.card) or a.card.card_name == "Look" or a.card.card_name == "Spider"


func _own_near(p: Vector2) -> int:
	var best := -1
	var best_d := PICK_RADIUS
	for i in _player_states.size():
		var u := _player_states[i]
		if not u.is_bailed and u.pos.distance_to(p) <= best_d:
			best_d = u.pos.distance_to(p)
			best = i
	return best


## Index of the known enemy (in sight or a radar ping) nearest `p`, or -1.
func _enemy_near(p: Vector2) -> int:
	var best := -1
	var best_d := PICK_RADIUS * 1.5
	for i in _enemy_states.size():
		var e := _enemy_states[i]
		if e.is_bailed:
			continue
		var at := _known_pos(e)
		if at == OFFBOARD:
			continue
		var d := at.distance_to(p)
		if d <= best_d:
			best_d = d
			best = i
	return best


## Where we believe an enemy is: exact in sight, the ping on radar, else OFFBOARD.
func _known_pos(e: UnitState) -> Vector2:
	if e.fog == Visibility.State.SIGHT and e.pos != OFFBOARD:
		return e.pos
	if e.fog == Visibility.State.RADAR:
		return e.ping_pos
	return OFFBOARD


func _on_point_hovered(p: Vector2, level: int) -> void:
	_hover_point = p
	_hover_level = level
	var a := _timeline.get_selected_action()
	if a != null and a.needs_target():
		_update_targeting()


# --- Planning previews --------------------------------------------------------

func _on_unit_selected(i: int) -> void:
	_focus_unit(i)


## Zooms the camera onto character `i` and lights it up.
func _focus_unit(i: int) -> void:
	if i < 0 or i >= _player_states.size() or _player_states[i].is_bailed:
		return
	var u := _player_states[i]
	if _camera != null:
		_camera.focus_on(_board.world_at(u.pos, u.level), minf(_camera.size, FOCUS_SIZE))
	_update_targeting()


func _focus_camera_only(i: int) -> void:
	if _camera == null or i < 0 or i >= _player_states.size():
		return
	var u := _player_states[i]
	if not u.is_bailed:
		_camera.focus_on(_board.world_at(u.pos, u.level))


func _sync_unit_status() -> void:
	for i in _player_states.size():
		var u := _player_states[i]
		_timeline.set_unit_status(i, u.trion_hp, u.unit_data.base_trion_hp, u.is_bailed)


## Redraws every planning preview for the selected character: its routes,
## the selected action's reach, where it will be and look, the spotlight,
## and the squad's vision.
func _update_targeting() -> void:
	_board.clear_overlays()
	if _resolving or _over_shown or _player_states.is_empty():
		_units_view.clear_ghost()
		_units_view.clear_vision()
		_spotlight.clear()
		_units_view.hide_squad_vision()
		if _prediction_label != null:
			_prediction_label.visible = false
		return
	var idx := _timeline.get_current_unit()
	if idx < 0 or idx >= _player_states.size():
		return
	var u := _player_states[idx]
	_units_view.set_selected(u)
	_markers.selected = idx
	var plan := _timeline.get_plan()
	var sched := plan.move_schedule(_ms, u, idx)
	var color := BoardUnits.team_color(u.team).lerp(Color.WHITE, 0.3)
	# Planned routes, with a marker at each stop.
	for e in sched:
		if not bool(e["ok"]) or (e["segments"] as Array).is_empty():
			continue
		var pts: Array = []
		for s in e["segments"]:
			pts.append(_board.world_at(s["from"], int(s["l0"])))
			pts.append(_board.world_at(s["to"], int(s["l1"])))
		_board.add_path(pts, Color(color, 0.75))
		_board.add_marker(e["to_pos"], int(e["to_level"]), Color(color, 0.8), 0.3)
	var sel := _timeline.get_selection()
	var a: PlanAction = sel.get("action")
	# When the selected action happens, and where the character is then.
	var t := _action_time(plan, idx, sel)
	var at := TurnPlan.position_at(sched, u, t, u.unit_data)
	var pos: Vector2 = at["pos"]
	var lvl: int = at["level"]
	var facing := _facing_at(plan, idx, sched, t)
	# Preview the spot being aimed at (hover) for moves.
	if a != null and a.needs_target() and TurnPlan.is_move_card(a.card) and _hover_point != Vector2.INF:
		_units_view.show_ghost(u, _hover_point, _hover_level, (_hover_point - pos).angle())
	elif a != null and TurnPlan.is_move_card(a.card) and a.has_point:
		_units_view.show_ghost(u, a.point, a.level)
	else:
		_units_view.clear_ghost()
	_draw_reach(a, pos, lvl, color)
	# Vision where (and how) it will be when the action happens.
	var own_rect: Dictionary = {}
	if _ms.geometry().is_inside(pos, lvl):
		var ri := _ms.geometry().rect_at(pos)
		if ri != -1:
			own_rect = _ms.building_rects()[ri]
	_units_view.show_vision(u, pos, lvl, facing, own_rect)
	_update_squad_vision(idx)
	_spotlight.focus_shape(_units_view.vision_center(), _units_view.vision_outline())
	_update_prediction(a, u, pos, lvl)


## Start time of the selected action (its end for attacks, which fire then);
## the end of the plan's movement when nothing is selected.
func _action_time(plan: TurnPlan, idx: int, sel: Dictionary) -> float:
	var u := _player_states[idx]
	if sel.is_empty():
		return plan.move_used(_ms, u, idx)
	var lane_id: int = sel["lane"]
	var i: int = sel["index"]
	var sched := plan.move_schedule(_ms, u, idx) if lane_id == TurnPlan.MOVE_LANE else plan.act_schedule(idx)
	if i >= sched.size():
		return 0.0
	var a: PlanAction = sel["action"]
	return float(sched[i]["end"]) if a.is_attack() or lane_id == TurnPlan.MOVE_LANE else float(sched[i]["start"])


## Facing at time `t`: the last Look before it, else the direction of travel,
## else the current facing.
func _facing_at(plan: TurnPlan, idx: int, sched: Array, t: float) -> float:
	var u := _player_states[idx]
	var facing := u.facing
	var watch := Vector2.INF
	for e in plan.act_schedule(idx):
		var a: PlanAction = e["action"]
		if a.card.card_name == "Look" and a.has_point and float(e["end"]) <= t + 0.001:
			watch = a.point
	var at := TurnPlan.position_at(sched, u, t, u.unit_data)
	if watch != Vector2.INF:
		var d: Vector2 = watch - (at["pos"] as Vector2)
		return d.angle() if d.length() > 0.001 else facing
	var dir: Vector2 = at["moving_dir"]
	if dir != Vector2.ZERO:
		return dir.angle()
	# Stopped: the direction of the last leg walked before t.
	for e in sched:
		if bool(e["ok"]) and float(e["end"]) <= t + 0.001 and not (e["segments"] as Array).is_empty():
			var s: Dictionary = (e["segments"] as Array).back()
			var d: Vector2 = (s["to"] as Vector2) - (s["from"] as Vector2)
			if d.length() > 0.001:
				facing = d.angle()
	return facing


## Range circle for the selected action, drawn where it will happen.
func _draw_reach(a: PlanAction, pos: Vector2, lvl: int, color: Color) -> void:
	if a == null:
		return
	var reach := 0.0
	if a.is_attack():
		reach = TurnEngine.MELEE_RANGE if a.card.card_type == TriggerCard.CardType.MELEE else a.card.attack_range
	elif a.card.jump:
		reach = CityGeometry.JUMP_RANGE
	elif a.card.card_name == "Spider":
		reach = TurnEngine.SPIDER_RANGE
	if reach > 0.0:
		_board.add_range(pos, lvl, reach, Color(1.0, 0.6, 0.3, 0.8))
	if a.is_attack() and a.target_unit >= 0 and a.target_unit < _enemy_states.size():
		var tp := _known_pos(_enemy_states[a.target_unit])
		if tp != OFFBOARD:
			_board.add_marker(tp, _enemy_states[a.target_unit].level, Color(1.0, 0.4, 0.3, 0.9), 0.55)
	if a.has_point and not TurnPlan.is_move_card(a.card):
		_board.add_marker(a.point, 0, Color(color, 0.9), 0.4)


## Faint vision for every other living character in the squad.
func _update_squad_vision(selected_idx: int) -> void:
	var entries: Array = []
	for i in _player_states.size():
		var u := _player_states[i]
		if i == selected_idx or u.is_bailed:
			continue
		var own_rect: Dictionary = {}
		if _ms.geometry().is_inside(u.pos, u.level):
			var ri := _ms.geometry().rect_at(u.pos)
			if ri != -1:
				own_rect = _ms.building_rects()[ri]
		entries.append({ "unit": u, "pos": u.pos, "level": u.level, "facing": u.facing, "own_rect": own_rect })
	_units_view.show_squad_vision(entries)


## Hit-chance readout for the selected attack against its target (or the
## enemy under the pointer), from where the attacker will be when it fires.
func _update_prediction(a: PlanAction, u: UnitState, pos: Vector2, lvl: int) -> void:
	if _prediction_label == null:
		return
	_prediction_label.visible = false
	if a == null or not a.is_attack():
		return
	var ti := a.target_unit
	if ti < 0 and _hover_point != Vector2.INF:
		ti = _enemy_near(_hover_point)
	if ti < 0 or ti >= _enemy_states.size():
		return
	var target := _enemy_states[ti]
	var tp := _known_pos(target)
	if tp == OFFBOARD:
		return
	var dist := pos.distance_to(tp)
	var melee := a.card.card_type == TriggerCard.CardType.MELEE
	var reach := TurnEngine.MELEE_RANGE if melee else a.card.attack_range
	var text := "%s » %s: %.1f m (reach %.1f m)" % [a.card.card_name, target.unit_data.unit_name, dist, reach]
	if dist > reach:
		text += "  ·  out of reach from there"
	elif not melee and not a.card.curved and not Visibility.has_los(_ms, pos, lvl, tp, target.level):
		text += "  ·  no clear line"
	else:
		var probe := TurnEngine.new()
		probe._ms = _ms
		var ghost := UnitState.new(u.unit_data, u.team, pos, (tp - pos).angle())
		ghost.level = lvl
		var chance := probe.hit_chance(ghost, target, a.card)
		text += "  ·  %d%% to hit, %d damage before shields" % [roundi(chance * 100.0), u.unit_data.attack_rating + a.card.power]
	if target.fog != Visibility.State.SIGHT:
		text += "  ·  (radar only: must be seen when it fires)"
	_prediction_label.text = text
	_prediction_label.visible = true


# --- Submit / Resolve -------------------------------------------------------

## Makes the plan submittable as it stands (the live buzzer): drops actions
## that were never aimed or can't be walked, then trims each lane from the
## end until it fits the turn. What the player did plan still happens.
func _sanitize_plan() -> void:
	_timeline.get_plan().sanitize(_ms, _player_states)
	_timeline.plan_edited()


func _on_plan_submitted() -> void:
	if _resolving:
		return
	_resolving = true
	_timeline.set_locked(true)
	if _live != null:
		_submit_live()
	elif _online:
		await _submit_online()
	else:
		await _submit_local()


## Local turn: the AI plans on the real match, the turn is recorded like the
## server does it, and we replay our team's view of it.
func _submit_local() -> void:
	_build_enemy_plan()
	var plans := [_timeline.get_plan(), _enemy_plan] if _team == 0 else [_enemy_plan, _timeline.get_plan()]
	var frames := MatchRunner.record_turn(_truth, plans[0], plans[1], func(n: int) -> int: return _salt(n))
	var winner := await _replay_frames(frames[_team])
	winner = MatchRunner.winner(_truth)
	_after_resolution(winner)


func _submit_online() -> void:
	var plan_dict := PlanCodec.encode_plan(_timeline.get_plan())
	var submit := await _backend.submit_plan(_match_id, _token, _turn, plan_dict)
	# 409 = stale turn (e.g. the server auto-resolved while we were away):
	# fall through to catch-up instead of failing.
	if not submit.get("success", false) and int(submit.get("status", 0)) != 409:
		_show_waiting("Submit failed:\n%s" % str(submit.get("error", "?")))
		_resolving = false
		_timeline.set_locked(false)
		return

	_show_waiting("Plan submitted.\nWaiting for opponent…")
	var poll := await _poll_for_result()
	if poll.is_empty():
		if is_inside_tree():
			_show_waiting("This match is no longer available.")
			_btn_row.visible = true
		_resolving = false
		return
	_overlay.visible = false

	var body: Dictionary = poll["body"]
	var winner := await _catch_up(body)
	if winner == -1:
		# Ended without a new turn result (e.g. the opponent forfeited).
		winner = int(body.get("winner", -1))
	_after_resolution(winner)
	if winner != -1 and bool(body.get("ranked", false)):
		var delta := int((body.get("rating_change", [0, 0]) as Array)[_team])
		_turn_info.text += "\nRanked: rating %+d" % delta
		_event_log.add_message("Rating %+d" % delta, Color(0.6, 0.85, 1.0))


## Waits for the turn's result. Correspondence turns can take hours, so this
## never gives up on its own: it polls slower over time, rides out network
## blips ("Reconnecting…"), and only stops for an answer the server will not
## change (the match or our seat is gone).
func _poll_for_result() -> Dictionary:
	var polls := 0
	var failures := 0
	while is_inside_tree():
		var wait := POLL_INTERVAL if polls < 60 else (5.0 if polls < 300 else 15.0)
		await get_tree().create_timer(wait).timeout
		if not is_inside_tree():
			break
		polls += 1
		var resp := await _backend.get_match(_match_id, _token, _turn)
		if not resp.get("success", false):
			var status := int(resp.get("status", 0))
			if status == 404 or status == 403:
				return {}
			failures += 1
			if failures == 3:
				_show_waiting("Connection lost.\nReconnecting…")
			continue
		if failures >= 3:
			_show_waiting("Plan submitted.\nWaiting for opponent…")
		failures = 0
		var b: Dictionary = resp["body"]
		if int(b.get("winner", -1)) != -1:
			return resp
		var result: Variant = b.get("result")
		if result is Dictionary and int(result.get("turn", -1)) >= _turn:
			return resp
	return {}


## Replays every server result from our current turn onward (more than one if
## turns were auto-resolved while we weren't polling). Returns the winner.
func _catch_up(body: Dictionary) -> int:
	var history: Array = body.get("history", [])
	var winner := -1
	for result in history:
		if int(result.get("turn", -1)) < _turn:
			continue
		_turn = int(result["turn"])
		_event_log.set_turn(_turn)
		winner = await _replay_frames(result.get("frames", []))
		if int(result.get("winner", -1)) != -1:
			winner = int(result["winner"])
			break
	return winner




## Replays one turn from its frames ({t, events, view}): the board glides
## from frame to frame in real time and events play at their moment. Returns
## the winner as far as our view can tell (the server's word comes after).
func _replay_frames(frames: Array) -> int:
	_begin_replay()
	await get_tree().create_timer(0.3).timeout
	var last_t := 0.0
	for i in frames.size():
		if not is_inside_tree():
			return -1
		var frame: Dictionary = frames[i]
		var t := float(frame.get("t", 0.0))
		var dt := maxf(0.0, t - last_t)
		last_t = t
		var before := {}
		for u in _ms.all_units():
			before[u] = { "fog": u.fog, "pos": u.pos }
		_apply_view(frame.get("view", {}))
		_board.set_wires(_ms.wires)
		var events: Array = frame.get("events", [])
		for ev in events:
			_event_log.add_event_dict(ev)
		_units_view.update_labels()
		_units_view.apply_fog()
		_sync_unit_status()
		for u in _ms.all_units():
			var was: Dictionary = before[u]
			if u.fog != Visibility.State.SIGHT or u.pos == OFFBOARD:
				continue
			if int(was["fog"]) != Visibility.State.SIGHT or was["pos"] == OFFBOARD or i == 0:
				_units_view.snap(u)
			else:
				_units_view.glide_to(u, _board.world_at(u.pos, u.level), u.facing, maxf(dt, 0.05))
		_present_frame_events(events)
		if dt > 0.0:
			await get_tree().create_timer(dt).timeout
	await get_tree().create_timer(0.25).timeout
	return MatchRunner.winner(_ms)


## Applies a view (Visibility.encode_view) to our MatchState. Unseen enemies
## are parked OFFBOARD; RADAR ones keep only a ping position.
func _apply_view(view: Dictionary) -> void:
	var units := _ms.all_units()
	var rows: Array = view.get("units", [])
	for i in mini(units.size(), rows.size()):
		var u: UnitState = units[i]
		var row: Dictionary = rows[i]
		u.fog = int(row.get("vis", Visibility.State.SIGHT))
		match u.fog:
			Visibility.State.SIGHT:
				var pos: Array = row.get("pos", [u.pos.x, u.pos.y])
				u.pos = Vector2(float(pos[0]), float(pos[1]))
				u.level = int(row.get("level", 0))
				u.facing = float(row.get("facing", u.facing))
				u.trion_hp = int(row.get("hp", u.trion_hp))
				u.is_bailed = bool(row.get("bailed", false))
				u.stealth_active = bool(row.get("stealth", false))
				u.weight_time = float(row.get("weight", 0.0))
				u.shield_active = bool(row.get("shield", false))
			Visibility.State.RADAR:
				var ping: Array = row.get("ping", [0, 0])
				u.ping_pos = Vector2(float(ping[0]), float(ping[1]))
				u.pos = OFFBOARD
			_:
				u.pos = OFFBOARD
	_ms.wires.clear()
	for w in view.get("wires", []):
		if w is Array and w.size() >= 3:
			_ms.wires.append({ "pos": Vector2(float(w[0]), float(w[1])), "team": int(w[2]) })


## Combat effects for one frame's events (cosmetic).
func _present_frame_events(events: Array) -> void:
	var by_name := {}
	for u in _ms.all_units():
		by_name[u.display_name()] = u
	var shown: Array = []
	for ev in events:
		shown.append({ "phase": int(ev.get("phase", -1)), "message": str(ev.get("message", "")),
			"actor": by_name.get(str(ev.get("actor", ""))), "target": by_name.get(str(ev.get("target", ""))),
			"damage": int(ev.get("damage", 0)) })
	_present_combat(shown)


func _begin_replay() -> void:
	_spotlight.clear()
	_units_view.hide_squad_vision()
	_event_log.clear()
	_board.clear_overlays()
	_units_view.clear_ghost()
	_units_view.clear_vision()
	_units_view.set_selected(null)
	if _prediction_label != null:
		_prediction_label.visible = false
	_event_log.add_message("Resolving turn %d…" % _turn, Color(0.7, 0.8, 1.0))


func _after_resolution(winner: int) -> void:
	if _over_shown:
		_resolving = false
		return
	if winner != -1:
		_show_match_over(winner)
		_resolving = false
		return
	_turn += 1
	if not _online:
		_apply_view(Visibility.encode_view(_truth, _team, _salt(0), true))
		_units_view.refresh()
		_board.set_wires(_ms.wires)
	_event_log.set_turn(_turn)
	_event_log.add_message("Turn %d — plan your next move." % _turn, Color(0.6, 0.9, 0.6))
	_resolving = false
	_timeline.set_locked(false)
	_sync_unit_status()
	_timeline.begin_new_turn()
	_focus_unit(_timeline.get_current_unit())


## Whether the local player currently sees `u` standing on the board.
func _on_board(u: UnitState) -> bool:
	return u != null and u.pos != OFFBOARD and (u.team == _team or u.fog == Visibility.State.SIGHT) and _units_view.has_marker(u)


# --- Combat presentation ------------------------------------------------------
# Purely cosmetic: turns one tick's visible events ({phase, message, actor,
# target, damage}; actor/target are UnitStates or null) into attack motions,
# tracers, slashes, shield flares, hit reactions, damage numbers, and camera
# shake. Attacks fire once the tick's movement has mostly played; nothing
# here changes how long a tick takes.

const ATTACK_DELAY := 0.2
const BLADE_COLOR := Color(0.75, 1.0, 0.9)
const MISS_COLOR := Color(0.8, 0.84, 0.9)
const GUARD_COLOR := Color(0.55, 0.9, 1.0)

var _present_serial := 0


func _present_combat(events: Array) -> void:
	_present_serial += 1
	var serial := _present_serial
	var fx: BoardFx = _units_view.fx
	if fx == null:
		return
	var attackers := {}   # target UnitState -> world position the hit came from
	var attacks: Array = []
	var results: Array = []
	for ev in events:
		var actor: UnitState = ev["actor"]
		var target: UnitState = ev["target"]
		var message: String = ev["message"]
		match int(ev["phase"]):
			CombatEvent.Phase.STATE:
				if _on_board(actor) and message.contains("Bagworm"):
					fx.ground_pulse(_units_view.chest_pos(actor) - Vector3(0, 0.9, 0), Color(0.6, 0.7, 1.0))
			CombatEvent.Phase.DEFENSE:
				if _on_board(actor):
					fx.shield_flash(_units_view.chest_pos(actor), Vector3.ZERO, GUARD_COLOR, true)
			CombatEvent.Phase.ATTACK:
				if actor != null and target != null and actor != target and actor.team != target.team:
					attacks.append(ev)
			CombatEvent.Phase.RESOLUTION:
				if target != null and (int(ev["damage"]) > 0 or message.contains("weighed down")):
					results.append(ev)
	if attacks.is_empty() and results.is_empty():
		return
	await get_tree().create_timer(ATTACK_DELAY).timeout
	if serial != _present_serial or not is_inside_tree():
		return   # a newer tick (or a scene change) took over
	var impact_delay := 0.0
	for ev in attacks:
		var actor: UnitState = ev["actor"]
		var target: UnitState = ev["target"]
		var message: String = ev["message"]
		if not _on_board(actor) or not _on_board(target):
			continue   # one side is in the fog: no line drawn back to a hidden shooter
		var from := _units_view.chest_pos(actor)
		var to := _units_view.chest_pos(target)
		var card := _card_in_message(message)
		var melee := actor.pos.distance_to(target.pos) <= TurnEngine.MELEE_RANGE + 0.3 and actor.level == target.level
		if card != null:
			melee = card.card_type == TriggerCard.CardType.MELEE
		var heavy := card != null and card.power >= 6
		var missed := message.contains("misses")
		var color := BoardUnits.team_color(actor.team)
		attackers[target] = from
		_units_view.play_attack(actor, to, melee)
		if melee:
			fx.slash(to, to - from, BLADE_COLOR.lerp(color, 0.35), heavy)
		else:
			var aim := to
			if missed:
				var side := (to - from).cross(Vector3.UP).normalized()
				aim = to + side * 0.55 + Vector3(0, 0.25, 0) + (to - from).normalized() * 1.5
			fx.muzzle_flash(from + (to - from).normalized() * 0.35, color, heavy)
			var arc := 0.0
			if card != null and card.curved:
				arc = 1.0
			elif card != null and card.homing:
				arc = 0.45
			impact_delay = maxf(impact_delay, fx.tracer(from, aim, color, arc, heavy))
		if missed:
			fx.popup(_units_view.head_pos(target), "MISS", MISS_COLOR)
		elif message.contains("mitigated") and not message.contains("mitigated 0.0"):
			fx.shield_flash(to, from - to, GUARD_COLOR)
	if results.is_empty():
		return
	if impact_delay > 0.0:
		await get_tree().create_timer(impact_delay).timeout
		if serial != _present_serial or not is_inside_tree():
			return
	var worst := 0
	for ev in results:
		var target: UnitState = ev["target"]
		if not _units_view.has_marker(target):
			continue
		var damage := int(ev["damage"])
		var at := _units_view.chest_pos(target)
		var from_dir := Vector3.ZERO
		if attackers.has(target):
			from_dir = (attackers[target] as Vector3) - at
		if damage <= 0:
			fx.popup(_units_view.head_pos(target), "WEIGHTED", Color(0.75, 0.75, 0.85))
			fx.ground_pulse(at - Vector3(0, 0.9, 0), Color(0.6, 0.6, 0.7))
			continue
		if target.is_bailed:
			_units_view.play_bail(target)
			fx.popup(_units_view.head_pos(target), "BAIL OUT", Color(1.0, 0.9, 0.5), true)
			worst = maxi(worst, 12)
		elif _on_board(target):
			_units_view.flash_hit(target, from_dir)
			fx.impact(at, BoardUnits.team_color(1 - target.team), damage >= 8)
			fx.popup(_units_view.head_pos(target), "-%d" % damage, Color(1.0, 0.5, 0.4), damage >= 8)
			worst = maxi(worst, damage)
	if worst > 0 and _camera != null:
		_camera.shake(clampf(worst / 12.0, 0.25, 1.0))

## The trigger named in an attack message ("... with Asteroid for 5"), or null.
func _card_in_message(message: String) -> TriggerCard:
	if message.contains("Lead Bullet"):
		return TriggerLibrary.get_card("Lead Bullet")
	for card in TriggerLibrary.all_cards():
		if message.contains(" with %s " % card.card_name):
			return card
	return null


# --- Targeting / Camera -----------------------------------------------------

func _build_prediction_label(ui_layer: CanvasLayer) -> void:
	_prediction_label = Label.new()
	_prediction_label.name = "PredictionLabel"
	_prediction_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prediction_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prediction_label.add_theme_font_size_override("font_size", 16)
	_prediction_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prediction_label.visible = false
	ui_layer.add_child(_prediction_label)
	_fit_prediction_label()
	get_viewport().size_changed.connect(_fit_prediction_label)


func _fit_prediction_label() -> void:
	if _prediction_label == null:
		return
	var vs := get_viewport().get_visible_rect().size
	_prediction_label.position = Vector2(0, TimelineUI.TOP_BAR_HEIGHT + 4.0)
	_prediction_label.size = Vector2(vs.x, 34)


# --- Match-Over / Waiting Overlay ------------------------------------------

func _build_overlay(ui_layer: CanvasLayer) -> void:
	_overlay = Control.new()
	_overlay.name = "MatchOverlay"
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.visible = false
	_fit_overlay()
	get_viewport().size_changed.connect(_fit_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.14, 0.95)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	_result_label = Label.new()
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 44)
	vbox.add_child(_result_label)

	_turn_info = Label.new()
	_turn_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_info.add_theme_font_size_override("font_size", 18)
	_turn_info.modulate = Color(0.8, 0.85, 0.9)
	vbox.add_child(_turn_info)

	_btn_row = HBoxContainer.new()
	_btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(_btn_row)

	_rematch_btn = Button.new()
	_rematch_btn.text = "Rematch"
	_rematch_btn.pressed.connect(_start_match)
	_btn_row.add_child(_rematch_btn)

	_hangar_btn = Button.new()
	_hangar_btn.text = "Return to Hangar"
	_hangar_btn.pressed.connect(func() -> void:
		UiTheme.change_scene(get_tree(), "res://ui/hangar/hangar.tscn"))
	_btn_row.add_child(_hangar_btn)

	ui_layer.add_child(_overlay)


func _fit_overlay() -> void:
	if _overlay == null:
		return
	_overlay.position = Vector2.ZERO
	_overlay.size = get_viewport().get_visible_rect().size


func _show_waiting(text: String) -> void:
	_result_label.text = "Waiting…"
	_result_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	_turn_info.text = text
	_btn_row.visible = false
	_overlay.visible = true


func _show_match_over(winner: int) -> void:
	if _over_shown:
		return
	_over_shown = true
	_spotlight.clear()
	_markers.visible = false
	_units_view.hide_squad_vision()
	var won := winner == _team
	var draw := winner == MatchRunner.DRAW
	_result_label.text = "DRAW" if draw else ("VICTORY" if won else "DEFEAT")
	_result_label.add_theme_color_override("font_color",
		Color(0.85, 0.85, 0.6) if draw else (Color(0.4, 0.95, 0.5) if won else Color(1.0, 0.4, 0.4)))
	_turn_info.text = "Match ended after %d turns" % _turn
	if not _live_over.is_empty():
		_turn_info.text += _live_result_text(_live_over)
	if _clock_label != null:
		_clock_label.visible = false
	_surrender_btn.visible = false
	# Rematch replays the local AI match; online matches go back to the Hangar.
	_rematch_btn.visible = not _online
	_btn_row.visible = true
	_overlay.visible = true
	_timeline.set_locked(true)
	_board.clear_overlays()
	_units_view.clear_ghost()
	if _prediction_label != null:
		_prediction_label.visible = false
	_event_log.add_message(
		"Match over — %s!" % ("Draw" if draw else ("Victory" if won else "Defeat")),
		Color(0.4, 0.95, 0.5) if won else Color(1.0, 0.4, 0.4))


# --- Live Mode ----------------------------------------------------------------
# Live ranked / friendly matches: the server runs a short turn clock and
# pushes results over the live WebSocket. The client mirrors the clock,
# auto-locks the current plan just before it runs out, and replays pushed
# results in order (several can queue up after a reconnect).

func _start_live(body: Dictionary) -> void:
	_build_clock_label()
	_set_live_deadline(float(body.get("seconds_left", -1.0)))
	_live = LiveClient.new()
	_live.name = "LiveClient"
	add_child(_live)
	_live.state_received.connect(_on_live_state)
	_live.turn_resolved.connect(_on_live_resolved)
	_live.opponent_locked.connect(func(turn: int) -> void:
		if turn == _turn:
			_opponent_locked = true)
	_live.submit_acked.connect(_on_live_ack)
	_live.match_over.connect(_on_live_match_over)
	_live.presence_changed.connect(func(connected: Array) -> void:
		_opponent_online = bool(connected[1 - _team]))
	_live.connection_changed.connect(func(connected: bool) -> void:
		if not connected:
			_event_log.add_message("Connection lost — reconnecting…", Color(1.0, 0.7, 0.4)))
	var url := MatchSession.live_url if MatchSession.live_url != "" else LiveClient.derive_url(MatchSession.server_url)
	_live.open(url, _match_id, _token)


func _set_live_deadline(seconds_left: float) -> void:
	_live_deadline_ms = Time.get_ticks_msec() + int(seconds_left * 1000.0) if seconds_left >= 0.0 else -1


func _submit_live() -> void:
	_live.submit(_turn, PlanCodec.encode_plan(_timeline.get_plan()))
	_event_log.add_message("Plan locked in.", Color(0.7, 0.85, 1.0))


func _process(_delta: float) -> void:
	if _live == null or _clock_label == null or _over_shown:
		return
	_live.since_turn = _turn   # a reconnect only needs turns we haven't replayed
	var left := -1.0
	if _live_deadline_ms >= 0:
		left = maxf(0.0, (_live_deadline_ms - Time.get_ticks_msec()) / 1000.0)
	var status := ""
	if _resolving and not _live_replaying:
		status = "  ·  locked in"
	if _opponent_locked:
		status += "  ·  opponent locked in"
	if not _opponent_online:
		status += "  ·  opponent reconnecting…"
	if not _live.is_open():
		status += "  ·  reconnecting…"
	var clock := "--:--"
	if left >= 0.0:
		clock = "%d:%02d" % [int(left) / 60, int(left) % 60]
	_clock_label.text = "Turn %d/%d   %s%s" % [_turn, Ladder.LIVE_MAX_TURNS, clock, status]
	_clock_label.modulate = Color(1.0, 0.45, 0.4) if left >= 0.0 and left < 10.0 else Color(1, 1, 1)
	# Buzzer: lock in whatever is planned (the server would otherwise fall
	# back to "Stand Ground + Shield").
	if left >= 0.0 and left <= LIVE_AUTO_LOCK_SEC and not _resolving and not _live_replaying:
		_sanitize_plan()
		_on_plan_submitted()


## Full state after every (re)connect: queue any turn results we missed.
func _on_live_state(body: Dictionary) -> void:
	_set_live_deadline(float(body.get("seconds_left", -1.0)))
	for result in body.get("history", []):
		if int(result.get("turn", -1)) >= _turn and not _queued(int(result["turn"])):
			_live_queue.append(result)
	var winner := int(body.get("winner", -1))
	if winner != -1 and _live_over.is_empty():
		_live_over = { "winner": winner, "reason": body.get("end_reason", ""),
			"rating_change": body.get("rating_change", [0, 0]), "trophy_change": body.get("trophy_change", [0, 0]) }
	_drain_live()


func _on_live_resolved(result: Dictionary, _next_turn: int, seconds_left: float) -> void:
	_set_live_deadline(seconds_left)
	if int(result.get("turn", -1)) >= _turn and not _queued(int(result["turn"])):
		_live_queue.append(result)
	_drain_live()


func _on_live_ack(msg: Dictionary) -> void:
	# 409 = stale turn: the turn already resolved; its result is on the way.
	if msg.has("error") and int(msg.get("code", 0)) != 409:
		_event_log.add_message("Submit rejected: %s" % str(msg["error"]), Color(1.0, 0.4, 0.4))
		_resolving = false
		_timeline.set_locked(false)


func _on_live_match_over(msg: Dictionary) -> void:
	_live_over = msg
	_drain_live()


func _queued(turn: int) -> bool:
	for r in _live_queue:
		if int(r.get("turn", -1)) == turn:
			return true
	return false


## Replays queued results one at a time, then shows the result if the match
## is over.
func _drain_live() -> void:
	if _live_replaying:
		return
	_live_replaying = true
	while not _live_queue.is_empty():
		var result: Dictionary = _live_queue.pop_front()
		if int(result.get("turn", -1)) < _turn:
			continue
		_resolving = true
		_timeline.set_locked(true)
		_overlay.visible = false
		var winner := await _catch_up({ "history": [result] })
		_opponent_locked = false
		if winner != -1:
			_live_replaying = false
			_show_match_over(winner)
			return
		_after_resolution(-1)
	_live_replaying = false
	if not _live_over.is_empty():
		_show_match_over(int(_live_over.get("winner", -1)))


func _live_result_text(msg: Dictionary) -> String:
	var reason := str(msg.get("reason", ""))
	var text := ""
	match reason:
		"turn_cap":
			text = "\nTurn limit — decided on units and Trion left"
		"forfeit":
			text = "\nOpponent surrendered" if int(msg.get("winner", -1)) == _team else "\nYou surrendered"
		"afk":
			text = "\nDecided by inactivity"
	var trophies := int((msg.get("trophy_change", [0, 0]) as Array)[_team])
	if trophies != 0:
		text += "\nTrophies %+d" % trophies
	return text


func _build_clock_label() -> void:
	_clock_label = Label.new()
	_clock_label.name = "LiveClock"
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_label.add_theme_font_size_override("font_size", 20)
	_clock_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_clock_label.add_theme_constant_override("font_outline_size", 6)
	_clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prediction_label.get_parent().add_child(_clock_label)
	_fit_clock_label()
	get_viewport().size_changed.connect(_fit_clock_label)


func _fit_clock_label() -> void:
	_clock_label.position = Vector2(0, 84)
	_clock_label.size = Vector2(get_viewport().get_visible_rect().size.x, 28)


# --- Surrender --------------------------------------------------------------

func _build_surrender_button(ui_layer: CanvasLayer) -> void:
	_surrender_btn = Button.new()
	_surrender_btn.name = "SurrenderButton"
	_surrender_btn.custom_minimum_size = Vector2(150, 40)
	# Top-left, under the unit bar (the event log owns the top-right).
	_surrender_btn.position = Vector2(12, TimelineUI.TOP_BAR_HEIGHT + 6.0)
	_surrender_btn.icon = _white_flag_icon()
	_surrender_btn.pressed.connect(_on_surrender_pressed)
	ui_layer.add_child(_surrender_btn)
	_reset_surrender_button()


## A small white flag on a pole, drawn in code (no asset needed).
static func _white_flag_icon() -> ImageTexture:
	var img := Image.create(20, 20, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(Rect2i(3, 2, 2, 17), Color(0.75, 0.75, 0.78))     # pole
	for y in range(2, 11):
		# Flag with a notched (swallowtail) fly end.
		var notch := 3 - absi(y - 6) if absi(y - 6) < 3 else 0
		img.fill_rect(Rect2i(5, y, 13 - notch, 1), Color(0.97, 0.97, 0.97))
	return ImageTexture.create_from_image(img)


func _reset_surrender_button() -> void:
	if _surrender_btn == null:
		return
	_surrender_btn.text = "Surrender"
	_surrender_btn.disabled = false
	_surrender_btn.visible = true
	_surrender_btn.modulate = Color(1, 1, 1)
	_surrender_armed_until = 0


## First tap arms the button; a second tap within SURRENDER_CONFIRM_MS
## concedes. Online, the server ends the match (trophies apply) and pushes or
## returns the result.
func _on_surrender_pressed() -> void:
	if _over_shown:
		return
	var now := Time.get_ticks_msec()
	if now > _surrender_armed_until:
		_surrender_armed_until = now + SURRENDER_CONFIRM_MS
		_surrender_btn.text = "Tap again to confirm"
		_surrender_btn.modulate = Color(1.0, 0.55, 0.5)
		await get_tree().create_timer(SURRENDER_CONFIRM_MS / 1000.0).timeout
		if not _over_shown and Time.get_ticks_msec() >= _surrender_armed_until:
			_reset_surrender_button()
		return
	_surrender_btn.disabled = true
	if not _online:
		_live_over = { "winner": 1 - _team, "reason": "forfeit" }
		_show_match_over(1 - _team)
		return
	if _live != null and _live.is_open():
		_live.forfeit()   # match_over arrives over the live channel
		return
	var res := await _backend.forfeit(_match_id, _token)
	if not res.get("success", false) and int(res.get("status", 0)) != 409:
		_event_log.add_message("Surrender failed: %s" % str(res.get("error", "?")), Color(1.0, 0.4, 0.4))
		_reset_surrender_button()
		return
	var info := await _backend.get_match(_match_id, _token)
	var body: Dictionary = info.get("body", {})
	_live_over = { "winner": int(body.get("winner", 1 - _team)), "reason": body.get("end_reason", "forfeit"),
		"trophy_change": body.get("trophy_change", [0, 0]) }
	_show_match_over(int(_live_over["winner"]))




# --- Enemy AI (local mode only) --------------------------------------------
# The AI plays fair under fog of war: it works on the real match but only
# uses what its own team can see (enemies in sight; radar ghosts for the
# rest), walks the same routes, and its plans pass the same timing rules.

func _build_enemy_plan() -> void:
	var ai_team := 1 - _team
	var units: Array = _truth.teams[ai_team]
	var data: Array[UnitData] = []
	for u in units:
		data.append((u as UnitState).unit_data)
	_enemy_plan = TurnPlan.new(data)
	var seen := Visibility.enemy_states(_truth, ai_team)
	for i in units.size():
		if not (units[i] as UnitState).is_bailed:
			_plan_enemy_unit(i, units[i], seen)
			# Never submit something the rules would refuse.
			if not _enemy_plan.is_unit_valid(_truth, units[i], i):
				_enemy_plan.clear_unit(i)
				_enemy_plan.add(i, _hold_action("Shield", TurnPlan.TURN_SECONDS)) if _has_card(data[i], "Shield") else null


func _plan_enemy_unit(i: int, u: UnitState, seen: Dictionary) -> void:
	var data := u.unit_data
	var melee := _best_card(data, TriggerCard.CardType.MELEE)
	var ranged := _best_card(data, TriggerCard.CardType.RANGED)
	var shield_ok := _has_card(data, "Shield")
	var low_hp := u.trion_hp <= data.base_trion_hp * 0.25

	# Panic defense: bunker down when nearly bailed out.
	if low_hp and shield_ok:
		_enemy_plan.add(i, _hold_action("Shield", TurnPlan.TURN_SECONDS))
		return

	var target := _ai_pick(u, seen, true)
	var goal := target if target != null else _ai_pick(u, seen, false)
	var goal_pos := Vector2.INF
	if goal != null:
		goal_pos = goal.pos if int(seen.get(goal, Visibility.State.HIDDEN)) == Visibility.State.SIGHT \
			else Visibility.radar_ping(_truth, goal, goal.team, _turn)
	var geo := _truth.geometry()

	# Movement: close in (melee all the way, shooters to firing range).
	if goal_pos != Vector2.INF and u.level == 0:
		var want := TurnEngine.MELEE_RANGE * 0.7 if melee != null and (ranged == null or u.pos.distance_to(goal_pos) < 8.0) \
			else (ranged.attack_range * 0.7 if ranged != null else 2.0)
		if u.pos.distance_to(goal_pos) > want + 0.5:
			var path := geo.nav_path(u.pos, _ground_near(geo, goal_pos))
			if path.size() >= 2:
				var dest := _along(path, maxf(0.0, geo.path_length(path) - want), TurnPlan.speed(data) * 4.5)
				if dest.distance_to(u.pos) > 0.5 and geo.ground_ok(dest):
					var mv := PlanAction.new(TriggerLibrary.get_move_card())
					mv.set_point(dest, 0)
					_enemy_plan.add(i, mv)
		var look := PlanAction.new(TriggerLibrary.get_look_card())
		look.set_point(goal_pos, 0)
		_enemy_plan.add(i, look)

	# Actions: attack what the team sees, as often as the turn allows.
	var weapon: TriggerCard = melee if melee != null and target != null and u.pos.distance_to(target.pos) < 4.0 else ranged
	if weapon == null:
		weapon = melee
	if target != null and weapon != null:
		var enemy_index: int = _truth.teams[target.team].find(target)
		while _enemy_plan.act_used(i) + weapon.action_time / data.tempo <= TurnPlan.TURN_SECONDS:
			var shot := PlanAction.new(weapon)
			shot.target_unit = enemy_index
			_enemy_plan.add(i, shot)
	elif shield_ok:
		var left := TurnPlan.TURN_SECONDS - _enemy_plan.act_used(i)
		if left >= TurnPlan.MIN_HOLD:
			_enemy_plan.add(i, _hold_action("Shield", snappedf(left - 0.01, 0.01)))


## The weakest enemy in sight (ties: nearest); with `sight_only` false, the
## nearest known contact (radar included).
func _ai_pick(u: UnitState, seen: Dictionary, sight_only: bool) -> UnitState:
	var best: UnitState = null
	var best_score := INF
	for p in _truth.teams[1 - u.team]:
		var e: UnitState = p
		if e.is_bailed:
			continue
		var state := int(seen.get(e, Visibility.State.HIDDEN))
		if state == Visibility.State.HIDDEN or (sight_only and state != Visibility.State.SIGHT):
			continue
		var score := u.pos.distance_to(e.pos) + (e.trion_hp * 10.0 if sight_only else 0.0)
		if score < best_score:
			best_score = score
			best = e
	return best


## The point `dist` metres along `path`, but no further than `cap` metres.
static func _along(path: PackedVector2Array, dist: float, cap: float) -> Vector2:
	var left := minf(dist, cap)
	for k in range(1, path.size()):
		var seg := path[k - 1].distance_to(path[k])
		if left <= seg:
			return path[k - 1].lerp(path[k], left / maxf(seg, 0.0001))
		left -= seg
	return path[path.size() - 1]


## An open street point near `p` (radar ghosts can sit inside walls).
static func _ground_near(geo: CityGeometry, p: Vector2) -> Vector2:
	if geo.ground_ok(p):
		return p
	for r in [0.5, 1.0, 1.5, 2.5, 3.5]:
		for k in 12:
			var q: Vector2 = p + Vector2.from_angle(TAU * k / 12.0) * float(r)
			if geo.ground_ok(q):
				return q
	return p


static func _best_card(data: UnitData, type: int) -> TriggerCard:
	var best: TriggerCard = null
	for slots in [data.main_trigger_slots, data.sub_trigger_slots]:
		for c in slots:
			var card: TriggerCard = c
			if card != null and card.card_type == type and card.power > 0 and (best == null or card.power > best.power):
				best = card
	return best


static func _has_card(data: UnitData, card_name: String) -> bool:
	for slots in [data.main_trigger_slots, data.sub_trigger_slots]:
		for c in slots:
			if c != null and (c as TriggerCard).card_name == card_name:
				return true
	return false


static func _hold_action(card_name: String, seconds: float) -> PlanAction:
	var a := PlanAction.new(TriggerLibrary.get_card(card_name))
	a.hold = seconds
	return a
