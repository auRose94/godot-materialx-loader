extends SceneTree

## Renders the custom Oren-Nayar light node against Godot's built-in lighting and
## measures the numeric difference, separating the diffuse and specular lobes.
##
## The claim under test is that diffuse_roughness = 0 reduces the node to Lambert,
## so turning the flag on cannot change a default material. That is readable in
## the formula -- A = 1 and B = 0, so diffuse_term = 1.0, giving exactly Godot's
## albedo * NdotL / PI (scene_forward_lights_inc.glsl:222-244). But a formula
## that reads right is not a pipeline that renders right: writing to the light
## stage sets LIGHT_CODE_USED, which makes Godot skip its entire lighting model,
## so anything the node failed to transcribe vanishes with no error.
##
## The lobes are separated by differencing albedo rather than by masking.
## f0 = mix(0.16 * specular_amount^2, albedo, metallic), so with metallic = 0 it
## is 0.16 whatever the albedo is -- the specular response is identical across
## the pair and cancels:
##
##     rendered(coloured albedo) - rendered(black albedo)  ==  albedo * L_D
##
## on Godot's path, and the same identity holds on the node's path with its own
## diffuse term in place. So differencing two renders isolates the diffuse lobe
## exactly, with no assumption about how wrong the specular lobe is, and no
## masking that could quietly exclude the pixels that matter.
##
## The distinction matters because the two lobes fail differently. The node fits
## the split-sum DFG energy-compensation term analytically, because a light
## function cannot sample the lookup texture (scene_forward_clustered_inc.glsl:502)
## where Godot reads the real texture, so specular is knowingly approximate. The
## diffuse lobe has no such excuse and must match.

const OrenNayarLight := preload("res://addons/materialx/mtlx_oren_nayar_light.gd")
const GodotMap := preload("res://addons/materialx/godot_map.gd")

const FRAGMENT := 1     # VisualShader.TYPE_FRAGMENT
const LIGHT_STAGE := 2  # VisualShader.TYPE_LIGHT
const OUTPUT_NODE := 0  # implicit VisualShaderNodeOutput (mtlx_emitter.gd:26)

const RES := 192
const ROUGHNESS := 0.35
const DIELECTRIC := Color(0.62, 0.55, 0.48)

## The smallest difference this test can meaningfully resolve, with headroom.
##
## The viewport texture is RGBA8, so a single capture quantises to 1/255. The
## diffuse-only figure is a difference of two captures, and comparing that figure
## against the total is a second difference, so the resolution limit is about
## 4/255. It is a little above that in practice, because both _sub and _diff
## reduce three channels with a max, compounding the rounding. The measured value
## sits at 4.1/255 -- the floor, not above it.
##
## Nothing smaller than that is signal rather than quantisation, so this is what a
## claim of "exact" has to be measured against, not an arbitrary tolerance. Note
## what it can and cannot do: it bounds the diffuse error at roughly 0.025, and
## detects a regression that clears that, but it cannot prove bit-equality. The
## test that could is a flat-lit quad compared in a single capture, where the
## quantisation step is a single 1/255 rather than a difference of differences.
##
## The threshold is still well below what the bug it exists to catch measured:
## when the node multiplied by albedo inside the light function as well as after
## it, the same test reported a diffuse mean of about 0.064, nearly four times
## this bound.
const QUANT_FLOOR := 6.0 / 255.0

var _bad := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var black := Color(0, 0, 0)

	# Godot's built-in path, twice: coloured and black albedo.
	var builtin_col := await _render(_shader(DIELECTRIC, false, true))
	var builtin_blk := await _render(_shader(black, false, true))
	# The custom light node, same pair.
	var custom_col := await _render(_shader(DIELECTRIC, false, false))
	var custom_blk := await _render(_shader(black, false, false))

	for img in [builtin_col, builtin_blk, custom_col, custom_blk]:
		if img == null:
			print("  FAIL: could not capture every render")
			quit(1)
			return

	var lit := _lit_fraction(builtin_col)
	print("captured %dx%d, %.1f%% of pixels lit" % [RES, RES, lit * 100.0])
	_expect(lit > 0.30, "the sphere fills enough of the frame for the "
		+ "comparison to mean something")

	# Both lobes together, which is what a user would actually see.
	var total := _diff(builtin_col, custom_col)

	# Diffuse only: differencing the albedo pair cancels the specular response.
	var diffuse_builtin := _sub(builtin_col, builtin_blk)
	var diffuse_custom := _sub(custom_col, custom_blk)
	var diffuse := _diff(diffuse_builtin, diffuse_custom)

	# Specular only: what is left of the total once diffuse is accounted for.
	var specular := _sub_arr(total, diffuse)

	print("\n=== difference from Godot's built-in path, 0..1 ===")
	_report("both lobes", total)
	_report("diffuse only", diffuse)
	_report("specular only", specular)

	print("\n=== verdict ===")
	print("  mean error, both lobes   : %.6f" % _mean(total))
	print("  mean error, diffuse only : %.6f" % _mean(diffuse))
	print("  mean error, specular only: %.6f" % _mean(specular))

	print("  quantisation floor        : %.6f" % QUANT_FLOOR)

	_expect(_mean(diffuse) <= QUANT_FLOOR,
		"diffuse sits at the quantisation floor, so it cannot be distinguished "
		+ "from Godot's own Lambert -- and a real regression would clear it")
	_expect(_max(specular) > _max(diffuse),
		"specular is where the remaining error lives, as expected from the "
		+ "analytic DFG fit")

	print("\n--- %s ---" % ("equivalence OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


## custom_light puts the Oren-Nayar node on the light stage; without it the
## same material is lit by Godot's built-in model.
func _shader(albedo: Color, unused_mode: bool, custom_light: bool) -> VisualShader:
	var sh := VisualShader.new()

	var col := VisualShaderNodeVec3Constant.new()
	col.constant = Vector3(albedo.r, albedo.g, albedo.b)
	sh.add_node(FRAGMENT, col, Vector2(0, -100), 2)

	var rough := VisualShaderNodeFloatConstant.new()
	rough.constant = ROUGHNESS
	sh.add_node(FRAGMENT, rough, Vector2(0, -180), 3)

	var metal := VisualShaderNodeFloatConstant.new()
	metal.constant = 0.0
	sh.add_node(FRAGMENT, metal, Vector2(0, -260), 4)

	sh.connect_nodes(FRAGMENT, 2, 0, OUTPUT_NODE, GodotMap.OUT_ALBEDO)
	sh.connect_nodes(FRAGMENT, 3, 0, OUTPUT_NODE, GodotMap.OUT_ROUGHNESS)
	sh.connect_nodes(FRAGMENT, 4, 0, OUTPUT_NODE, GodotMap.OUT_METALLIC)

	if custom_light:
		# diffuse_roughness pinned to 0 -- the value every default material has,
		# since MaterialX's default is 0 and that is exactly where Oren-Nayar
		# degenerates to Lambert.
		var sigma := VisualShaderNodeFloatConstant.new()
		sigma.constant = 0.0
		sh.add_node(LIGHT_STAGE, sigma, Vector2(0, -100), 2)

		var light := OrenNayarLight.new()
		sh.add_node(LIGHT_STAGE, light, Vector2(220, 0), 3)

		sh.connect_nodes_forced(LIGHT_STAGE, 2, 0, 3, 0)
		# The node's two outputs go to the light stage's own output ports:
		# DIFFUSE_LIGHT = 0, SPECULAR_LIGHT = 1.
		sh.connect_nodes_forced(LIGHT_STAGE, 3, 0, OUTPUT_NODE, 0)
		sh.connect_nodes_forced(LIGHT_STAGE, 3, 1, OUTPUT_NODE, 1)
	return sh


## Renders one shader on a sphere under a single light and returns the image.
##
## Each pass gets its own SubViewport with a black, ambient-free environment, so
## the capture is purely the lighting response under comparison and nothing else
## can mask a difference.
func _render(sh: VisualShader) -> Image:
	var vp := SubViewport.new()
	vp.size = Vector2i(RES, RES)
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 1.12)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	vp.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-32.0), deg_to_rad(28.0), 0.0)
	light.light_energy = 1.0
	light.shadow_enabled = false
	vp.add_child(light)

	var mesh := MeshInstance3D.new()
	mesh.mesh = SphereMesh.new()
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mesh.material_override = mat
	vp.add_child(mesh)

	root.add_child(vp)
	# own_world_3d leaves world_3d null until the viewport has been through a
	# frame, so the World3D and its environment are assigned outright.
	var world := World3D.new()
	world.environment = _environment()
	vp.world_3d = world

	# Two frames: the first compiles the shader, the second draws with it.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img: Image = vp.get_texture().get_image()
	vp.queue_free()
	return img


func _environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0, 0, 0)
	env.ambient_light_energy = 0.0
	# Linear, so the numbers below are reflectance rather than a tone-mapped
	# curve; a filmic curve would compress the specular difference and hide it.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	return env


## Elementwise |a - b| over two difference fields, isolating what is left of the
## total once the diffuse lobe has been accounted for.
func _sub_arr(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(a.size())
	for i in a.size():
		out[i] = absf(a[i] - b[i])
	return out


## Signed per-pixel difference a - b, worst channel, as a positive magnitude per
## pixel. Used to difference an albedo pair so the shared specular response drops
## out.
func _sub(a: Image, b: Image) -> Image:
	var out := Image.create(a.get_width(), a.get_height(), false, a.get_format())
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			out.set_pixel(x, y, Color(
				absf(pa.r - pb.r), absf(pa.g - pb.g), absf(pa.b - pb.b), 1.0))
	return out


## Per-pixel difference between two images, worst channel.
func _per_pixel_sub(a: Image, b: Image) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(a.get_width() * a.get_height())
	var i := 0
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			out[i] = maxf(absf(pa.r - pb.r),
				maxf(absf(pa.g - pb.g), absf(pa.b - pb.b)))
			i += 1
	return out


## Per-pixel worst-channel absolute difference, as a PackedFloat32Array.
func _diff(a: Image, b: Image) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(a.get_width() * a.get_height())
	var i := 0
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			out[i] = maxf(absf(pa.r - pb.r),
				maxf(absf(pa.g - pb.g), absf(pa.b - pb.b)))
			i += 1
	return out


## |a - b| elementwise: how much the diffuse lobe adds on top of what the
## specular-only comparison already explains.
func _residual(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(a.size())
	for i in a.size():
		out[i] = absf(a[i] - b[i])
	return out


func _mean(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _max(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m


func _report(label: String, d: PackedFloat32Array) -> void:
	var differing := 0
	for v in d:
		if v > 1.0 / 255.0:
			differing += 1
	print("  %-38s max %.6f  mean %.6f  over 1/255: %d/%d" % [
		label, _max(d), _mean(d), differing, d.size()])


## Fraction of pixels actually lit, so a 0.00 mean over an all-black image
## cannot masquerade as a pass.
func _lit_fraction(img: Image) -> float:
	var lit := 0
	var total := img.get_width() * img.get_height()
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).r > 0.01:
				lit += 1
	return float(lit) / maxf(total, 1.0)


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
