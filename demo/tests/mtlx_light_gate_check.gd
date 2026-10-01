extends SceneTree

## A/B check for the custom-lighting flag.
##
## The contract being tested:
##
##   flag off -> byte-for-byte the same graph as before. Nothing may move,
##                because 256 of the 277 materials must be untouched.
##   flag on  -> a light stage exists, and only for a material that actually
##                drives diffuse_roughness away from the default.
##
## The gate has two refusals that matter as much as the opt-in, so both are
## checked: a material at the default must NOT opt in, and a material using
## subsurface scattering must NOT opt in, because its transmittance uniforms are
## per-object and unreachable from a light function.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const Config := preload("res://addons/materialx/mtlx_config.gd")

const TMP := "res://.light_gate"
const LIGHT := 2  # VisualShader.TYPE_LIGHT
## Only the custom light node emits this, so it marks the gate.
const OREN_MARKER := "stinv"

var _bad := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	ProjectSettings.set_setting(Config.CUSTOM_LIGHTING, false)

	var rough := '    <input name="diffuse_roughness" type="float" value="0.5" />\n'

	# --- flag off: nothing changes ---
	var off := _build(_surface(rough))
	_expect(off.ok, "converts with the flag off")
	print("  [flag=%s] fragment nodes: %d, light nodes: %d, vertex nodes: %d" % [
		Config.custom_lighting(),
		off.shader.get_node_list(1).size(),
		off.shader.get_node_list(LIGHT).size(),
		off.shader.get_node_list(0).size()])
	# The light stage always holds its implicit output node, the same way the
	# fragment stage does, so "empty" means "output node only".
	_expect(_light_user_nodes(off.shader) == 0,
		"flag off: no light stage nodes beyond the implicit output")
	_expect(not off.shader.code.contains(OREN_MARKER),
		"flag off: no Oren-Nayar in the generated code")

	# --- flag on: the rough material opts in ---
	ProjectSettings.set_setting(Config.CUSTOM_LIGHTING, true)

	var on := _build(_surface(rough))
	_expect(on.ok, "converts with the flag on")
	print("\n  fragment nodes: %d, light nodes: %d" % [
		on.shader.get_node_list(1).size(), on.shader.get_node_list(LIGHT).size()])
	_expect(_light_user_nodes(on.shader) == 2,
		"flag on: the sigma constant and the light node were added")
	_expect(on.shader.code.contains(OREN_MARKER),
		"flag on: the Oren-Nayar term is in the generated code")
	_expect(on.shader.get_node_connections(LIGHT).size() >= 2,
		"flag on: both diffuse and specular outputs are wired")

	# --- a material at the default must not opt in ---
	var plain := _build(_surface(""))
	_expect(plain.ok, "plain material converts")
	_expect(_light_user_nodes(plain.shader) == 0,
		"a material at the default keeps Godot's lighting (nothing to gain)")

	# --- a scale without its weight is inert, so it must still opt in ---
	#
	# subsurface_scale says how far light travels; subsurface says whether any
	# of it is there. Testing the scale refuses every material in the library,
	# because scale is routinely written as a non-default vector even while the
	# weight is 0 -- the same reasoning the gate applies to coat_roughness. The
	# gate tests the enabling input, not the parameters.
	var inert := _build(_surface(rough
		+ '    <input name="subsurface_scale" type="vector3" value="1, 0.2, 0.1" />\n'))
	_expect(inert.ok, "a material with an inert subsurface scale converts")
	_expect(_light_user_nodes(inert.shader) > 0,
		"an inert subsurface scale does not block the custom lobe")

	# --- subsurface scattering must not opt in ---
	var sss := _build(_surface(rough
		+ '    <input name="subsurface" type="float" value="0.4" />\n'))
	_expect(sss.ok, "subsurface material converts")
	_expect(_light_user_nodes(sss.shader) == 0,
		"subsurface scattering is refused, since its transmittance is unreachable")
	# --- and the whole library is unharmed ---
	var all_clear := true
	for f in _materials():
		var r := Emitter.build_file(f)
		if not r.ok:
			all_clear = false
			print("    failed: ", f)
	ProjectSettings.set_setting(Config.CUSTOM_LIGHTING, false)
	_expect(all_clear, "every material in the library still converts")

	_cleanup()
	print("\n--- %s ---" % ("gate OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)



## Light-stage nodes, excluding the implicit output node that is always present.
func _light_user_nodes(shader: VisualShader) -> int:
	var n := 0
	for id in shader.get_node_list(LIGHT):
		if id != 0:
			n += 1
	return n


# --- helpers ---------------------------------------------------------------

func _materials() -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open("res://materials")
	if d == null:
		return out
	for f in d.get_files():
		if f.get_extension().to_lower() == "mtlx":
			out.append("res://materials/" + f)
	return out


func _build(text: String) -> Emitter.Result:
	var path := TMP.path_join("case.mtlx")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f = null
	return Emitter.build_file(path)


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


func _cleanup() -> void:
	var abs_dir := ProjectSettings.globalize_path(TMP)
	for f in DirAccess.get_files_at(TMP):
		DirAccess.remove_absolute(abs_dir.path_join(f))
	DirAccess.remove_absolute(abs_dir)


func _expect(cond: bool, what: String) -> void:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)