extends Node

const POLL_SECONDS := 0.05
const AUTO_MINE_MAX_LEASE_MS := 850.0
const ARTIFACT_POPUP := "res://GUI/artifact_reward_popup.gd"
const LAYER_WARNING := "res://GUI/starting_layer_mismatch_warning.gd"
const BUTTONS := {
	"open_save_picker": "res://Title/start_game_button.gd",
	"load_slot": "res://Title/load_slot_button.gd",
	"start_day": "res://GUI/new_day_button.gd",
}

var _channel := ""
var _next_poll := 0.0
var _auto_mine_token := ""
var _auto_mine_until_ms := 0.0
var _auto_mine_state := {"ok": true, "state": "waiting", "day": 0}

func initialize() -> void:
	# No port, executable command, or arbitrary method dispatch. An operator
	# must explicitly provide a private local directory to enable the channel.
	_channel = OS.get_environment("QUARRY_CONTROL_DIR")
	if _channel.is_empty():
		var enable := ProjectSettings.globalize_path("user://quarry-control-path.txt")
		if FileAccess.file_exists(enable):
			_channel = FileAccess.get_file_as_string(enable).strip_edges()
	if not _channel.is_absolute_path() or not DirAccess.dir_exists_absolute(_channel):
		queue_free()
		return
	get_tree().process_frame.connect(_process_control)

func _process_control() -> void:
	var now := Time.get_unix_time_from_system()
	if _auto_mine_until_ms <= now * 1000.0 or _auto_mine_until_ms - now * 1000.0 > AUTO_MINE_MAX_LEASE_MS:
		_auto_mine_token = ""
	_poll(now)
	if not _auto_mine_token.is_empty() and not get_tree().paused:
		_auto_mine_state = _execute("advance_day", 0)

func _poll(now: float) -> void:
	if now < _next_poll and _next_poll - now < 1.0:
		return
	_next_poll = now + POLL_SECONDS
	var request := _channel.path_join("request.json")
	if not FileAccess.file_exists(request):
		return
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(request))
	DirAccess.remove_absolute(request)
	if not json is Dictionary or not json.has("id"):
		return
	var command := str(json.get("action", ""))
	if command == "advance_day" and float(json.get("expires_unix_ms", 0)) < now * 1000.0:
		return
	var result: Dictionary
	if command == "auto_mine_heartbeat" or command == "auto_mine_stop":
		result = _update_auto_mine_lease(command, json, now * 1000.0)
	else:
		result = _execute(command, int(json.get("slot", 0)))
	if command == "save_and_close" and result.get("ok", false):
		_auto_mine_token = ""
		_auto_mine_until_ms = 0.0
	result["id"] = json["id"]
	var temp := _channel.path_join("response.tmp")
	var response := _channel.path_join("response.json")
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(result))
	file.close()
	if FileAccess.file_exists(response):
		DirAccess.remove_absolute(response)
	if DirAccess.rename_absolute(temp, response) == OK and command == "save_and_close" and result.get("ok", false):
		get_tree().quit.call_deferred()

func _update_auto_mine_lease(command: String, message: Dictionary, now_ms: float) -> Dictionary:
	var token := str(message.get("auto_mine_token", ""))
	if token.length() != 32:
		return {"ok": false, "reason": "invalid auto-mining token"}
	if not _auto_mine_token.is_empty() and token != _auto_mine_token:
		return {"ok": false, "reason": "another auto-mining session is active"}
	if command == "auto_mine_stop":
		_auto_mine_token = ""
		_auto_mine_until_ms = 0.0
		return {"ok": true, "state": "stopped"}
	var until_ms := float(message.get("expires_unix_ms", 0))
	if not is_finite(until_ms) or until_ms <= now_ms or until_ms - now_ms > AUTO_MINE_MAX_LEASE_MS:
		return {"ok": false, "reason": "expired or invalid auto-mining heartbeat"}
	if _auto_mine_token.is_empty():
		var scene := get_tree().current_scene
		var game := get_tree().root.get_node_or_null("global")
		if scene == null or scene.name != &"Level" or game == null:
			_auto_mine_state = {"ok": true, "state": "load_save"}
		else:
			var running: Dictionary = game.get("game_info")
			_auto_mine_state = {"ok": true, "state": "mining" if running["time_running"] else "waiting", "day": int(running["day"])}
	_auto_mine_token = token
	_auto_mine_until_ms = until_ms
	return _auto_mine_state.duplicate()

func _advance_day(scene: Node, running: Dictionary) -> Dictionary:
	if scene.name != &"Level":
		return {"ok": true, "state": "load_save"}
	var day := int(running["day"])
	if running["time_running"]:
		return {"ok": true, "state": "mining", "day": day}
	# The generator leaves the countdown at zero until the mine is ready.
	if float(running["current_time"]) <= 0.0 or get_tree().paused:
		return {"ok": true, "state": "waiting", "day": day}
	var gui := get_tree().get_first_node_in_group(&"GUI")
	if _accept_artifact(gui):
		return {"ok": true, "state": "reward", "day": day}
	if gui != null:
		for child in gui.get_children():
			var script := child.get_script() as Script
			if script != null and script.resource_path == LAYER_WARNING:
				return {"ok": true, "state": "starting", "day": day}
	var button := get_tree().get_first_node_in_group(&"New Day Button") as BaseButton
	if button == null or button.disabled or not button.is_visible_in_tree():
		return {"ok": true, "state": "waiting", "day": day}
	button.pressed.emit()
	if not running["time_running"]:
		return {"ok": true, "state": "starting", "day": day}
	return {"ok": true, "state": "started", "day": day}

func _accept_artifact(gui: Node) -> bool:
	if gui == null:
		return false
	for child in gui.get_children():
		var script := child.get_script() as Script
		if child.is_queued_for_deletion() or script == null or script.resource_path != ARTIFACT_POPUP:
			continue
		var accept := child.get("button") as Button
		if accept != null and accept.is_visible_in_tree() and not accept.disabled:
			accept.pressed.emit()
			return true
	return false

func _execute(command: String, slot: int) -> Dictionary:
	var tree := get_tree()
	var scene := tree.current_scene
	var game := tree.root.get_node_or_null("global")
	if scene == null or game == null:
		return {"ok": false, "reason": "scene not ready"}
	var running: Dictionary = game.get("game_info")
	if command == "camera_autopan_off":
		if scene.name != "Level":
			return {"ok": false, "reason": "not in a mining level"}
		game.get("settings")["camera_autopan"] = false
		return {"ok": true}
	if command == "advance_day":
		return _advance_day(scene, running)
	if command == "status":
		var units := tree.get_nodes_in_group("miner") + tree.get_nodes_in_group("digger")
		var workers := []
		var on_demand_rays := 0
		for worker in units:
			workers.append({"id": worker.get_instance_id(), "x": worker.position.x, "y": worker.position.y, "state": worker.get("state")})
			var ray := worker.get_node_or_null("MineableCheckRaycast") as RayCast3D
			if ray != null and not ray.enabled:
				on_demand_rays += 1
		var compat := get_parent()
		var blocks := tree.root.get_node("blocks")
		var ring := scene.get_node_or_null("Evertree/EvertreeShaderRing") as MeshInstance3D
		var particles := scene.get_node_or_null("Evertree/EvertreeShaderRing/EvertreeRingParticles") as GPUParticles3D
		var shake: Dictionary = game.get("settings")
		var camera := scene.get_node_or_null("Camera") as Camera3D
		var view := {"autopan": bool(shake.get("camera_autopan", true))}
		if camera != null:
			view.merge({"y": camera.global_position.y, "reset_group": camera.is_in_group(&"Reset from Geomancer"),
				"resetting": camera.get("resetting_position"), "panning": camera.get("panning_to_starting_layer")})
		var impact := compat.get_node_or_null("QuarryImpact")
		var audio := {}
		var damage_queue := {"pending": blocks.get("block_queue").size() - int(blocks.get("queue_index"))}
		if "_peak_pending" in blocks:
			damage_queue.merge({"peak": blocks.get("_peak_pending"), "applied_in_catchup": blocks.get("_applied"),
				"expired_in_catchup": blocks.get("_expired"), "budget_stops": blocks.get("_over_budget"),
				"early_batches": blocks.get("_early_batches")})
		if impact != null:
			audio = {"shared": impact.is_processing(), "submitted": impact.get("_submitted"),
				"played": impact.get("_played")}
		return {"ok": true, "pid": OS.get_process_id(), "scene": str(scene.name), "slot": game.get("save_slot"), "auto_mining": not _auto_mine_token.is_empty(),
			"remaining": running.get("current_time"), "running": running.get("time_running"),
			"day": running.get("day"), "workers": workers, "blocks": blocks.call("get_total_block_count"),
			"factor": compat.get("_factor"), "physics_hz": Engine.physics_ticks_per_second,
			"frames": Engine.get_frames_drawn(), "pruned_blocks": compat.get("_pruned_blocks"),
			"on_demand_rays": on_demand_rays,
			"edge_recoveries": compat.get("_edge_recoveries"),
			"max_steps_per_frame": Engine.max_physics_steps_per_frame,
			"audio": audio, "damage_queue": damage_queue, "camera": view,
			"discarded_frames": compat.get("_discarded_frames"),
			"visuals": {"ring_visible": ring != null and ring.is_visible_in_tree(),
				"menu_emitters_without_physics": (compat.get("_menu_emitters") as Array).size(),
				"ring_emitting": particles != null and particles.emitting,
				"wind_materials_static": (compat.get("_wind") as Dictionary).size(),
				"block_shake": shake.get("block_shake")}}
	if command == "save_and_close":
		if OS.get_environment("QUARRY_TEST_PROFILE") == "1":
			return {"ok": false, "reason": "live save action unavailable in tests"}
		if scene.name == "Level":
			if int(game.get("save_slot")) < 1 or not game.get("allow_saving"):
				return {"ok": false, "reason": "no writable active slot"}
			tree.root.get_node("helpers").call("game_save_handling")
			# Force a save only on days the game's helper does not autosave.
			if int(running["day"]) % int(game.get("days_for_save")) != 0:
				tree.root.get_node("saves").call("save_game", false)
		elif scene.name != "Title":
			return {"ok": false, "reason": "wait until the level or title is ready"}
		return {"ok": true}
	if command == "acknowledge_artifact":
		if scene.name != "Level":
			return {"ok": false, "reason": "not in a mining level"}
		if _accept_artifact(tree.get_first_node_in_group(&"GUI")):
			return {"ok": true}
		return {"ok": false, "reason": "no visible artifact reward"}
	if not BUTTONS.has(command) or (command == "load_slot" and (slot < 1 or slot > 3)):
		return {"ok": false, "reason": "unsupported action"}
	for button in scene.find_children("*", "BaseButton", true, false):
		var script: Script = button.get_script()
		if script == null or script.resource_path != BUTTONS[command]:
			continue
		if command == "load_slot" and (button.get("slot") != slot or button.get("is_backup")):
			continue
		if command == "open_save_picker" and not button.get("initialization_complete"):
			continue
		if not button.disabled and button.is_visible_in_tree():
			button.pressed.emit()
			return {"ok": true}
	return {"ok": false, "reason": "button is unavailable"}
