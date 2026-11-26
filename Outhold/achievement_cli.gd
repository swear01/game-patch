extends Node

var level_number := 0
var plan: Dictionary
var attempted: Array[String] = []
var plan_path: String
var slot := 0

func _ready() -> void:
	if OS.get_cmdline_user_args().has("--check-bridge"):
		print("CLI achievement bridge compiled")
		get_tree().quit()
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("play_jobs")

func play_jobs() -> void:
	var profile := ProjectSettings.globalize_path("user://")
	if profile != OS.get_environment("APPDATA").replace("\\", "/").path_join("Godot/app_userdata/Outhold") + "/":
		push_error("Unexpected original profile: " + profile)
		return
	SaveSystem.set_save_slot(slot)
	if not SaveSystem.load_game(false):
		push_error("Could not load original save slot 1")
		return
	if not await verify_speed():
		return
	# Keep the native fixed timestep when the accelerated clock needs more ticks per rendered frame.
	Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, 24)
	Engine.max_fps = 0
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1280, 720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	print("CLI native physics ticks/game second=", Engine.physics_ticks_per_second, " max steps/render frame=", Engine.max_physics_steps_per_frame)
	plan_path = OS.get_environment("OUTHOLD_ACHIEVEMENT_PLAN")
	print("CLI original slot 1 PID=", OS.get_process_id(), " mode=stock")
	report_steam_achievements()
	while true:
		var text := FileAccess.get_file_as_string(plan_path)
		var queue: Variant = JSON.parse_string(text) if not text.is_empty() else []
		var chosen: Dictionary = {}
		if queue is Array:
			for job in queue:
				if not attempted.has(job.id) and not persisted_target(job):
					chosen = job
					break
		if chosen.is_empty():
			print("CLI waiting for updated jobs")
			while FileAccess.get_file_as_string(plan_path) == text:
				await get_tree().create_timer(1.0).timeout
			attempted.clear()
			continue
		plan = chosen
		attempted.append(plan.id)
		if not await run_job():
			return

func persisted_target(job: Dictionary) -> bool:
	var save := ConfigFile.new()
	if save.load(SaveSystem.get_save_file_path()) != OK:
		return false
	var level := int(job.level)
	var kind := str(job.get("target", "TIME"))
	match kind:
		"TIME":
			return bool(save.get_value("time_challenges_completed", "LEVEL_%d" % level, false))
		"PRESTIGE":
			return int(save.get_value("progress", "completed_hard_levels", 0)) >= level
		"TOKEN":
			return bool(save.get_value("token_limit_challenges_completed", "LEVEL_%d" % level, false))
		"ENDLESS":
			return bool(save.get_value(SaveSystem.ENDLESS_LEVELS_COMPLETED, "LEVEL_%d" % level, false))
		"ARTIFACT":
			var level_id: String = Levels.get_level_string_id(Levels.LevelType[job.artifact])
			return bool(save.get_value(SaveSystem.ARTIFACT_LEVELS_COMPLETED, level_id, false))
	return false

func run_job() -> bool:
	level_number = int(plan.level)
	var previous_id := Level.active_level.get_instance_id() if is_instance_valid(Level.active_level) else 0
	if Modal.is_open():
		Modal.close(false)
	get_tree().paused = false
	await Router.navigate_to_route(Router.Route.UPGRADE_TREE, {}, {"show_screen_transition": false})
	var preset := int(plan.get("preset", Upgrades.current_upgrade_preset_index))
	if preset != Upgrades.current_upgrade_preset_index:
		Upgrades.change_upgrade_preset(preset)
	if bool(plan.get("reset_preset", false)):
		Upgrades.reset()
	invest_in_progression()
	if str(plan.get("target", "")) == "TREE":
		inspect_tree()
		return true
	var mode_name := str(plan.get("mode", "NORMAL"))
	var mode: Levels.Mode = Levels.Mode[mode_name]
	var kind: Levels.LevelType = Levels.get_level_type_by_order(level_number)
	if plan.has("artifact"):
		kind = Levels.LevelType[plan.artifact]
	var level_config: Dictionary = Levels.get_level(kind)
	if mode == Levels.Mode.HARD and (not Levels.has_unlocked_hard_mode() or level_number > Levels.completed_hard_levels + 1):
		print("CLI prestige not unlocked for ", plan.id)
		return true
	if mode == Levels.Mode.TOKEN_LIMIT:
		var limits: Dictionary = level_config.get("mode", {}).get(mode, {}).get("max_tokens", {})
		if not Levels.has_unlocked_token_limit_mode() or limits.is_empty() or not TokenLimitChallenge.check_tokens(limits):
			print("CLI native token entrance denied for ", plan.id, " limits=", limits)
			return true
	if Levels.is_any_endless_mode(mode):
		var endless_config: Dictionary = level_config.get("mode", {}).get(Levels.get_config_mode(mode), {})
		if not Levels.has_unlocked_endless_mode() or endless_config.is_empty():
			print("CLI native endless entrance denied for ", plan.id)
			return true
		if mode == Levels.Mode.ENDLESS and not TokenLimitChallenge.check_tokens(endless_config.get("max_tokens", {})):
			print("CLI native endless budget denied for ", plan.id)
			return true
	var props := {"level_type": kind, "level_props": {"mode": mode}} if plan.has("artifact") else {"level_index": level_number, "level_props": {"mode": mode}}
	await Router.navigate_to_route(Router.Route.LEVEL_PLAYER, props, {"show_screen_transition": false})
	var deadline := Time.get_unix_time_from_system() + 15.0
	while Time.get_unix_time_from_system() < deadline:
		if is_instance_valid(Level.active_level) and Level.active_level.get_instance_id() != previous_id:
			break
		await get_tree().process_frame
	if not is_instance_valid(Level.active_level) or Level.active_level.get_instance_id() == previous_id:
		push_error("Native level failed to open")
		return false
	await get_tree().physics_frame
	var battle := Level.active_level
	if battle.level != kind or battle.mode != mode:
		push_error("Unexpected native map or mode")
		return false
	await play_battle(battle)
	await get_tree().create_timer(2.0).timeout
	return true

func play_battle(battle: Level) -> void:
	var points: Array = battle.build_points.duplicate()
	points.sort_custom(func(a, b): return a.global_position.distance_squared_to(battle.core.global_position) < b.global_position.distance_squared_to(battle.core.global_position))
	var core := battle.core.health_component
	var last_wave := -1
	var last_status := 0.0
	var next_action := 0.0
	var next_boss_sample := 0.0
	var sample_time := Time.get_unix_time_from_system()
	var sample_physics := Engine.get_physics_frames()
	var sample_frames := Engine.get_process_frames()
	var native_time := battle.time_challenge
	var deadline := Time.get_unix_time_from_system() + float(plan.get("timeout_seconds", 900))
	var end_run_after := int(plan.get("end_run_after", 0))
	var end_requested := false
	print("CLI started ", plan.id, " mode=", battle.mode, " health=", core.get_health(), " gems=", battle.get_current_gems())
	for point in points:
		print("CLI tile ", point.coords, " open=", point.unlocked, " enchant=", point.enchant)
	for index in range(points.size()):
		var count := battle.built_towers.size()
		build_defenses(battle, points)
		await get_tree().process_frame
		if battle.built_towers.size() == count:
			break
	while not battle.is_game_over and Time.get_unix_time_from_system() < deadline:
		if end_run_after > 0 and Levels.is_any_endless_mode(battle.mode) and battle.spawn_manager.waves_completed >= end_run_after:
			if not end_requested and not Modal.is_open():
				battle._on_menu_button_pressed()
			if not end_requested and Modal.active_scene is InGameMenu:
				end_requested = true
				print("CLI ending endless run from native menu at ", battle.spawn_manager.waves_completed, " completed waves")
				Modal.active_scene._on_end_run_pressed()
			await get_tree().process_frame
			continue
		var now := Time.get_unix_time_from_system()
		if last_wave != battle.spawn_manager.waves_spawned or now >= last_status:
			last_wave = battle.spawn_manager.waves_spawned
			last_status = now + 12.0
			var clock: String = native_time.get_formatted_time_elapsed() if is_instance_valid(native_time) else "-"
			print("CLI progress ", plan.id, " wave=", last_wave, "/", battle.waves.size(), " stopwatch=", clock, " gems=", battle.get_current_gems(), " core=", core.get_health())
		if now - sample_time >= 10.0:
			print("CLI simulation physics/s=", (Engine.get_physics_frames() - sample_physics) / (now - sample_time), " render/s=", (Engine.get_process_frames() - sample_frames) / (now - sample_time))
			sample_time = now
			sample_physics = Engine.get_physics_frames()
			sample_frames = Engine.get_process_frames()
		if now >= next_action:
			if Upgrades.get_current_level(Upgrades.Upgrade.CORE_HEAL) > 0 and core.get_health_ratio() < 0.65 and battle.get_current_gems() >= battle.core.get_heal_cost():
				battle.core.heal()
			if bool(plan.get("mark_boss", false)) and Upgrades.get_current_level(Upgrades.Upgrade.TARGETTING) > 0:
				mark_live_boss(battle)
			build_defenses(battle, points)
			if not battle.start_wave_button.disabled and (not battle.spawn_manager.is_any_wave_in_progress() or can_start_early(battle)):
				battle._on_start_wave_button_pressed()
			next_action = now + 0.08
		if bool(plan.get("diagnose_boss", false)) and now >= next_boss_sample:
			next_boss_sample = now + 0.75
			for enemy in battle.spawn_manager.get_alive_enemies_sorted_by_spawn_index():
				if is_instance_valid(enemy) and not enemy.is_dead and enemy.is_boss():
					print("CLI boss ", plan.id, " at=", enemy.global_position, " hp_percent=", enemy.get_health_percentage())
		await get_tree().process_frame
	var elapsed: String = native_time.get_formatted_time_elapsed() if is_instance_valid(native_time) else "-"
	var waves := int(battle.spawn_manager.waves_completed)
	var settle_until := Time.get_unix_time_from_system() + 4.0
	while Time.get_unix_time_from_system() < settle_until and not persisted_target(plan):
		await get_tree().process_frame
	if Modal.active_scene is LevelEndPanel:
		print("CLI native result win=", Modal.active_scene.did_win, " reward totals=", Modal.active_scene.rewards.get("total_tokens", {}))
	print("CLI result ", plan.id, " earned=", persisted_target(plan), " stopwatch=", elapsed, " waves=", waves)
	report_steam_achievements()

func mark_live_boss(battle: Level) -> void:
	for enemy in battle.spawn_manager.get_alive_enemies_sorted_by_spawn_index():
		if is_instance_valid(enemy) and not enemy.is_dead and enemy.is_boss():
			if battle.enemy_target.current_target != enemy:
				battle.enemy_target.target(enemy)
			return

func can_start_early(battle: Level) -> bool:
	var permitted: int = int(plan.get("early_remaining", 0))
	if permitted <= 0 or battle.start_wave_button.disabled:
		return false
	if not Levels.is_any_endless_mode(battle.mode) and battle.spawn_manager.waves_spawned >= battle.waves.size():
		return false
	if battle.core.health_component.get_health_ratio() < float(plan.get("early_min_hp", 0.8)) or battle.built_towers.size() < int(plan.get("early_min_towers", 5)):
		return false
	var pending: int = battle.spawn_manager.spawn_queue.size()
	if pending > 0 and not bool(plan.get("early_queue", false)):
		return false
	var remaining := pending
	for enemy in battle.spawn_manager.get_alive_enemies_sorted_by_spawn_index():
		if not is_instance_valid(enemy) or enemy.is_dead:
			continue
		if enemy.is_boss():
			return false
		remaining += 1
	return remaining > 0 and remaining <= permitted

func report_steam_achievements() -> void:
	if not Steamworks.is_available:
		print("CLI Steam achievement API unavailable")
		return
	var ids := ["COMPLETE_GAME", "COMPLETE_TIME_CHALLENGES", "COMPLETE_LEVEL_CHALLENGES", "COMPLETE_TOKEN_LIMIT_CHALLENGES", "COMPLETE_HARD_MODE", "COMPLETE_ALL_CHALLENGES", "STATUS_EFFECT_COUNT", "MAX_TREE", "RESPEC", "FIRST_LEVEL", "FIRST_ARTIFACT", "FIRST_CHALLENGE", "FIRST_TIME", "FIRST_TOKEN_LIMIT", "FIRST_HARD_MODE"]
	var unlocked: Array[String] = []
	for key in ids:
		var achievement: Dictionary = Steamworks.steam_api.getAchievement(key)
		if bool(achievement.get("achieved", false)):
			unlocked.append(key)
	print("CLI Steam unlocked ", unlocked.size(), "/15 ", unlocked)

func inspect_tree() -> void:
	var tree: Node = Router.active_scene
	if is_instance_valid(tree) and tree is UpgradeTree:
		var spent := {}
		for token in tree.total_cost:
			spent[Tokens.Types.keys()[token]] = Tokens.get_spent_tokens(token)
		print("CLI stock tree totals ", tree.total_cost, " active spent ", spent)

func verify_speed() -> bool:
	var measured := await sample_speed()
	for attempt in range(8):
		if absf(measured - 10.0) <= 0.4:
			break
		measured = await sample_speed()
	print("CLI process speed ", "%.3f" % measured, "x; Engine.time_scale=", Engine.time_scale)
	if not is_equal_approx(Engine.time_scale, 1.0) or absf(measured - 10.0) > 0.4:
		push_error("OpenSpeedy 10x or native Engine time scale verification failed")
		return false
	return true

func invest_in_progression() -> void:
	for key in plan.get("refund", []):
		var upgrade: int = Upgrades.Upgrade[key]
		if Upgrades.get_current_level(upgrade) > 0:
			Upgrades.decrease_level(upgrade)
	if Upgrades.current_upgrade_preset_index == 1 and Upgrades.get_current_level(Upgrades.Upgrade.CORE_HEALTH_2) < 2:
		for upgrade in [Upgrades.Upgrade.ARROW_TOWER_FIRE_RATE_2, Upgrades.Upgrade.LIGHTNING_TOWER_SHOCK_STUN_DURATION_EXTRA]:
			if Upgrades.get_current_level(upgrade) > 0:
				Upgrades.decrease_level(upgrade)
				print("CLI refunded ", Upgrades.Upgrade.keys()[upgrade], " for core health")
	var keys := [
		"STARTING_GEMS", "BOSS_DEFEAT_PARTIAL_TOKEN", "BOSS_DAMAGE_TAKEN_BASIC_TOKEN_INCREASE",
		"GEM_DROPS", "GEM_SHOT", "GEM_CONVERT", "STARTING_GEMS_2",
		"CORE_HEALTH", "CORE_HEALTH_2",
		"CORE_HEALTH_3", "CORE_LOST_HEALTH_INCREASE_DAMAGE", "CORE_HEAL", "CORE_HEAL_EXTRA",
		"LIGHTNING_TOWER_DAMAGE", "LIGHTNING_TOWER_DAMAGE_EXTRA",
		"LIGHTNING_TOWER_SPEED", "LIGHTNING_TOWER_EXTRA_SPEED",
		"LIGHTNING_TOWER_JUMPS", "LIGHTNING_TOWER_EXTRA_JUMPS",
		"LIGHTNING_TOWER_JUMP_DAMAGE_REDUCTION", "LIGHTNING_TOWER_CRIT_CHANCE",
		"LIGHTNING_TOWER_JUMP_RANGE", "LIGHTNING_TOWER_APPLY_SHOCK",
		"LIGHTNING_TOWER_SHOCK_STUN_DURATION", "LIGHTNING_TOWER_STUN_INCREASE_DAMAGE",
		"BURN_STACKING_DAMAGE",
		"BURN_DAMAGE", "BURN_DAMAGE_FIRE_TOWER", "BURN_TICKS_EXTRA", "BURN_TICK_RATE",
		"BURN_CONCENTRATION", "BURN_SPREADING", "BURN_SPREAD_CHANCE",
		"VULNERABLE_DAMAGE_MULTIPLIER", "SLOW_TOWER_FIRE_RATE", "SLOW_DAMAGE_BONUS",
		"CORE_HEALTH", "CORE_HEALTH_2", "CORE_LOST_HEALTH_INCREASE_DAMAGE",
		"ARROW_TOWER_DAMAGE", "ARROW_TOWER_DAMAGE_2", "ARROW_TOWER_FIRE_RATE",
		"ARROW_TOWER_CRIT_DAMAGE", "ARROW_TOWER_CRIT_DAMAGE_2",
		"ARROW_TOWER_CRIT_CHANCE", "ARROW_TOWER_PIERCE_SHIELD",
		"BANK_TOWER_UNLOCK", "BANK_TOWER_CHANCE_TO_SPAWN_COIN", "BANK_TOWER_NUMBER_COINS",
		"ECONOMY_ENEMY_DEFEAT_UPGRADE_DISCOUNT", "ECONOMY_UNCAPPED_LEVELS"
	]
	if not bool(plan.get("default_buys", true)):
		keys.clear()
	for key in plan.get("buy", []) + keys:
		var upgrade: int = Upgrades.Upgrade[key]
		while Upgrades.get_current_level(upgrade) < int(plan.get("upgrade_caps", {}).get(key, 100)):
			var availability: Upgrades.ActivationLevel = Upgrades.get_activation_level(upgrade)
			if availability not in [Upgrades.ActivationLevel.AVAILABLE, Upgrades.ActivationLevel.LEVELED]:
				break
			if not Upgrades.increase_level(upgrade, false):
				break
			print("CLI bought ", key, " level=", Upgrades.get_current_level(upgrade))
	SaveSystem.save_game()

func build_defenses(battle: Level, points: Array) -> void:
	if int(plan.get("save_from_wave", 100)) <= battle.spawn_manager.waves_spawned:
		return
	if plan.has("phase_after_goal") and battle.level_challenge.challenge_state in [LevelChallenge.State.CHALLENGE_COMPLETED_IF_LEVEL_COMPLETED, LevelChallenge.State.CHALLENGE_COMPLETED]:
		var change: Dictionary = plan.phase_after_goal
		plan.erase("phase_after_goal")
		plan.merge(change, true)
		print("CLI challenge threshold reached; switching defense")
	if plan.has("placements"):
		build_planned_defenses(battle, points)
		return
	var unlocked: Array = Towers.get_unlocked_towers()
	var fire_count: int = battle.get_built_tower_count(Towers.Types.FIRE)
	var slow_count: int = battle.get_built_tower_count(Towers.Types.SLOW)
	var arrow_count: int = battle.get_built_tower_count(Towers.Types.ARROW)
	var lightning_count: int = battle.get_built_tower_count(Towers.Types.LIGHTNING)
	var reserved := 0
	if level_number == 5:
		var order := [Vector2i(-1, -3), Vector2i(1, -3), Vector2i(0, -1), Vector2i(2, -1), Vector2i(-2, -1)]
		var ranked: Array = []
		for coords in order:
			ranked.append_array(points.filter(func(point): return point.coords == coords))
		points = ranked + points.filter(func(point): return not ranked.has(point))
	if unlocked.has(Towers.Types.FIRE) and fire_count == 0:
		try_build_tower(battle, points, Towers.Types.FIRE)
	if unlocked.has(Towers.Types.SLOW) and slow_count == 0:
		try_build_tower(battle, points, Towers.Types.SLOW)
	if unlocked.has(Towers.Types.LIGHTNING) and lightning_count == 0:
		try_build_tower(battle, points, Towers.Types.LIGHTNING)
	if level_number >= 6 and unlocked.has(Towers.Types.BANK) and battle.get_built_tower_count(Towers.Types.BANK) < int(plan.get("bank_count", 1)) and lightning_count >= 2:
		try_build_tower(battle, points, Towers.Types.BANK)
	if arrow_count < 2:
		try_build_tower(battle, points, Towers.Types.ARROW)
	if unlocked.has(Towers.Types.FIRE) and fire_count == 1:
		if not try_build_tower(battle, points.slice(1), Towers.Types.FIRE):
			reserved = Towers.get_build_cost(Towers.Types.FIRE)
	if unlocked.has(Towers.Types.LIGHTNING) and lightning_count > 0 and lightning_count < int(plan.get("lightning_count", 2)):
		if not try_build_tower(battle, points, Towers.Types.LIGHTNING):
			reserved = Towers.get_build_cost(Towers.Types.LIGHTNING)
	var priority := battle.built_towers.duplicate()
	priority.sort_custom(func(a, b): return upgrade_score(a) > upgrade_score(b))
	for tower in priority:
		if not is_instance_valid(tower):
			continue
		var cost: int = Towers.get_upgrade_cost(tower)
		if battle.get_current_gems() >= cost and (reserved == 0 or tower.level < 2):
			if tower.level < int(plan.get("level_caps", {}).get(Towers.Types.keys()[tower.type], 99)) and Towers.can_afford_upgrade_tower(tower) and tower.upgrade():
				print("CLI upgraded ", Towers.get_tower_string_id(tower.type), " ", tower.coords, " to ", tower.level)
	if reserved == 0 and battle.get_current_gems() >= 28:
		try_build_tower(battle, points, Towers.Types.ARROW)

func build_planned_defenses(battle: Level, points: Array) -> void:
	var needs_saving := false
	for entry in plan.placements:
		var coords := Vector2i(entry[0], entry[1])
		var tower_type: Towers.Types = Towers.Types[entry[2]]
		var point: BuildPoint
		for candidate in points:
			if candidate.coords == coords:
				point = candidate
				break
		if point == null or not Towers.get_unlocked_towers().has(tower_type):
			continue
		var existing: Tower
		for tower in battle.built_towers:
			if tower.coords == coords:
				existing = tower
				break
		if existing != null:
			if entry.size() > 3 and existing.enchant == Enchants.Type.NONE:
				var kind: Enchants.Type = Enchants.Type[entry[3]]
				if Artifacts.get_temporary_artifact_count(kind) > 0:
					existing.tower_options._on_enchant_chosen({"enchant": kind})
			continue
		if not point.unlocked:
			battle.unlock_build_point(coords)
			if not point.unlocked:
				needs_saving = true
				break
		if not try_build_tower(battle, [point], tower_type):
			needs_saving = true
			break
		return
	if bool(plan.get("no_upgrade", false)):
		return
	if needs_saving and battle.built_towers.size() < int(plan.get("allow_upgrade_after", 4)):
		return
	var priority := battle.built_towers.duplicate()
	priority.sort_custom(func(a, b): return upgrade_score(a) > upgrade_score(b))
	for tower in priority:
		var cap := int(plan.get("level_caps", {}).get(Towers.Types.keys()[tower.type], 99))
		if needs_saving:
			cap = mini(cap, int(plan.get("saving_rank_cap", 99)))
		if tower.level < cap and Towers.can_afford_upgrade_tower(tower) and tower.upgrade():
			print("CLI upgraded ", Towers.get_tower_string_id(tower.type), " ", tower.coords, " to ", tower.level)

func upgrade_score(tower: Tower) -> float:
	var impact := 4.0 if tower.type in [Towers.Types.FIRE, Towers.Types.LIGHTNING] else 1.0
	impact = float(plan.get("weights", {}).get(Towers.Types.keys()[tower.type], impact))
	var coords := "%d,%d" % [tower.coords.x, tower.coords.y]
	impact *= float(plan.get("position_weights", {}).get(coords, 1.0))
	return impact / maxf(float(Towers.get_upgrade_cost(tower)), 1.0)

func try_build_tower(battle: Level, points: Array, tower_type: Towers.Types) -> bool:
	if battle.get_current_gems() < Towers.get_build_cost(tower_type):
		return false
	for point in points:
		if not point.unlocked or battle.built_towers.any(func(tower): return tower.coords == point.coords):
			continue
		if point.build_tower(tower_type):
			point.disable()
			print("CLI placed ", Towers.get_tower_string_id(tower_type), " ", point.coords)
			return true
	return false

func wait_for_speed() -> float:
	for attempt in range(8):
		var measured := await sample_speed()
		print("CLI clock OpenSpeedy ", "%.3f" % measured, "x")
		if measured >= 9.7 and measured <= 10.3:
			return measured
	return 0.0

func sample_speed() -> float:
	var wall := Time.get_unix_time_from_system()
	var ticks := Time.get_ticks_usec()
	while Time.get_unix_time_from_system() - wall < 0.35:
		await get_tree().process_frame
	return (Time.get_ticks_usec() - ticks) / (1000000.0 * (Time.get_unix_time_from_system() - wall))
