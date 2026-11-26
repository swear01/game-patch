extends "res://Pools/block_pool.gd"

const QuarryBlock = preload("quarry-block-audio.gd")
const WARMUP_CHUNK := 160
const MATERIAL_BAND_HEIGHT := 16.0
# The stock MeshBlock vanishes at 26 m with 1 m of hysteresis. The
# extra metre covers its bounds and makes this vertical test conservative.
const MATERIAL_BAND_RADIUS := 28.0
var _reuse_prune_empty_callbacks := false
var _prepruned_callback_count := 0
var _collect_material_bands := false
var _material_bands: Dictionary = {}

func _initialize_pool() -> void:
	# Preserve the exact pool size and order. The stock 10 per frame makes
	# initialization take 936 frames even when the CPU has spare time.
	for first in range(0, POOL_SIZE, WARMUP_CHUNK):
		if not _is_initializing:
			return
		var end := mini(first + WARMUP_CHUNK, POOL_SIZE)
		for index in range(first, end):
			var block: Node3D = block_scene.instantiate()
			_configure_block(block)
			_blocks.append(block)
			add_child(block)
		blocks_loaded = end
		_initialization_progress = float(end) / POOL_SIZE
		initialization_progress.emit(_initialization_progress)
		await get_tree().process_frame
	_is_initializing = false
	initialization_complete.emit()
	print("Quarry BlockPool: initialization complete (", blocks_loaded, " blocks)")

func reset_pool() -> void:
	_prepruned_callback_count = 0
	if not _is_initializing:
		QuarryBlock.release_mine_sonars()
	super.reset_pool()

func begin_rollover_reuse(cell_count: int) -> bool:
	_prepruned_callback_count = 0
	_reuse_prune_empty_callbacks = false
	if _is_initializing or _is_resetting or _blocks.size() != cell_count:
		return false
	# An exact stock-compatible block has no callback to run. Preserve the
	# ordinary activation path outside the covered one-step high-speed rebuild.
	var block_script: Script = QuarryBlock
	var prune: bool = Engine.max_physics_steps_per_frame == 1 and not block_script.has_script_method(&"_physics_process") and not block_script.has_script_method(&"_notification")
	for block in _blocks:
		if not is_instance_valid(block):
			return false
		if prune and block.get_script() != QuarryBlock:
			prune = false
		# Old tiles remain behind the wipe until their slot is rewritten.
		block.prepared = false
	_reuse_prune_empty_callbacks = prune
	QuarryBlock.release_mine_sonars()
	_current_index = 0
	_active_blocks.clear()
	return true

func finish_rollover_reuse() -> void:
	if _collect_material_bands:
		_material_bands.clear()
	for block in _active_blocks:
		block.prepared = block.visible
		if _reuse_prune_empty_callbacks and block.visible:
			_prepruned_callback_count += 1
		if _collect_material_bands and block.visible:
			var band := floori(block.global_position.y / MATERIAL_BAND_HEIGHT)
			if not _material_bands.has(band):
				_material_bands[band] = []
			_material_bands[band].append(block)
	if _collect_material_bands and not RenderingServer.frame_pre_draw.is_connected(_flush_visible_material_bands):
		RenderingServer.frame_pre_draw.connect(_flush_visible_material_bands)
	_collect_material_bands = false

func begin_rollover_materials() -> bool:
	if not RenderingServer.render_loop_enabled or DisplayServer.get_name() == "headless":
		return false
	var mesh: MeshInstance3D = _blocks[0].mesh_block
	if mesh.visibility_range_end != 26.0 or mesh.visibility_range_end_margin != 1.0:
		return false
	_collect_material_bands = true
	QuarryBlock.capture_rollover_materials = true
	return true

func end_rollover_materials() -> void:
	QuarryBlock.capture_rollover_materials = false

func _flush_visible_material_bands() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var y := camera.get_camera_transform().origin.y
	var first := floori((y - MATERIAL_BAND_RADIUS) / MATERIAL_BAND_HEIGHT)
	var last := floori((y + MATERIAL_BAND_RADIUS) / MATERIAL_BAND_HEIGHT)
	for band in range(first, last + 1):
		if not _material_bands.has(band):
			continue
		for block in _material_bands[band]:
			if is_instance_valid(block) and block.visible:
				block.flush_rollover_material()
		_material_bands.erase(band)
	if _material_bands.is_empty():
		RenderingServer.frame_pre_draw.disconnect(_flush_visible_material_bands)

func begin_rollover_artifact_cache() -> bool:
	return QuarryBlock.begin_rollover_artifact_cache()

func end_rollover_artifact_cache() -> void:
	QuarryBlock.end_rollover_artifact_cache()

func take_prepruned_callback_count() -> int:
	var count := _prepruned_callback_count
	_prepruned_callback_count = 0
	return count

func get_rollover_block(tile_type: String, cell_position: Vector3, reuse_tiles: bool) -> Node3D:
	if tile_type == "null" and not reuse_tiles:
		# Holes may never receive a final definition; keep their exact setup.
		return get_block(true)
	var block: QuarryBlock = _blocks[_current_index]
	_current_index = (_current_index + 1) % _blocks.size()
	if reuse_tiles:
		if _reuse_prune_empty_callbacks and block.is_physics_processing():
			block.set_physics_process(false)
		# Avoid moving the collider off-map and through the origin each day.
		if block.position != cell_position:
			block.position = cell_position
		if block.rotation != Vector3.ZERO:
			block.rotation = Vector3.ZERO
		if block.scale != Vector3.ONE:
			block.scale = Vector3.ONE
		if tile_type == "null":
			if not _reuse_prune_empty_callbacks:
				block.set_physics_process(true)
			block.block_type = "dirt"
			block.health = 0.0
			block.being_destroyed = false
			block.define(false)
			_active_blocks.append(block)
			return block
	# The mine generator immediately places and fully defines this cell.
	# Keep only the provisional dirt definition's persistent side effects.
	if not (reuse_tiles and _reuse_prune_empty_callbacks):
		block.set_physics_process(true)
	block.visible = true
	block.prepared = true
	block.is_mined = false
	block_data["miscellaneous"].append(block)
	_active_blocks.append(block)
	if tile_type == "basalt" or tile_type == "marble":
		# The final definition for these tiles only writes rim.
		block.reset_rollover_emission()
	return block

func prepare_rollover(generator: Node) -> void:
	QuarryBlock.release_mine_sonars()
	_is_resetting = true
	_current_index = 0
	_active_blocks.clear()
	var started := Time.get_unix_time_from_system()
	for i in range(_blocks.size() - 1, -1, -1):
		if i % 64 == 0 and Time.get_unix_time_from_system() - started >= 0.004:
			await get_tree().process_frame
			if not is_instance_valid(generator) or not generator.is_inside_tree():
				_is_resetting = false
				return
			started = Time.get_unix_time_from_system()
		var block: Node3D = _blocks[i]
		if not is_instance_valid(block):
			_blocks.remove_at(i)
			continue
		# A reset now spans physics frames; don't stack active shapes off-map.
		var shape := block.get_node("CollisionShape3D") as CollisionShape3D
		shape.disabled = true
		super._configure_block(block)
	_is_resetting = false

func _configure_block(block: Node3D) -> void:
	block.set_script(QuarryBlock)
	super._configure_block(block)
	# Pooled blocks all start at the same off-map position. Keep unused
	# shapes out of the broad phase until Block.define() activates them.
	var shape := block.get_node("CollisionShape3D") as CollisionShape3D
	shape.disabled = true
