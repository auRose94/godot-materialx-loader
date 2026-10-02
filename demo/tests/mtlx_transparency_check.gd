extends SceneTree

## Guards the render modes a transparent material gets, and an opaque one must
## not. Writing ALPHA is what makes a converted material transparent, and every
## transparent material needs two render modes on top of the default line:
##
## * cull_disabled -- without it Godot shades only the front face, so a glass
##   shell hides its far wall from itself and the refraction loses the surface
##   behind the surface.
## * depth_prepass_alpha -- without it the engine's casts_shadows() marks any
##   ALPHA-writing material shadowless and the shadow passes skip it entirely.
##   This engine's render mode exists to restore exactly that.
##
## The fixtures are written rather than picked from the library, so the expected
## result does not depend on which materials happen to be installed.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const REFRACTION_FLAG := "materialx/screen_space_refraction"
const TMP := "res://.transparency_check"

var _bad := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	var refraction_state: Variant = ProjectSettings.get_setting(REFRACTION_FLAG, false)
	var had_refraction_flag := ProjectSettings.has_setting(REFRACTION_FLAG)

	_test_opaque_is_untouched()
	_test_opacity_is_transparent()
	ProjectSettings.set_setting(REFRACTION_FLAG, false)
	_test_transmission_without_refraction()
	ProjectSettings.set_setting(REFRACTION_FLAG, true)
	_test_transmission_with_refraction()
	_test_modes_survive_a_tres_round_trip()

	if had_refraction_flag:
		ProjectSettings.set_setting(REFRACTION_FLAG, refraction_state)
	else:
		ProjectSettings.set_setting(REFRACTION_FLAG, null)
	ProjectSettings.save()

	_cleanup()
	print("\n--- %s ---" % ("transparency OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


## base_color alone is the opaque case: the generated line keeps the engine
## default cull_back and gains no alpha-prepass, so for the corpus majority the
## render_mode line is unchanged.
func _test_opaque_is_untouched() -> void:
	var r := _build(_surface_mtlx(""))
	if not _expect(r.ok, "an opaque surface builds"):
		return
	var line: String = _render_mode_line(r.shader.code)
	_expect(line.contains("cull_back") and not line.contains("cull_disabled"),
		"opaque: cull stays at the default -> %s" % line)
	_expect(not line.contains("depth_prepass_alpha"),
		"opaque: no depth_prepass_alpha")


## opacity is MaterialX's alpha; any non-default value must reach ALPHA and
## turn the render modes on. Rubber.mtlx carries opacity too, but the fixture
## pins the behaviour down to the input itself.
func _test_opacity_is_transparent() -> void:
	var r := _build(_surface_mtlx('    <input name="opacity" type="float" value="0.4" />\n'))
	_expect(r.ok, "an opacity surface builds")
	if not r.ok:
		return
	_expect(_alpha_connected(r), "opacity: ALPHA is written")
	_check_transparent_modes(r, "opacity")


## With refraction off, transmission falls back to ALPHA (floored at 0.15), so
## the material is still transparent and still earns the render modes.
func _test_transmission_without_refraction() -> void:
	var r := _build(_surface_mtlx('    <input name="transmission" type="float" value="1.0" />\n'))
	_expect(r.ok, "a transmission surface builds")
	if not r.ok:
		return
	var code: String = r.shader.code
	_expect(code.find("hint_screen_texture") < 0,
		"transmission (refraction off): no screen sampler")
	_expect(_alpha_connected(r),
		"transmission (refraction off): ALPHA is written in its place")
	_check_transparent_modes(r, "transmission (refraction off)")


## With refraction on, ALPHA = 1.0 is written unconditionally to reach the
## transparent pass -- which is exactly the transparency these modes follow.
## But the prepass is withheld from a screen reader: a surface with the depth
## flag joins the OPAQUE list as well as the alpha list, and Compatibility
## draws both, so the surface rasterises into the screen copy and then
## refraction-samples itself -- the black-hole feedback, rendered as a black
## sphere with zero displacement. One .tres is rendered by both pipelines, so
## the shader keeps cull_disabled only, and casts no shadow.
func _test_transmission_with_refraction() -> void:
	var r := _build(_surface_mtlx('    <input name="transmission" type="float" value="1.0" />\n'))
	_expect(r.ok, "a transmission surface builds with refraction on")
	if not r.ok:
		return
	var code: String = r.shader.code
	_expect(code.find("hint_screen_texture") >= 0,
		"transmission (refraction on): the screen sampler is used")
	_expect(_alpha_connected(r), "transmission (refraction on): ALPHA is written")
	var line: String = _render_mode_line(code)
	_expect(line.contains("cull_disabled"),
		"transmission (refraction on): cull_disabled is set -> %s" % line)
	_expect(line.find("depth_prepass_alpha") < 0,
		"transmission (refraction on): the screen reader keeps no depth prepass")


## The modes live on the VisualShader, and the ShaderMaterial the game loads
## embeds that VisualShader: a saved .tres must reconstruct both modes, or the
## first load after a project reimport would silently drop the shadows.
func _test_modes_survive_a_tres_round_trip() -> void:
	var r := _build(_surface_mtlx('    <input name="opacity" type="float" value="0.4" />\n'))
	if not _expect(r.ok, "the round-trip fixture builds"):
		return
	var path: String = TMP.path_join("case.tres")
	var err: Error = ResourceSaver.save(r.shader, path)
	_expect(err == OK, "the VisualShader saves")
	var loaded: VisualShader = load(path)
	_expect(loaded != null, "and loads back")
	if loaded == null:
		return
	var line: String = _render_mode_line(loaded.code)
	_expect(line.contains("cull_disabled") and line.contains("depth_prepass_alpha"),
		"round trip: both modes survive -> %s" % line)


# --- helpers ---------------------------------------------------------------


func _check_transparent_modes(r: Emitter.Result, what: String) -> void:
	var line: String = _render_mode_line(r.shader.code)
	_expect(line.contains("cull_disabled"), "%s: cull_disabled is set -> %s" % [what, line])
	_expect(line.contains("depth_prepass_alpha"), "%s: depth_prepass_alpha is set" % what)


func _render_mode_line(code: String) -> String:
	for line in code.split("\n"):
		if line.begins_with("render_mode"):
			return line.strip_edges()
	return ""


func _alpha_connected(r: Emitter.Result) -> bool:
	for c in r.shader.get_node_connections(Emitter.FRAGMENT):
		if int(c["to_node"]) == 0 and int(c["to_port"]) == GodotMap.OUT_ALPHA:
			return true
	return false


func _build(text: String) -> Emitter.Result:
	var path := TMP.path_join("case.mtlx")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f = null
	return Emitter.build_file(path)


func _surface_mtlx(inputs: String) -> String:
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