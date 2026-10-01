extends SceneTree

## Measures whether screen-space refraction actually displaces the background, or
## whether it merely makes the surface opaque.
##
## Two earlier versions of this test were wrong, in ways worth recording.
##
## The first compared refraction off against refraction on and called the
## difference a displacement. It was measuring the switch from alpha-blended to
## opaque-plus-emission: halving the strength left the number identical.
##
## The second held the strength still and varied it, which is right, but put a
## single bright bar behind the sphere and measured a centroid inside a disc that
## the bar did not overlap -- the bar covered screen x 27..91 and the disc was
## x 94..162. There was nothing in the measured region to move, so it read zero for
## the same reason the first one did.
##
## So: a repeating vertical bar pattern covering the whole frame, and the shift
## found by cross-correlation rather than by a centroid. A centroid cannot move if
## the feature it measures is not in the window; cross-correlation over a periodic
## pattern can, and it reports the displacement in pixels rather than a brightness
## difference.
##
## All captures share one compiled shader and differ only in a uniform, so the
## strength parameter is the only thing being varied.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const FLAG := "materialx/screen_space_refraction"
const GLASS := "res://materials/mtlx/Glass.mtlx"
const PARAM := "refraction_strength"
const RES := 256
## A disc well inside the sphere's silhouette, so the rim and the background around
## the sphere cannot contribute.
const DISC := 30
const STRENGTHS := [0.02, 0.06, 0.20]


var _bad := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var saved: Variant = ProjectSettings.get_setting(FLAG, false)
	var had := ProjectSettings.has_setting(FLAG)
	ProjectSettings.set_setting(FLAG, true)

	var result := Emitter.build_file(GLASS, PackedStringArray(["res://materials/mtlx"]))
	if had:
		ProjectSettings.set_setting(FLAG, saved)
	else:
		ProjectSettings.set_setting(FLAG, null)

	if not result.ok:
		print("  FAIL: Glass did not build: %s" % result.message)
		quit(1)
		return

	print("  strength 0.00 is the reference: the offset is zero there\n")

	# Raw pixel difference rather than a centroid. The centroid was swamped: the
	# sphere's own lit surface covers the disc almost uniformly, so the bar's
	# contribution moves a fraction of a pixel's worth of weight and the number
	# does not budge. A difference image has no such problem, and a difference of
	# exactly zero says the two renders are byte-identical, which is a fact worth
	# being able to state.
	var baseline: Image = await _render(result.shader, 0.0)
	if baseline == null:
		print("  FAIL: could not capture the baseline")
		quit(1)
		return

	print("=== pixel difference inside the sphere, against strength 0 ===")
	print("  %-10s %12s %12s %12s" % ["strength", "max diff", "mean diff", "pixels moved"])
	var previous := -1.0
	var moved := false
	var grew := false

	for s in STRENGTHS:
		var img: Image = await _render(result.shader, float(s))
		if img == null:
			print("  FAIL: could not capture at strength %s" % str(s))
			quit(1)
			return
		var diff := _max_difference(baseline, img)
		print("  %-10s %12.5f %12.6f %12d" % [
			str(s), diff.x, diff.y, diff.z])
		if s > 0.0 and float(diff.z) > 0:
			moved = true
		if previous >= 0.0 and float(diff.x) > previous:
			grew = true
		previous = diff.x

	print("\n=== verdict ===")
	_expect(moved,
		"raising the strength changes what the surface shows, so the offset is "
		+ "reaching the sample")
	_expect(grew,
		"and a larger strength changes more, so the size of the change follows "
		+ "the knob")
	quit(1 if _bad > 0 else 0)


## Largest, mean and non-zero pixel difference between two captures, over the
## disc at frame centre. Returns (max, mean, count of pixels that changed).
func _max_difference(a: Image, b: Image) -> Vector3:
	var c := RES / 2
	var worst := 0.0
	var sum := 0.0
	var n := 0
	var changed := 0
	for y in range(c - DISC, c + DISC):
		for x in range(c - DISC, c + DISC):
			if _outside(x, y, c):
				continue
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			var d: float = maxf(absf(pa.r - pb.r),
				maxf(absf(pa.g - pb.g), absf(pa.b - pb.b)))
			worst = maxf(worst, d)
			sum += d
			n += 1
			if d > 1.0 / 255.0:
				changed += 1
	return Vector3(worst, sum / maxf(n, 1.0), changed)


func _outside(x: int, y: int, c: int) -> bool:
	return (x - c) * (x - c) + (y - c) * (y - c) > DISC * DISC


func _luma(col: Color) -> float:
	return 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b


## Mean x of the bright pixels inside a disc at the frame centre, weighted by
## brightness above the darker half of the range so a uniform haze does not drag it.
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

	# One bar, with its right edge inside the measuring disc. The placement
	# matters: the second version of this test put the bar entirely outside the
	# disc and read zero, and a repeating pattern was worse still because
	# cross-correlation locks onto false maxima on a periodic signal -- at
	# strength 0, where the offset is provably zero, it reported a shift of 41 px.
	var quad := QuadMesh.new()
	quad.size = Vector2(1.2, 8.0)
	var bar := MeshInstance3D.new()
	bar.mesh = quad
	var bar_mat := StandardMaterial3D.new()
	bar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bar_mat.albedo_color = Color(1, 1, 1)
	bar.material_override = bar_mat
	# Spans world x -1.0 .. 0.2 at z = -2, which is screen x ~82 .. ~137 with the
	# disc at 98 .. 158, so the edge is well inside the measured region.
	bar.position = Vector3(-0.4, 0, -2.0)
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

func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond
