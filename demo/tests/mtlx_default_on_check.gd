extends SceneTree

## Confirms the default is live in a project that has never set the flag, and
## that the old key migrates rather than being silently ignored.
##
## The corpus check is not enough on its own: it only proves nothing crashes.
## This one asserts the material count actually changes, because a default that
## silently fails to register would leave the feature off and every other test
## would still pass.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const Config := preload("res://addons/materialx/mtlx_config.gd")

const DIR := "res://materials"
const LIGHT_STAGE := 2  # VisualShader.TYPE_LIGHT
const NEW_KEY := "materialx/custom_lighting"
const OLD_KEY := "materialx/experimental_custom_lighting"

var _bad := 0


func _init() -> void:
	# Whatever the project file currently says, start from nothing so this is a
	# test of the shipped default rather than of local state.
	var had_new := ProjectSettings.has_setting(NEW_KEY)
	var saved_new: Variant = ProjectSettings.get_setting(NEW_KEY) if had_new else null
	var had_old := ProjectSettings.has_setting(OLD_KEY)
	var saved_old: Variant = ProjectSettings.get_setting(OLD_KEY) if had_old else null

	ProjectSettings.set_setting(NEW_KEY, null)
	ProjectSettings.set_setting(OLD_KEY, null)
	Config.install_defaults()

	_expect(Config.custom_lighting(),
		"a project that never set the flag gets Oren-Nayar on")
	_expect(ProjectSettings.has_setting(NEW_KEY),
		"the default is written, so it is visible and editable")

	var lit := _count_with_custom_light()
	print("  materials reached by the default: %d / 277" % lit)
	_expect(lit > 0, "the default actually changes how materials are built")

	# And the old opt-out key still wins, so an existing project is not switched
	# on by the upgrade.
	ProjectSettings.set_setting(NEW_KEY, null)
	ProjectSettings.set_setting(OLD_KEY, false)
	Config.install_defaults()
	_expect(not Config.custom_lighting(),
		"a project that chose off under the old key stays off")

	# Put the project back as it was found.
	ProjectSettings.set_setting(NEW_KEY, saved_new if had_new else null)
	ProjectSettings.set_setting(OLD_KEY, saved_old if had_old else null)
	ProjectSettings.save()

	print("\n--- %s ---" % ("default OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


func _count_with_custom_light() -> int:
	var n := 0
	var d := DirAccess.open(DIR)
	if d == null:
		return 0
	for f in d.get_files():
		if not f.ends_with(".mtlx"):
			continue
		var result := Emitter.build_file(DIR.path_join(f))
		if not result.ok:
			continue
		for id in result.shader.get_node_list(LIGHT_STAGE):
			if result.shader.get_node(LIGHT_STAGE, id) is VisualShaderNodeCustom:
				n += 1
				break
	return n


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
