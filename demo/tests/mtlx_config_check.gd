extends SceneTree

## Guards the custom-lighting setting's default and its move off the old key.
##
## This setting was opt-in and undocumented while it was called "experimental".
## It is now on by default under materialx/custom_lighting, which has two failure
## modes worth pinning down:
##
## - a fresh project must get the default, or the feature silently vanishes for
##   everyone who has not touched Project Settings
## - a project that set the old materialx/experimental_custom_lighting key must
##   keep its value rather than picking up the new default, or upgrading would
##   silently change how their materials render
##
## Also guards the two path settings, materialx/materials_folder and
## materialx/export_path: both must register on first use so the Project
## Settings window shows them, and empty must read as auto-detect respectively
## disabled rather than as a path.

const Config := preload("res://addons/materialx/mtlx_config.gd")

const NEW_KEY := "materialx/custom_lighting"
const OLD_KEY := "materialx/experimental_custom_lighting"
const FOLDER_KEY := "materialx/materials_folder"
const EXPORT_KEY := "materialx/export_path"

var _bad := 0
var _touched := PackedStringArray()


func _init() -> void:
	_fresh()
	_test_default_is_on()
	_test_old_key_true_is_kept()
	_test_old_key_false_is_honoured()
	_test_materials_folder()
	_test_export_path()

	for k in _touched:
		ProjectSettings.set_setting(k, null)
	ProjectSettings.save()

	print("\n--- %s ---" % ("config OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


## A project that has never seen this setting should get the default.
func _fresh() -> void:
	for k in [NEW_KEY, OLD_KEY, FOLDER_KEY, EXPORT_KEY]:
		if ProjectSettings.has_setting(k):
			_touched.append(k)
			ProjectSettings.set_setting(k, null)


func _test_default_is_on() -> void:
	_fresh()
	# The getter alone must answer correctly even before anything is written,
	# since a project can be mid-load.
	_expect(Config.custom_lighting(),
		"custom lighting is on with no setting present")

	_touched.append(NEW_KEY)
	Config.install_defaults()

	# And it must actually be registered, or Project Settings never shows it and
	# the only way to turn it off is the dock checkbox.
	_expect(ProjectSettings.has_setting(NEW_KEY),
		"the key is written on first use")
	_expect(ProjectSettings.get_property_list().any(
		func(p): return p.name == NEW_KEY),
		"the key is registered so it appears in Project Settings")


## A project that had opted in under the old key keeps opting in.
func _test_old_key_true_is_kept() -> void:
	_fresh()
	_touched.append(OLD_KEY)
	ProjectSettings.set_setting(OLD_KEY, true)

	Config.install_defaults()

	_expect(bool(ProjectSettings.get_setting(NEW_KEY, true)),
		"a project that had opted in stays opted in")
	_expect(not ProjectSettings.has_setting(OLD_KEY),
		"the old key is removed, so it does not linger as a dead entry")


## An old project that explicitly chose "off" must keep it. Silently switching
## someone to a different lighting model on upgrade is not acceptable.
func _test_old_key_false_is_honoured() -> void:
	_fresh()
	_touched.append(OLD_KEY)
	ProjectSettings.set_setting(OLD_KEY, false)
	# null erases the key, which is exactly the state a project that never
	# touched this setting arrives in.
	ProjectSettings.set_setting(NEW_KEY, null)

	Config.install_defaults()

	_expect(not bool(ProjectSettings.get_setting(NEW_KEY, true)),
		"a project that chose 'off' under the old key stays off")
	_expect(not Config.custom_lighting(),
		"and the getter agrees")
	_expect(not ProjectSettings.has_setting(OLD_KEY),
		"the old key is still cleaned up")


## The path settings share one contract: empty is a meaningful value, not a
## missing one (materials_folder's empty is auto-detect, export_path's disables
## the conversion); register them on first use so the Project Settings window
## shows them; and never invent a path a project did not save.
func _test_materials_folder() -> void:
	_test_path_setting(FOLDER_KEY, Config.materials_folder,
		"auto-detect", "res://materials/mtlx")


func _test_export_path() -> void:
	_test_path_setting(EXPORT_KEY, Config.export_path,
		"a disabled conversion", "res://materials/converted")


func _test_path_setting(key: String, getter: Callable, empty_means: String,
		saved: String) -> void:
	_fresh()
	# The getter alone must answer correctly even before anything is written,
	# since a project can be mid-load.
	_expect(str(getter.call()) == "",
		"an unset %s reads as empty, i.e. %s" % [key, empty_means])

	_touched.append(key)
	Config.install_defaults()

	_expect(ProjectSettings.has_setting(key),
		"%s is written on first use" % key)
	_expect(ProjectSettings.get_property_list().any(
		func(p): return p.name == key),
		"%s is registered so it appears in Project Settings" % key)
	_expect(str(getter.call()) == "",
		"registering %s does not invent a path" % key)

	ProjectSettings.set_setting(key, saved)
	_expect(str(getter.call()) == saved,
		"the getter returns the path the project saved")


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
