extends SceneTree

## Exercises the live preview off-screen: builds the converted shader, renders
## it on a sphere in a SubViewport, and reports what came out.
##
## Driven from _process rather than _init, because awaiting
## RenderingServer.frame_post_draw inside _init deadlocks -- the SceneTree has
## not started iterating yet.
##
## The editor dock is the real user path; this only proves the render works and
## produces a real image rather than a blank one.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const TestKit := preload("res://tests/mtlx_test_kit.gd")

const CASES := ["Bricks", "Brick_Irregular", "Granite", "Marble_Red", "Gold",
	"Nickel", "Copper_Brushed", "Glass", "Semitransparent_Silicone", "Chains"]
const SIZE := 128

var _index := 0
var _pending: SubViewport
var _frames := 0
var _bad := 0
var _name := ""


func _initialize() -> void:
	_set_up()


func _process(_delta: float) -> bool:
	# MainLoop._process returns true to QUIT, so continuing means false.
	if _pending == null:
		return true

	_frames += 1
	# Two frames: the first warms the material up, the second is readable.
	if _frames < 3:
		return false

	var img: Image = _pending.get_texture().get_image()
	if img == null:
		print("%-18s NO IMAGE" % _name)
		_bad += 1
	else:
		var mean := Vector3.ZERO
		var n := 0.0
		for y in range(0, img.get_height(), 2):
			for x in range(0, img.get_width(), 2):
				var c: Color = img.get_pixel(x, y)
				mean += Vector3(c.r, c.g, c.b)
				n += 1.0
		mean /= n
		print("%-18s %dx%d  mean rgb %.3f/%.3f/%.3f" % [_name, img.get_width(), img.get_height(), mean.x, mean.y, mean.z])
		var out: String = "user://live_%s.png" % _name
		img.save_png(out)
		print("%-18s saved %s" % ["", ProjectSettings.globalize_path(out)])

	_pending.queue_free()
	_pending = null
	_set_up()
	if _pending == null:
		print("\n--- %s ---" % ("live preview renders" if _bad == 0 else "%d failures" % _bad))
		quit(1 if _bad > 0 else 0)
	return false


## Builds the next material's scene, or clears _pending when finished.
func _set_up() -> void:
	if _index >= CASES.size():
		_pending = null
		return

	_name = CASES[_index]
	_index += 1
	var path: String = TestKit.primary_dir().path_join("%s.mtlx" % _name)
	var result: MtlxEmitter.Result = Emitter.build_file(path)
	if not result.ok:
		print("%-18s build failed: %s" % [_name, result.message])
		_bad += 1
		return

	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	var env := WorldEnvironment.new()
	var e: Environment = load("res://environment/default_environment.tres")
	if e == null:
		e = Environment.new()
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color(0.16, 0.17, 0.19)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color(0.6, 0.62, 0.66)
		e.ambient_light_energy = 0.35
	env.environment = e
	vp.add_child(env)

	var key := DirectionalLight3D.new()
	key.light_energy = 3.0
	key.rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(-40.0), 0.0)
	vp.add_child(key)

	var mat := ShaderMaterial.new()
	mat.shader = result.shader

	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 48
	sphere.rings = 24
	mi.mesh = sphere
	mi.material_override = mat
	vp.add_child(mi)

	var cam := Camera3D.new()
	cam.fov = 45.0
	cam.position = Vector3(0.0, 0.0, 1.3)
	cam.look_at_from_position(cam.position, Vector3.ZERO, Vector3.UP)
	vp.add_child(cam)
	cam.current = true

	_pending = vp
	_frames = 0