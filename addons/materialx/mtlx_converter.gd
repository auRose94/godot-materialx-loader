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
var _project_btn: Button
var _live: MtlxLivePreview
var _live_picker: OptionButton
var _custom_lighting: CheckBox
var _live_paths: PackedStringArray = PackedStringArray()
var _texture_roots: PackedStringArray = PackedStringArray()
var _export: LineEdit
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

	_folder = LineEdit.new()
	# Committed edits are saved to project settings, so the dock reopens where
	# the user left it rather than re-guessing every session (see
	# _on_folder_committed). What the field starts as is decided by
	# _populate_folder below.
	_folder.text_submitted.connect(_on_folder_committed)
	_folder.focus_exited.connect(_on_folder_committed)
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

	# Project-wide conversion: every .mtlx in the project, written flat into
	# one export folder. Keeping the output apart from the sources is what
	# makes the folder browsable -- a ShaderMaterial previews itself as a
	# material ball in the FileSystem dock, a .mtlx does not, and a folder of
	# only converted materials is therefore the one place to scan by eye.
	var export_sep := HSeparator.new()
	body.add_child(export_sep)

	var export_label := Label.new()
	export_label.text = "Export folder (project-wide)"
	body.add_child(export_label)

	_export = LineEdit.new()
	_export.text = Config.export_path()
	# The field is empty for a project that has not chosen yet; the example
	# makes the expected shape obvious without pretending it is saved.
	_export.placeholder_text = "res://materials/converted"
	_export.text_submitted.connect(_on_export_committed)
	_export.focus_exited.connect(_on_export_committed)
	body.add_child(_export)

	_project_btn = Button.new()
	_project_btn.text = "Convert project to export folder"
	_project_btn.pressed.connect(_on_convert_project)
	body.add_child(_project_btn)

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
	var saved := Config.materials_folder().strip_edges()
	var dir := saved
	# An unset folder auto-detects; a saved one wins unless it has stopped
	# existing, which is better than pointing the dock at nothing.
	if saved.is_empty() or DirAccess.open(saved) == null:
		dir = _suggest_folder()
	_folder.text = dir
	_folder.placeholder_text = dir


## Saves the source folder to project settings when the user commits the field,
## so the dock reopens on it next session. Fires on Enter and on focus leaving
## the field -- which covers clicking Convert straight after typing, since the
## button takes focus.
##
## Writes nothing when the value is unchanged, so building the dock and tearing
## it down never touch project.godot. Clearing the field returns the project to
## auto-detect, which is what empty means.
##
## Accepts an optional argument because text_submitted carries the field's text
## and focus_exited carries nothing; both arrive here for the same decision.
func _on_folder_committed(_text: String = "") -> void:
	if _commit_setting(_folder, Config.MATERIALS_FOLDER):
		# The live picker lists the .mtlx files of this folder, so follow it.
		_populate_live_picker()


## Same saving for the export folder; a changed value has no side effects
## beyond the settings write, so it needs no follow-up here.
func _on_export_committed(_text: String = "") -> void:
	_commit_setting(_export, Config.EXPORT_PATH)


## Saves a committed path field's value under `key`, shared by every path field
## on the dock so they cannot drift apart on formatting. Returns true when the
## stored value changed.
##
## Writes nothing when the value is unchanged, so rebuilding a dock never
## touches project.godot. Clearing a field stores empty, which is whatever
## auto/default meaning the setting gives it. Trailing slashes are noise; a
## bare scheme such as res:// is not.
func _commit_setting(field: LineEdit, key: String) -> bool:
	var v := _trim_slashes(field.text.strip_edges())
	if v == _trim_slashes(str(ProjectSettings.get_setting(key, ""))):
		return false
	ProjectSettings.set_setting(key, v)
	ProjectSettings.save()
	return true


## Trailing slashes stripped, schemes kept.
static func _trim_slashes(v: String) -> String:
	while v.ends_with("/") and not v.ends_with("://"):
		v = v.left(v.length() - 1)
	return v


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
func _convert_and_save(path: String, out_path: String, dry_run: bool) -> MtlxEmitter.Result:
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
		var err: Error = ResourceSaver.save(_as_material(result), out_path)
		if err != OK:
			_log.text += "[color=red]SAVE FAIL[/color] %s (err %d)\n" % [out_path, err]
			return null
	return result


## Dropped inputs and missing textures, the two per-file findings a conversion
## reports. Shared by both conversion scopes so they log identically.
func _log_result(path: String, result: MtlxEmitter.Result) -> void:
	for key in result.dropped.keys():
		_log.text += "  [color=grey]%s: %s dropped (%s)[/color]\n" % [
			path.get_file(), key, result.dropped[key]]
	for t in result.missing_textures:
		_log.text += "  [color=orange]%s: missing texture %s[/color]\n" % [path.get_file(), t]


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
		var result: MtlxEmitter.Result = _convert_and_save(
			path, path.get_basename() + ".tres", _dry_run)
		if result == null:
			failed += 1
			continue
		written += 1
		dropped_total += result.dropped.size()
		_log_result(path, result)

	var verb: String = "would convert" if _dry_run else "converted"
	_status.text = "%s %d file(s), %d failed, %d dropped inputs." % [verb, written, failed, dropped_total]
	if _dry_run:
		_status.text += "\n[color=yellow]Preview only.[/color]"

	if not _dry_run:
		_rescan()


## Converts every .mtlx in the project into one flat export folder.
##
## The per-folder converter writes next to each source, which scatters a
## converted library across the source tree and mixes the two. This scope
## instead reads recursively (but never res://addons, and never the export
## folder itself) and writes <export>/<basename>.tres, so the export folder
## becomes a single browsable library of materials the FileSystem dock
## previews by itself while the sources stay where they are.
##
## Refuses to run with an empty export folder rather than guessing where
## hundreds of generated files should land. Honours the dry-run flag like the
## per-folder conversion, and dry runs log the full source-to-target mapping
## so a bulk write can be checked before it happens.
func _on_convert_project() -> void:
	var export_root := _trim_slashes(_export.text.strip_edges())
	if export_root.is_empty():
		_status.text = "[color=yellow]Set the export folder first (saved to %s when you commit the field).[/color]" % Config.EXPORT_PATH
		return

	var dirs := _source_dirs(export_root)
	var files := PackedStringArray()
	for d in dirs:
		var here := _list_mtlx(d)
		here.sort()
		files.append_array(here)
	if files.is_empty():
		_status.text = "[color=yellow]No .mtlx files found in the project outside %s.[/color]" % export_root
		return

	# Name every target before converting anything, so dry and real runs map
	# identically and the log can show exact destinations.
	var used := {}
	var targets := PackedStringArray()
	var renamed := 0
	for src in files:
		var target := _target_for(src, export_root, used)
		if target.get_file() != src.get_file().get_basename() + ".tres":
			renamed += 1
		targets.append(target)

	if not _dry_run:
		DirAccess.make_dir_recursive_absolute(export_root)

	_log.clear()
	var written := 0
	var failed := 0
	for i in files.size():
		if _dry_run:
			_log.text += "[color=grey]%s -> %s[/color]\n" % [
				files[i].trim_prefix("res://"), targets[i].trim_prefix("res://")]
		var result: MtlxEmitter.Result = _convert_and_save(files[i], targets[i], _dry_run)
		if result == null:
			failed += 1
			continue
		written += 1
		_log_result(files[i], result)

	var verb: String = "would convert" if _dry_run else "converted"
	_status.text = "%s %d material(s) into %s: %d failed, %d renamed for duplicate names." % [
		verb, written, export_root, failed, renamed]
	if _dry_run:
		_status.text += "\n[color=yellow]Preview only.[/color]"

	if not _dry_run:
		_rescan()


## Every folder the project-wide conversion may read .mtlx files from.
##
## Prefers the editor's FileSystem index, which is authoritative about the
## project, and walks the filesystem for when the dock runs without a plugin
## (a test, or the plugin is disabled). res://addons and anything under the
## export folder are dropped either way: another addon's files are not this
## project's materials, and the conversion must never re-read its own output
## area.
func _source_dirs(export_root: String) -> PackedStringArray:
	var dirs := PackedStringArray()
	if plugin != null and plugin.has_method("material_dirs"):
		dirs = plugin.material_dirs()
	else:
		_scan_material_dirs("res://", dirs)
		dirs.sort()
	var out := PackedStringArray()
	for d in dirs:
		if d == export_root or (export_root != "" and d.begins_with(export_root + "/")):
			continue
		if d == "res://addons" or d.begins_with("res://addons/"):
			continue
		out.append(d)
	return out


## Recursive fallback scan for folders holding .mtlx files at their top
## level. Hidden directories are skipped -- including .godot and .git, which
## are not project content and can be large.
func _scan_material_dirs(dir_path: String, out: PackedStringArray) -> void:
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		if f.get_extension().to_lower() == "mtlx":
			out.append(dir_path)
			break
	for sub in d.get_directories():
		if sub.begins_with("."):
			continue
		_scan_material_dirs(dir_path.path_join(sub), out)


## A source's flat output path: export folder plus its basename, however deep
## the source sits. A basename already claimed gets a numbered suffix --
## keeping every source converting, none overwriting another, and names
## readable in the FileSystem dock. `used` gains the returned path.
static func _target_for(src: String, export_root: String, used: Dictionary) -> String:
	var base := src.get_file().get_basename()
	var target := export_root.path_join(base + ".tres")
	var n := 1
	while used.has(target):
		n += 1
		target = export_root.path_join(base + "-%d.tres" % n)
	used[target] = true
	return target


## Rescans the FileSystem if there is one to rescan. Headless runs (the
## checks) have no editor filesystem and skip; in the editor a rescan is what
## makes the new .tres appear and preview.
func _rescan() -> void:
	if Engine.is_editor_hint() and EditorInterface.get_resource_filesystem() != null:
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
		_rescan()