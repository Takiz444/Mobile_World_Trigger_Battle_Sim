extends Node
## Renders the battle scene for a few frames and saves a PNG (visual QA).
## Needs a rendering window, so do NOT pass --headless.
##
## Run:
##   godot --path . res://test/screenshot.tscn -- <out.png> [ortho_size] [pitch_deg] [turns] [center]
##   godot --path . res://test/screenshot.tscn -- <out.png> hangar
## `turns` plays that many empty local turns first (the enemy AI advances).

const FRAMES := 45


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://screenshot.png"
	get_window().size = Vector2i(1280, 720)
	if args.size() > 1 and args[1] == "hangar":
		add_child(load("res://ui/hangar/hangar.tscn").instantiate())
		await _save_after_frames(out)
		return
	var main: Node = load("res://levels/board/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	var turns := int(args[3]) if args.size() > 3 else 0
	var controller := main.get_node_or_null("MatchController") as MatchController
	for _t in turns:
		if controller == null or controller._overlay.visible:
			break
		controller._build_enemy_plan()
		await controller._on_plan_submitted()
	var cam := get_viewport().get_camera_3d() as BoardCamera
	if cam != null and args.size() > 1:
		cam.size = float(args[1])
		if args.size() > 2:
			cam.pitch = deg_to_rad(float(args[2]))
		if args.size() > 4 and args[4] == "center":
			var board := main.get_node("HexBoard") as HexBoard
			cam.screen_offset_px = Vector2.ZERO
			cam.recenter(board.get_bounds().get_center())
			(main.get_node("UILayer") as CanvasLayer).visible = false
		else:
			cam.recenter(Vector3(cam.target.x, 0.0, cam.target.z - 12.0))
	await _save_after_frames(out)


func _save_after_frames(out: String) -> void:
	for _i in FRAMES:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("saved ", out)
	get_tree().quit()
