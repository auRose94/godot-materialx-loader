@tool
extends EditorPlugin

## MaterialX Loader.
##
## Registers a ResourceFormatLoader so .mtlx files load directly as
## VisualShaders in the editor, a preview generator so they show a material
## thumbnail in the FileSystem dock, and a dock for batch conversion and
## texture-import repair.
##
## Thumbnails are baked with the real GPU shader automatically, because the CPU
## fallback cannot see materials that build their colour from packed masks.
##
## The converter is MtlxEmitter; this file is only the editor plumbing.

const FormatLoader := preload("res://addons/materialx/mtlx_format_loader.gd")
const Converter := preload("res://addons/materialx/mtlx_converter.gd")
const PreviewGenerator := preload("res://addons/materialx/mtlx_preview_generator.gd")
const AutoBaker := preload("res://addons/materialx/mtlx_auto_baker.gd")
const Config := preload("res://addons/materialx/mtlx_config.gd")

var _loader: ResourceFormatLoader
var _preview: EditorResourcePreviewGenerator
var _baker: MtlxAutoBaker
var _dock: Control
var _timer: Timer


func _enter_tree() -> void:
	# Only writes project.godot on the first run, when the settings are absent.
	if Config.install_defaults():
		ProjectSettings.save()

	_loader = FormatLoader.install(Config.texture_roots())

	# Thumbnails for the FileSystem dock. Registered after the format loader so
	# the resource type it reports ("VisualShader") is what the generator sees.
	_preview = PreviewGenerator.new()
	EditorInterface.get_resource_previewer().add_preview_generator(_preview)

	# Bake real GPU thumbnails automatically. Without this the FileSystem falls
	# back to the CPU approximation, which cannot see materials whose colour
	# comes from packed masks rather than a single sRGB image.
	_baker = AutoBaker.new()
	_baker.name = "MtlxAutoBaker"
	_baker.enabled = Config.auto_bake()
	_baker.size = Config.preview_size()
	add_child(_baker)
	bake_previews()

	# Re-check periodically, so a newly added or edited .mtlx is baked without
	# the user doing anything.
	_timer = Timer.new()
	_timer.wait_time = 10.0
	_timer.autostart = true
	_timer.timeout.connect(bake_previews)
	add_child(_timer)

	_dock = Converter.new()
	_dock.plugin = self
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


## Bakes any material whose preview is missing or out of date. Cheap to call
## when there is nothing to do.
func bake_previews() -> void:
	if _baker == null:
		return
	_baker.start(material_dirs())


## Turns automatic thumbnail baking on or off (the dock checkbox).
func set_auto_bake(on: bool) -> void:
	if _baker == null:
		return
	_baker.enabled = on
	if on:
		bake_previews()


func _exit_tree() -> void:
	if _timer != null:
		_timer.stop()
		_timer.queue_free()
		_timer = null
	if _baker != null:
		_baker.stop()
		_baker.queue_free()
		_baker = null
	if _preview != null:
		EditorInterface.get_resource_previewer().remove_preview_generator(_preview)
		_preview = null
	if _loader != null:
		ResourceLoader.remove_resource_format_loader(_loader)
		_loader = null
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


## Folders that hold .mtlx files, found from the FileSystem rather than assumed.
##
## Hardcoding a folder here is what would stop this working in someone else's
## project; asking the editor what it actually indexed cannot be wrong.
##
## The tree is walked by hand because EditorFileSystem has no flat file list in
## 4.x -- the root directory object is reached with get_filesystem() and
## traversed with get_subdir_count() / get_subdir().
func material_dirs() -> PackedStringArray:
	var dirs := PackedStringArray()
	var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if fs == null:
		return dirs
	var root: EditorFileSystemDirectory = fs.get_filesystem()
	if root == null:
		return dirs
	_collect_material_dirs(root, dirs)
	dirs.sort()
	return dirs


func _collect_material_dirs(dir: EditorFileSystemDirectory, out: PackedStringArray) -> void:
	for i in dir.get_file_count():
		if dir.get_file(i).get_extension().to_lower() == "mtlx":
			out.append(dir.get_path())
			break
	for i in dir.get_subdir_count():
		_collect_material_dirs(dir.get_subdir(i), out)


func _get_plugin_name() -> String:
	return "MaterialX Loader"