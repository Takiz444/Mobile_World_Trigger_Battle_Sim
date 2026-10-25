class_name MatchController
extends Node
## Orchestrates a full match in two modes:
##   LOCAL  — vs the built-in enemy AI, resolved locally.
##   ONLINE — async backend: submit plans, poll for the opponent, then replay
##            the server-resolved plans through the deterministic engine.
##            With MatchSession.live, the server pushes results over the live
##            WebSocket (LiveClient) and a short turn clock runs: whatever is
##            planned when it runs out is locked in automatically.
##
## Drives the shared replay visualization (tweened movement, event log) for
## both modes.

const MOVE_DURATION := 0.35
const TICK_PAUSE := 0.25
const POLL_INTERVAL := 1.0
const MATCH_SEED := 12345
## Where hidden enemies are parked in the client's MatchState (online mode),
## so occupancy checks can't leak their real position.
const OFFBOARD := Vector2i(100000, 100000)

var _board: HexBoard
var _timeline: TimelineUI
var _event_log: EventLogUI
var _units_view: BoardUnits
var _camera: BoardCamera
var _engine := TickEngine.new()

var _player_states: Array[UnitState] = []
var _enemy_states: Array[UnitState] = []
var _enemy_data: Array[UnitData] = []
var _data_teams: Array = []   # [team 0 UnitData squad, team 1 UnitData squad]
var _ms: MatchState
var _enemy_plan: TurnPlan
var _resolving := false
var _turn := 1
var _hovered_hex: Vector2i = HexBoard.INVALID_HEX

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
var _live_deadline_ms := -1          # Time.get_ticks_msec() of the turn deadline
var _live_queue: Array[Dictionary] = []   # pushed turn results awaiting replay
var _live_replaying := false
var _live_over: Dictionary = {}      # match_over message, once received
var _opponent_online := true
var _opponent_locked := false
var _over_shown := false
var _clock_label: Label

# Match-over / waiting overlay
var _overlay: Control
var _result_label: Label
var _turn_info: Label
var _btn_row: HBoxContainer
var _rematch_btn: Button
var _hangar_btn: Button
var _prediction_label: Label


func setup(board: HexBoard, timeline: TimelineUI, event_log: EventLogUI, ui_layer: CanvasLayer, camera: BoardCamera = null) -> void:
	_board = board
	_timeline = timeline
	_event_log = event_log
	_camera = camera

	_units_view = BoardUnits.new()
	_units_view.name = "BoardUnits"
	_board.add_child(_units_view)

	_build_prediction_label(ui_layer)
	_build_overlay(ui_layer)

	_board.tile_selected.connect(_on_tile_selected)
	_board.tile_hovered.connect(_on_tile_hovered)
	_timeline.plan_submitted.connect(_on_plan_submitted)
	_timeline.unit_selected.connect(_on_unit_selected)
	_timeline.targeting_changed.connect(_update_targeting)

	_online = MatchSession.mode == MatchSession.Mode.ONLINE
	if _online:
		_setup_online()
	else:
		_start_match()


# --- Match Setup ------------------------------------------------------------

## Resets to a fresh local match (also used by the Rematch button).
func _start_match() -> void:
	_build_squads()
	_board.clear_highlights()
	_units_view.clear_ghost()
	if _prediction_label != null:
		_prediction_label.visible = false
	_turn = 1
	_over_shown = false
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
	_build_board_view()
	_refresh_fog_local(_view_salt())


## Builds the map, props, and unit markers for _ms and frames the camera on
## the local squad.
func _build_board_view() -> void:
	_board.set_map(_ms.tiles)
	_units_view.setup(_ms.all_units(), _board.hex_size)
	_board.set_cover(_ms.cover)
	_board.set_buildings(_ms.buildings)
	_board.set_wires(_ms.wires)
	var board_box := _board.get_bounds()
	var edge := _board.hex_size
	_units_view.set_map_bounds(Rect2(board_box.position.x - edge, board_box.position.z - edge,
		board_box.size.x + 2.0 * edge, board_box.size.z + 2.0 * edge))
	if _camera != null:
		_camera.set_bounds(_board.get_bounds())
		# Frame the squad with some battlefield ahead of it: aim a few hexes
		# from the squad's center toward the middle of the map.
		var squad := Vector3.ZERO
		for u in _player_states:
			squad += _board.hex_to_world(u.hex)
		squad /= maxf(1.0, _player_states.size())
		var bounds := _board.get_bounds()
		var ahead := (bounds.get_center() - squad)
		ahead.y = 0.0
		_camera.recenter(squad + ahead.normalized() * 5.0)


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

	var seed := int(body.get("seed", MATCH_SEED))
	var teams: Array = body.get("teams", [])
	var squad0 := PlanCodec.decode_squad(teams[0]) if teams.size() > 0 and teams[0] != null else []
	var squad1 := PlanCodec.decode_squad(teams[1]) if teams.size() > 1 and teams[1] != null else []
	_data_teams = [squad0, squad1]

	_ms = MatchRunner.build_match(squad0, squad1, seed)
	_player_states = _ms.teams[_team]
	_enemy_states = _ms.teams[1 - _team]
	# The server only sends what our team can see (fog of war); start from
	# that view, which also resyncs a reconnect mid-match.
	var view: Variant = body.get("view")
	if view is Dictionary:
		_apply_view(view)
	_build_board_view()
	_refresh_fog_overlay()

	# The timeline plans only the local team's units.
	_timeline.setup(_data_teams[_team])

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
	if MatchSession.live:
		_start_live(body)


func _on_tile_selected(hex: Vector2i) -> void:
	_timeline.set_target_for_selected_slot(hex, _target_floor_for_click(hex))


## Picks the destination floor for a clicked hex. Movement cards may climb or
## descend within the unit's own hex (toggle up/down on repeated clicks);
## every other card targets by hex only (floor 0).
func _target_floor_for_click(hex: Vector2i) -> int:
	var info := _timeline.get_selected_target_info()
	if info.is_empty():
		return 0
	var card: TriggerCard = info.get("card")
	if not TickEngine.is_move_card(card):
		return 0
	var f := _preferred_move_floor(info, hex, true)
	return f if f != -1 else _projected_floor(int(info.get("unit", 0)), int(info.get("tick", 0)) - 1)


## Floors of `hex` the selected move card can reach from the unit's
## projected position (unoccupied by known units). Same rules as the engine.
func _move_floors(info: Dictionary, hex: Vector2i) -> Array[int]:
	var out: Array[int] = []
	var card: TriggerCard = info.get("card")
	var unit_index: int = info.get("unit", -1)
	var tick: int = info.get("tick", -1)
	if card == null or unit_index < 0 or not _board.has_tile(hex):
		return out
	var origin := _projected_hex(unit_index, tick - 1)
	var origin_floor := _projected_floor(unit_index, tick - 1)
	for f in range(0, maxi(_ms.building_floors(hex), origin_floor + 1) + 1):
		if f == origin_floor and hex == origin:
			continue
		if _known_unit_at(hex, f) != null:
			continue
		if TickEngine.is_valid_move(_ms, origin, origin_floor, hex, f, card, _team):
			out.append(f)
	return out


## Best destination floor for `hex`, or -1 if unreachable: stay level when
## possible; Grasshopper prefers rooftops; on the unit's own hex, climb (and
## toggle down on a repeated click when `toggle`).
func _preferred_move_floor(info: Dictionary, hex: Vector2i, toggle: bool) -> int:
	var floors := _move_floors(info, hex)
	if floors.is_empty():
		return -1
	var card: TriggerCard = info.get("card")
	var unit_index: int = info.get("unit", -1)
	var tick: int = info.get("tick", -1)
	var origin := _projected_hex(unit_index, tick - 1)
	var origin_floor := _projected_floor(unit_index, tick - 1)
	if hex == origin:
		var up := origin_floor + 1
		if toggle and _target_hex_for(info) == origin and _target_floor_for(info) >= up and floors.has(origin_floor - 1):
			return origin_floor - 1
		if card.jump:
			return floors.max()
		return up if floors.has(up) else floors[0]
	if card.jump:
		return floors.max()
	if floors.has(origin_floor):
		return origin_floor
	return floors[0]


func _on_tile_hovered(hex: Vector2i) -> void:
	_hovered_hex = hex
	_update_targeting()


# --- Submit / Resolve -------------------------------------------------------

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


func _submit_local() -> void:
	_build_enemy_plan()
	var winner := await _replay_turn(_timeline.get_plan(), _enemy_plan)
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
		_show_waiting("Lost connection to server.")
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


func _poll_for_result() -> Dictionary:
	for _i in 300:  # up to ~5 minutes
		await get_tree().create_timer(POLL_INTERVAL).timeout
		var resp := await _backend.get_match(_match_id, _token)
		if not resp.get("success", false):
			return {}
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


## Online replay: the server sends one fog-filtered frame per tick (our view
## of the board + the events we may see). We animate between frames instead
## of re-simulating, since the client never learns hidden enemy actions.
func _replay_frames(frames: Array) -> int:
	_begin_replay()
	await get_tree().create_timer(0.4).timeout
	for frame in frames:
		var snapshots := _snapshot_units()
		_apply_view(frame.get("view", {}))
		_board.set_wires(_ms.wires)
		var events: Array = frame.get("events", [])
		for ev in events:
			_event_log.add_event_dict(ev)
		_refresh_fog_overlay()
		_units_view.update_labels()
		_animate_frame(snapshots, events)
		await get_tree().create_timer(MOVE_DURATION + TICK_PAUSE).timeout
	return MatchRunner.winner(_ms)


## Applies a server view (Visibility.encode_view) to the client MatchState.
## Unseen enemies are parked OFFBOARD; RADAR ones keep only a ping position.
func _apply_view(view: Dictionary) -> void:
	var units := _ms.all_units()
	var rows: Array = view.get("units", [])
	for i in mini(units.size(), rows.size()):
		var u: UnitState = units[i]
		var row: Dictionary = rows[i]
		u.fog = int(row.get("vis", Visibility.State.SIGHT))
		match u.fog:
			Visibility.State.SIGHT:
				var hex: Array = row.get("hex", [u.hex.x, u.hex.y])
				u.hex = Vector2i(int(hex[0]), int(hex[1]))
				u.floor = int(row.get("floor", 0))
				u.facing = int(row.get("facing", u.facing))
				u.trion_hp = int(row.get("hp", u.trion_hp))
				u.is_bailed = bool(row.get("bailed", false))
				u.stealth_active = bool(row.get("stealth", false))
				u.weight_ticks = int(row.get("weight", 0))
			Visibility.State.RADAR:
				var ping: Array = row.get("ping", [0, 0])
				u.ping_hex = Vector2i(int(ping[0]), int(ping[1]))
				u.hex = OFFBOARD
			_:
				u.hex = OFFBOARD
	_ms.wires.clear()
	for w in view.get("wires", []):
		_ms.wires[Vector2i(int(w[0]), int(w[1]))] = int(w[2]) if w.size() > 2 else -1


func _animate_frame(snapshots: Dictionary, events: Array) -> void:
	_animate_moves(snapshots)
	var by_name := {}
	for u in _ms.all_units():
		by_name[u.display_name()] = u
	for ev in events:
		if int(ev.get("phase", -1)) != CombatEvent.Phase.RESOLUTION or int(ev.get("damage", 0)) <= 0:
			continue
		var target: UnitState = by_name.get(str(ev.get("target", "")))
		if target == null:
			continue
		if target.is_bailed:
			_units_view.play_bail(target)
		else:
			_units_view.flash_hit(target)


## Local mode: resolves + animates a full 3-tick turn and returns the winner
## (-1 if none). The engine sees everything, but the board and the combat log
## only show what the player's team can see (fog of war).
func _replay_turn(player_plan: TurnPlan, enemy_plan: TurnPlan) -> int:
	_begin_replay()
	await get_tree().create_timer(0.4).timeout

	for tick in TurnPlan.TICKS_PER_TURN:
		var snapshots := _snapshot_units()
		var events := _engine.resolve_tick(_ms, player_plan, enemy_plan, tick)
		_board.set_wires(_ms.wires)
		var states := _refresh_fog_local(_turn * 10 + tick)
		for ev in events:
			if Visibility.event_visible(ev, _team, states):
				_event_log.add_event(ev)
		_units_view.update_labels()
		_animate_transitions(snapshots, events)
		await get_tree().create_timer(MOVE_DURATION + TICK_PAUSE).timeout

	return MatchRunner.winner(_ms)


func _begin_replay() -> void:
	_event_log.clear()
	_board.clear_highlights()
	_units_view.clear_ghost()
	_units_view.clear_vision()
	_units_view.set_selected(null)
	if _prediction_label != null:
		_prediction_label.visible = false
	_event_log.add_message("Resolving turn %d…" % _turn, Color(0.7, 0.8, 1.0))


# --- Fog of War -------------------------------------------------------------

## Radar salt for the planning view; equals the last replay tick's salt
## (turn * 10 + 5) of the previous turn so pings don't jump.
func _view_salt() -> int:
	return _turn * 10 - 5


## Local mode: recomputes what our team sees from the full MatchState.
## Returns the enemy visibility states (for event filtering).
func _refresh_fog_local(salt: int) -> Dictionary:
	var states := Visibility.enemy_states(_ms, _team)
	var index := 0
	for u in _ms.all_units():
		if u.team != _team:
			u.fog = int(states[u])
			if u.fog == Visibility.State.RADAR:
				u.ping_hex = Visibility.radar_ping(_ms, u, index, salt)
		index += 1
	_refresh_fog_overlay()
	return states


func _refresh_fog_overlay() -> void:
	_board.set_fog(Visibility.visible_hexes(_ms, _team))
	_units_view.apply_fog()


## Enemy units the player is allowed to know about right now.
func _is_known(u: UnitState) -> bool:
	return u.team == _team or u.fog == Visibility.State.SIGHT


## Occupancy check that ignores enemies hidden by fog (so the planning UI
## can't leak their position).
func _known_unit_at(hex: Vector2i, floor: int) -> UnitState:
	var u := _ms.get_unit_at(hex, floor)
	return u if u != null and _is_known(u) else null


func _after_resolution(winner: int) -> void:
	if winner != -1:
		_show_match_over(winner)
		_resolving = false
		return
	_turn += 1
	if not _online:
		_refresh_fog_local(_view_salt())
	_event_log.set_turn(_turn)
	_event_log.add_message("Turn %d — plan your next move." % _turn, Color(0.6, 0.9, 0.6))
	_timeline.set_locked(false)
	_timeline.begin_new_turn()
	_resolving = false


func _snapshot_units() -> Dictionary:
	var snap := {}
	for u in _ms.all_units():
		snap[u] = { "hex": u.hex, "facing": u.facing, "floor": u.floor, "fog": u.fog }
	return snap


## Tweens units that moved. Units that just came out of the fog snap into
## place instead of sliding in from their last known (or parked) position.
func _animate_moves(snapshots: Dictionary) -> void:
	for u in _ms.all_units():
		var old: Dictionary = snapshots.get(u, {})
		if old.is_empty():
			continue
		if int(old["fog"]) != Visibility.State.SIGHT or old["hex"] == OFFBOARD:
			_units_view.snap(u)
			continue
		if old["hex"] != u.hex or old["floor"] != u.floor:
			_units_view.tween_to(u, _board.hex_to_world_at(u.hex, u.floor), MOVE_DURATION)
		if old["facing"] != u.facing:
			_units_view.tween_facing(u, u.facing, MOVE_DURATION)


func _animate_transitions(snapshots: Dictionary, events: Array[CombatEvent]) -> void:
	_animate_moves(snapshots)
	for ev in events:
		if ev.phase == CombatEvent.Phase.RESOLUTION and ev.damage > 0 and ev.target != null:
			if ev.target.is_bailed:
				_units_view.play_bail(ev.target)
			else:
				_units_view.flash_hit(ev.target)


# --- Targeting / Camera -----------------------------------------------------

func _on_unit_selected(i: int) -> void:
	if _camera == null or i < 0 or i >= _player_states.size():
		return
	_camera.recenter(_board.hex_to_world(_player_states[i].hex))


func _update_targeting() -> void:
	var info := _timeline.get_selected_target_info()
	_board.highlight_hexes(_compute_range_hexes(info))
	_board.highlight_effects(_compute_effect_hexes(info))
	_update_ghost(info)
	_update_prediction(info)
	var idx := _timeline.get_current_unit()
	if idx >= 0 and idx < _player_states.size():
		_units_view.set_selected(_player_states[idx])
	_update_vision(info)


## Shows the selected character's vision cones where it will be (and which
## way it will face) at the selected tick. With a Look card selected, the
## cone follows the hovered hex to preview the new facing.
func _update_vision(info: Dictionary) -> void:
	if _resolving or _player_states.is_empty():
		_units_view.clear_vision()
		return
	var idx: int = info.get("unit", _timeline.get_current_unit())
	if idx < 0 or idx >= _player_states.size() or _player_states[idx].is_bailed:
		_units_view.clear_vision()
		return
	var tick: int = info.get("tick", -1)
	var hex := _projected_hex(idx, tick)
	var floor := _projected_floor(idx, tick)
	var facing := _projected_facing(idx, tick)
	var card: TriggerCard = info.get("card")
	if card != null and card.card_name == "Look" and _target_hex_for(info) == HexBoard.INVALID_HEX \
			and _hovered_hex != HexBoard.INVALID_HEX:
		var dir := TickEngine.attack_direction(hex, _hovered_hex)
		if dir != -1:
			facing = dir
	# Standing inside a building: vision only leaves through its outer wall.
	var own_rect: Dictionary = {}
	if floor < _ms.building_floors(hex):
		var ri := _ms.building_rect_index(hex)
		if ri != -1:
			own_rect = _ms.building_rects()[ri]
	_units_view.show_vision(_player_states[idx], hex, floor, facing, own_rect)


## Facing after ticks 0..through_tick of the plan: moves face their step,
## Look faces its target, attacks turn toward their target (engine rules).
func _projected_facing(unit_index: int, through_tick: int) -> int:
	var u: UnitState = _player_states[unit_index]
	var facing := u.facing
	var plan := _timeline.get_plan()
	for t in range(through_tick + 1):
		var hex := _projected_hex(unit_index, t - 1)
		var ta: TickAction = plan.get_tick(unit_index, t)
		var moved_to := _projected_hex(unit_index, t)
		if moved_to != hex:
			var dir := TickEngine.attack_direction(hex, moved_to)
			if dir != -1:
				facing = dir
		for slot in [TurnPlan.MAIN_SLOT, TurnPlan.SUB_SLOT]:
			var card := ta.slot_card(slot)
			if card == null or not ta.slot_has_target(slot) or TickEngine.is_move_card(card):
				continue
			if card.card_name == "Look" or card.card_type == TriggerCard.CardType.MELEE or card.card_type == TriggerCard.CardType.RANGED:
				var dir := TickEngine.attack_direction(moved_to, ta.slot_target(slot))
				if dir != -1:
					facing = dir
	return facing


## Live hit-chance / damage readout for the hovered (or locked) target of the
## selected offensive card.
func _update_prediction(info: Dictionary) -> void:
	if _prediction_label == null:
		return
	if info.is_empty():
		_prediction_label.visible = false
		return

	var unit_index: int = info.get("unit", -1)
	var card: TriggerCard = info.get("card")
	if card == null or unit_index < 0 or unit_index >= _player_states.size():
		_prediction_label.visible = false
		return
	if card.card_type != TriggerCard.CardType.MELEE and card.card_type != TriggerCard.CardType.RANGED:
		_prediction_label.visible = false
		return

	var tick: int = info.get("tick", -1)
	var origin := _projected_hex(unit_index, tick)
	var origin_floor := _projected_floor(unit_index, tick)
	var attacker: UnitState = _player_states[unit_index]

	var target_hex := _target_hex_for(info)
	if target_hex == HexBoard.INVALID_HEX or not _board.has_tile(target_hex):
		target_hex = _hovered_hex
	if target_hex == HexBoard.INVALID_HEX or not _board.has_tile(target_hex):
		_prediction_label.visible = false
		return

	var target := _ms.get_unit_at_any_floor(target_hex)
	if target == null or not _is_known(target):
		_prediction_label.visible = false
		return

	var p := _engine.preview_attack(_ms, attacker, origin, card, target, origin_floor)
	_prediction_label.text = _format_prediction(card, attacker, target, p)
	_prediction_label.visible = true


func _format_prediction(card: TriggerCard, attacker: UnitState, target: UnitState, p: Dictionary) -> String:
	var cname := card.card_name
	var tname := target.display_name()
	if target.team == attacker.team:
		_prediction_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.4))
		return "%s → %s — friendly" % [cname, tname]
	if not p["range_ok"]:
		_prediction_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
		return "%s → %s — out of range" % [cname, tname]
	if p["blocked"]:
		_prediction_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
		return "%s → %s — no line of sight" % [cname, tname]
	if card.effect == "weight":
		_prediction_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.55))
		return "%s → %s — %d%% hit · weighs down (no move/dodge)" % [cname, tname, roundi(float(p["hit_chance"]) * 100.0)]

	var dmg := int(p["power"])
	var note := ""
	if p["half_cover"]:
		dmg = roundi(float(p["power"]) * 0.5)
		note = " · ½ cover"
	if p.get("piercing", false):
		note += " · pierces shields"
	var hit := roundi(float(p["hit_chance"]) * 100.0)
	_prediction_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.55))
	return "%s → %s — %d%% hit · %d dmg%s" % [cname, tname, hit, dmg, note]


## Green tiles the player may click for the selected slot's card. Only
## movement destinations live here; attack/trap areas use effect highlights.
func _compute_range_hexes(info: Dictionary) -> Array[Vector2i]:
	if info.is_empty():
		return []
	var unit_index: int = info.get("unit", -1)
	var card: TriggerCard = info.get("card")
	if card == null or unit_index < 0 or unit_index >= _player_states.size():
		return []

	var tick: int = info.get("tick", -1)
	var result: Array[Vector2i] = []

	if TickEngine.is_move_card(card):
		var origin := _projected_hex(unit_index, tick - 1)
		for hex in HexCoord.spiral(origin, maxi(TickEngine.JUMP_RANGE, TickEngine.WIRE_DASH_RANGE)):
			if not _move_floors(info, hex).is_empty():
				result.append(hex)

	return result


## Orange tiles the selected slot's card affects: attack targets, Spider wire
## area, or the unit's own hex for self-buffs (Shield / Bagworm). Origins use
## the unit's projected position (after this tick's move, per the engine order).
func _compute_effect_hexes(info: Dictionary) -> Array[Vector2i]:
	if info.is_empty():
		return []
	var unit_index: int = info.get("unit", -1)
	var card: TriggerCard = info.get("card")
	if card == null or unit_index < 0 or unit_index >= _player_states.size():
		return []

	var tick: int = info.get("tick", -1)
	var origin := _projected_hex(unit_index, tick)
	var origin_floor := _projected_floor(unit_index, tick)
	var result: Array[Vector2i] = []

	if card.card_type == TriggerCard.CardType.MELEE:
		for e in _enemy_states:
			if _is_known(e) and not e.is_bailed and HexCoord.distance(origin, e.hex) == 1 and e.floor == origin_floor:
				result.append(e.hex)
	elif card.card_type == TriggerCard.CardType.RANGED:
		for e in _enemy_states:
			if _is_known(e) and not e.is_bailed and HexCoord.distance(origin, e.hex) <= card.attack_range:
				result.append(e.hex)
	elif card.card_name == "Spider":
		for hex in HexCoord.spiral(origin, 3):
			if _board.has_tile(hex):
				result.append(hex)
	elif card.card_type == TriggerCard.CardType.SHIELD or card.card_type == TriggerCard.CardType.STEALTH:
		result.append(origin)

	return result


## Shows a translucent "ghost" of the selected unit's position for the current
## slot. For Move cards it previews the destination (locked target, then the
## hovered tile, then the projected origin). For every other card it keeps
## showing where the unit will be when that action fires, so attacks/abilities
## read from the correct projected position.
func _update_ghost(info: Dictionary) -> void:
	var u := _selected_unit(info)
	if u == null:
		_units_view.clear_ghost()
		return

	var unit_index: int = info.get("unit", -1)
	var tick: int = info.get("tick", -1)
	var card: TriggerCard = info.get("card")
	var is_move := TickEngine.is_move_card(card)

	if is_move:
		var origin := _projected_hex(unit_index, tick - 1)
		var origin_floor := _projected_floor(unit_index, tick - 1)
		var target := _target_hex_for(info)
		var target_floor := _target_floor_for(info)
		if target != HexBoard.INVALID_HEX and _board.has_tile(target):
			_units_view.show_ghost(u, target, target_floor)
			return
		var hover_floor := _preferred_move_floor(info, _hovered_hex, false) if _hovered_hex != HexBoard.INVALID_HEX else -1
		if hover_floor != -1:
			_units_view.show_ghost(u, _hovered_hex, hover_floor)
			return
		if origin != u.hex or origin_floor != u.floor:
			_units_view.show_ghost(u, origin, origin_floor)
			return
		_units_view.clear_ghost()
		return

	# Non-move (attack / shield / utility / empty): keep the ghost at the
	# unit's projected position so the player can see where the action happens.
	var pos := _projected_hex(unit_index, tick)
	var pos_floor := _projected_floor(unit_index, tick)
	if pos != u.hex or pos_floor != u.floor:
		_units_view.show_ghost(u, pos, pos_floor)
	else:
		_units_view.clear_ghost()


func _selected_unit(info: Dictionary) -> UnitState:
	if info.is_empty():
		return null
	var unit_index: int = info.get("unit", -1)
	if unit_index < 0 or unit_index >= _player_states.size():
		return null
	return _player_states[unit_index]


func _target_hex_for(info: Dictionary) -> Vector2i:
	var unit_index: int = info.get("unit", -1)
	var tick: int = info.get("tick", -1)
	if unit_index < 0 or tick < 0:
		return HexBoard.INVALID_HEX
	var ta: TickAction = _timeline.get_plan().get_tick(unit_index, tick)
	var slot: int = info.get("slot", TurnPlan.MAIN_SLOT)
	if ta != null and ta.slot_has_target(slot):
		return ta.slot_target(slot)
	return HexBoard.INVALID_HEX


func _target_floor_for(info: Dictionary) -> int:
	var unit_index: int = info.get("unit", -1)
	var tick: int = info.get("tick", -1)
	if unit_index < 0 or tick < 0:
		return 0
	var ta: TickAction = _timeline.get_plan().get_tick(unit_index, tick)
	var slot: int = info.get("slot", TurnPlan.MAIN_SLOT)
	if ta != null and ta.slot_has_target(slot):
		return ta.slot_target_floor(slot)
	return 0


## Where a unit will be after resolving all Move cards in ticks 0..through_tick
## (inclusive). through_tick < 0 means "no moves yet" (returns its current
## position). Matches the engine's sequential per-tick movement for previews.
func _projected_pos(unit_index: int, through_tick: int) -> Dictionary:
	var u: UnitState = _player_states[unit_index]
	var hex := u.hex
	var floor := u.floor
	var plan := _timeline.get_plan()
	for t in range(through_tick + 1):
		var ta: TickAction = plan.get_tick(unit_index, t)
		var slot := TickEngine.move_slot(ta)
		if slot != -1 and ta.slot_has_target(slot):
			var to_hex := ta.slot_target(slot)
			var to_floor := ta.slot_target_floor(slot)
			if TickEngine.is_valid_move(_ms, hex, floor, to_hex, to_floor, ta.slot_card(slot), _team) and _known_unit_at(to_hex, to_floor) == null:
				hex = to_hex
				floor = to_floor
	return { "hex": hex, "floor": floor }


func _projected_hex(unit_index: int, through_tick: int) -> Vector2i:
	return _projected_pos(unit_index, through_tick)["hex"]


func _projected_floor(unit_index: int, through_tick: int) -> int:
	return _projected_pos(unit_index, through_tick)["floor"]


# --- Prediction Readout -----------------------------------------------------

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
	_prediction_label.position = Vector2(0, 48)
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
		get_tree().change_scene_to_file("res://ui/hangar/hangar.tscn"))
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
	# Rematch replays the local AI match; online matches go back to the Hangar.
	_rematch_btn.visible = not _online
	_btn_row.visible = true
	_overlay.visible = true
	_timeline.set_locked(true)
	_board.clear_highlights()
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


# --- Enemy AI (local mode only) --------------------------------------------
# The AI plays fair under fog of war: it only attacks player units its team
# can see, closes in on radar contacts, and paths around buildings.

## Rebuilds the enemy plan for the current turn from the enemy loadout.
func _build_enemy_plan() -> void:
	_enemy_plan = TurnPlan.new(_enemy_data)
	var seen := Visibility.enemy_states(_ms, 1)
	for i in _enemy_data.size():
		if not _enemy_states[i].is_bailed:
			_plan_enemy_unit(i, seen)


func _plan_enemy_unit(i: int, seen: Dictionary) -> void:
	var u := _enemy_states[i]
	var actions := _enemy_plan.get_available_actions(i)
	var melee: TriggerCard = null
	var ranged: TriggerCard = null
	var shield: TriggerCard = null
	var move_card: TriggerCard = null
	for a in actions:
		if melee == null and a.card_type == TriggerCard.CardType.MELEE:
			melee = a
		elif a.card_type == TriggerCard.CardType.RANGED and a.power > 0 and (ranged == null or a.power > ranged.power):
			ranged = a
		elif shield == null and a.card_type == TriggerCard.CardType.SHIELD:
			shield = a
		elif move_card == null and a.card_type == TriggerCard.CardType.MOVE:
			move_card = a

	var low_hp := u.trion_hp <= u.unit_data.base_trion_hp * 0.2
	var pos := u.hex  # projected position as the plan's moves accumulate
	var floor := u.floor

	for tick in TurnPlan.TICKS_PER_TURN:
		# Panic defense: bunker up when nearly bailed.
		if low_hp and shield != null and _try_full_guard(i, tick, shield):
			continue

		var target := _pick_target(pos, seen, true)
		if target != null:
			var dist := HexCoord.distance(pos, target.hex)
			var weapon: TriggerCard = null
			if melee != null and dist == 1 and target.floor == floor:
				weapon = melee
			elif ranged != null and dist <= ranged.attack_range \
					and (ranged.curved or Visibility.has_los(_ms, pos, floor, target.hex, target.floor)):
				weapon = ranged
			if weapon != null and _enemy_plan.assign(i, tick, TurnPlan.MAIN_SLOT, weapon):
				_enemy_plan.set_target(i, tick, target.hex)
				continue

		# Advance on a seen enemy, else on the nearest radar contact, while
		# keeping eyes on it (Look is free and fits the Sub slot).
		var goal := target if target != null else _pick_target(pos, seen, false)
		if goal != null and move_card != null and floor == 0 and HexCoord.distance(pos, goal.hex) > 1:
			var step := _next_step(pos, goal.hex)
			if step != pos and _enemy_plan.assign(i, tick, TurnPlan.MAIN_SLOT, move_card):
				_enemy_plan.set_target(i, tick, step)
				pos = step
				_watch(i, tick, goal.hex)
				continue

		# Fallback: raise shield (more AT lets later ticks do other things).
		if shield != null:
			_enemy_plan.assign(i, tick, TurnPlan.MAIN_SLOT, shield)
		if goal != null:
			_watch(i, tick, goal.hex)


## Free Look toward `hex` in the Sub slot (keeps the AI's vision on threats).
func _watch(i: int, tick: int, hex: Vector2i) -> void:
	if _enemy_plan.assign(i, tick, TurnPlan.SUB_SLOT, TriggerLibrary.get_look_card()):
		_enemy_plan.set_target(i, tick, hex, 0, TurnPlan.SUB_SLOT)


## Assigns Main+Sub shield in one tick (Full Guard, 4 AT) if affordable.
func _try_full_guard(i: int, tick: int, shield: TriggerCard) -> bool:
	if not _enemy_plan.can_assign(i, tick, TurnPlan.MAIN_SLOT, shield):
		return false
	_enemy_plan.assign(i, tick, TurnPlan.MAIN_SLOT, shield)
	_enemy_plan.assign(i, tick, TurnPlan.SUB_SLOT, shield)
	return true


## Focus-fires the weakest player unit in sight (ties broken by proximity).
## With `sight_only` false, also considers radar contacts (approximate
## positions the AI may advance toward but not shoot at).
func _pick_target(from: Vector2i, seen: Dictionary, sight_only: bool) -> UnitState:
	var best: UnitState = null
	var best_score := 0x7FFFFFFF
	for p in _player_states:
		if p.is_bailed:
			continue
		var state := int(seen.get(p, Visibility.State.HIDDEN))
		if state == Visibility.State.HIDDEN or (sight_only and state != Visibility.State.SIGHT):
			continue
		var score := p.trion_hp * 1000 + HexCoord.distance(from, p.hex)
		if not sight_only:
			score = HexCoord.distance(from, p.hex)
		if score < best_score:
			best_score = score
			best = p
	return best


## Next street hex on the shortest ground path toward `goal` (A* around
## buildings). Falls back to a greedy step when no path exists.
func _next_step(from: Vector2i, goal: Vector2i) -> Vector2i:
	var walkable := func(h: Vector2i) -> bool:
		return _board.has_tile(h) and (h == goal or _ms.floor_legal(h, 0))
	var path := HexCoord.find_path(from, goal, walkable, 40)
	var step := from
	if path.size() >= 2:
		step = path[1]
	else:
		var best_d := HexCoord.distance(from, goal)
		for n in HexCoord.neighbors(from):
			if walkable.call(n) and HexCoord.distance(n, goal) < best_d:
				best_d = HexCoord.distance(n, goal)
				step = n
	if step == goal or not _ms.floor_legal(step, 0) or _ms.get_unit_at(step, 0) != null:
		return from
	return step
