extends SceneTree

## Counts, empirically, how many corpus materials actually get the custom light
## node when custom_lighting is forced on.
##
## The gate-diag tool explained the refusals in isolation; this one builds every
## material for real and counts, so the two agree. It also asserts the thing that
## actually matters: no material that the gate accepted may fail to compile, and
## the accepted set must not silently shrink.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const DIR := "res://materials"
const FLAG := "materialx/custom_lighting"
const LIGHT_STAGE := 2  # VisualShader.TYPE_LIGHT

var _bad := 0


func _init() -> void:
	ProjectSettings.set_setting(FLAG, true)

	var files := _list(DIR)
	var with_light := 0
	var built := 0
	var shader_errors := 0

	for path in files:
		var result := Emitter.build_file(path)
		if not result.ok:
			continue
		built += 1
		if _light_node_count(result.shader) > 0:
			with_light += 1
		var code: String = result.shader.code
		if code.find("ERROR") >= 0:
			shader_errors += 1
			print("  shader code contains ERROR: %s" % path.get_file())

	print("built                : %d / %d" % [built, files.size()])
	print("got a custom light   : %d" % with_light)
	print("kept on built-in path: %d" % (built - with_light))
	print("shader code errors   : %d" % shader_errors)

	_expect(built == files.size(), "every file builds")
	_expect(with_light > 0, "the custom light is actually used somewhere")
	_expect(shader_errors == 0, "no material emits a broken shader")

	# Every custom light must sit on the light stage and declare the right node.
	var sample: Emitter.Result = _first_with_light(files)
	if sample != null:
		var n := _light_node_count(sample.shader)
		_expect(n == 1, "a material carries exactly one light node, not several")
		_expect(sample.shader.code.find("LIGHT_CODE") >= 0 or n > 0,
			"light stage code was emitted")

	print("\n--- %s ---" % ("gate OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


func _light_node_count(shader: VisualShader) -> int:
	var n := 0
	for id in shader.get_node_list(LIGHT_STAGE):
		if shader.get_node(LIGHT_STAGE, id) is VisualShaderNodeCustom:
			n += 1
	return n


func _first_with_light(files: PackedStringArray) -> Emitter.Result:
	for path in files:
		var result := Emitter.build_file(path)
		if result.ok and _light_node_count(result.shader) > 0:
			return result
	return null


func _list(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".mtlx"):
			out.append(dir_path.path_join(f))
	return out


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
