extends SceneTree

## Guards the custom resource loader against claiming resources that are not ours.
##
## ResourceFormatLoader._get_resource_type used to answer "VisualShader"
## unconditionally. That sounds harmless and was not: ResourceLoader's
## get_resource_type returns the first non-empty answer from any registered loader
## and asks every loader about every path (core/io/resource_loader.cpp:1389), so
## this addon claimed the type of every resource in the project, scripts included.
##
## The editor then asked for res://addons/map_builder/core/brush_geometry.gd as a
## VisualShader, no loader could produce one, and the failure cascaded through
## every file that preloads it. The addon could not load its own .mtlx files while
## an unrelated addon was broken.
##
## Nothing in the addon's own tests would have caught it, because every test loads
## a .mtlx and that path always answered correctly. This one asks about paths that
## are not ours, which is the case that was wrong.

const Loader := preload("res://addons/materialx/mtlx_format_loader.gd")

var _bad := 0


func _init() -> void:
	var loader := Loader.new()

	# The positive case, so the guard cannot be "fixed" by answering nothing.
	_expect(loader._get_resource_type("res://materials/Gold.mtlx") == "VisualShader",
		"a .mtlx is still reported as a VisualShader")
	_expect(loader._recognize_path("res://materials/Gold.mtlx", ""),
		"a .mtlx is still recognised")

	# The case that broke another addon: every other kind of path.
	var foreign := [
		"res://addons/map_builder/core/brush_geometry.gd",
		"res://addons/some_other_addon/plugin.gd",
		"res://scenes/main.tscn",
		"res://materials/textures/Aluminum_Brushed_normal.png",
		"res://environment/default_environment.tres",
		"res://icon.svg",
	]
	for path in foreign:
		_expect(loader._get_resource_type(path).is_empty(),
			"does not claim a type for " + path)
		_expect(not loader._recognize_path(path, ""),
			"does not recognise " + path)
		_expect(not loader._recognize_path(path, "VisualShader"),
			"does not recognise " + path + " even when asked for a VisualShader")

	# _get_dependencies is asked the same way, and parsing a script as MaterialX
	# would only produce a spurious warning.
	for path in foreign:
		var deps: PackedStringArray = loader._get_dependencies(path, false)
		_expect(deps.is_empty(),
			"reports no dependencies for " + path)

	# Extensions are matched case-insensitively, and a path with no extension at
	# all is not ours either.
	_expect(not loader._get_resource_type("res://materials/Gold").is_empty() == false,
		"an extensionless path is not claimed as ours")
	_expect(loader._get_resource_type("res://materials/Gold.MTLX") == "VisualShader",
		"uppercase .MTLX is still recognised")

	print("\n--- %s ---" % ("loader scope OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
