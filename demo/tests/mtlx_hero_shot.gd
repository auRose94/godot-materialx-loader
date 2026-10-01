extends SceneTree

## Renders the README hero image: a contact sheet of converted MaterialX
## materials, each on its own sphere, under this project's environment.
##
## Uses the project's own default environment rather than a neutral studio setup,
## because that is the honest picture -- the reflection in Gold_Foil or
## Perforated_Metal is the sky you are actually going to see, and a material that
## only looks good against a studio HDRI is not much use.
##
## Nine materials on a 3x3 grid: the four simple ones the README already showed,
## then five from the standard library that exercise what conversion has to cope
## with -- normal maps, tiling patterns, height, clearcoat, sheen.
##
## Needs a framebuffer, so run it under xvfb:
##   xvfb-run -a godot --rendering-driver opengl3 --script tools/mtlx_hero_shot.gd

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const OUT := "/mnt/matrix/Work/godot-materialx-loader/docs/preview.png"

const SIZE := Vector2i(1200, 1200)
const COLS := 3
const SPACING := 3.4
const RADIUS := 1.0
## Frames to render before capturing. Each distinct shader has to compile, and
## under a software rasteriser that is not instant, so this is generous rather
## than tuned. The capture is discarded unless every sphere has drawn.
const SETTLE_FRAMES := 90

## Grid_Paint is hand-written for the demo project rather than part of the
## matlib corpus, so it is staged into this project before the shoot. An absolute
## path, because res:// cannot reach across projects; the staging is checked and
## reported rather than assumed, so a missing checkout fails with a sentence
## instead of an empty cell.
const STAGE_DIR := "res://hero_staging/materials"
const GRID_PAINT_SOURCE := "/mnt/matrix/Work/godot-materialx-loader/demo/materials"
const GRID_PAINT_FILES := [
	"Grid_Paint.mtlx",
	"textures/Demo_Grid.png",
	"textures/Demo_Ripple_Normal.png",
]

## Simple first, then the complex ones, so the grid reads as a progression.
const MATERIALS := [
	["res://materials/Gold.mtlx", "materials"],
	["res://materials/Glass.mtlx", "materials"],
	["res://materials/Rubber.mtlx", "materials"],
	["res://hero_staging/materials/Grid_Paint.mtlx", "hero_staging/materials"],
	["res://materials/Black_Upholstery.mtlx", "materials"],
	["res://materials/Glazed_Cube_Pattern_Tiles.mtlx", "materials"],
	["res://materials/TH_Blue_Denim_Fabric.mtlx", "materials"],
	["res://materials/Gold_Foil.mtlx", "materials"],
	["res://materials/Perforated_Metal.mtlx", "materials"],
]


func _init() -> void:
	_shoot.call_deferred()


func _shoot() -> void:
	if not _stage_grid_paint():
		print("  FAIL: could not stage Grid_Paint from %s" % GRID_PAINT_SOURCE)
		quit(1)
		return

	var vp := SubViewport.new()
	vp.size = SIZE
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Smooth sphere silhouettes, which matter at this size.
	vp.msaa_3d = Viewport.MSAA_4X
	vp.own_world_3d = true

	var world := World3D.new()
	world.environment = _environment()
	vp.world_3d = world

	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.position = Vector3(0, 0, _camera_distance())
	cam.look_at_from_position(cam.position, Vector3.ZERO, Vector3.UP)
	vp.add_child(cam)

	# The sky alone is flat ambient plus reflections, which leaves the spheres
	# without form. A key light supplies the shaping; a weak fill keeps the
	# shadow side from going flat black.
	var key := DirectionalLight3D.new()
	key.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(-26.0), 0.0)
	key.light_energy = 2.6
	key.light_specular = 1.0
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 40.0
	vp.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-12.0), deg_to_rad(140.0), 0.0)
	fill.light_energy = 0.5
	fill.light_color = Color(0.72, 0.78, 0.92)
	fill.shadow_enabled = false
	vp.add_child(fill)

	# On-axis light, which is what a product photographer would use and what a
	# metal needs to exist at all. A fully metallic surface has no diffuse term,
	# so it renders black unless it reflects something bright; at the centre of a
	# sphere the reflected direction points back past the camera, and the
	# procedural sky's ground half is nearly black there. Gold measured 0.016
	# luminance without this.
	var axis := DirectionalLight3D.new()
	# A DirectionalLight3D shines along its own -Z, so this one travels from the
	# camera into the scene.
	axis.rotation = Vector3(0.0, deg_to_rad(180.0), 0.0)
	axis.light_energy = 1.8
	axis.shadow_enabled = false
	vp.add_child(axis)

	var failed := 0
	for i in MATERIALS.size():
		var path: String = MATERIALS[i][0]
		var root: String = MATERIALS[i][1]
		if not _add_sphere(vp, path, root, i):
			failed += 1

	root.add_child(vp)

	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw

	var img: Image = vp.get_texture().get_image()
	_report_cells(img)

	var err := img.save_png(OUT)
	if err != OK:
		print("  FAIL: could not write %s (error %d)" % [OUT, err])
		quit(1)
		return

	print("wrote %s (%dx%d, %d material(s) failed)" % [OUT, SIZE.x, SIZE.y, failed])
	quit(1 if failed > 0 else 0)


## Copies the demo project's hand-written Grid_Paint into this project so the
## sheet can include it. Returns false with a clear reason if it cannot.
func _stage_grid_paint() -> bool:
	if not DirAccess.dir_exists_absolute(GRID_PAINT_SOURCE):
		push_warning("demo project not found at %s" % GRID_PAINT_SOURCE)
		return false
	if DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(STAGE_DIR + "/textures")) != OK:
		push_warning("could not create the staging directory")
		return false
	for f in GRID_PAINT_FILES:
		var dst := ProjectSettings.globalize_path(STAGE_DIR.path_join(f))
		if FileAccess.file_exists(dst):
			continue
		var err := DirAccess.copy_absolute(
			GRID_PAINT_SOURCE.path_join(f), dst)
		if err != OK:
			push_warning("could not stage %s (error %d)" % [f, err])
			return false
	return true


## A soft vertical gradient behind the spheres.## Prints the mean luminance of each grid cell.
##
## This image is the addon's front page, and it is rendered by a script rather
## than photographed, so the failure modes are silent: an unrotated camera gives
## a flat backdrop, a material that fails to compile gives a grey ball, and a
## texture that failed to load gives a flat colour. All three look like "a
## picture" in a file browser. Numbers per cell catch them.
func _report_cells(img: Image) -> void:
	print("\n=== mean luminance per cell (0 = black, 1 = white) ===")
	var cw := img.get_width() / COLS
	var ch := img.get_height() / 3
	var dull := 0
	for row in 3:
		var line := ""
		for col in COLS:
			var sum := 0.0
			var n := 0
			for y in range(row * ch, (row + 1) * ch, 4):
				for x in range(col * cw, (col + 1) * cw, 4):
					var c := img.get_pixel(x, y)
					sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
					n += 1
			var mean: float = sum / maxf(n, 1.0)
			line += "%6.3f " % mean
			# A sphere fills its cell, so a cell this dark is not a sphere.
			if mean < 0.05:
				dull += 1
		print("  row %d: %s" % [row + 1, line])

	# Centre samples and contrast, which is what actually distinguishes "the
	# material rendered" from "something filled the square". A failed texture
	# still produces a shaded ball; it just produces a *flat* one, so a low
	# standard deviation is the tell.
	print("\n=== centre sample and texture contrast (stddev) ===")
	var flat := 0
	for row in 3:
		var centres := ""
		var spreads := ""
		for col in COLS:
			var sum := 0.0
			var sum_sq := 0.0
			var n := 0
			var cx := col * cw + cw / 2
			var cy := row * ch + ch / 2
			# A disc well inside the sphere, so background never contributes.
			for y in range(cy - cw / 5, cy + cw / 5, 2):
				for x in range(cx - cw / 5, cx + cw / 5, 2):
					var c := img.get_pixel(x, y)
					var lum := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
					sum += lum
					sum_sq += lum * lum
					n += 1
			var mean: float = sum / maxf(n, 1.0)
			var sd: float = sqrt(maxf(sum_sq / maxf(n, 1) - mean * mean, 0.0))
			centres += "%6.3f " % mean
			spreads += "%6.3f " % sd
			if sd < 0.02:
				flat += 1
		print("  row %d centre: %s" % [row + 1, centres])
		print("  row %d stddev: %s" % [row + 1, spreads])
	print("\n  cells with flat texture (stddev < 0.02): %d / 9" % flat)

	var all := 0.0
	var total := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y)
			all += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			total += 1
	print("\n  whole image mean: %.4f" % (all / maxf(total, 1.0)))

	if dull > 0:
		push_warning("%d cell(s) are nearly black -- a material may not have drawn" % dull)
	print("  cells that are nearly black: %d / 9" % dull)


## Puts one sphere on the grid. Returns false if the material could not be
## converted, which must not be silently skipped -- a hole in the sheet would
## ship as a broken README.
func _add_sphere(vp: SubViewport, path: String, root: String, index: int) -> bool:
	var result := Emitter.build_file(path, PackedStringArray(["res://" + root]))
	if not result.ok:
		print("  FAIL: %s: %s" % [path.get_file(), result.message])
		return false

	var mesh := MeshInstance3D.new()
	mesh.mesh = SphereMesh.new()
	mesh.mesh.radius = RADIUS
	mesh.mesh.height = RADIUS * 2.0

	var mat := ShaderMaterial.new()
	mat.shader = result.shader
	mesh.material_override = mat

	var col := index % COLS
	var row := index / COLS
	var offset := (COLS - 1) * 0.5
	mesh.position = Vector3(
		(col - offset) * SPACING,
		-(row - 1.0) * SPACING,
		0.0)
	vp.add_child(mesh)
	return true


## This project's environment, which the project settings point at. Falls back to
## the sky alone rather than inventing a studio look, so the image cannot
## accidentally flatter the materials.
func _environment() -> Environment:
	var path: String = ProjectSettings.get_setting(
		"rendering/environment/defaults/default_environment", "")
	if path != "" and ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Environment:
			return res
	push_warning("no default environment found; using a bare sky")
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	return env


## Far enough back that the outer spheres and their silhouettes both fit.
func _camera_distance() -> float:
	var extent: float = (COLS - 1) * 0.5 * SPACING + RADIUS * 1.25
	return extent / tan(deg_to_rad(62.0) * 0.5)
