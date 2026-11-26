extends "res://Autoload/blocks.gd"

const CATCHUP_THRESHOLD := 64
const MIN_BATCH := 32
const MAX_BATCH := 256
const WALL_BUDGET_SECONDS := 0.00125
const BUDGET_CHECK_INTERVAL := 8
const EARLY_FACTOR := 70.0
const EARLY_CREW_SIZE := 16
const EARLY_STEPS := 5
const EARLY_BATCH_LIMIT := 4
const EARLY_PENDING := 24
const EARLY_BATCH_SIZE := 48
const EARLY_BUDGET_SECONDS := 0.00075

var _clock: Node
var _peak_pending := 0
var _applied := 0
var _expired := 0
var _over_budget := 0
var _earlier := false
var _early_batches := 0
var _early_left := 0

func _ready() -> void:
	_clock = get_tree().root.get_node_or_null("QuarryOpenSpeedy")

func _process(delta: float) -> void:
	if _clock == null:
		_clock = get_tree().root.get_node_or_null("QuarryOpenSpeedy")
	var factor := float(_clock.get("_factor")) if _clock != null else 1.0
	var mining := bool(global.game_info["time_running"])
	var earlier: bool = mining and factor >= EARLY_FACTOR and _clock.get("_workers").size() >= EARLY_CREW_SIZE
	if earlier != _earlier:
		_earlier = earlier
		if earlier:
			get_tree().physics_frame.connect(_drain_before_step)
		else:
			get_tree().physics_frame.disconnect(_drain_before_step)
	_early_left = EARLY_BATCH_LIMIT
	if factor < 1.5 or not mining:
		super._process(delta)
		return
	var pending := block_queue.size() - int(queue_index)
	_peak_pending = maxi(_peak_pending, pending)
	# Keep vanilla timing when it is keeping up. A growing backlog can use
	# this frame immediately, with bounded work even for large chain effects.
	if pending < CATCHUP_THRESHOLD and (factor < 30.0 or pending < 30):
		super._process(delta)
		return
	frame_counter = (int(frame_counter) + 1) % 3
	_drain(clampi(pending, MIN_BATCH, MAX_BATCH), WALL_BUDGET_SECONDS)

func _drain_before_step() -> void:
	if _early_left == 0 or Engine.get_physics_frames() % EARLY_STEPS != 0:
		return
	if get_tree().paused or not global.game_info["time_running"]:
		return
	var pending := block_queue.size() - int(queue_index)
	_peak_pending = maxi(_peak_pending, pending)
	if pending < EARLY_PENDING:
		return
	# Run after contact signals have been flushed, before actors decide what
	# to hit next. Long render frames otherwise leave many miners attacking
	# a block that a hit already in the queue could destroy.
	_early_left -= 1
	_early_batches += 1
	_drain(EARLY_BATCH_SIZE, EARLY_BUDGET_SECONDS)

func _drain(remaining: int, wall_budget: float) -> void:
	var deadline := Time.get_unix_time_from_system() + wall_budget
	var hits_before_clock := BUDGET_CHECK_INTERVAL
	# A perk may append new hits. Those stay behind every already queued hit.
	while remaining > 0 and queue_index < block_queue.size():
		var item: Array = block_queue[queue_index]
		block_queue[queue_index] = null
		queue_index += 1
		remaining -= 1
		var target: Node3D = item[0] as Node3D if is_instance_valid(item[0]) else null
		if target == null or not target.visible:
			_expired += 1
			continue
		target.take_damage(item[1], item[2], item[3], item[4], item[5])
		_applied += 1
		hits_before_clock -= 1
		if hits_before_clock == 0:
			hits_before_clock = BUDGET_CHECK_INTERVAL
			if Time.get_unix_time_from_system() >= deadline:
				_over_budget += 1
				break
	if queue_index >= 512 and queue_index >= block_queue.size() - queue_index:
		block_queue = block_queue.slice(queue_index)
		queue_index = 0
