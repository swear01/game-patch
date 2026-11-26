extends Node

const SAMPLE_SECONDS := 0.30
const PHYSICS_BUDGET := 120.0
const MIN_MINING_TICKS := 12
const MIN_STOCK_MINER_TICKS := 9
const MAX_ACCELERATED_STEPS := 6
const MAX_CATCHUP_STEPS := 12
const HIGH_SPEED_CATCHUP_STEPS := 34
const CATCHUP_TARGET_FPS := 40.0
const HIGH_SPEED_TARGET_FPS := 35.0
const COVERED_REBUILD_STEPS := 1
const MAX_VALID_FRAME_DELTA := 8.0
const MINING_WORKERS := ["res://Actors/miner.gd", "res://Actors/digger.gd"]
const STOCK_BLOCK_SCRIPT := "res://Blocks/block.gd"
const MINE_OUTER_LEFT := -15.2
const MINE_OUTER_RIGHT := 13.6
const MINER_LEFT := -14.6
const MINER_RIGHT := 12.8
const MENU_PARTICLE_ROOTS := [
	"UpgradeScreens/LevelUp/NodesCanvasLayer",
	"UpgradeScreens/EvertreeTree/NodesCanvasLayer",
]
const TREE_CAMERA_CLOCK_FILES := {
	"res://LevelUp/level_up_camera.gd": "quarry-levelup-camera-clock.gd",
	"res://Evertree/evertree_camera.gd": "quarry-evertree-camera-clock.gd",
}

var _previous_wall := 0.0
var _previous_clock := 0
var _next_frame := 0.0
var _stock_ticks := 60
var _stock_steps := 8
var _desired_steps := 8
var _covered_generator: Node
var _requested_fps := 0
var _factor := 1.0
var _logged_factor := 1.0
var _workers: Dictionary = {}
var _wall_frame_pacing := true
var _visuals: Dictionary = {}
var _wind: Dictionary = {}
var _menu_emitters: Array[GPUParticles2D] = []
var _visual_scene: Node
var _lighter_view := false
var _visuals_trimmed := false
var _mining := false
var _pruned_blocks := 0
var _game: Node
var _resume_after_bad_frame := false
var _discarded_frames := 0
var _edge_recoveries := 0
var _block_audio: Script
var _rollover_script: Script
var _tree_camera_clocks: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 10000
	_stock_ticks = Engine.physics_ticks_per_second
	_stock_steps = Engine.max_physics_steps_per_frame
	_desired_steps = _stock_steps
	_requested_fps = Engine.max_fps
	_wall_frame_pacing = DisplayServer.get_name() != "headless"
	_previous_wall = Time.get_unix_time_from_system()
	_previous_clock = Time.get_ticks_usec()
	_game = get_tree().root.get_node("global")
	var block_pool := get_tree().root.get_node("block_pool")
	_block_audio = block_pool.get_script().get_script_constant_map().get("QuarryBlock") as Script
	if _block_audio != null:
		var impact_script := load(get_script().resource_path.get_base_dir().path_join("quarry-impact-player.gd")) as Script
		if impact_script != null:
			var impact_player: Node = impact_script.new()
			impact_player.name = "QuarryImpact"
			add_child(impact_player)
			_block_audio.impact_player = impact_player
	# The engine's absolute QPC frame deadline can become stale when OpenSpeedy
	# rebases the clock. Keep the real-time cap here, including when minimized.
	Engine.max_fps = 0
	OS.low_processor_usage_mode_sleep_usec = 0
	get_tree().node_added.connect(_register_worker)
	get_tree().node_removed.connect(_forget_worker)
	var rollover_path: String = get_script().resource_path.get_base_dir().path_join("quarry-mine-rollover.gd")
	if ResourceLoader.exists(rollover_path):
		_rollover_script = load(rollover_path) as Script
		get_tree().node_added.connect(_install_rollover)
	_load_tree_camera_clocks()
	get_tree().process_frame.connect(_update_physics_budget)
	var control_script: Script = load(get_script().resource_path.get_base_dir().path_join("quarry-control.gd"))
	if control_script != null:
		var control: Node = control_script.new()
		add_child(control)
		control.initialize()
	print("Quarry OpenSpeedy compatibility loaded (mining and clock)")

func _install_rollover(node: Node) -> void:
	if node.name != &"MineGenerator" or _rollover_script == null:
		return
	var stock: Script = node.get_script()
	if stock != null and stock.resource_path == "res://mine_generator.gd":
		node.set_script(_rollover_script)

func _load_tree_camera_clocks() -> void:
	var directory: String = get_script().resource_path.get_base_dir()
	for stock_path in TREE_CAMERA_CLOCK_FILES:
		var replacement_path := directory.path_join(TREE_CAMERA_CLOCK_FILES[stock_path])
		if ResourceLoader.exists(replacement_path):
			var replacement := load(replacement_path) as Script
			if replacement != null:
				_tree_camera_clocks[stock_path] = replacement
	if not _tree_camera_clocks.is_empty():
		get_tree().node_added.connect(_install_tree_camera_clock)

func _install_tree_camera_clock(node: Node) -> void:
	if not node is Camera2D:
		return
	var stock := node.get_script() as Script
	if stock == null:
		return
	var replacement := _tree_camera_clocks.get(stock.resource_path) as Script
	if replacement != null:
		# The scene has attached its script, but the camera's inherited _ready
		# and its owning tree's onready references have not yet run.
		node.set_script(replacement)

func _update_physics_budget() -> void:
	_guard_frame(get_process_delta_time())
	var wall := Time.get_unix_time_from_system()
	_update_speed(wall)
	_apply_physics_step_cap()
	_skip_empty_block_updates()
	if _mining and _factor > 15.0 and not get_tree().paused:
		_keep_miners_in_quarry()
	_update_visuals()
	_keep_cursor_position()
	_steady_camera()
	_pace_frame(wall)

func _guard_frame(delta: float) -> void:
	var tree := get_tree()
	if is_finite(delta) and delta >= 0.0 and delta <= MAX_VALID_FRAME_DELTA:
		if _resume_after_bad_frame:
			tree.paused = false
			_resume_after_bad_frame = false
		return
	# An OpenSpeedy clock rewind can underflow Godot's unsigned counter.
	# Skip this frame before it reaches the game countdown and looping tweens.
	if not tree.paused:
		tree.paused = true
		_resume_after_bad_frame = true
	_discarded_frames += 1
	_discard_looping_decorations()
	_discard_looping_decorations.call_deferred()
	print("Quarry OpenSpeedy: discarded invalid frame delta %.3f" % delta)

func _discard_looping_decorations() -> void:
	# The shipped game's infinite tweens are decorative purchase hints.
	for tween in get_tree().get_processed_tweens():
		if tween.get_loops_left() == -1:
			tween.kill()

func set_covered_rebuild(generator: Node, active: bool) -> void:
	if active:
		_covered_generator = generator
	elif is_instance_valid(_covered_generator) and _covered_generator == generator:
		_covered_generator = null
	_apply_physics_step_cap()

func _apply_physics_step_cap() -> void:
	var steps := _desired_steps
	if is_instance_valid(_covered_generator):
		if not _covered_generator.is_inside_tree() or _game.get("game_info")["time_running"]:
			_covered_generator = null
		elif _factor >= 15.0:
			# Keep collision updates live without running accelerated catch-up
			# while there is no active mining and the wipe covers the rebuild.
			steps = mini(steps, COVERED_REBUILD_STEPS)
	if Engine.max_physics_steps_per_frame != steps:
		Engine.max_physics_steps_per_frame = steps

func _update_speed(wall: float) -> void:
	# GetSystemTime is independent of the OpenSpeedy QPC hook.
	var elapsed := wall - _previous_wall
	if elapsed >= 0.0 and elapsed < SAMPLE_SECONDS:
		return
	var clock := Time.get_ticks_usec()
	var game_elapsed := (clock - _previous_clock) * 0.000001
	_previous_wall = wall
	_previous_clock = clock
	if elapsed < SAMPLE_SECONDS or elapsed > 5.0 or game_elapsed <= 0.0:
		return
	var factor := game_elapsed / elapsed
	if not is_finite(factor) or factor < 0.0005 or factor > 1050.0:
		return
	_factor = factor
	if _block_audio != null:
		# A large crew can saturate positional playback at a lower multiplier.
		var crowded := _workers.size() >= 16
		var enter_compact := 9.5 if crowded else 31.0
		var leave_compact := 8.5 if crowded else 28.0
		_block_audio.compact_impacts = factor > enter_compact or (_block_audio.compact_impacts and factor > leave_compact)
		if is_instance_valid(_block_audio.impact_player):
			_block_audio.impact_player.enable(_block_audio.compact_impacts)
	# Mining and ground contacts must get a bounded step even at high multipliers.
	var minimum := MIN_MINING_TICKS
	if factor > 15.0 and _can_reduce_miner_steps():
		minimum = MIN_STOCK_MINER_TICKS
	var ticks := clampi(roundi(PHYSICS_BUDGET / factor), minimum, _stock_ticks)
	# Let high speeds use the headroom from pruning, but don't build up an
	# unbounded backlog. At six steps and 45 FPS, 9 Hz can only reach 30×.
	var steps := mini(_stock_steps, MAX_ACCELERATED_STEPS) if factor > 2.0 else _stock_steps
	if factor >= 20.0 and _pruned_blocks > 0:
		# Keep the conservative cap for the normal presets and special units.
		# Stock miners can use the extra headroom from coalescing audio.
		if _block_audio != null and factor >= 45.0 and ticks == MIN_STOCK_MINER_TICKS:
			steps = clampi(ceili(roundf(factor) * ticks / HIGH_SPEED_TARGET_FPS) + 1, steps, HIGH_SPEED_CATCHUP_STEPS)
		else:
			steps = clampi(ceili(roundf(factor) * ticks / CATCHUP_TARGET_FPS) + 1, steps, MAX_CATCHUP_STEPS)
	if Engine.physics_ticks_per_second != ticks:
		Engine.physics_ticks_per_second = ticks
	_desired_steps = steps
	for worker in _workers.values():
		_set_mining_clock(worker, factor > 1.05)
		_set_mining_ray(worker, factor)
	if absf(factor - _logged_factor) > maxf(0.03, _logged_factor * 0.06):
		_logged_factor = factor
		print("Quarry OpenSpeedy: %.3fx; %d physics ticks/game-second, %d max steps/frame" % [factor, ticks, steps])

func _register_worker(node: Node) -> void:
	if _lighter_view and node is Light3D:
		_lighten_node.call_deferred(node)
	var script: Script = node.get_script()
	if script == null or script.resource_path not in MINING_WORKERS:
		return
	var animation := node.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var timer := node.get_node_or_null("MiningDelay") as Timer
	if animation == null or timer == null:
		return
	# Only the stock miner's execution paths have been validated to force a
	# fresh query before every read. Leave other actors and their sensors alone.
	var ray: RayCast3D
	if script.resource_path == MINING_WORKERS[0]:
		ray = node.get_node_or_null("MineableCheckRaycast") as RayCast3D
	var worker := [animation, timer, animation.callback_mode_process, timer.process_callback, node, ray, ray != null and ray.enabled]
	_workers[node.get_instance_id()] = worker
	_set_mining_clock(worker, _factor > 1.05)
	_set_mining_ray(worker, _factor)

func _forget_worker(node: Node) -> void:
	_workers.erase(node.get_instance_id())

func _can_reduce_miner_steps() -> bool:
	# Faster or heavier workers need the usual floor for their ground sensors.
	if _workers.is_empty():
		return false
	var root := get_tree().root
	var unlocks: Dictionary = _game.get("unlocks")
	if unlocks.get("drill", false) or unlocks.get("exploder", false) or unlocks.get("supervisor", false) or unlocks.get("necromancer", false):
		return false
	var ascension: Dictionary = root.get_node("ascension").get("nodes")
	if ascension.get("drill_miner_teleport", false):
		return false
	for worker in _workers.values():
		var unit: Node = worker[4]
		if unit.get("type") != "miner" or unit.get("supervisor_buffed") or unit.get("movement_speed") > 7.0:
			return false
	return true

func _skip_empty_block_updates() -> void:
	var scene := get_tree().current_scene
	var mining := is_instance_valid(scene) and scene.name == "Level" and bool(_game.get("game_info")["time_running"])
	if mining and not _mining:
		_pruned_blocks = 0
		var pool := get_tree().root.get_node("block_pool")
		if pool.has_method("take_prepruned_callback_count"):
			# Keep the catch-up budget when this pool did the pruning during generation.
			_pruned_blocks = int(pool.call("take_prepruned_callback_count"))
		# BlockPool enables this callback again each time the mine is generated.
		# This only unschedules the block's script callback, not its physics body.
		for block in get_tree().get_nodes_in_group("Block"):
			if not block.is_physics_processing():
				continue
			var script := block.get_script() as Script
			if script == null or (script.resource_path != STOCK_BLOCK_SCRIPT and script != _block_audio):
				continue
			if not script.has_script_method(&"_physics_process") and not script.has_script_method(&"_notification"):
				block.set_physics_process(false)
				_pruned_blocks += 1
	_mining = mining

func _set_mining_clock(worker: Array, accelerated: bool) -> void:
	# The animation's method track lands the hit. Advance it on the same clock
	# as MiningDelay so the timer can't keep restarting an unfinished strike.
	var animation: AnimationPlayer = worker[0]
	var timer: Timer = worker[1]
	var animation_mode: int = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS if accelerated else worker[2]
	var timer_mode: int = Timer.TIMER_PROCESS_PHYSICS if accelerated else worker[3]
	if animation.callback_mode_process != animation_mode:
		animation.callback_mode_process = animation_mode
	if timer.process_callback != timer_mode:
		timer.process_callback = timer_mode

func _set_mining_ray(worker: Array, factor: float) -> void:
	var ray: RayCast3D = worker[5]
	if ray == null or not worker[6]:
		return
	# force_raycast_update() remains available when automatic updates are off.
	var automatic := factor < (20.0 if ray.enabled else 18.0)
	if ray.enabled != automatic:
		ray.enabled = automatic

func _keep_miners_in_quarry() -> void:
	# Automatic movement can overshoot the outside wall at a coarse step.
	# Past the 18-column grid there is no floor and a miner can fall forever.
	# Use the stock movement endpoints, leaving travel inside the grid alone.
	for worker in _workers.values():
		if worker[5] == null:
			continue
		var unit: Node3D = worker[4]
		var point := unit.global_position
		if point.x < MINE_OUTER_LEFT or point.x > MINE_OUTER_RIGHT:
			point.x = clampf(point.x, MINER_LEFT, MINER_RIGHT)
			unit.global_position = point
			_edge_recoveries += 1

func _update_visuals() -> void:
	var scene := get_tree().current_scene
	var trim := is_instance_valid(scene) and scene.name == "Level" and _factor > 1.05
	var lighter := is_instance_valid(scene) and scene.name == "Level" and (
		_factor > 15.0 or (_lighter_view and _factor > 12.0))
	if _visual_scene == scene and _lighter_view == lighter and _visuals_trimmed == trim:
		return
	for item in _visuals.values():
		if is_instance_valid(item[0]):
			item[0].set(item[1], item[2])
	_visuals.clear()
	for item in _wind.values():
		item[0].set_shader_parameter(&"wind_strength", item[1])
	_wind.clear()
	for emitter in _menu_emitters:
		if is_instance_valid(emitter):
			emitter.set_physics_process_internal(true)
	_menu_emitters.clear()
	_visual_scene = scene
	_lighter_view = lighter
	_visuals_trimmed = trim
	if lighter:
		for light in scene.find_children("*", "Light3D", true, false):
			_lighten_node(light)
		for environment in scene.find_children("*", "WorldEnvironment", true, false):
			if environment.environment != null:
				_reduce_visual(environment.environment, &"glow_enabled")
		for path in MENU_PARTICLE_ROOTS:
			var branch := scene.get_node_or_null(path)
			if branch == null:
				continue
			for emitter: GPUParticles2D in branch.find_children("*", "GPUParticles2D", true, false):
				if emitter.get_script() == null and emitter.is_physics_processing_internal():
					# Godot 4.5.1's physics callback only tracks emitter
					# velocity. Keep rendering, emission and finished intact.
					emitter.set_physics_process_internal(false)
					_menu_emitters.append(emitter)
	if not trim:
		return
	var terrain := scene.get_node_or_null("TerrainSprites")
	if terrain != null:
		for sprite in terrain.find_children("*", "Sprite3D", true, false):
			var material := sprite.material_override as ShaderMaterial
			if material == null or material.shader == null or material.shader.resource_path != "res://Shaders/wind_shader.gdshader":
				continue
			var id := material.get_instance_id()
			if not _wind.has(id):
				_wind[id] = [material, material.get_shader_parameter(&"wind_strength")]
				material.set_shader_parameter(&"wind_strength", 0.0)
	# These emitters are purely visual. Keep their nodes and scripts intact:
	# the Geomancer's casting and mine reset still run normally.
	for effect in get_tree().get_nodes_in_group("Geomancer Particles"):
		if effect is GPUParticles3D and scene.is_ancestor_of(effect):
			_trim_particles(effect)
	var ring_mesh := scene.get_node_or_null("Evertree/EvertreeShaderRing") as MeshInstance3D
	if ring_mesh != null:
		# The ring samples and displaces the screen behind it even when the
		# camera is stationary. Hide the effect, not the Evertree.
		_reduce_visual(ring_mesh, &"visible")
	var ring := scene.get_node_or_null("Evertree/EvertreeShaderRing/EvertreeRingParticles") as GPUParticles3D
	if ring != null:
		_trim_particles(ring)
		_reduce_visual(ring, &"emitting")

func _lighten_node(light: Light3D) -> void:
	if not _lighter_view or not is_instance_valid(light) or not is_instance_valid(_visual_scene):
		return
	if not _visual_scene.is_ancestor_of(light):
		return
	_reduce_visual(light, &"shadow_enabled")

func _reduce_visual(object: Object, property: StringName) -> void:
	if not object.get(property):
		return
	_visuals[[object.get_instance_id(), property]] = [object, property, true]
	object.set(property, false)

func _trim_particles(effect: GPUParticles3D) -> void:
	_reduce_visual(effect, &"visible")
	var property := &"amount_ratio"
	_visuals[[effect.get_instance_id(), property]] = [effect, property, effect.amount_ratio]
	effect.amount_ratio = 0.0

func _keep_cursor_position() -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.name != &"Level":
		return
	var cursor := scene.get_node_or_null(^"Cursor")
	if cursor == null:
		return
	var script := cursor.get_script() as Script
	# The stock initialization flag only guards a mouse warp. Set it before
	# the cursor processes so the mining pointer still follows the real mouse.
	if script != null and script.resource_path == "res://cursor.gd" and cursor.get(&"initialized") == false:
		cursor.set(&"initialized", true)

func _steady_camera() -> void:
	var scene := get_tree().current_scene
	if not is_instance_valid(scene) or scene.name != "Level":
		return
	var camera := scene.get_node_or_null("Camera") as Camera3D
	if camera == null:
		return
	var autopan := bool(_game.get("settings").get("camera_autopan", true))
	# The stock menu gates the Start Day pan, but the Geomancer also
	# resets the camera via a separate group at the end of the day.
	const RESET_GROUP := &"Reset from Geomancer"
	if camera.is_in_group(RESET_GROUP) != autopan:
		if autopan:
			camera.add_to_group(RESET_GROUP)
		else:
			camera.remove_from_group(RESET_GROUP)
	if not autopan and (camera.get("panning_to_starting_layer") or camera.get("resetting_position")):
		camera.set("panning_to_starting_layer", false)
		camera.set("resetting_position", false)
		camera.set("disable_camera_input", false)

func _pace_frame(wall: float) -> void:
	if Engine.max_fps != 0:
		_requested_fps = Engine.max_fps
		Engine.max_fps = 0
	if not _wall_frame_pacing or _requested_fps <= 0:
		return
	if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED:
		var refresh := DisplayServer.screen_get_refresh_rate()
		if refresh > 0.0 and refresh <= _requested_fps + 0.25:
			_next_frame = 0.0
			return
	var period := 1.0 / _requested_fps
	var target := _next_frame
	# A wall clock adjustment or slow frame must never leave a backlog of waits.
	if target - wall > period:
		target = wall
	var now := Time.get_unix_time_from_system()
	while now >= wall and now < target:
		var remaining := target - now
		if remaining > 0.002 and _factor >= 0.95:
			# Sleep itself is accelerated. Keep each request bounded in case
			# the user changes the multiplier before the next speed sample.
			OS.delay_msec(clampi(floori((remaining - 0.0015) * _factor * 1000.0), 1, 48))
		now = Time.get_unix_time_from_system()
	_next_frame = maxf(target, now - period * 0.25) + period
