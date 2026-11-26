extends Node

# One audible representative for an impact burst. A destruction wins over
# a hit; among equal kinds, prefer the candidate closest to the camera.
const INTERVAL := 0.033
const VOLUME_DB := -11.0

var _player: AudioStreamPlayer
var _source: Node
var _scene: Node
var _sounds: Dictionary
var _pending: AudioStream
var _pitch := 1.0
var _is_smash := false
var _distance := INF
var _next := 0.0
var _submitted := 0
var _played := 0

func _ready() -> void:
	_source = get_tree().root.get_node("sfx")
	_player = AudioStreamPlayer.new()
	_player.name = "QuarryImpactPlayer"
	_player.bus = &"SFX"
	_player.volume_db = VOLUME_DB
	_player.max_polyphony = 1
	add_child(_player)
	set_process(false)

func enable(enabled: bool) -> void:
	if is_processing() == enabled:
		return
	if not enabled:
		_pending = null
		_player.stop()
		_next = 0.0
	set_process(enabled)

func offer(kind: String, sound: String, at: Vector3, pitch: float) -> void:
	_submitted += 1
	if _scene != get_tree().current_scene:
		_scene = get_tree().current_scene
		_pending = null
		_player.stop()
	var camera := get_viewport().get_camera_3d()
	if camera == null or camera.is_position_behind(at):
		return
	var distance := camera.global_position.distance_squared_to(at)
	var smash := kind == "smash"
	if _pending != null and ((_is_smash and not smash) or (_is_smash == smash and distance >= _distance)):
		return
	if _sounds.is_empty():
		_sounds = _source.get("sounds")
	_pending = _sounds[kind][sound]
	_pitch = pitch
	_is_smash = smash
	_distance = distance

func _process(_delta: float) -> void:
	if _pending == null:
		return
	if _scene != get_tree().current_scene:
		_pending = null
		return
	var now := Time.get_unix_time_from_system()
	if now < _next and now > _next - 1.0:
		return
	_next = now + INTERVAL
	# Don't cut off the tail of an ordinary tap just to play another tap.
	if not _player.playing or _is_smash:
		if _player.stream != _pending:
			_player.stream = _pending
		_player.volume_db = minf(VOLUME_DB, linear_to_db(10.0 / sqrt(maxf(_distance, 0.0001))) - 3.0)
		_player.pitch_scale = _pitch
		_player.play()
		_played += 1
	_pending = null
