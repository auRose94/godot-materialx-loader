extends SceneTree

## Decides whether Cream_Onyx going dim on the custom lighting path is a bug or
## the Oren-Nayar lobe working.
##
## Cream_Onyx.mtlx has diffuse_roughness = 1.0, and at that value the lobe is
## supposed to be darker than Lambert:
##
##     sigma2 = 1.0
##     A = 1.0 - 0.5 * (1.0 / 1.33) = 0.624
##     B = 0.45 * (1.0 / 1.09)        = 0.413
##     diffuse_term = A + B * stinv   -> 0.624 .. 1.037
##
## Oren-Nayar's whole point is that a rough diffuse surface reflects less at
## normal incidence and sends the rest toward grazing angles. So a material asking
## for it rendering darker than Godot's Lambert is correct, and
## mtlx_light_path_check -- which treats any darkening as a failure -- may be
## asserting the wrong thing.
##
## The way to tell: render the same material twice on the custom path, once with
## its authored sigma and once with sigma pinned to 0, and compare each against
## Godot's own lighting. At sigma 0 the term is exactly 1.0, so the custom path
## must match Godot to within measurement noise. If it does, the transcription is
## sound and the darkening belongs to the lobe.
##
## The texture graphs are left untouched; only the one literal is rewritten.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const SOURCE := "res://materials/Cream_Onyx.mtlx"
const TMP := "res://.onyx_probe"
const LIGHT_STAGE := 2  # VisualShader.TYPE_LIGHT
const RES := 192
## Measured over a disc well inside the sphere, where the surface fills the frame.
const DISC := 30

var _bad := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	var zero_path: String = _variant(0.0)
	var one_path: String = _variant(1.0)

	# Built-in lighting, for the reference.
	_set_custom(false)
	var builtin := await _luminance(SOURCE)
	_set_custom(true)
	var at_zero := await _luminance(zero_path)
	var at_one := await _luminance(one_path)
	_set_custom(false)

	_cleanup()

	print("\n=== mean luminance inside the sphere ===")
	print("  Godot's own lighting        : %.4f" % builtin)
	print("  custom path, sigma = 0.0    : %.4f   (delta %+.4f)" % [
		at_zero, at_zero - builtin])
	print("  custom path, sigma = 1.0    : %.4f   (delta %+.4f)" % [
		at_one, at_one - builtin])

	# What the formula says the lobe does at sigma 1.0.
	var a: float = 1.0 - 0.5 * (1.0 / (1.0 + 0.33))
	var b: float = 0.45 * (1.0 / (1.0 + 0.09))
	print("\n=== what the lobe predicts ===")
	print("  A = %.3f, B = %.3f" % [a, b])
	print("  diffuse_term spans %.3f .. %.3f" % [a, a + b])
	print("  so a surface lit only by that term should land at roughly %.0f%% of Lambert" % (
		100.0 * a))

	print("\n=== verdict ===")
	var at_zero_ok: bool = absf(at_zero - builtin) <= 0.02
	if at_zero_ok:
		print("  OK: at sigma 0 the custom path matches Godot to within noise, so "
			+ "the transcription is sound")
	else:
		print("  FAIL: at sigma 0 the custom path still differs from Godot by "
			+ "%.4f, so the darkening is not only the lobe" % absf(at_zero - builtin))

	var lobe_ok: bool = at_one < at_zero - 0.02
	if lobe_ok:
		print("  OK: raising sigma to 1.0 darkens it, which is the lobe working")
	else:
		print("  FAIL: sigma 1.0 did not darken it, so something else is going on")

	quit(1 if _bad > 0 else 0)


## Copies the material with its diffuse_roughness literal rewritten, so the only
## difference between the two builds is that one number.
func _variant(sigma: float) -> String:
	var text := FileAccess.get_file_as_string(SOURCE)
	var rewritten := text.replace(
		'<input name="diffuse_roughness" type="float" value="1.0" />',
		'<input name="diffuse_roughness" type="float" value="%s" />' % sigma)
	if rewritten == text and sigma != 1.0:
		push_warning("could not find the diffuse_roughness literal to rewrite")
	var path := TMP.path_join("onyx_sigma_%s.mtlx" % str(sigma))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(rewritten)
	f = null
	return path


func _set_custom(on: bool) -> void:
	ProjectSettings.set_setting("materialx/custom_lighting", on)


func _cleanup() -> void:
	var abs_dir := ProjectSettings.globalize_path(TMP)
	for f in DirAccess.get_files_at(TMP):
		DirAccess.remove_absolute(abs_dir.path_join(f))
	DirAccess.remove_absolute(abs_dir)


func _luminance(path: String) -> float:
	var result := Emitter.build_file(path, PackedStringArray(["res://materials"]))
	if not result.ok:
		push_warning("%s did not build: %s" % [path, result.message])
		return -1.0

	var vp := SubViewport.new()
	vp.size = Vector2i(RES, RES)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	vp.own_world_3d = true

	var world := World3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.06)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.78)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = env
	vp.world_3d = world

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 3.1)
	cam.look_at_from_position(cam.position, Vector3.ZERO, Vector3.UP)
	vp.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(-26.0), 0.0)
	light.light_energy = 2.4
	light.shadow_enabled = false
	vp.add_child(light)

	var mesh := MeshInstance3D.new()
	mesh.mesh = SphereMesh.new()
	var mat := ShaderMaterial.new()
	mat.shader = result.shader
	mesh.material_override = mat
	vp.add_child(mesh)

	root.add_child(vp)
	for i in 25:
		await RenderingServer.frame_post_draw

	var img: Image = vp.get_texture().get_image()
	vp.queue_free()
	await RenderingServer.frame_post_draw

	var c := RES / 2
	var sum := 0.0
	var n := 0
	for y in range(c - DISC, c + DISC, 2):
		for x in range(c - DISC, c + DISC, 2):
			var px := img.get_pixel(x, y)
			sum += 0.2126 * px.r + 0.7152 * px.g + 0.0722 * px.b
			n += 1
	return sum / maxf(n, 1.0)
