extends SceneTree

## Checks that the custom lighting path is faithful, by asserting the one thing
## that is supposed to be true of it.
##
## The previous version of this test flagged any material that rendered darker on
## the custom path than on Godot's own. That looked reasonable and was wrong: it
## treats Oren-Nayar itself as a fault. A rough diffuse lobe is *supposed* to be
## darker than Lambert at normal incidence, because that energy is redirected
## toward grazing angles. Cream_Onyx was refused by the gate over this for a while,
## on the strength of a 0.10 delta, before it turned out to be asking for
## diffuse_roughness = 1.0 -- where the lobe is 0.624 to 1.037 and the darkening
## is the material doing what it says.
##
## The invariant that does hold is sharper and catches real faults: at
## diffuse_roughness 0 the Oren-Nayar term is exactly 1.0, so the custom path must
## reproduce Godot's lighting to within noise. Everything else about the node --
## albedo, energy compensation, specular, the light loop -- has to be right for
## that to come out, which is how the double-albedo bug was caught.
##
## Darkening at the authored sigma is then reported, not judged, and read against
## the formula rather than against a threshold.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const FLAG := "materialx/custom_lighting"
const TMP := "res://.light_path"
const RES := 128
## A disc well inside the sphere, so the silhouette never contributes.
const DISC := 18

## Tolerance on the sigma-0 comparison. The capture is RGBA8, so a difference of
## a couple of quantisation steps is the floor, not signal.
const TOLERANCE := 0.02

var _bad := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))

	var subjects: PackedStringArray = _custom_lighting_corpus()
	print("checking %d material(s) on the custom lighting path\n" % subjects.size())
	print("%-32s %9s %9s %9s %9s" % [
		"material", "godot", "sigma=0", "authored", "expected"])

	var mismatched := 0
	var darkened := 0

	for path in subjects:
		_set_custom(false)
		var builtin: float = await _luminance(path)

		_set_custom(true)
		var at_zero: float = await _luminance(_variant(path, 0.0))
		var authored: float = await _luminance(path)

		var delta: float = at_zero - builtin
		var expected := _lobe_at(_diffuse_roughness(path))

		print("%-32s %9.4f %9.4f %9.4f %9.4f" % [
			path.get_file(), builtin, at_zero, authored, expected])

		if absf(delta) > TOLERANCE:
			mismatched += 1
			print("      MISMATCH at sigma 0: %+.4f from Godot's own lighting" % delta)
		if authored < builtin - TOLERANCE:
			darkened += 1

	_set_custom(false)
	_cleanup()

	print("\n=== verdict ===")
	print("  materials whose sigma 0 disagrees with Godot : %d / %d" % [
		mismatched, subjects.size()])
	print("  materials darker than Lambert at their own sigma: %d / %d" % [
		darkened, subjects.size()])

	_expect(mismatched == 0,
		"at sigma 0 the custom path reproduces Godot's own lighting, which is "
		+ "the invariant that catches transcription faults")

	print("\n--- %s ---" % ("light path OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


## The mean of A + B * stinv over the sphere's visible normals, which is what the
## lobe does to a diffuse term on average. A crude integral is enough: the point
## is to have a number to read the darkening against, not to match the render.
func _lobe_at(sigma: float) -> float:
	if sigma <= 0.0:
		return 1.0
	var s2 := sigma * sigma
	var a := 1.0 - 0.5 * (s2 / (s2 + 0.33))
	var b := 0.45 * s2 / (s2 + 0.09)
	# stinv is 0 at normal incidence and approaches 1 at grazing, so a uniform
	# view sees something between A and A + B.
	return a + b * 0.5


## The material's authored diffuse_roughness, as a literal where there is one.
func _diffuse_roughness(path: String) -> float:
	var text := FileAccess.get_file_as_string(path)
	var at := text.find('name="diffuse_roughness"')
	if at < 0:
		return 0.0
	var tail := text.substr(at, 120)
	var value_at := tail.find('value="')
	if value_at < 0:
		return 0.0
	tail = tail.substr(value_at + 7, 24)
	var end := tail.find("\"")
	if end <= 0:
		return 0.0
	return tail.substr(0, end).to_float()


## A copy of the material with its diffuse_roughness literal rewritten. The only
## difference between the two builds is that one number.
func _variant(path: String, sigma: float) -> String:
	var text := FileAccess.get_file_as_string(path)
	var at := text.find('name="diffuse_roughness"')
	if at < 0:
		# Already at the default, so the original already is the variant.
		return path
	var value_at := text.find('value="', at)
	if value_at < 0:
		return path
	var start := value_at + 7
	var end := text.find("\"", start)
	if end <= start:
		return path
	var out := text.substr(0, start) + str(sigma) + text.substr(end)
	var dst := TMP.path_join(path.get_file())
	var f := FileAccess.open(dst, FileAccess.WRITE)
	f.store_string(out)
	f = null
	return dst


## Every corpus material the custom lighting path takes over, found by building
## and looking for the light node so the list cannot drift from the gate.
func _custom_lighting_corpus() -> PackedStringArray:
	_set_custom(true)
	var out := PackedStringArray()
	var d := DirAccess.open("res://materials")
	if d == null:
		return out
	for f in d.get_files():
		if not f.ends_with(".mtlx"):
			continue
		var path := "res://materials/" + f
		var result := Emitter.build_file(path, PackedStringArray(["res://materials"]))
		if not result.ok:
			continue
		for id in result.shader.get_node_list(2):
			if result.shader.get_node(2, id) is VisualShaderNodeCustom:
				out.append(path)
				break
	return out


func _set_custom(on: bool) -> void:
	ProjectSettings.set_setting(FLAG, on)


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
	for i in 20:
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


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
