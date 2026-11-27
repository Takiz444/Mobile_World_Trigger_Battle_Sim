extends Node3D
## Renders a Tokyo section with the game's lighting and saves a PNG (visual
## QA of the map; needs a window, so do NOT pass --headless).
##
##   godot --path . res://test/tokyo_shot.tscn -- <out.png> [district|seed] [ortho] [pitch] [yaw] [dx] [dz]
##   (TT_DESTROY=<n> shows the n buildings nearest the centre collapsed)
##
## The second argument is a district id (a section near its middle) or a
## number (TokyoMap.random_section of that seed). dx / dz shift the camera
## target from the section's center.

const FRAMES := 30


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://tokyo.png"
	var which := args[1] if args.size() > 1 else "shibuya"
	get_window().size = Vector2i(1280, 720)
	var section: Dictionary
	if which == "sheet":
		section = { "district": TokyoMap.SHEET, "rect": MapData.random_section(3) }
	elif which.is_valid_int():
		section = TokyoMap.random_section(which.to_int())
	elif which.contains(":"):
		section = { "district": which.get_slice(":", 0), "zone": which.get_slice(":", 1).to_int() }
	else:
		section = { "district": which, "zone": 0 }
	print("section: ", TokyoMap.place_name(section), " ", TokyoMap.section_to_json(section))
	var hide := OS.get_environment("TT_HIDE").split(",", false)
	var ms := MatchRunner.build_match(TriggerLibrary.sample_units(), TriggerLibrary.sample_units(), 7, section)
	var main: Node3D = load("res://levels/board/main.gd").new()
	# Only the environment and lights of the battle scene.
	main._setup_environment()
	main._setup_lights()
	for c in main.get_children():
		main.remove_child(c)
		add_child(c)
		if c is DirectionalLight3D:
			print("light ", c.name, " ", c.rotation_degrees, " energy ", c.light_energy, " shadow ", c.shadow_enabled)
			if OS.get_environment("TT_NOSHADOW") == "1":
				c.shadow_enabled = false
			if OS.get_environment("TT_SHADOW_DIST") != "":
				c.directional_shadow_max_distance = OS.get_environment("TT_SHADOW_DIST").to_float()
			if OS.get_environment("TT_SHADOW_MODE") != "":
				c.directional_shadow_mode = OS.get_environment("TT_SHADOW_MODE").to_int()
	main.free()
	var board := CityBoard.new()
	add_child(board)
	board.set_city(ms)
	# TT_DESTROY=<n>: collapse the n buildings nearest the section's centre
	# (Ibis), to check the rubble.
	if OS.get_environment("TT_DESTROY") != "":
		var rects := ms.all_building_rects()
		var mid := ms.bounds().get_center()
		var order := range(rects.size())
		order.sort_custom(func(x: int, y: int) -> bool:
			return (rects[x]["c"] as Vector2).distance_to(mid) < (rects[y]["c"] as Vector2).distance_to(mid))
		ms.set_destroyed(order.slice(0, OS.get_environment("TT_DESTROY").to_int()))
		board.set_destroyed(ms)
	for n in hide:
		for node in board.find_children(n, "", true, false):
			(node as Node3D).visible = false
	var units := BoardUnits.new()
	board.add_child(units)
	units.setup(ms.all_units(), 1.0)
	units.set_map_bounds(ms.bounds())
	units.refresh()
	# TT_SELECT=<i>: select that character (cutaway) and frame it.
	var sel := OS.get_environment("TT_SELECT")
	var cam := BoardCamera.new()
	cam.start_size = float(args[2]) if args.size() > 2 else 50.0
	cam.pitch = deg_to_rad(float(args[3]) if args.size() > 3 else 50.0)
	cam.yaw = deg_to_rad(float(args[4]) if args.size() > 4 else 0.0)
	add_child(cam)
	var c := ms.bounds().get_center()
	if sel != "":
		var u: UnitState = ms.all_units()[sel.to_int()]
		units.set_selected(u)
		c = u.pos
	cam.target = Vector3(c.x + (float(args[5]) if args.size() > 5 else 0.0), 0, c.y + (float(args[6]) if args.size() > 6 else 0.0))
	cam._update_transform()
	if OS.get_environment("TT_SHADOW_DIST") != "":
		for l in get_tree().get_nodes_in_group(BoardCamera.SUN_GROUP):
			l.directional_shadow_max_distance = OS.get_environment("TT_SHADOW_DIST").to_float()
	for _i in FRAMES:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	get_tree().quit()
