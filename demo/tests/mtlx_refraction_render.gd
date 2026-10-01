extends SceneTree

## Renders Glass.mtlx twice -- screen-space refraction off, then on -- in front of
## a deliberately lopsided background, and measures whether the background seen
## through the sphere actually moves.
##
## A refraction shader that compiles, declares a screen sampler and calls
## refract() can still do nothing visible: sample at an offset that happens to be
## zero, or sample the wrong thing. Checking the generated code cannot see any of
## that. So this measures the only thing that matters -- whether the pattern
## behind the sphere is displaced -- by taking the brightness centroid inside the
## sphere's disc and comparing the two renders.
##
## The background is a bright bar on one side only, so a displaced sample pulls
## the centroid with it and the direction of the shift is also worth seeing.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const FLAG := "materialx/screen_space_refraction"
const GLASS := "res://materials/Glass.mtlx"
const RES := 256
const DISC_RADIUS := 46  ## pixels, comfortably inside the sphere


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var saved: Variant = ProjectSettings.get_setting(FLAG, false)
	var had := ProjectSettings.has_setting(FLAG)

	ProjectSettings.set_setting(FLAG, false)
	var off := await _render()
	ProjectSettings.set_setting(FLAG, true)
	var on := await _render()

	if had:
		ProjectSettings.set_setting(FLAG, saved)
	else:
		ProjectSettings.set_setting(FLAG, null)

	if off == null or on == null:
		print("  FAIL: could not capture a render")
		quit(1)
		return
	var off_c: float = _centroid_x(off)
	var on_c: float = _centroid_x(on)

	print("=== brightness centroid inside the sphere's disc ===")
	print("  refraction off : %.2f px" % off_c)
	print("  refraction on  : %.2f px" % on_c)
	var shift: float = on_c - off_c
	print("  shift          : %+.2f px" % shift)

	print("\n=== verdict ===")
	# The sphere's own specular highlight sits near the light and would bias both
	# renders the same way, so a shared bias does not matter -- only the change
	# between the two does.
	var moved: bool = absf(shift) >= 3.0
	if moved:
		print("  OK: the background behind the glass is displaced by refraction")
	else:
		print("  FAIL: the background is in the same place, so refraction did "
			+ "not displace anything")
	quit(0 if moved else 1)


## Mean x of the bright pixels within the disc at the frame centre.
##
## Weighted by brightness above the darker background, so a uniform haze of glass
## does not drag the centroid around on its own.
func _centroid_x(img: Image) -> float:
	var cx := RES / 2
	var cy := RES / 2
	var sum := 0.0
	var weighted := 0.0
	var peak := 0.0

	# Two passes: find the brightest value in the disc so the weighting has
	# something stable to measure against.
	for y in range(cy - DISC_RADIUS, cy + DISC_RADIUS):
		for x in range(cx - DISC_RADIUS, cx + DISC_RADIUS):
			if (x - cx) * (x - cx) + (y - cy) * (y - cy) > DISC_RADIUS * DISC_RADIUS:
				continue
			peak = maxf(peak, _luma(img.get_pixel(x, y)))
	if peak <= 0.0:
		return -1.0

	for y in range(cy - DISC_RADIUS, cy + DISC_RADIUS):
		for x in range(cx - DISC_RADIUS, cx + DISC_RADIUS):
			if (x - cx) * (x - cx) + (y - cy) * (y - cy) > DISC_RADIUS * DISC_RADIUS:
				continue
			var w: float = maxf(_luma(img.get_pixel(x, y)) / peak - 0.25, 0.0)
			sum += w
			weighted += w * x
	return weighted / maxf(sum, 1e-6)


func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _render() -> Image:
	var result := Emitter.build_file(GLASS, PackedStringArray(["res://materials"]))
	if not result.ok:
		push_warning("Glass did not build: %s" % result.message)
		return null

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
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = env
	vp.world_3d = world

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4.0)
	cam.look_at_from_position(cam.position, Vector3.ZERO, Vector3.UP)
	cam.fov = 50.0
	vp.add_child(cam)

	# A bright bar on the left half only. Sampling through the sphere at an offset
	# moves the bar, and the centroid follows it.
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
	mat.shader = result.shader
	mesh.material_override = mat
	vp.add_child(mesh)

	root.add_child(vp)
	for i in 30:
		await RenderingServer.frame_post_draw

	var img: Image = vp.get_texture().get_image()
	vp.queue_free()
	await RenderingServer.frame_post_draw
	return img
