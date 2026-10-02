extends SceneTree

## Guards the dock's remembered source folder (materialx/materials_folder).
##
## The setting exists so the dock reopens where the user left it instead of
## re-guessing each session. Four ways that could silently break:
##
## - a saved folder must win over auto-detect, or the setting is decoration
## - a saved folder that no longer exists must fall back to auto-detect, or a
##   moved or renamed folder points the dock at nothing
## - committing the field must write the setting, or the dock forgets on the
##   next launch
## - clearing the field must write empty, or there is no way back to auto-detect

const Converter := preload("res://addons/materialx/mtlx_converter.gd")
const Config := preload("res://addons/materialx/mtlx_config.gd")

const KEY := "materialx/materials_folder"
## Exists in this project, and holds the demo .mtlx files, so auto-detect
## lands on it too.
const REAL_DIR := "res://materials"
## Exists in no project.
const GHOST_DIR := "res://no_such_material_folder"

var _bad := 0


func _init() -> void:
	_forget()
	await _test_saved_folder_wins()
	await _test_dead_folder_falls_back()
	await _test_commit_saves()
	await _test_clearing_returns_to_auto()

	# Leave the demo project as it started: no folder chosen. The saves the
	# commit cases triggered are undone by this one.
	_forget()
	ProjectSettings.save()

	print("\n--- %s ---" % ("folder setting OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


## Start every case from the not-chosen-yet state.
func _forget() -> void:
	if ProjectSettings.has_setting(KEY):
		ProjectSettings.set_setting(KEY, null)


## Builds the dock as the editor would, with no plugin behind it, so folder
## auto-detect falls to the top-level scan. Untyped on purpose: the check must
## not depend on global class-name resolution.
##
## Waits a frame, because _ready has not fired yet while the SceneTree script
## is still in _init.
func _fresh_dock():
	var dock = Converter.new()
	root.add_child(dock)
	await process_frame
	return dock


func _test_saved_folder_wins() -> void:
	ProjectSettings.set_setting(KEY, REAL_DIR)
	var dock = await _fresh_dock()
	_expect(dock._folder.text == REAL_DIR, "the dock opens on the saved folder")
	dock.free()


func _test_dead_folder_falls_back() -> void:
	ProjectSettings.set_setting(KEY, GHOST_DIR)
	var dock = await _fresh_dock()
	_expect(dock._folder.text == REAL_DIR,
		"a saved folder that no longer exists falls back to auto-detect")
	dock.free()


func _test_commit_saves() -> void:
	var dock = await _fresh_dock()
	dock._folder.text = REAL_DIR + "/"
	dock._on_folder_committed()
	_expect(Config.materials_folder() == REAL_DIR,
		"committing the field saves it, without the trailing slash")
	_expect(String(ProjectSettings.get_setting(KEY, "")) == REAL_DIR,
		"and it reaches the project settings, not just the getter")
	dock.free()


func _test_clearing_returns_to_auto() -> void:
	# The previous case left REAL_DIR saved.
	var dock = await _fresh_dock()
	_expect(dock._folder.text == REAL_DIR, "the dock opened on the saved folder")
	dock._folder.text = ""
	dock._on_folder_committed()
	_expect(Config.materials_folder() == "", "clearing the field forgets the folder")

	var rebuilt = await _fresh_dock()
	# With the setting empty, whatever the rebuilt dock shows is auto-detect;
	# in this project that is res://materials again.
	_expect(rebuilt._folder.text == REAL_DIR, "so a rebuilt dock auto-detects again")
	dock.free()
	rebuilt.free()


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond