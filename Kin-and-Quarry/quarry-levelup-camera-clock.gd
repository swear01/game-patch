extends "res://LevelUp/level_up_camera.gd"

var _last_wall := 0.0

func _process(_game_delta):
	# System wall time is independent of OpenSpeedy's QPC hook. A stalled or
	# hidden frame must not make the camera catch up in a single large jump.
	var now := Time.get_unix_time_from_system()
	var wall_delta := clampf(now - _last_wall, 0.0, 0.050) if _last_wall > 0.0 else 0.0
	_last_wall = now
	super._process(wall_delta)
