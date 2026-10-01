extends SceneTree

## Measures whether screen-space refraction actually displaces the background, or
## whether it merely makes the surface opaque.
##
## The earlier version of this test rendered with refraction off and on, took the
## brightness centroid inside the sphere, and called the difference a displacement.
## It was not. Halving the strength left the number identical, which meant the
## metric was measuring the switch from alpha-blended to opaque-plus-emission rather
## than any movement of the sample.
##
## The fix is to compare renders that differ in nothing but the strength knob. At
## strength 0 the offset is zero, so the screen texture is sampled exactly at
## SCREEN_UV and what shows through is the unrefracted background. Any movement
## between that and a non-zero strength can only come from the offset itself, and if
## it grows with the knob then the knob is what is moving it.
##
## Three strengths rather than two, so monotonicity is visible. A coincidence at
## one setting would not survive three.
##
## refraction_strength is a shader parameter, so all three renders share one compiled
## shader and differ only in a uniform.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const FLAG := "materialx/screen_space_refraction"
const GLASS := "res://materials/Glass.mtlx"
const PARAM := "refraction_strength"
const RES := 256
## A disc well inside the sphere's silhouette, so the rim and the background around
## the sphere cannot contribute.
const DISC := 34
const STRENGTHS := [0.0, 0.05, 0.10]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var saved: Variant = ProjectSettings.get_setting(FLAG, false)
	var had := ProjectSettings.has_setting(FLAG)
	ProjectSettings.set_setting(FLAG, true)

	var result := Emitter.build_file(GLASS, PackedStringArray(["res://materials"]))
	if had:
		ProjectSettings.set_setting(FLAG, saved)
	else:
		ProjectSettings.set_setting(FLAG, null)

	if not result.ok:
		print("  FAIL: Glass did not build: %s" % result.message)
		quit(1)
		return

	# One shader, three materials, differing only in the parameter.
	print("=== brightness centroid inside the sphere ===")
	print("  %-14s %10s %12s" % ["strength", "centroid x", "shift"])
	var baseline := -1.0
	var shifts: Array = []
	for s in STRENGTHS:
		var img: Image = await _render(result.shader, float(s))
		if img == null:
			print("  FAIL: could not capture at strength %s" % str(s))
			quit(1)
			return
		var c := _centroid_x(img)
		if baseline < 0.0:
			baseline = c
			print("  %-14s %10.2f %12s" % ["0.00 (base)", c, "-"])
		else:
			var shift: float = c - baseline
			shifts.append(shift)
			print("  %-14s %10.2f %+12.2f" % [str(s), c, shift])

	# Monotonic in the same direction, and not noise.
	var grows: bool = shifts.size() >= 2 and absf(float(shifts[1])) > absf(float(shifts[0]))
	var moved: bool = shifts.size() > 0 and absf(float(shifts[0])) >= 2.0

	print("\n=== verdict ===")
	if not moved:
		print("  FAIL: strength 0 and strength %.2f look identical inside the "
			% float(shifts[0] if shifts.size() > 0 else 0.0)
			+ "sphere, so the offset is not moving the sample")
		quit(1)
		return
	print("  OK: raising the strength moves the background by %+.2f px"
		% float(shifts[0]))
	if grows:
		print("  OK: and it keeps moving as the strength rises, so the knob is "
			+ "what is moving it")
	else:
		print("  FAIL: the movement did not grow with the strength, so it is "
			+ "not the offset doing it")
		quit(1)
		return
	quit(0)


## Mean x of the bright pixels inside a disc at the frame centre, weighted by
## brightness above the darker half of the range so a uniform haze does not drag it.
func _centroid_x(img: Image) -> float:
	var c := RES / 2
	var peak := 0.0
	for y in range(c - DISC, c + DISC):
		for x in range(c - DISC, c + DISC):
			if _outside(x, y, c):
				continue
			peak = maxf(peak, _luma(img.get_pixel(x, y)))
	if peak <= 0.0:
		return -1.0

	var sum := 0.0
	var weighted := 0.0
	for y in range(c - DISC, c + DISC):
		for x in range(c - DISC, c + DISC):
			if _outside(x, y, c):
				continue
			var w: float = maxf(_luma(img.get_pixel(x, y)) / peak - 0.25, 0.0)
			sum += w
			weighted += w * x
	return weighted / maxf(sum, 1e-6)


func _outside(x: int, y: int, c: int) -> bool:
	return (x - c) * (x - c) + (y - c) * (y - c) > DISC * DISC


func _luma(col: Color) -> float:
	return 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b


## One material, one strength, one capture. The shader is shared across calls, so
## nothing is recompiled and the only difference between captures is the uniform.
func _render(shader: VisualShader, strength: float) -> Image:
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
	cam.position = Vector3(0, 0, 4.0)
	cam.look_at_from_position(cam.position, Vector3.ZERO, Vector3.UP)
	cam.fov = 50.0
	vp.add_child(cam)

	# A bright bar on the left of frame only. Anything that displaces the sample
	# pulls the bar sideways and the centroid follows it, so the measurement has a
	# direction as well as a magnitude.
	var bar := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.4, 6.0)
	bar.mesh = quad
	var bar_mat := StandardMaterial3D.new()
	bar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bar_mat.albedo_color = Color(1, 1, 1)
	bar.material_override = bar_mat
	bar.position = Vector3(-1.5, 0, -2.0)
	vp.add_child(bar)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-40.0), deg_to_rad(25.0), 0.0)
	light.light_energy = 2.2
	light.shadow_enabled = false
	vp.add_child(light)

	var mesh := MeshInstance3D.new()
	mesh.mesh = SphereMesh.new()
	mesh.mesh.radius = 1.0
	mesh.mesh.height = 2.0
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter(PARAM, strength)
	mesh.material_override = mat
	vp.add_child(mesh)

	root.add_child(vp)
	for i in 25:
		await RenderingServer.frame_post_draw

	var img: Image = vp.get_texture().get_image()
	vp.queue_free()
	await RenderingServer.frame_post_draw
	return img
