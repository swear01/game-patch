extends RefCounted

const BUTTON_SCRIPTS := {
	"open_save_picker": "res://Title/start_game_button.gd",
	"start_day": "res://GUI/new_day_button.gd",
}

static func press(tree: SceneTree, action: String) -> Error:
	# A test must explicitly start in a profile copied outside the live save folder.
	if OS.get_environment("QUARRY_TEST_PROFILE") != "1" or tree.current_scene == null:
		return ERR_UNAUTHORIZED
	var expected: String = BUTTON_SCRIPTS.get(action, "")
	if expected.is_empty():
		return ERR_INVALID_PARAMETER
	for node in tree.current_scene.find_children("*", "BaseButton", true, false):
		var script: Script = node.get_script()
		if script == null or script.resource_path != expected:
			continue
		if node.disabled or not node.is_visible_in_tree():
			return ERR_UNAVAILABLE
		node.pressed.emit()
		return OK
	return ERR_DOES_NOT_EXIST
