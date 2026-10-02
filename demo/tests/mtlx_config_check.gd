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
## Also guards materialx/materials_folder: it must register on first use so the
## Project Settings window shows it, and empty must read as auto-detect rather
## than as a path.

const Config := preload("res://addons/materialx/mtlx_config.gd")

const NEW_KEY := "materialx/custom_lighting"
const OLD_KEY := "materialx/experimental_custom_lighting"
const FOLDER_KEY := "materialx/materials_folder"

var _bad := 0
var _touched := PackedStringArray()


func _init() -> void:
	_fresh()
	_test_default_is_on()
	_test_old_key_true_is_kept()
	_test_old_key_false_is_honoured()
	_test_materials_folder()

	for k in _touched:
		ProjectSettings.set_setting(k, null)
	ProjectSettings.save()

	print("\n--- %s ---" % ("config OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


## A project that has never seen this setting should get the default.
func _fresh() -> void:
	for k in [NEW_KEY, OLD_KEY, FOLDER_KEY]:
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


## Empty is a meaningful value here, not a missing one: it is what auto-detect
## looks like, so a project that never chose a folder must read as empty even
## after the key is registered and written.
func _test_materials_folder() -> void:
	_fresh()
	# The getter alone must answer correctly even before anything is written,
	# since a project can be mid-load.
	_expect(Config.materials_folder() == "",
		"an unset folder reads as empty, i.e. auto-detect")

	_touched.append(FOLDER_KEY)
	Config.install_defaults()

	_expect(ProjectSettings.has_setting(FOLDER_KEY),
		"the folder key is written on first use")
	_expect(ProjectSettings.get_property_list().any(
		func(p): return p.name == FOLDER_KEY),
		"the folder key is registered so it appears in Project Settings")
	_expect(Config.materials_folder() == "",
		"registering the key does not invent a folder")

	ProjectSettings.set_setting(FOLDER_KEY, "res://materials/mtlx")
	_expect(Config.materials_folder() == "res://materials/mtlx",
		"the getter returns the folder the project saved")


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
