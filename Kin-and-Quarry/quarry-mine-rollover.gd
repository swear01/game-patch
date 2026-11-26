extends "res://mine_generator.gd"

const COVERED_POSITION := 0.4
const SLICE_SECONDS := 0.007
const FAST_SLICE_SECONDS := 1000.0

var _rolling_over := false
var _reuse_tiles := false

func begin_regenerating_mine():
	if global.keep_current_day:
		super.begin_regenerating_mine()
		return
	if _rolling_over:
		return
	_rolling_over = true
	goals.determine_rewards()
	var anim: AnimationPlayer = mine_reset_canvas_layer.get("mine_reset_anim")
	var stock_callback := anim.callback_mode_process
	anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	mine_reset_canvas_layer.reset()
	# The stock wipe fully covers the mine at 0.4 s. Hold it there so the
	# reset callback cannot enable Start Day before the replacement terrain.
	var elapsed := 0.0
	while elapsed < COVERED_POSITION:
		await get_tree().process_frame
		if get_tree().paused:
			continue
		var step := minf(get_process_delta_time(), COVERED_POSITION - elapsed)
		anim.advance(step)
		elapsed += step
	get_tree().call_group("GUI", "check_layer_clear")
	var compat := get_tree().root.get_node_or_null("QuarryOpenSpeedy")
	if compat != null and compat.has_method("set_covered_rebuild"):
		compat.call("set_covered_rebuild", self, true)
	if is_instance_valid(compat) and float(compat.get("_factor")) >= 45.0 and RenderingServer.render_loop_enabled and DisplayServer.get_name() != "headless":
		# Give the completely covered frame one full render pass before the burst.
		await get_tree().process_frame
		if not is_inside_tree():
			return
	await _rebuild_for_rollover()
	if is_inside_tree() and not get_tree().paused and is_instance_valid(compat) and float(compat.get("_factor")) >= 45.0:
		# Finish the now-ready wipe without dropping its stock reset method key.
		var remaining_wipe := anim.current_animation_length - anim.current_animation_position
		anim.advance(maxf(0.0, remaining_wipe) + 0.00001)
		# Give the queued reset a low-pressure iteration before restoring catch-up.
		await get_tree().process_frame
	if is_instance_valid(compat) and compat.has_method("set_covered_rebuild"):
		compat.call("set_covered_rebuild", self, false)
	if is_inside_tree():
		anim.callback_mode_process = stock_callback

func _rebuild_for_rollover():
	items.reset_artifact_pool()
	block_pool.reset_block_data()
	x_offset = grid_width / 2.0
	_reuse_tiles = block_pool.begin_rollover_reuse(grid_width * grid_height)
	if not _reuse_tiles:
		await block_pool.call("prepare_rollover", self)
		if not is_inside_tree():
			return

	if global.game_info["tutorial_step"] == 2\
	and global.tutorial:
		if helpers.artifact_queue.size() <= 0:
			run_tutorial()
		else:
			awaiting_tutorial = true


	mine_blocks.clear()
	mine_blocks.resize(grid_height)
	for y in range(grid_height):
		var row: Array = []
		row.resize(grid_width)
		mine_blocks[y] = row



	noise1.seed = randi()
	noise1.fractal_octaves = 4
	noise1.frequency = 0.6
	noise1.fractal_gain = 0.5


	noise2.seed = randi()
	noise2.fractal_octaves = 3
	noise2.frequency = 0.25
	noise2.fractal_gain = 0.5


	noise3.seed = randi()
	noise3.fractal_octaves = 4
	noise3.frequency = 0.25
	noise3.fractal_gain = 0.5


	noise4.seed = randi()
	noise4.fractal_octaves = 4
	noise4.frequency = 0.5
	noise4.fractal_gain = 0.5

	await generate_blocks(grid_height)
	if _reuse_tiles:
		block_pool.finish_rollover_reuse()

func _rollover_slice_seconds() -> float:
	# The high-speed compatibility guard lowers the cap while the wipe is fully covered.
	# Use some of that freed frame time for terrain without changing ordinary play.
	return FAST_SLICE_SECONDS if Engine.max_physics_steps_per_frame == 1 else SLICE_SECONDS

# Same tile order and rules as the shipped generator; yield between rows only
# for a normal end-of-day reset. Initial load and starting-layer changes are stock.
func generate_blocks(amount, define_artifact_and_effect: bool = true):
	if not _rolling_over:
		super.generate_blocks(amount, define_artifact_and_effect)
		return

	blocks.reset_block_count()
	var slice_started := Time.get_unix_time_from_system()
	var slice_seconds := _rollover_slice_seconds()
	# Ownership and collection can change between frames, so keep cached
	# eligibility only during the reused-grid synchronous burst.
	var artifact_cache: bool = _reuse_tiles and define_artifact_and_effect and slice_seconds == FAST_SLICE_SECONDS and block_pool.begin_rollover_artifact_cache()
	var defer_materials: bool = _reuse_tiles and slice_seconds == FAST_SLICE_SECONDS and block_pool.begin_rollover_materials()
	for y in range(amount):
		if y > 0 and Time.get_unix_time_from_system() - slice_started >= slice_seconds:
			if artifact_cache:
				block_pool.end_rollover_artifact_cache()
				artifact_cache = false
			if defer_materials:
				block_pool.end_rollover_materials()
				defer_materials = false
			await get_tree().process_frame
			slice_started = Time.get_unix_time_from_system()
			slice_seconds = _rollover_slice_seconds()
		var starting_layer = global.game_info["starting_layer"]
		var abandon: bool = false
		if starting_layer == 14 and y < 476: abandon = true
		elif starting_layer == 13 and y < 436: abandon = true
		elif starting_layer == 12 and y < 396: abandon = true
		elif starting_layer == 11 and y < 356: abandon = true
		elif starting_layer == 10 and y < 316: abandon = true
		elif starting_layer == 9 and y < 276: abandon = true
		elif starting_layer == 8 and y < 236: abandon = true
		elif starting_layer == 7 and y < 196: abandon = true
		elif starting_layer == 6 and y < 156: abandon = true
		elif starting_layer == 5 and y < 116: abandon = true
		elif starting_layer == 4 and y < 76: abandon = true
		elif starting_layer == 3 and y < 40: abandon = true
		elif starting_layer == 2 and y < 16: abandon = true
		for x in range(grid_width):

			var layer: int = 1

			if abandon:


				block_type = "null"
			else:

				if y == 0:
					block_type = "grass"
					layer = 1
				elif y < 16 or y >= 556:
					# Deeper rows choose their own material below.

					layer = 1
					var noise_value = noise1.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.2:
						block_type = "wood"
					elif noise_value < 0.0:
						block_type = "dirt"
					elif noise_value > 0.3 and noise_value < 0.4:
						block_type = "null"
					else:
						block_type = "dirt"
				if y >= 16 and y < 40:

					layer = 2
					var noise_value = noise2.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.35:
						block_type = "coal"
					elif noise_value < -0.1 and noise_value > -0.22:
						block_type = "limestone"
					elif noise_value > 0.25:
						block_type = "tin"
					elif noise_value > -0.11 and noise_value < 0.03:
						block_type = "null"
					else:
						block_type = "stone"
				elif y >= 40 and y < 76:

					layer = 3
					var noise_value = noise2.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.35:
						block_type = "copper"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "coal"
					elif noise_value > 0.32:
						block_type = "iron"
					elif noise_value > -0.14 and noise_value < 0.09:
						block_type = "null"
					else:
						block_type = "stone"
				elif y >= 76 and y < 116:

					layer = 4
					var noise_value = noise3.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.3:
						block_type = "lead"
					elif noise_value < -0.05 and noise_value > -0.22:
						block_type = "barium"
					elif noise_value > -0.14 and noise_value < 0.09:
						block_type = "null"
					else:
						block_type = "slate"
				elif y >= 116 and y < 156:

					layer = 5
					var noise_value = noise3.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.29:
						block_type = "manganese"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "bauxite"
					elif noise_value > 0.29:
						block_type = "iron"
					elif noise_value > -0.13 and noise_value < 0.08:
						block_type = "null"
					else:
						block_type = "slate"
				elif y >= 156 and y < 196:

					layer = 6
					var noise_value = noise4.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.29:
						block_type = "zinc"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "lead"
					elif noise_value > 0.29:
						block_type = "magnesium"
					elif noise_value > -0.12 and noise_value < 0.07:
						block_type = "null"
					else:
						block_type = "navystone"
				elif y >= 196 and y < 236:

					layer = 7
					var noise_value = noise4.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.29:
						block_type = "silver"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "tin"
					elif noise_value > 0.5:
						block_type = "gold"
					elif noise_value > -0.11 and noise_value < 0.06:
						block_type = "null"
					else:
						block_type = "navystone"
				elif y >= 236 and y < 276:

					layer = 8
					var noise_value = noise4.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.29:
						block_type = "platinum"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "gold"
					elif noise_value > 0.29:
						block_type = "nickel"
					elif noise_value > -0.11 and noise_value < 0.05:
						block_type = "null"
					else:
						block_type = "basalt"
				elif y >= 276 and y < 316:

					layer = 9
					var noise_value = noise4.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.15:
						block_type = "niobium"
					elif noise_value < 0.03 and noise_value > -0.03:
						block_type = "null"
					elif noise_value > 0.15:
						block_type = "mercury"
					elif noise_value > -0.11 and noise_value < 0.04:
						block_type = "null"
					else:
						block_type = "basalt"
				elif y >= 316 and y < 356:

					layer = 10
					var noise_value = noise4.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.29:
						block_type = "titanium"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "cobalt"
					elif noise_value > 0.29:
						block_type = "niobium"
					elif noise_value > -0.11 and noise_value < 0.03:
						block_type = "null"
					else:
						block_type = "deepmoss"
				elif y >= 356 and y < 396:

					layer = 11
					var noise_value = noise4.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.29:
						block_type = "molybdenum"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "tantalum"
					elif noise_value > 0.29:
						block_type = "magnesium"
					elif noise_value > -0.11 and noise_value < 0.03:
						block_type = "null"
					else:
						block_type = "deepmoss"
				elif y >= 396 and y < 436:

					layer = 12
					var noise_value = noise4.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.29:
						block_type = "quartz"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "molybdenum"
					elif noise_value > 0.29:
						block_type = "tungsten"
					elif noise_value > -0.11 and noise_value < 0.03:
						block_type = "null"
					else:
						block_type = "marble"
				elif y >= 436 and y < 476:

					layer = 13
					var noise_value = noise4.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.29:
						block_type = "quartz"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "molybdenum"
					elif noise_value > 0.29:
						block_type = "tungsten"
					else:
						block_type = "marble"
				elif y >= 476 and y < 556:

					layer = 14
					var noise_value = noise4.get_noise_2d(x * 0.1, y * 0.1)
					if noise_value < -0.29:
						block_type = "chromium"
					elif noise_value < 0.0 and noise_value > -0.17:
						block_type = "uranium"
					elif noise_value > 0.29:
						block_type = "tungsten"
					else:
						block_type = "granite"

			var y_pos = (( - y * div) - 0.8)
			var cell_position := Vector3(((x - x_offset) * div), y_pos, 0.8)
			var block_inst = block_pool.get_rollover_block(block_type, cell_position, _reuse_tiles)
			if not _reuse_tiles:
				block_inst.position = cell_position

			if block_type == "null":
				var was_converted = false

				if perks.nodes["null_to_wood"] > 0:
					var ntw_perk = perks.nodes["null_to_wood"] * perks.node_info["null_to_wood"]["amount"]
					var null_to_wood_layer = ntw_perk
					if layer <= null_to_wood_layer and layer >= global.game_info["starting_layer"]:
						block_type = "wood"
						was_converted = true


						blocks.add_block_count(layer)


						block_inst.block_layer = layer
						block_inst.block_type = block_type
						block_inst.max_health = blocks.block_info[block_type]["max_health"]

						block_inst.define(define_artifact_and_effect)

						block_inst.check_goal_completion()

						mine_blocks[y][x] = block_inst

				if !was_converted and perks.nodes["null_to_coal"] > 0:
					var ntc_perk = perks.nodes["null_to_coal"] * perks.node_info["null_to_coal"]["amount"]
					var null_to_coal_layer = 5 + ntc_perk



					if layer > 5 and layer <= null_to_coal_layer and layer >= global.game_info["starting_layer"]:
						block_type = "coal"
						was_converted = true


						blocks.add_block_count(layer)


						block_inst.block_layer = layer
						block_inst.block_type = block_type
						block_inst.max_health = blocks.block_info[block_type]["max_health"]

						block_inst.define(define_artifact_and_effect)

						block_inst.check_goal_completion()

						mine_blocks[y][x] = block_inst

				if !was_converted and block_type == "null":

					block_inst.visible = false
					block_inst.prepared = false
					block_inst.collision_shape.disabled = true
					block_inst.set_collision_layer_value(4, false)
					block_inst.set_collision_layer_value(1, false)
					block_inst.set_collision_mask_value(1, false)
					block_inst.set_physics_process(false)
			else:
				if perks.nodes["misc_to_dirt"] > 0:
					var mtd_perk = perks.nodes["misc_to_dirt"] * perks.node_info["misc_to_dirt"]["amount"]
					var misc_to_dirt_layer = 1 + mtd_perk

					var is_misc = blocks.check_if_misc(block_type)
					if layer > 1 and layer <= misc_to_dirt_layer and is_misc:


						block_type = "dirt"


				blocks.add_block_count(layer)

				block_inst.block_layer = layer
				block_inst.block_type = block_type
				block_inst.max_health = blocks.block_info[block_type]["max_health"]

				block_inst.define(define_artifact_and_effect)

				block_inst.check_goal_completion()

				mine_blocks[y][x] = block_inst
			if _reuse_tiles:
				# Ignore damage from a previous day's lingering effects until ready.
				block_inst.prepared = false
	if artifact_cache:
		block_pool.end_rollover_artifact_cache()
	if defer_materials:
		block_pool.end_rollover_materials()
	_rolling_over = false
