class_name MatchController
extends Node
## Orchestrates a full match in two modes:
##   LOCAL  — vs the built-in enemy AI, resolved locally.
##   ONLINE — async backend: submit plans, poll for the opponent, then replay
##            the server-resolved plans through the deterministic engine.
##
## Drives the shared replay visualization (tweened movement, event log) for
## both modes.

const MOVE_DURATION := 0.35
const TICK_PAUSE := 0.25
const POLL_INTERVAL := 1.0
const MATCH_SEED := 12345

var _board: HexBoard
var _timeline: TimelineUI
var _event_log: EventLogUI
var _units_view: BoardUnits
var _engine := TickEngine.new()

var _player_states: Array[UnitState] = []
var _enemy_states: Array[UnitState] = []
var _enemy_data: Array[UnitData] = []
var _data_teams: Array = []   # [team 0 UnitData squad, team 1 UnitData squad]
var _ms: MatchState
var _enemy_plan: TurnPlan
var _resolving := false
var _turn := 1

# Online mode
var _online := false
var _backend: HttpBackend
var _match_id := ""
var _team := 0

# Match-over / waiting overlay
var _overlay: Control
var _result_label: Label
var _turn_info: Label
var _btn_row: HBoxContainer
var _rematch_btn: Button
var _hangar_btn: Button


func setup(board: HexBoard, timeline: TimelineUI, event_log: EventLogUI, ui_layer: CanvasLayer) -> void:
	_board = board
	_timeline = timeline
	_event_log = event_log

	_units_view = BoardUnits.new()
	_units_view.name = "BoardUnits"
	_board.add_child(_units_view)

	_build_overlay(ui_layer)

	_board.tile_selected.connect(_on_tile_selected)
	_timeline.plan_submitted.connect(_on_plan_submitted)

	_online = MatchSession.mode == MatchSession.Mode.ONLINE
	if _online:
		_setup_online()
	else:
		_start_match()


# --- Match Setup ------------------------------------------------------------

## Resets to a fresh local match (also used by the Rematch button).
func _start_match() -> void:
	_build_squads()
	_turn = 1
	_overlay.visible = false
	_btn_row.visible = true
	_event_log.set_turn(_turn)
	_event_log.clear()
	_event_log.add_message("Match started — plan your turn.", Color(0.6, 0.9, 0.6))
	_timeline.set_locked(false)
	_timeline.begin_new_turn()


## Places both squads and builds a fresh MatchState (the enemy plan is rebuilt
## each turn).
func _build_squads() -> void:
	var player_data := SquadStore.get_squad()
	_enemy_data = TriggerLibrary.sample_units()
	for u in _enemy_data:
		u.ensure_slot_arrays()
	_data_teams = [player_data, _enemy_data]
	_ms = MatchRunner.build_match(player_data, _enemy_data, MATCH_SEED)
	_player_states = _ms.teams[0]
	_enemy_states = _ms.teams[1]
	_units_view.setup(_ms.all_units(), _board.hex_size)


func _setup_online() -> void:
	_match_id = MatchSession.match_id
	_team = MatchSession.team
	_backend = HttpBackend.new()
	_backend.name = "HttpBackend"
	_backend.server_url = MatchSession.server_url
	add_child(_backend)

	_show_waiting("Connecting to server…")
	var info := await _backend.get_match(_match_id)
	if not info.get("success", false):
		_show_waiting("Could not reach server:\n%s" % str(info.get("error", "?")))
		return

	var body: Dictionary = info["body"]

	# Host waits for an opponent to join.
	if not bool(body.get("ready", false)):
		_show_waiting("Waiting for opponent to join…\nMatch ID: %s" % _match_id)
		while true:
			await get_tree().create_timer(POLL_INTERVAL).timeout
			var poll := await _backend.get_match(_match_id)
			if poll.get("success", false) and bool(poll["body"].get("ready", false)):
				body = poll["body"]
				break

	var seed := int(body.get("seed", MATCH_SEED))
	var teams: Array = body.get("teams", [])
	var squad0 := PlanCodec.decode_squad(teams[0]) if teams.size() > 0 and teams[0] != null else []
	var squad1 := PlanCodec.decode_squad(teams[1]) if teams.size() > 1 and teams[1] != null else []
	_data_teams = [squad0, squad1]

	_ms = MatchRunner.build_match(squad0, squad1, seed)
	_player_states = _ms.teams[_team]
	_enemy_states = _ms.teams[1 - _team]
	_units_view.setup(_ms.all_units(), _board.hex_size)

	# The timeline plans only the local team's units.
	_timeline.setup(_data_teams[_team])

	_turn = int(body.get("turn", 1))
	_overlay.visible = false
	_btn_row.visible = true
	_event_log.set_turn(_turn)
	_event_log.clear()
	_event_log.add_message("Online match %s — you are team %d." % [_match_id, _team], Color(0.6, 0.9, 0.6))
	_timeline.set_locked(false)


func _on_tile_selected(hex: Vector2i) -> void:
	_timeline.set_target_for_selected_slot(hex)


# --- Submit / Resolve -------------------------------------------------------

func _on_plan_submitted() -> void:
	if _resolving:
		return
	_resolving = true
	_timeline.set_locked(true)
	if _online:
		await _submit_online()
	else:
		await _submit_local()


func _submit_local() -> void:
	_build_enemy_plan()
	var winner := await _replay_turn(_timeline.get_plan(), _enemy_plan)
	_after_resolution(winner)


func _submit_online() -> void:
	var plan_dict := PlanCodec.encode_plan(_timeline.get_plan())
	var submit := await _backend.submit_plan(_match_id, _team, plan_dict)
	if not submit.get("success", false):
		_show_waiting("Submit failed:\n%s" % str(submit.get("error", "?")))
		_resolving = false
		return

	_show_waiting("Plan submitted.\nWaiting for opponent…")
	var poll := await _poll_for_result()
	if poll.is_empty():
		_show_waiting("Lost connection to server.")
		_resolving = false
		return
	_overlay.visible = false

	var body: Dictionary = poll["body"]
	var result: Dictionary = body.get("result", {})
	var plans: Array = result.get("plans", [])
	if plans.size() < 2:
		_show_waiting("Server returned an incomplete result.")
		_resolving = false
		return

	var p0 := PlanCodec.decode_plan(plans[0], _data_teams[0])
	var p1 := PlanCodec.decode_plan(plans[1], _data_teams[1])
	var winner := await _replay_turn(p0, p1)
	_after_resolution(winner)


func _poll_for_result() -> Dictionary:
	for _i in 300:  # up to ~5 minutes
		await get_tree().create_timer(POLL_INTERVAL).timeout
		var resp := await _backend.get_match(_match_id)
		if not resp.get("success", false):
			return {}
		var b: Dictionary = resp["body"]
		if int(b.get("winner", -1)) != -1:
			return resp
		var result: Variant = b.get("result")
		if result is Dictionary and int(result.get("turn", -1)) >= _turn:
			return resp
	return {}


## Resolves + animates a full 6-tick turn and returns the winner (-1 if none).
func _replay_turn(player_plan: TurnPlan, enemy_plan: TurnPlan) -> int:
	_event_log.clear()
	_event_log.add_message("Resolving turn %d…" % _turn, Color(0.7, 0.8, 1.0))
	await get_tree().create_timer(0.4).timeout

	for tick in TurnPlan.TICKS_PER_TURN:
		var snapshots := _snapshot_units()
		var events := _engine.resolve_tick(_ms, player_plan, enemy_plan, tick)
		for ev in events:
			_event_log.add_event(ev)
		_units_view.update_labels()
		_animate_transitions(snapshots, events)
		await get_tree().create_timer(MOVE_DURATION + TICK_PAUSE).timeout

	return MatchRunner.winner(_ms)


func _after_resolution(winner: int) -> void:
	if winner != -1:
		_show_match_over(winner)
		_resolving = false
		return
	_turn += 1
	_event_log.set_turn(_turn)
	_event_log.add_message("Turn %d — plan your next move." % _turn, Color(0.6, 0.9, 0.6))
	_timeline.set_locked(false)
	_timeline.begin_new_turn()
	_resolving = false


func _snapshot_units() -> Dictionary:
	var snap := {}
	for u in _ms.all_units():
		snap[u] = { "hex": u.hex, "facing": u.facing }
	return snap


func _animate_transitions(snapshots: Dictionary, events: Array[CombatEvent]) -> void:
	for u in _ms.all_units():
		var old: Dictionary = snapshots.get(u, {})
		if old.is_empty():
			continue
		if old["hex"] != u.hex:
			_units_view.tween_to(u, _board.hex_to_world(u.hex), MOVE_DURATION)
		if old["facing"] != u.facing:
			_units_view.tween_facing(u, u.facing, MOVE_DURATION)
	for ev in events:
		if ev.phase == CombatEvent.Phase.RESOLUTION and ev.damage > 0 and ev.target != null:
			if ev.target.is_bailed:
				_units_view.play_bail(ev.target)
			else:
				_units_view.flash_hit(ev.target)


# --- Match-Over / Waiting Overlay ------------------------------------------

func _build_overlay(ui_layer: CanvasLayer) -> void:
	_overlay = Control.new()
	_overlay.name = "MatchOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.visible = false

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
		get_tree().change_scene_to_file("res://ui/hangar/hangar.tscn"))
	_btn_row.add_child(_hangar_btn)

	ui_layer.add_child(_overlay)


func _show_waiting(text: String) -> void:
	_result_label.text = "Waiting…"
	_result_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	_turn_info.text = text
	_btn_row.visible = false
	_overlay.visible = true


func _show_match_over(winner: int) -> void:
	_result_label.text = "VICTORY" if winner == 0 else "DEFEAT"
	_result_label.add_theme_color_override("font_color",
		Color(0.4, 0.95, 0.5) if winner == 0 else Color(1.0, 0.4, 0.4))
	_turn_info.text = "Match ended after %d turns" % _turn
	_btn_row.visible = true
	_overlay.visible = true
	_timeline.set_locked(true)
	_event_log.add_message(
		"Match over — %s!" % ("Victory" if winner == 0 else "Defeat"),
		Color(0.4, 0.95, 0.5) if winner == 0 else Color(1.0, 0.4, 0.4))


# --- Enemy AI (local mode only) --------------------------------------------

## Rebuilds the enemy plan for the current turn from the enemy loadout.
func _build_enemy_plan() -> void:
	_enemy_plan = TurnPlan.new(_enemy_data)
	for i in _enemy_data.size():
		_plan_enemy_unit(i)


func _plan_enemy_unit(i: int) -> void:
	var u := _enemy_states[i]
	var actions := _enemy_plan.get_available_actions(i)
	var melee: TriggerCard = null
	var ranged: TriggerCard = null
	var shield: TriggerCard = null
	var move_card: TriggerCard = null
	for a in actions:
		if melee == null and a.card_type == TriggerCard.CardType.MELEE:
			melee = a
		elif ranged == null and a.card_type == TriggerCard.CardType.RANGED:
			ranged = a
		elif shield == null and a.card_type == TriggerCard.CardType.SHIELD:
			shield = a
		elif move_card == null and a.card_type == TriggerCard.CardType.MOVE:
			move_card = a

	var low_hp := u.trion_hp <= u.unit_data.base_trion_hp * 0.35

	for tick in TurnPlan.TICKS_PER_TURN:
		var target := _pick_target(u)

		# Panic defense: bunker up when nearly bailed.
		if low_hp and u.trion_hp <= u.unit_data.base_trion_hp * 0.2 and shield != null:
			if _try_full_guard(i, tick, shield):
				continue

		if target != null:
			var dist := HexCoord.distance(u.hex, target.hex)
			var weapon := melee if dist == 1 else (ranged if dist <= TickEngine.DEFAULT_RANGED_RANGE else null)
			if weapon != null and _line_clear(u, target, weapon):
				if _enemy_plan.assign(i, tick, TurnPlan.MAIN_SLOT, weapon):
					_enemy_plan.set_target(i, tick, target.hex)
					continue
			if move_card != null and dist > 1:
				var step := _best_step_toward(u, target)
				if step != u.hex and _enemy_plan.assign(i, tick, TurnPlan.MAIN_SLOT, move_card):
					_enemy_plan.set_target(i, tick, step)
					continue

		# Fallback: raise shield (more AT lets later ticks do other things).
		if shield != null:
			_enemy_plan.assign(i, tick, TurnPlan.MAIN_SLOT, shield)


## Assigns Main+Sub shield in one tick (Full Guard, 4 AT) if affordable.
func _try_full_guard(i: int, tick: int, shield: TriggerCard) -> bool:
	if not _enemy_plan.can_assign(i, tick, TurnPlan.MAIN_SLOT, shield):
		return false
	_enemy_plan.assign(i, tick, TurnPlan.MAIN_SLOT, shield)
	_enemy_plan.assign(i, tick, TurnPlan.SUB_SLOT, shield)
	return true


## Focus-fires the weakest player unit; ties broken by proximity.
func _pick_target(from: UnitState) -> UnitState:
	var best: UnitState = null
	var best_score := 0x7FFFFFFF
	for p in _player_states:
		if p.is_bailed:
			continue
		var score := p.trion_hp * 1000 + HexCoord.distance(from.hex, p.hex)
		if score < best_score:
			best_score = score
			best = p
	return best


## One-hex step toward `target`, choosing the neighbor that most reduces
## distance while skipping off-board or occupied hexes.
func _best_step_toward(u: UnitState, target: UnitState) -> Vector2i:
	var best := u.hex
	var best_d := HexCoord.distance(u.hex, target.hex)
	for n in HexCoord.neighbors(u.hex):
		if not _board.has_tile(n):
			continue
		if _ms.get_unit_at(n) != null:
			continue
		var d := HexCoord.distance(n, target.hex)
		if d < best_d:
			best_d = d
			best = n
	return best


## Whether a ranged shot is clear of full cover (Viper curves around cover).
func _line_clear(u: UnitState, target: UnitState, weapon: TriggerCard) -> bool:
	if weapon.card_type != TriggerCard.CardType.RANGED:
		return true
	if weapon.card_name == "Viper":
		return true
	for hex in HexCoord.line(u.hex, target.hex):
		if hex == u.hex or hex == target.hex:
			continue
		if int(_ms.cover.get(hex, 0)) >= 2:
			return false
	return true
