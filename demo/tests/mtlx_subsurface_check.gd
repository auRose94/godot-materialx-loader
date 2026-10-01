extends SceneTree

## Checks the subsurface mapping.
##
## Godot implements subsurface scattering as a compute pass that blurs the
## diffuse buffer, keyed off the SSS_STRENGTH the fragment shader writes
## (scene_forward_clustered.glsl:3074 puts it in diffuse_buffer.a). So the port is
## the whole interface -- there is nothing else for a material to fill in.
##
## Verified empirically that SSS_STRENGTH is output port 17 and BACKLIGHT is 18,
## and that SSS_TRANSMITTANCE_COLOR, _DEPTH and _BOOST are not writable output
## ports at all: the node has 25 ports and 19-24 are ALPHA_SCISSOR_THRESHOLD,
## ALPHA_HASH_SCALE, ALPHA_ANTIALIASING_EDGE, ALPHA_TEXTURE_COORDINATE, DEPTH and
## BENT_NORMAL_MAP. So subsurface colour and radius have nowhere to go, and the
## honest thing is to report them rather than approximate them silently.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const GodotMap := preload("res://addons/materialx/godot_map.gd")

const FRAGMENT := 1  # VisualShader.TYPE_FRAGMENT
const OUTPUT_NODE := 0
const OUT_ALPHA := 1



const TMP := "res://.sss_check"

var _bad := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))

	# A material that asks for subsurface scattering, with the colour and radius
	# MaterialX also specifies.
	var sss := _build("""
    <input name="subsurface" type="float" value="0.6" />
    <input name="subsurface_color" type="color3" value="0.9, 0.2, 0.1" />
    <input name="subsurface_radius" type="color3" value="1.0, 0.2, 0.1" />
""")
	_expect(sss.ok, "a subsurface material converts")

	var code: String = sss.shader.code
	_expect(code.find("SSS_STRENGTH") >= 0, "subsurface reaches SSS_STRENGTH")
	_expect(absf(_sss_value(sss.shader) - 0.6) < 0.001,
		"the authored weight is carried through, not defaulted")

	print("\n  reported drops:")
	for k in sss.dropped.keys():
		print("    %-24s %s" % [k, sss.dropped[k]])
	for name in ["subsurface_color", "subsurface_radius"]:
		_expect(sss.dropped.has(name),
			name + " is reported as dropped, not silently approximated")

	# A material with no subsurface must not write the port, or every material in
	# the library would opt into a post-process it never asked for.
	var plain := _build("")
	_expect(plain.ok, "a plain material converts")
	_expect(plain.shader.code.find("SSS_STRENGTH") < 0,
		"a material without subsurface leaves SSS_STRENGTH alone")

	# 0 is the MaterialX default, so it must also be inert.
	var zero := _build('    <input name="subsurface" type="float" value="0.0" />\n')
	_expect(zero.ok, "a zero-subsurface material converts")
	_expect(zero.shader.code.find("SSS_STRENGTH") < 0,
		"subsurface at its 0.0 default is inert, so the post-process is opt-in")

	var clamped := _build('    <input name="subsurface" type="float" value="4.0" />\n')
	_expect(clamped.ok, "an out-of-range weight still converts")
	var value: float = _sss_value(clamped.shader)
	print("\n  subsurface = 4.0 reaches SSS_STRENGTH as %.3f" % value)
	_expect(value <= 1.0,
		"an out-of-range weight is clamped to 0..1, since Godot's port is a "
		+ "straight multiply into the blur strength")

	_cleanup()
	print("\n--- %s ---" % ("subsurface OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


func _surface(inputs: String) -> String:
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


## Writes a real .mtlx and converts it, so the parser is exercised rather than a
## hand-assembled document being trusted to match what a file actually produces.
func _build(inputs: String) -> Emitter.Result:
	var path := TMP.path_join("case.mtlx")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(_surface(inputs))
	f = null
	return Emitter.build_file(path)


func _cleanup() -> void:
	var abs_dir := ProjectSettings.globalize_path(TMP)
	for f in DirAccess.get_files_at(TMP):
		DirAccess.remove_absolute(abs_dir.path_join(f))
	DirAccess.remove_absolute(abs_dir)


## The literal value driven into the SSS_STRENGTH port, by reading the default
## input value on whatever feeds it.
func _sss_value(shader: VisualShader) -> float:
	for c in shader.get_node_connections(FRAGMENT):
		var d: Dictionary = c
		if int(d["to_node"]) == OUTPUT_NODE and int(d["to_port"]) == GodotMap.OUT_SSS_STRENGTH:
			var src: VisualShaderNode = shader.get_node(
				FRAGMENT, int(d["from_node"]))
			if src is VisualShaderNodeFloatParameter:
				return src.default_value
			if src is VisualShaderNodeFloatConstant:
				return src.constant
	return -1.0


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
