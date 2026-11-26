extends "res://Blocks/block.gd"

const IMPACT_INTERVAL := 0.03
const QuarryArtifactCache = preload("quarry-artifact-cache.gd")
static var compact_impacts := false
static var impact_player: Node
static var _next_impact := 0.0
static var _sonar_blocks: Dictionary = {}
static var _artifact_cache: QuarryArtifactCache
static var capture_rollover_materials := false
var _pending_material: Dictionary = {}

func define(define_artifact_and_effect: bool = true):
	if not capture_rollover_materials:
		flush_rollover_material()
		super.define(define_artifact_and_effect)
		return
	# Let the stock definition choose textures and advance the RNG in its
	# original order. Only its ShaderMaterial writes go through this receiver.
	var material = mesh_shader if mesh_shader != null else mesh_block.get_surface_override_material(0)
	mesh_shader = self
	super.define(define_artifact_and_effect)
	mesh_shader = material

func set_shader_parameter(parameter: String, value: Variant) -> void:
	_pending_material[parameter] = value

func reset_rollover_emission() -> void:
	if capture_rollover_materials:
		set_shader_parameter("emission_energy", 0.0)
	else:
		mesh_shader.set_shader_parameter("emission_energy", 0.0)

func change_modulate(color):
	if mesh_shader != self and not _pending_material.is_empty():
		# A later cursor highlight wins over the white queued by define().
		set_shader_parameter("albedo", color)
	else:
		super.change_modulate(color)

func flush_rollover_material() -> void:
	if _pending_material.is_empty():
		return
	for parameter in _pending_material:
		mesh_shader.set_shader_parameter(parameter, _pending_material[parameter])
	_pending_material.clear()

static func begin_rollover_artifact_cache() -> bool:
	_artifact_cache = null
	var cache := QuarryArtifactCache.new()
	if not cache.setup(items.item, items.collection, items.drop_rate, items.misc_min_layer, items.artifact_pool):
		return false
	_artifact_cache = cache
	return true

static func end_rollover_artifact_cache() -> void:
	_artifact_cache = null

func artifact_drop_handling() -> void:
	if _artifact_cache == null:
		super.artifact_drop_handling()
		return
	if block_layer < 0 or block_layer > QuarryArtifactCache.LAST_LAYER:
		end_rollover_artifact_cache()
		super.artifact_drop_handling()
		return
	if reward_type == "wood" or reward_type == "voidstone":
		if sonar_particles_instance != null:
			sonar_particles_instance.reset_sonar()
		artifact_drop = 0
		return
	var cached_bounds: Variant = _artifact_cache.ranges.get(reward_type)
	if cached_bounds == null:
		# Use the shipped path before any RNG draw for an unfamiliar material.
		end_rollover_artifact_cache()
		super.artifact_drop_handling()
		return
	var bounds: PackedFloat64Array = cached_bounds
	if sonar_particles_instance != null:
		sonar_particles_instance.reset_sonar()
	artifact_drop = 0
	var drop: Variant = _artifact_cache.choose(reward_type, block_layer, bounds)
	if drop != null:
		item_to_drop = drop[0]
		var rank: int = drop[1]
		get_or_create_sonar_particles().play_rarity_animation(QuarryArtifactCache.RARITIES[rank])
		artifact_drop = QuarryArtifactCache.RARITIES.size() - rank

func get_or_create_sonar_particles():
	var sonar: Node3D = super.get_or_create_sonar_particles()
	_sonar_blocks[get_instance_id()] = self
	return sonar

static func release_mine_sonars() -> void:
	# These indicate artifacts in the old mine. A regenerated mine creates
	# new indicators only where its own artifacts actually spawn.
	for block in _sonar_blocks.values():
		if not is_instance_valid(block):
			continue
		var sonar: Node3D = block.sonar_particles_instance
		if is_instance_valid(sonar):
			sonar.hide()
			sonar.queue_free()
		block.sonar_particles_instance = null
	_sonar_blocks.clear()

func play_sound(type: String = "mine") -> void:
	if not compact_impacts:
		super.play_sound(type)
		return
	# Keep the same RNG draws for drop and perk ordering. Share a real-time
	# limit across blocks so Windows audio does not starve the mining loop.
	var sound: String = sfx.get_sound(type)
	var pitch := randf_range(0.8, 1.2)
	if is_instance_valid(impact_player):
		impact_player.offer(type, sound, global_position, pitch)
		return
	var now := Time.get_unix_time_from_system()
	if now < _next_impact and now > _next_impact - 1.0:
		return
	_next_impact = now + IMPACT_INTERVAL
	audio_player.stream = sfx.sounds[type][sound]
	audio_player.pitch_scale = pitch
	audio_player.play()
