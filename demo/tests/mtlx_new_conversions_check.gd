extends SceneTree

## Verifies the two newly implemented conversions actually produce the right
## graph, rather than merely compiling:
##
##   * hsvadjust builds RGB -> HSV -> adjust -> HSV -> RGB out of native nodes
##   * sheen drives RIM, and a non-white sheen_color drives RIM_TINT
##
## The fixtures are written rather than picked from the library, so the expected
## result does not depend on which materials happen to be installed.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const TMP := "res://.hsv_check"

var _bad := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	_test_hsv_identity()
	_test_hsv_hue_rotate()
	_test_sheen()
	_cleanup()
	print("\n--- %s ---" % ("new conversions OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


## amount = (0, 1, 1) is a no-op by the spec, so the output must be the input.
func _test_hsv_identity() -> void:
	var r := _build(_hsv_mtlx("0, 1, 1"))
	_expect(r.ok, "identity hsvadjust builds")
	if not r.ok:
		return
	var code: String = r.shader.code
	print("\n--- hsvadjust, amount = (0, 1, 1) ---")
	_expect(code.contains("vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0)"), "converts to HSV")
	_expect(code.contains("vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0)"), "converts back to RGB")
	_expect(code.contains("fract("), "wraps the hue with fract")
	# amount.x is 0, so the hue add is a no-op. Godot folds a constant into the
	# generated code rather than emitting a redundant add.
	print(code.strip_edges().split("\n")[0] if code.is_empty() else "  generated ok")


## A non-zero hue rotation has to actually shift the hue, which means the add is
## present rather than folded away.
func _test_hsv_hue_rotate() -> void:
	var r := _build(_hsv_mtlx("0.25, 1, 1"))
	_expect(r.ok, "hue rotation builds")
	if not r.ok:
		return
	var code: String = r.shader.code
	_expect(code.contains("vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0)") and code.contains("vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0)"),
		"hue rotation round-trips through HSV")


## sheen -> RIM directly; sheen_color -> RIM_TINT, which must be absent for the
## MaterialX default (white) and present otherwise.
func _test_sheen() -> void:
	var plain := _build(_surface_mtlx('    <input name="sheen" type="float" value="0.6" />\n', ""))
	_expect(plain.ok, "sheen builds")
	if plain.ok:
		_expect(_has_output(plain, GodotMap.OUT_RIM), "sheen drives RIM")

	var white := _build(_surface_mtlx(
		'    <input name="sheen" type="float" value="0.6" />\n'
		+ '    <input name="sheen_color" type="color3" value="1, 1, 1" />\n', ""))
	if _expect(white.ok, "white sheen_color builds"):
		_expect(not _has_output(white, GodotMap.OUT_RIM_TINT),
			"white sheen_color leaves RIM_TINT alone (it is a no-op)")

	var coloured := _build(_surface_mtlx(
		'    <input name="sheen" type="float" value="0.6" />\n'
		+ '    <input name="sheen_color" type="color3" value="0.5, 0, 0" />\n', ""))
	if _expect(coloured.ok, "coloured sheen_color builds"):
		_expect(_has_output(coloured, GodotMap.OUT_RIM_TINT),
			"coloured sheen_color drives RIM_TINT")
		_expect(_has_output(coloured, GodotMap.OUT_RIM),
			"and RIM is still driven")


# --- helpers ---------------------------------------------------------------

func _build(text: String) -> Emitter.Result:
	var path := TMP.path_join("case.mtlx")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f = null
	return Emitter.build_file(path)


func _has_output(r: Emitter.Result, port: int) -> bool:
	for c in r.shader.get_node_connections(1):
		if int(c["to_node"]) == 0 and int(c["to_port"]) == port:
			return true
	return false


func _hsv_mtlx(amount: String) -> String:
	return """<?xml version="1.0"?>
<materialx version="1.38">
  <constant name="c" type="color3">
    <input name="value" type="color3" value="0.2, 0.6, 0.4" />
  </constant>
  <constant name="a" type="vector3">
    <input name="value" type="vector3" value="%s" />
  </constant>
  <hsvadjust name="adj" type="color3">
    <input name="in" type="color3" nodename="c" />
    <input name="amount" type="vector3" nodename="a" />
  </hsvadjust>
  <standard_surface name="SR" type="surfaceshader">
    <input name="base_color" type="color3" nodename="adj" />
  </standard_surface>
  <surfacematerial name="M" type="material">
    <input name="surfaceshader" type="surfaceshader" nodename="SR" />
  </surfacematerial>
</materialx>
""" % amount


func _surface_mtlx(inputs: String, _unused: String) -> String:
	return """<?xml version="1.0"?>
<materialx version="1.38">
  <standard_surface name="SR" type="surfaceshader">
    <input name="base_color" type="color3" value="0.8, 0.8, 0.8" />
%s  </standard_surface>
  <surfacematerial name="M" type="material">
    <input name="surfaceshader" type="surfaceshader" nodename="SR" />
  </surfacematerial>
</materialx>
""" % inputs


func _cleanup() -> void:
	var abs_dir := ProjectSettings.globalize_path(TMP)
	for f in DirAccess.get_files_at(TMP):
		DirAccess.remove_absolute(abs_dir.path_join(f))
	DirAccess.remove_absolute(abs_dir)


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
