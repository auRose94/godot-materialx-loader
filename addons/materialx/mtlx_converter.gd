@tool
class_name MtlxConverter
extends VBoxContainer

## Editor dock for MaterialX: batch-convert a folder of .mtlx files into
## VisualShader .tres files, and repair the import settings of the textures
## they reference.
##
## The converter is deliberately a plain Control rather than an
## EditorImportPlugin: Godot 4.7 registers ResourceImporter as abstract, so a
## GDScript importer is not possible.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const Fixer := preload("res://addons/materialx/mtlx_texture_fixer.gd")
const Config := preload("res://addons/materialx/mtlx_config.gd")

@export var plugin: EditorPlugin

var _folder: LineEdit
var _status: RichTextLabel
var _log: RichTextLabel
var _convert_btn: Button
var _fix_btn: Button
var _live: MtlxLivePreview
var _live_picker: OptionButton
var _custom_lighting: CheckBox
var _live_paths: PackedStringArray = PackedStringArray()
var _texture_roots: PackedStringArray = PackedStringArray()
var _dry_run := true


func _ready() -> void:
	name = "MaterialX"
	custom_minimum_size = Vector2(320, 0)

	# Everything lives inside a ScrollContainer.
	#
	# A dock reports a minimum size taken from its content, and the old layout
	# stacked a 256px preview plus a 240px log under the controls -- taller than
	# the bottom panel. That pushed the panel's own tab bar (Output, Debugger,
	# Shader Editor, FileSystem) off the bottom of the window, so the other docks
	# became unreachable and the only way out was to close this one.
	#
	# A ScrollContainer instead claims only a small minimum and lets the content
	# scroll, so the dock can never grow past the space it is given.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 120)
	add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	var title := Label.new()
	title.text = "MaterialX"
	title.add_theme_font_size_override("font_size", 16)
	body.add_child(title)

	var folder_label := Label.new()
	folder_label.text = "Source folder"
	body.add_child(folder_label)

	# Offer whatever folder the plugin actually found materials in, rather than a
	# fixed name that means nothing in another project.
	var suggested: String = _suggest_folder()
	_folder = LineEdit.new()
	_folder.text = suggested
	_folder.placeholder_text = suggested
	body.add_child(_folder)

	# Dry run by default: writing 276 files is easy to do by accident.
	var dry := CheckBox.new()
	dry.text = "Preview only (write nothing)"
	dry.button_pressed = true
	dry.toggled.connect(func(on: bool) -> void: _dry_run = on)
	body.add_child(dry)

	_convert_btn = Button.new()
	_convert_btn.text = "Convert .mtlx to .tres"
	_convert_btn.pressed.connect(_on_convert)
	body.add_child(_convert_btn)

	_fix_btn = Button.new()
	_fix_btn.text = "Repair texture imports"
	_fix_btn.pressed.connect(_on_fix_imports)
	body.add_child(_fix_btn)

	_status = RichTextLabel.new()
	_status.bbcode_enabled = true
	_status.fit_content = true
	_status.custom_minimum_size = Vector2(0, 60)
	body.add_child(_status)

	# Live preview: the real converted shader on a sphere. This is the accurate
	# one.
	var sep := HSeparator.new()
	body.add_child(sep)

	var live_title := Label.new()
	live_title.text = "Live preview"
	body.add_child(live_title)

	_live = MtlxLivePreview.new()
	# Texture search paths come from project settings, not from a guess.
	if _texture_roots.is_empty():
		_texture_roots = Config.texture_roots()
	_live.set_texture_roots(_texture_roots)
	body.add_child(_live)

	_live_picker = OptionButton.new()
	_live_picker.fit_to_longest_item = false
	_live_picker.item_selected.connect(_on_live_selected)
	body.add_child(_live_picker)

	# Custom lighting. Kept here rather than only in
	# Project Settings, because it is the one setting people need to flip in
	# order to see what it does.
	_custom_lighting = CheckBox.new()
	_custom_lighting.text = "Oren-Nayar diffuse (MaterialX)"
	_custom_lighting.tooltip_text = (
		"Evaluate MaterialX diffuse_roughness with an Oren-Nayar lobe, which "
		+ "Godot has no equivalent for. This replaces Godot's whole lighting "
		+ "model for materials that use it, because a light function replaces "
		+ "the engine's -- so the addon, not the engine, is responsible for "
		+ "the result. Rebuild previews after changing this.")
	_custom_lighting.button_pressed = Config.custom_lighting()
	_custom_lighting.toggled.connect(_on_custom_lighting_toggled)
	body.add_child(_custom_lighting)

	var cache_title := Label.new()
	cache_title.text = "Preview cache"
	body.add_child(cache_title)





	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.fit_content = true
	_log.scroll_following = true
	# Bounded: fit_content would otherwise grow the label to the height of every
	# line logged, which is what makes a dock swallow the whole panel.
	_log.custom_minimum_size = Vector2(0, 140)
	_log.size_flags_vertical = Control.SIZE_FILL
	body.add_child(_log)

	_populate_folder()
	_populate_live_picker()


## Fills the live-preview dropdown with every .mtlx in the source folder.
func _populate_live_picker() -> void:
	_live_picker.clear()
	_live_paths.clear()
	var dir: String = _folder.text.strip_edges()
	for f in _list_mtlx(dir):
		_live_paths.append(f)
		_live_picker.add_item(f.get_file())
	if _live_paths.size() > 0:
		_live_picker.select(0)
		_live.show_material(_live_paths[0])


func _on_live_selected(index: int) -> void:
	if index >= 0 and index < _live_paths.size():
		_live.show_material(_live_paths[index])


func _on_custom_lighting_toggled(on: bool) -> void:
	ProjectSettings.set_setting(Config.CUSTOM_LIGHTING, on)
	ProjectSettings.save()
	if on:
		_status.text = "Oren-Nayar diffuse on -- rebuild previews to see it"
	else:
		_status.text = "Oren-Nayar diffuse off -- rebuild previews to apply"


func _populate_folder() -> void:
	_folder.text = _suggest_folder()


## The folder to offer in the source field.
##
## Prefers what the plugin found via the editor's FileSystem, since that knows
## about materials in nested folders too. Falls back to a top-level scan for when
## the dock is built without a plugin (a test, or the plugin is disabled).
func _suggest_folder() -> String:
	if plugin != null and plugin.has_method("material_dirs"):
		var dirs: PackedStringArray = plugin.material_dirs()
		if not dirs.is_empty():
			return dirs[0]
	for dir in DirAccess.get_directories_at("res://"):
		var path: String = "res://" + dir
		if not _list_mtlx(path).is_empty():
			return path
	return "res://"


func _list_mtlx(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if f.get_extension().to_lower() == "mtlx":
			out.append(dir_path.path_join(f))
	return out


## Wraps the converted shader in a ShaderMaterial, which is what gets written out.
##
## A bare VisualShader is not something a level editor can drop on a mesh. It has
## to be put inside a ShaderMaterial by hand first, which is a container per
## material for every user who wants one. Exporting the material instead means the
## .tres loads straight onto a MeshInstance3D's surface material override, and the
## VisualShader travels inside it as a sub-resource.
##
## ShaderMaterial is the right wrapper and BaseMaterial3D is the trap. Godot 4.7
## gives ShaderMaterial exactly three properties -- shader, render_priority and
## next_pass (material.cpp:491-540) -- which is why cull_mode and depth_draw_mode
## are unavailable here and why they cannot be configured on the output at all.
## BaseMaterial3D has those, and several other render settings, but has no `shader`
## property whatsoever: it is its own BRDF, not a container, so assigning a
## VisualShader to one is impossible rather than merely discouraged.
##
## The VisualShader is embedded rather than referenced, so the .tres is
## self-contained. That is the point for an exported material, and it does mean the
## file is larger than a bare shader would be.

func _as_material(result: Emitter.Result) -> Resource:
	var mat := ShaderMaterial.new()
	mat.shader = result.shader
	return mat


## Builds one material and saves it, honouring the dry-run flag. Returns true
## when the file was (or would be) written.
##
## Includes a canary against the silent-failure class that bit once: a custom
## light node left with an unwired input emits "max(, 0.0)" and the shader
## refuses to compile. The emitter self-checks its wiring, so reaching this
## canary means the addon scripts the editor is running are older than the ones
## on disk (the editor caches scripts until the project reloads); the right
## response is to reload and reconvert, not to save a file every mesh will
## reject.
func _convert_and_save(path: String, dry_run: bool) -> MtlxEmitter.Result:
	var result: MtlxEmitter.Result = Emitter.build_file(path)
	if not result.ok:
		_log.text += "[color=red]FAIL[/color] %s: %s\n" % [path.get_file(), result.message]
		return null

	var code: String = result.shader.code
	for signature in ["max(,", "min(,", "clamp(,", "mix(,", "ERROR"]:
		if code.contains(signature):
			_log.text += "[color=red]FAIL[/color] %s: generated shader would not compile -- the editor is running stale addon scripts; reload the project and reconvert\n" % path.get_file()
			return null

	if not dry_run:
		var out_path: String = path.get_basename() + ".tres"
		var err: Error = ResourceSaver.save(_as_material(result), out_path)
		if err != OK:
			_log.text += "[color=red]SAVE FAIL[/color] %s (err %d)\n" % [out_path, err]
			return null
	return result


func _on_convert() -> void:
	var dir: String = _folder.text.strip_edges()
	var files: PackedStringArray = _list_mtlx(dir)
	if files.is_empty():
		_status.text = "[color=yellow]No .mtlx files found in %s[/color]" % dir
		return

	_log.clear()
	var written := 0
	var failed := 0
	var dropped_total := 0

	for path in files:
		var result: MtlxEmitter.Result = _convert_and_save(path, _dry_run)
		if result == null:
			failed += 1
			continue
		written += 1
		dropped_total += result.dropped.size()

		for key in result.dropped.keys():
			_log.text += "  [color=grey]%s: %s dropped (%s)[/color]\n" % [
				path.get_file(), key, result.dropped[key]]
		for t in result.missing_textures:
			_log.text += "  [color=orange]%s: missing texture %s[/color]\n" % [path.get_file(), t]

	var verb: String = "would convert" if _dry_run else "converted"
	_status.text = "%s %d file(s), %d failed, %d dropped inputs." % [verb, written, failed, dropped_total]
	if _dry_run:
		_status.text += "\n[color=yellow]Preview only.[/color]"

	if not _dry_run:
		EditorInterface.get_resource_filesystem().scan()

func _on_fix_imports() -> void:
	var dir: String = _folder.text.strip_edges()
	var files: PackedStringArray = _list_mtlx(dir)
	if files.is_empty():
		_status.text = "[color=yellow]No .mtlx files found in %s[/color]" % dir
		return

	_log.clear()
	var changed := 0
	var seen := {}
	for path in files:
		var report: Dictionary = Fixer.fix_file(path, not _dry_run)
		for entry in report.get("changed", []):
			var d: Dictionary = entry
			if seen.has(d["path"]):
				continue
			seen[d["path"]] = true
			changed += 1
			var changes: Dictionary = d["changes"]
			var bits := PackedStringArray()
			for k in changes.keys():
				bits.append("%s=%s" % [k, changes[k]])
			_log.text += "%s\n  %s\n" % [d["path"], ", ".join(bits)]

	_status.text = "%s %d texture import setting(s)." % [
		"would change" if _dry_run else "changed", changed]
	if not _dry_run:
		EditorInterface.get_resource_filesystem().scan()