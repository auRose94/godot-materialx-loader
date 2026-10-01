@tool
class_name MtlxLivePreview
extends VBoxContainer

## A real, GPU-rendered preview of one MaterialX material.
##
## Unlike MtlxThumbnail -- which shades a sphere on the CPU and can only see a
## single sRGB map or literal -- this puts the *converted shader* on a sphere and
## lets the engine render it, so what you see is exactly what a scene shows.
## That makes it the right tool for comparing against reference renders.
##
## Runs on the main thread, which is also why EditorResourcePreview cannot use it
## directly (its previews are generated on a worker thread).

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const SPHERE_RADIUS := 0.5

var _viewport: SubViewport
var _view_rect: TextureRect
var _material: ShaderMaterial
var _camera: Camera3D
var _mesh: MeshInstance3D
var _label: Label
var _status: Label
var _current: String = ""
var _texture_roots: PackedStringArray = PackedStringArray()


func _init() -> void:
	name = "MtlxLivePreview"
	# Kept small on purpose: this lives in a bottom dock, and a tall child makes
	# the dock's minimum size exceed the panel, which pushes the panel's tab bar
	# off-screen and locks the user out of the other docks.
	custom_minimum_size = Vector2(0, 160)

	_label = Label.new()
	_label.text = "(no material)"
	_label.clip_text = true
	add_child(_label)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(160, 160)
	_viewport.transparent_bg = false
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.gui_disable_input = true
	# The SubViewport renders off-screen; it does not draw itself. A bare
	# SubViewport as a child of a Control is invisible -- Viewport's own
	# is_visible_subviewport() (scene/main/viewport.cpp) only reports true when
	# the parent is a SubViewportContainer.
	add_child(_viewport)

	_view_rect = TextureRect.new()
	_view_rect.texture = _viewport.get_texture()
	_view_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_view_rect.custom_minimum_size = Vector2(0, 160)
	_view_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_view_rect)

	_build_scene()

	_status = Label.new()
	_status.text = ""
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)


func set_texture_roots(roots: PackedStringArray) -> void:
	_texture_roots = roots


## The studio rig: a sphere, a camera, a key light, a fill and a neutral
## environment. Deliberately plain so differences between materials are the
## thing you see.
## Uses the project's own environment so the preview matches what a scene shows.
##
## This matters most for metals: with a flat colour background there is nothing
## for them to reflect and gold renders near-black. The project environment
## supplies a sky for image-based lighting, which is what makes metal read as
## metal.
func _load_environment() -> Environment:
	var path: String = ProjectSettings.get_setting(
		"rendering/environment/defaults/default_environment", "")
	if path != "" and ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Environment:
			return res
	# Fallback so the panel still works in a project with no environment.
	var fallback := Environment.new()
	fallback.background_mode = Environment.BG_COLOR
	fallback.background_color = Color(0.16, 0.17, 0.19)
	fallback.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	fallback.ambient_light_color = Color(0.6, 0.62, 0.66)
	fallback.ambient_light_energy = 0.35
	return fallback


## A plain white sphere is used when no material is selected, so the panel is
## never empty.


func _build_scene() -> void:
	var env := WorldEnvironment.new()
	env.environment = _load_environment()
	_viewport.add_child(env)

	var key := DirectionalLight3D.new()
	key.light_energy = 3.0
	key.rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(-40.0), 0.0)
	_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.75
	fill.rotation = Vector3(deg_to_rad(-15.0), deg_to_rad(140.0), 0.0)
	_viewport.add_child(fill)

	_material = ShaderMaterial.new()

	_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = SPHERE_RADIUS
	sphere.height = SPHERE_RADIUS * 2.0
	sphere.radial_segments = 64
	sphere.rings = 32
	_mesh.mesh = sphere
	_mesh.material_override = _material
	_viewport.add_child(_mesh)

	_camera = Camera3D.new()
	_camera.fov = 45.0
	_camera.position = Vector3(0.0, 0.0, SPHERE_RADIUS * 2.6)
	_camera.look_at_from_position(_camera.position, Vector3.ZERO, Vector3.UP)
	_viewport.add_child(_camera)
	_camera.current = true


## Shows one material. Pass "" to clear.
func show_material(mtlx_path: String) -> void:
	if mtlx_path == "":
		_current = ""
		_material.shader = null
		_label.text = "(no material)"
		_status.text = ""
		return

	if not FileAccess.file_exists(mtlx_path):
		_status.text = "[color=red]no such file[/color]"
		return

	var result: Emitter.Result = Emitter.build_file(mtlx_path, _texture_roots)
	if not result.ok:
		_material.shader = null
		_label.text = mtlx_path.get_file()
		_status.text = "[color=red]%s[/color]" % result.message
		return

	_current = mtlx_path
	_material.shader = result.shader
	_label.text = mtlx_path.get_file()

	var dropped: int = result.dropped.size()
	var text: String = "%d dropped input(s); %d missing texture(s)." % [dropped, result.missing_textures.size()]
	if not result.missing_textures.is_empty():
		text += "\n[color=orange]missing: %s[/color]" % ", ".join(result.missing_textures)
	_status.text = text


func current_path() -> String:
	return _current
