@tool
extends EditorPlugin

## MaterialX Loader.
##
## Registers a ResourceFormatLoader so .mtlx files load directly as
## VisualShaders in the editor, and a dock for batch conversion and
## texture-import repair.
##
## There is no preview generator. There used to be one: a GPU baker with a CPU
## fallback, a watchdog, a thumbnail cache and a periodic timer, all so that
## .mtlx files would show a material ball in the FileSystem dock. That existed only
## because the editor does not know what a .mtlx is. Converting writes a
## ShaderMaterial, which the editor previews itself and correctly, so the whole
## pipeline was solving a problem the export path had already solved.
##
## The converter is MtlxEmitter; this file is only the editor plumbing.

const FormatLoader := preload("res://addons/materialx/mtlx_format_loader.gd")
const Converter := preload("res://addons/materialx/mtlx_converter.gd")
const Config := preload("res://addons/materialx/mtlx_config.gd")

var _loader: ResourceFormatLoader
var _dock: Control


func _enter_tree() -> void:
	# Only writes project.godot on the first run, when the settings are absent.
	if Config.install_defaults():
		ProjectSettings.save()

	_loader = FormatLoader.install(Config.texture_roots())

	_dock = Converter.new()
	_dock.plugin = self
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
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