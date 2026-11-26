extends "res://Pools/necromancer_projectile_pool.gd"

func _ready() -> void:
	# The inherited pool grows as needed. Avoid building 1,500 projectiles
	# on the title screen, including on saves with no necromancer.
	pass

func get_projectile():
	var projectile: Node
	for index in range(proj_pool.size() - 1, -1, -1):
		var candidate = proj_pool[index]
		if not is_instance_valid(candidate):
			proj_pool.remove_at(index)
			active_projectiles.erase(candidate)
		elif not candidate.is_active and candidate.get_parent() == null:
			# A projectile waiting for its destroy timer is inactive but still attached.
			projectile = candidate
			break
	if projectile == null:
		projectile = projectile_scene.instantiate()
		proj_pool.append(projectile)
	active_projectiles.append(projectile)
	projectile.set("is_active", true)
	projectile.set_physics_process(true)
	projectile.call("reset_projectile")
	return projectile

func _exit_tree() -> void:
	# Idle projectiles are detached from the tree, so it cannot free them.
	for projectile in proj_pool:
		if is_instance_valid(projectile) and projectile.get_parent() == null:
			projectile.free()
