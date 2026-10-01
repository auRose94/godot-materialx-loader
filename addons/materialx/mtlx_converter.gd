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
const Baker := preload("res://addons/materialx/mtlx_preview_baker.gd")
const Config := preload("res://addons/materialx/mtlx_config.gd")

@export var plugin: EditorPlugin

var _folder: LineEdit
var _status: RichTextLabel
var _log: RichTextLabel
var _convert_btn: Button
var _fix_btn: Button
var _live: MtlxLivePreview
var _live_picker: OptionButton
var _bake_btn: Button
var _auto: CheckBox
var _bake_progress: Label
var _experimental: CheckBox
var _rebake_all_btn: Button
var _clear_cache_btn: Button
var _cache_info: Label
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
	# one; the FileSystem thumbnails are a CPU approximation.
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

	_bake_btn = Button.new()
	_bake_btn.text = "Save live preview as thumbnail"
	_bake_btn.pressed.connect(_on_bake_preview)
	body.add_child(_bake_btn)

	# Automatic baking: every material whose preview is missing or older than
	# its source gets a real GPU render, one per frame, without the user doing
	# anything. See MtlxAutoBaker for why the CPU fallback is not enough.
	_auto = CheckBox.new()
	_auto.text = "Auto-bake thumbnails"
	_auto.button_pressed = true
	_auto.toggled.connect(_on_auto_toggled)
	body.add_child(_auto)

	_bake_progress = Label.new()
	_bake_progress.text = ""
	_bake_progress.clip_text = true
	body.add_child(_bake_progress)

	# Experimental custom lighting. Kept next to Auto-bake rather than only in
	# Project Settings, because it is the one setting people need to flip in
	# order to see what it does.
	_experimental = CheckBox.new()
	_experimental.text = "Experimental: Oren-Nayar diffuse"
	_experimental.tooltip_text = (
		"Evaluate MaterialX diffuse_roughness with an Oren-Nayar lobe. This "
		+ "replaces Godot's whole lighting model for materials that use it, "
		+ "because a light function replaces the engine's. Rebuild previews "
		+ "after changing this.")
	_experimental.button_pressed = Config.experimental_custom_lighting()
	_experimental.toggled.connect(_on_experimental_toggled)
	body.add_child(_experimental)

	var cache_title := Label.new()
	cache_title.text = "Preview cache"
	body.add_child(cache_title)

	_rebake_all_btn = Button.new()
	_rebake_all_btn.text = "Rebuild all previews"
	_rebake_all_btn.tooltip_text = "Re-render every material and drop Godot's cached thumbnails. Restart the editor to see the new ones."
	_rebake_all_btn.pressed.connect(_on_rebake_all)
	body.add_child(_rebake_all_btn)

	_clear_cache_btn = Button.new()
	_clear_cache_btn.text = "Delete all previews"
	_clear_cache_btn.tooltip_text = "Remove the baked renders and Godot's cached thumbnails. Regenerates on the next rebuild."
	_clear_cache_btn.pressed.connect(_on_clear_cache)
	body.add_child(_clear_cache_btn)

	_cache_info = Label.new()
	_cache_info.text = ""
	_cache_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_cache_info)


	# Reflect the plugin's baker progress, if one is attached. Connected first,
	# then counted, so startup baking updates the readout.
	if plugin != null and plugin.get("_baker") != null:
		var baker: Node = plugin.get("_baker")
		if baker.has_signal("progress"):
			baker.connect("progress", _on_bake_progress)
			baker.connect("finished", _on_bake_finished)
	_refresh_cache_info()

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


## Writes the live preview to disk so the FileSystem dock shows this exact
## render rather than the CPU approximation.
func _on_bake_preview() -> void:
	var path: String = _live.current_path()
	if path == "":
		_status.text = "[color=yellow]Pick a material first[/color]"
		return
	var err: Error = _live.bake_current(128)
	if err == OK:
		# Drop Godot's cached thumbnail so the dock regenerates from this render.
		Baker.invalidate_preview_cache(path)
		_status.text = "Baked thumbnail for %s" % path.get_file()
		# Nudge the FileSystem so it regenerates and picks up the new PNG.
		EditorInterface.get_resource_filesystem().update_file(path)
	else:
		_status.text = "[color=red]bake failed (%d)[/color]" % err


func _on_auto_toggled(on: bool) -> void:
	if plugin != null and plugin.has_method("set_auto_bake"):
		plugin.set_auto_bake(on)
	if on:
		_status.text = "Auto-bake on"
	else:
		_bake_progress.text = ""
		_status.text = "Auto-bake off"


## Shows how many renders exist and where the cache lives.
func _refresh_cache_info() -> void:
	var baked := 0
	var total := 0
	var dir: String = _folder.text.strip_edges()
	for f in _list_mtlx(dir):
		total += 1
		if Baker.is_baked(f):
			baked += 1
	_cache_info.text = "%d/%d rendered\ncache: %s" % [baked, total, Baker.editor_cache_dir()]


## Deletes every render and every cached thumbnail, then re-renders everything.
##
## The manual escape hatch for when the auto-baker's output is not what you
## want. Godot also holds thumbnails in memory for the rest of the session with
## no API to clear that, so a restart is needed before the change shows in the
## FileSystem dock.
func _on_rebake_all() -> void:
	var dir: String = _folder.text.strip_edges()
	var files: PackedStringArray = _list_mtlx(dir)
	if files.is_empty():
		_status.text = "[color=yellow]No .mtlx files in %s[/color]" % dir
		return

	var invalidated := 0
	for f in files:
		var png: String = Baker.cache_path(f)
		if FileAccess.file_exists(png):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(png))
		if Baker.invalidate_preview_cache(f):
			invalidated += 1

	_refresh_cache_info()
	_status.text = "Cleared previews, re-rendering %d material(s)..." % files.size()
	_log.text += "Rebuilding %d previews (%d cached thumbnails invalidated)\n" % [
		files.size(), invalidated]

	if plugin == null or not plugin.has_method("bake_previews"):
		_status.text = "[color=yellow]Auto-bake unavailable; is the plugin enabled?[/color]"
		return

	# The baker picks them up again immediately, since none are baked now.
	plugin.set_auto_bake(true)
	_auto.set_pressed_no_signal(true)
	plugin.bake_previews()


## Deletes every render and cached thumbnail without re-rendering.
func _on_clear_cache() -> void:
	var dir: String = _folder.text.strip_edges()
	var files: PackedStringArray = _list_mtlx(dir)
	var removed := 0
	for f in files:
		var png: String = Baker.cache_path(f)
		if FileAccess.file_exists(png):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(png))
			removed += 1
		Baker.invalidate_preview_cache(f)

	# The baker would immediately rebuild them, so hold it off until asked.
	if plugin != null and plugin.has_method("set_auto_bake"):
		plugin.set_auto_bake(false)
	_auto.set_pressed_no_signal(false)

	_refresh_cache_info()
	_status.text = "Deleted %d render(s); auto-bake off." % removed


## Flipping this changes the emitted shader, so anything already loaded keeps
## its old graph until it is rebuilt. Say so rather than leaving it to be found.
func _on_experimental_toggled(on: bool) -> void:
	ProjectSettings.set_setting(Config.EXPERIMENTAL_CUSTOM_LIGHTING, on)
	ProjectSettings.save()
	if on:
		_status.text = "Experimental lighting on -- rebuild previews to see it"
	else:
		_status.text = "Experimental lighting off -- rebuild previews to apply"


func _on_bake_progress(done: int, total: int, current: String) -> void:
	_bake_progress.text = "Baking %d/%d  %s" % [done, total, current]


func _on_bake_finished(baked: int, failed: int = 0) -> void:
	_refresh_cache_info()
	if failed > 0:
		# Not fatal: a material that cannot be rendered (no framebuffer yet, an
		# unsupported shader) is retried later instead of every few seconds.
		_bake_progress.text = "Baked %d, %d failed -- those retry in a couple of minutes" % [
			baked, failed]
	elif baked > 0:
		_bake_progress.text = "Baked %d -- restart the editor to refresh the dock" % baked
		# The FileSystem regenerates thumbnails on its own; nudging it makes that
		# happen promptly rather than waiting for a manual refresh.
		EditorInterface.get_resource_filesystem().scan()
	else:
		_bake_progress.text = "All previews up to date"


## Offers the first folder under the project that actually contains .mtlx files.
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
		var result: MtlxEmitter.Result = Emitter.build_file(path)
		if not result.ok:
			failed += 1
			_log.text += "[color=red]FAIL[/color] %s: %s\n" % [path.get_file(), result.message]
			continue

		var out_path: String = path.get_basename() + ".tres"
		if not _dry_run:
			var err: Error = ResourceSaver.save(result.shader, out_path)
			if err != OK:
				failed += 1
				_log.text += "[color=red]SAVE FAIL[/color] %s (err %d)\n" % [out_path, err]
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