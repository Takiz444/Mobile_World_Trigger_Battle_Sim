class_name MatchController
extends Node
## Orchestrates a full match: places the 4v4 squads on the board, routes board
## clicks to timeline targeting, drives turn resolution through the
## deterministic TickEngine, and animates an on-screen replay with the event log.
##
## Multi-turn lifecycle: turns advance until one squad bails out entirely.
## (Networking backend hooks arrive in Phase 3.)

const MOVE_DURATION := 0.35
const TICK_PAUSE := 0.25
const MATCH_SEED := 12345

var _board: HexBoard
var _timeline: TimelineUI
var _event_log: EventLogUI
var _units_view: BoardUnits
var _engine := TickEngine.new()

var _player_states: Array[UnitState] = []
var _enemy_states: Array[UnitState] = []
var _enemy_data: Array[UnitData] = []
var _ms: MatchState
var _enemy_plan: TurnPlan
var _resolving := false
var _turn := 1

# Match-over overlay
var _overlay: Control
var _result_label: Label
var _turn_info: Label


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

	_start_match()


## Resets to a fresh match (also used by the Rematch button).
func _start_match() -> void:
	_build_squads()
	_turn = 1
	_overlay.visible = false
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

	_player_states = []
	_enemy_states = []
	for i in player_data.size():
		_player_states.append(UnitState.new(player_data[i], 0, Vector2i(-3 + i * 2, -2), 5))
	for i in _enemy_data.size():
		_enemy_states.append(UnitState.new(_enemy_data[i], 1, Vector2i(-3 + i * 2, 2), 2))

	_ms = MatchState.new(MATCH_SEED)
	_ms.setup_team(0, _player_states)
	_ms.setup_team(1, _enemy_states)

	var all: Array[UnitState] = []
	all.append_array(_player_states)
	all.append_array(_enemy_states)
	_units_view.setup(all, _board.hex_size)


func _on_tile_selected(hex: Vector2i) -> void:
	_timeline.set_target_for_selected_slot(hex)


func _on_plan_submitted() -> void:
	if _resolving:
		return
	_resolving = true
	_timeline.set_locked(true)

	_build_enemy_plan()
	var player_plan := _timeline.get_plan()

	_event_log.clear()
	_event_log.add_message("Resolving turn %d…" % _turn, Color(0.7, 0.8, 1.0))
	await get_tree().create_timer(0.4).timeout

	for tick in TurnPlan.TICKS_PER_TURN:
		var snapshots := _snapshot_units()
		var events := _engine.resolve_tick(_ms, player_plan, _enemy_plan, tick)
		for ev in events:
			_event_log.add_event(ev)
		_units_view.update_labels()
		_animate_transitions(snapshots, events)
		await get_tree().create_timer(MOVE_DURATION + TICK_PAUSE).timeout

	var winner := _check_winner()
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


func _check_winner() -> int:
	if _team_all_bailed(0):
		return 1
	if _team_all_bailed(1):
		return 0
	return -1


func _team_all_bailed(team: int) -> bool:
	for u in _ms.teams[team]:
		if not u.is_bailed:
			return false
	return true


# --- Match-Over Overlay -----------------------------------------------------

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

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var rematch := Button.new()
	rematch.text = "Rematch"
	rematch.pressed.connect(_start_match)
	btn_row.add_child(rematch)

	var hangar := Button.new()
	hangar.text = "Return to Hangar"
	hangar.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://ui/hangar/hangar.tscn"))
	btn_row.add_child(hangar)

	ui_layer.add_child(_overlay)


func _show_match_over(winner: int) -> void:
	_result_label.text = "VICTORY" if winner == 0 else "DEFEAT"
	_result_label.add_theme_color_override("font_color",
		Color(0.4, 0.95, 0.5) if winner == 0 else Color(1.0, 0.4, 0.4))
	_turn_info.text = "Match ended after %d turns" % _turn
	_event_log.add_message(
		"Match over — %s!" % ("Victory" if winner == 0 else "Defeat"),
		Color(0.4, 0.95, 0.5) if winner == 0 else Color(1.0, 0.4, 0.4))
	_overlay.visible = true
	_timeline.set_locked(true)


# --- Enemy AI ---------------------------------------------------------------

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
