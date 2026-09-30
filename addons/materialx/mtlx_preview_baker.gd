@tool
class_name MtlxPreviewBaker
extends RefCounted

## Renders a real preview of a MaterialX material with the actual converted
## shader, for the FileSystem dock.
##
## ## Why this exists
##
## MtlxThumbnail shades a sphere on the CPU by sampling the material's maps
## directly. That is cheap and instant, but it can only understand a material
## whose base colour is a single sRGB image or a literal. 33 of the 276 files
## here build their colour from packed masks and constants instead, and those
## thumbnails come out as flat grey balls.
##
## This bakes the *real* shader instead: a sphere with the converted VisualShader
## on it, lit and rendered by the engine, then read back to a PNG. That is the
## same image the material produces in a scene, so it cannot drift from it.
##
## ## Threading
##
## EditorResourcePreview asks for previews on a worker thread, where a SubViewport
## cannot be built. So this runs on the main thread and writes a PNG; the preview
## generator then just loads that file, which is safe from any thread.
##
## Baking is opt-in and cached: re-bake only when the .mtlx is newer than the PNG.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const THUMBNAIL := preload("res://addons/materialx/mtlx_thumbnail.gd")

## Where baked previews live. Kept out of res:// so they are not imported as
## project assets.
const CACHE_DIR := "user://mtlx_previews"

const SPHERE_RADIUS := 0.5
const LIGHT_ENERGY := 3.0
const AMBIENT_ENERGY := 0.35
const FOV := 45.0

## Where the baked PNG for a material lives.
static func cache_path(mtlx_path: String) -> String:
	return CACHE_DIR.path_join(mtlx_path.get_file().get_basename() + ".png")


## Godot's editor preview cache directory.
##
## EditorPaths is not reachable from script, but OS.get_cache_dir() is the same
## root and Godot keeps its editor files in a "godot" subdirectory beneath it
## (on Linux: ~/.cache/godot).
static func editor_cache_dir() -> String:
	var dir: String = OS.get_cache_dir().path_join("godot")
	# If that guess does not exist, fall back to the parent so this keeps doing
	# something sensible on other platforms instead of silently doing nothing.
	if not DirAccess.dir_exists_absolute(dir):
		if DirAccess.dir_exists_absolute(OS.get_cache_dir()):
			return OS.get_cache_dir()
	return dir


## The base path (without extension) Godot uses to cache this file's thumbnail.
##
## EditorResourcePreview::_iterate() builds it as
## cache_dir + "resthumb-" + globalized_path.md5_text(), then writes .png,
## _small.png and .txt beside it.
static func preview_cache_base(res_path: String) -> String:
	var globalized: String = ProjectSettings.globalize_path(res_path)
	return editor_cache_dir().path_join("resthumb-" + globalized.md5_text())


## Deletes Godot's cached thumbnail for a material, so the next preview request
## regenerates it and picks up our baked render.
##
## Without this, a cached CPU-approximation thumbnail is reused on the next
## session even after a correct bake: the cache is keyed on the .mtlx's MD5, so
## an unchanged file keeps its old thumbnail indefinitely. That is why clearing
## the editor cache by hand used to be needed.
##
## Best effort -- if the cache directory cannot be found the render is still
## written and only this step is skipped.
static func invalidate_preview_cache(res_path: String) -> bool:
	var base: String = preview_cache_base(res_path)
	var removed := false
	for f in [base + ".png", base + "_small.png", base + ".txt"]:
		if not FileAccess.file_exists(f):
			continue
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(f)) == OK:
			removed = true
	return removed


## True when a baked preview exists and is newer than the source.
static func is_baked(mtlx_path: String) -> bool:
	var png: String = cache_path(mtlx_path)
	if not FileAccess.file_exists(png):
		return false
	return FileAccess.get_modified_time(png) >= FileAccess.get_modified_time(mtlx_path)


## Loads a baked preview, or null.
static func load_baked(mtlx_path: String) -> Image:
	var png: String = cache_path(mtlx_path)
	if not FileAccess.file_exists(png):
		return null
	var img := Image.new()
	if img.load(png) != OK:
		return null
	return img


## Renders `mtlx_path` and writes the PNG. Must run on the main thread.
##
## `viewport` is a SubViewport the caller owns and keeps alive; the scene is
## added to it for the duration of one frame and removed afterwards.


## The project's environment, so previews match what a scene shows and metals
## have a sky to reflect. Falls back to a neutral studio when there is none.
static func preview_environment() -> Environment:
	var path: String = ProjectSettings.get_setting(
		"rendering/environment/defaults/default_environment", "")
	if path != "" and ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Environment:
			return res
	var fallback := Environment.new()
	fallback.background_mode = Environment.BG_COLOR
	fallback.background_color = THUMBNAIL.BACKGROUND
	fallback.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	fallback.ambient_light_color = Color(0.6, 0.62, 0.66)
	fallback.ambient_light_energy = AMBIENT_ENERGY
	return fallback


static func bake(viewport: SubViewport, mtlx_path: String, texture_roots: PackedStringArray = PackedStringArray()) -> Error:
	var result: Emitter.Result = Emitter.build_file(mtlx_path, texture_roots)
	if not result.ok:
		return ERR_CANT_CREATE

	DirAccess.make_dir_recursive_absolute(CACHE_DIR)

	var shader_material := ShaderMaterial.new()
	shader_material.shader = result.shader

	var mesh_instance := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = SPHERE_RADIUS
	sphere.height = SPHERE_RADIUS * 2.0
	# Enough segments that the sphere reads as smooth at thumbnail size.
	sphere.radial_segments = 64
	sphere.rings = 32
	mesh_instance.mesh = sphere
	mesh_instance.material_override = shader_material

	var camera := Camera3D.new()
	camera.fov = FOV
	camera.position = Vector3(0.0, 0.0, SPHERE_RADIUS * 2.6)
	camera.look_at_from_position(camera.position, Vector3.ZERO, Vector3.UP)

	# A key and a fill light, so roughness and metalness are actually readable.
	var key := DirectionalLight3D.new()
	key.light_energy = LIGHT_ENERGY
	key.rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(-40.0), 0.0)
	var fill := DirectionalLight3D.new()
	fill.light_energy = LIGHT_ENERGY * 0.25
	fill.rotation = Vector3(deg_to_rad(-15.0), deg_to_rad(140.0), 0.0)

	# The project's own environment, so metals reflect a sky rather than a flat
	# colour. Without image-based lighting gold and chrome render near-black.
	var env := WorldEnvironment.new()
	env.environment = preview_environment()

	# The 3D nodes hang off the viewport itself for the duration of the render,
	# then come back out. A World3D is a resource, not a node, so it cannot be
	# given children -- `viewport.world_3d = World3D.new()` also leaves the
	# viewport with no scenario, which is what the "scenario is null" error is.
	var scene: Array[Node] = [env, key, fill, mesh_instance, camera]
	for n in scene:
		viewport.add_child(n)
	camera.current = true

	# Two frames: the first sets the render up, the second is the one to read,
	# because the material's textures may still be streaming in.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var image: Image = viewport.get_texture().get_image()

	for n in scene:
		viewport.remove_child(n)
		n.queue_free()

	if image == null:
		return ERR_CANT_CREATE
	return image.save_png(cache_path(mtlx_path))