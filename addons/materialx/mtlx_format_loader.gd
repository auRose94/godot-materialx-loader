@tool
class_name MtlxFormatLoader
extends ResourceFormatLoader

## Makes .mtlx load directly as a VisualShader.
##
## `load("res://materials/Aluminum.mtlx")` returns a VisualShader.
##
## Why a format loader and not an importer: Godot 4.7 registers
## ResourceImporter as an abstract class (core/register_core_types.cpp:293),
## so a custom importer cannot be written in GDScript. ResourceFormatLoader is
## registered concrete, and ResourceLoader.add_resource_format_loader() is
## exposed, so this is the extension point that lets MaterialX files be read
## directly rather than through the import pipeline.
##
## The trade-off is scope: registering from the EditorPlugin covers the editor
## and @tool scripts, but an *exported* game has no editor and therefore no
## plugin, so .mtlx will not load there. For a shipped build, run
## "Convert .mtlx to .tres" in the dock (or tools/mtlx_convert_all.gd) and ship
## the generated .tres instead. Converting up front is also what you want for
## release builds, since it moves the conversion cost out of load time.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

## Where to look for textures referenced by a .mtlx, in order.
@export var texture_roots: PackedStringArray = PackedStringArray()


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["mtlx"])


## Must answer "" for anything that is not a .mtlx.
##
## ResourceLoader::get_resource_type returns the first non-empty answer from any
## registered loader (core/io/resource_loader.cpp:1389), and it asks every loader
## about every path. Answering "VisualShader" unconditionally therefore makes this
## addon claim the type of *every resource in the project* -- including scripts.
## The editor then asks for res://addons/map_builder/core/brush_geometry.gd as a
## VisualShader, no loader can produce one, and the failure cascades through every
## file that preloads it.
## Must answer "" for anything that is not a .mtlx.
##
## ResourceLoader::get_resource_type returns the first non-empty answer from any
## registered loader (core/io/resource_loader.cpp:1389), and it asks every loader
## about every path. Answering "VisualShader" unconditionally therefore makes this
## addon claim the type of *every resource in the project* -- including scripts.
## The editor then asks for res://addons/map_builder/core/brush_geometry.gd as a
## VisualShader, no loader can produce one, and the failure cascades through every
## file that preloads it.
func _get_resource_type(path: String) -> String:
	if path.get_extension().to_lower() != "mtlx":
		return ""
	return "VisualShader"


func _get_resource_script_class(_path: String) -> String:
	return ""


## Report the textures a .mtlx depends on, so the editor tracks changes.
##
## Walks nested elements too: MtlxDocument.elements holds only top-level nodes,
## and an <image> inside a <nodegraph> is a perfectly ordinary way to author
## one. Missing those would mean the editor never reloads the material when the
## texture changes.
##
## Parsing the document once is also the point -- the previous version ran a
## full conversion first and then re-read the file, so every rescan built the
## whole shader graph twice.
func _get_dependencies(path: String, _add_types: bool) -> PackedStringArray:
	var deps := PackedStringArray()
	# Same reason as _get_resource_type: this is asked about paths that are not
	# ours, and parsing one as MaterialX would only produce a spurious warning.
	if path.get_extension().to_lower() != "mtlx":
		return deps
	# Same reason as _get_resource_type: this is asked about paths that are not
	# ours, and parsing one as MaterialX would only produce a spurious warning.
	if path.get_extension().to_lower() != "mtlx":
		return deps
	var doc: MtlxDocument = MtlxDocument.load_from_file(path)
	if doc == null:
		return deps
	var base: String = path.get_base_dir()
	_collect_images(doc.elements, base, deps)
	return deps


func _collect_images(elements: Array, base: String, deps: PackedStringArray) -> void:
	for el in elements:
		if el.def == "image":
			var file_inp: MtlxDocument.MtlxInput = el.input("file")
			if file_inp != null:
				var rel: String = file_inp.value.strip_edges()
				if rel != "":
					var resolved: String = MtlxEmitter.resolve_texture(rel, base, texture_roots)
					if resolved != "":
						deps.append(resolved)
		if not el.children.is_empty():
			_collect_images(el.children, base, deps)


## Recognise any path ending in .mtlx, so MaterialX files never fall through to
## the default (binary) loader and produce a confusing parse error.
func _recognize_path(path: String, for_type: StringName) -> bool:
	if path.get_extension().to_lower() != "mtlx":
		return false
	return for_type.is_empty() or for_type == "VisualShader" or for_type == "Shader"


func _exists(path: String) -> bool:
	return FileAccess.file_exists(path)


func _load(path: String, _original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Variant:
	var result: MtlxEmitter.Result = Emitter.build_file(path, texture_roots)
	if not result.ok:
		push_error("MaterialX: could not load %s: %s" % [path, result.message])
		return null
	for note in result.notes:
		print_verbose("MaterialX %s: %s" % [path.get_file(), note])
	return result.shader


## Registers this loader with ResourceLoader. Idempotent, so calling it from
## both the editor plugin and a runtime autoload is safe.
static func install(texture_roots: PackedStringArray = PackedStringArray()) -> MtlxFormatLoader:
	var loader := MtlxFormatLoader.new()
	loader.texture_roots = texture_roots
	ResourceLoader.add_resource_format_loader(loader, true)
	return loader