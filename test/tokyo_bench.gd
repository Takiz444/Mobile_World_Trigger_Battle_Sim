extends Node
## Timing of the Tokyo map pipeline at runtime (not part of CI):
##   godot --headless --path . res://test/tokyo_bench.tscn


func _ready() -> void:
	var t := Time.get_ticks_usec()
	for id in TokyoMap.district_ids():
		TokyoMap.district(id)
	print("load all districts: %.0f ms" % ((Time.get_ticks_usec() - t) / 1000.0))
	var worst := 0.0
	var total := 0.0
	for seed in range(100, 130):
		t = Time.get_ticks_usec()
		var s := TokyoMap.random_section(seed * 31)
		var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), seed, s)
		var dt := (Time.get_ticks_usec() - t) / 1000.0
		worst = maxf(worst, dt)
		total += dt
		if seed == 100:
			t = Time.get_ticks_usec()
			var p0 := TurnPlan.new(TriggerLibrary.sample_units())
			var p1 := TurnPlan.new(TriggerLibrary.sample_units())
			for i in 3:
				for team in 2:
					var u: UnitState = ms.teams[team][i]
					var mv := PlanAction.new(TriggerLibrary.get_move_card())
					var dest: Dictionary = ms.geometry().settle(u.pos + Vector2(8, 3).rotated(i), 0)
					mv.set_point(dest["pos"], 0)
					(p0 if team == 0 else p1).add(i, mv)
			MatchRunner.record_turn(ms, p0, p1, func(n: int) -> int: return n)
			print("record one turn (moves + fog frames): %.0f ms (%d buildings, %d solids, %d decks)" % [
				(Time.get_ticks_usec() - t) / 1000.0, ms.layout.buildings.size(), ms.layout.solids.size(), ms.layout.decks.size()])
	print("section + match: avg %.0f ms, worst %.0f ms" % [total / 30.0, worst])
	get_tree().quit()
