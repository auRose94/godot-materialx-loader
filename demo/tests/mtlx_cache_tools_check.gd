extends SceneTree

## Exercises the dock's preview-cache maintenance: "Delete all previews" and
## "Rebuild all previews", plus the static helpers they rely on.
##
## The point of the buttons is that a stale thumbnail must not survive a rebuild.
## Godot keys its thumbnail cache on the .mtlx's MD5, so an unchanged file keeps
## whatever it had -- which is why the cache has to be dropped explicitly.

const Baker := preload("res://addons/materialx/mtlx_preview_baker.gd")
const TestKit := preload("res://tests/mtlx_test_kit.gd")
const Converter := preload("res://addons/materialx/mtlx_converter.gd")

var DIR: String = TestKit.primary_dir()
## Enough to be meaningful without touching all 277 renders.
const LIMIT := 5

var _failures := 0


func _init() -> void:
	_test_cache_paths()
	# Awaited: each of these suspends on process_frame, so calling one without
	# await would let _init run on and quit while the checks were still going.
	await _test_clear_all()
	await _test_rebuild_all()
	print("\n--- %s ---" % ("preview cache tools work" if _failures == 0 else "%d failure(s)" % _failures))
	quit(1 if _failures > 0 else 0)


## The base path must be the one EditorResourcePreview would use, or the delete
## silently misses and the old thumbnail comes straight back.
func _test_cache_paths() -> void:
	print("cache dir: %s" % Baker.editor_cache_dir())

	var probe: String = TestKit.first(1)[0]
	var base := Baker.preview_cache_base(probe)
	print("  %s -> %s" % [probe.get_file(), base.get_file()])

	if not base.begins_with(Baker.editor_cache_dir()):
		_fail("preview cache base is outside the cache dir")
	if not base.get_file().begins_with("resthumb-"):
		_fail("preview cache base is not named resthumb-*, Godot would not read it")

	# The suffix must be the md5 of the *globalized* path, since that is what
	# EditorResourcePreview hashes (editor_resource_preview.cpp:322).
	var expected := ProjectSettings.globalize_path(probe).md5_text()
	if not base.ends_with(expected):
		_fail("cache key is not md5(globalized path): expected suffix %s" % expected)

	# A file planted at that base must be removed, and a neighbour must not be.
	var planted := base + ".txt"
	var neighbour := base + "_not_ours.txt"
	var abs_planted := ProjectSettings.globalize_path(planted)
	var abs_neighbour := ProjectSettings.globalize_path(neighbour)
	DirAccess.make_dir_recursive_absolute(abs_planted.get_base_dir())
	var f := FileAccess.open(planted, FileAccess.WRITE)
	if f == null:
		_fail("could not plant a test file at %s" % planted)
		return
	f.store_line("test")
	f = null
	f = FileAccess.open(neighbour, FileAccess.WRITE)
	if f != null:
		f.store_line("test")
		f = null

	if not Baker.invalidate_preview_cache(probe):
		_fail("invalidate reported no removal although a file was planted")

	if FileAccess.file_exists(planted):
		_fail("the cached thumbnail was not deleted")
	if not FileAccess.file_exists(neighbour):
		_fail("invalidate deleted an unrelated file")

	DirAccess.remove_absolute(abs_neighbour)
	print("  planted file removed, neighbour untouched")


## "Delete all previews": every render gone, editor cache cleared, auto-bake off.
func _test_clear_all() -> void:
	var files: PackedStringArray = _first(_list(DIR), LIMIT)
	if files.is_empty():
		_fail("no .mtlx found in %s" % DIR)
		return

	# Start from a known state: real renders and cached thumbnails present, so
	# the clear below has something to actually remove.
	var baked_before := 0
	for p in files:
		# Plant a render if the library has not been baked yet.
		var render := ProjectSettings.globalize_path(Baker.cache_path(p))
		if not FileAccess.file_exists(render):
			DirAccess.make_dir_recursive_absolute(render.get_base_dir())
			var r := FileAccess.open(render, FileAccess.WRITE)
			if r != null:
				r.store_line("x")
				r = null
		if FileAccess.file_exists(Baker.cache_path(p)):
			baked_before += 1
	for p in files:
		var src := ProjectSettings.globalize_path(Baker.preview_cache_base(p) + ".png")
		var w := FileAccess.open(src, FileAccess.WRITE)
		if w != null:
			w.store_line("x")
			w = null
	print("\nstarting state: %d/%d rendered, cached thumbnails planted" % [baked_before, files.size()])
	if baked_before != files.size():
		_fail("could not plant renders for the clear to remove")

	var dock: MtlxConverter = Converter.new()
	dock.set_script(Converter)
	root.add_child(dock)
	await process_frame

	dock._on_clear_cache()
	await process_frame

	var still_baked := 0
	for p in files:
		if FileAccess.file_exists(Baker.cache_path(p)):
			still_baked += 1
		if FileAccess.file_exists(Baker.preview_cache_base(p) + ".png"):
			_fail("cached thumbnail survived for %s" % p.get_file())
	print("after clear: %d render(s) left" % still_baked)
	if still_baked != 0:
		_fail("clear left %d render(s) behind" % still_baked)

	# Auto-bake must be off, or the renders would come straight back.
	if dock._auto.button_pressed:
		_fail("auto-bake was left on after clearing")

	dock.queue_free()


## "Rebuild all previews": clears first, then hands control back to the baker.
##
## EditorPlugin can only be instantiated by the editor, so a stub cannot stand in
## for one here. Instead this checks the two things that can be checked: that the
## button reports missing baking rather than failing silently, and that the
## methods it calls really exist on the plugin.
func _test_rebuild_all() -> void:
	var dock: MtlxConverter = Converter.new()
	dock.set_script(Converter)
	root.add_child(dock)
	await process_frame

	dock._folder.text = DIR
	dock._on_rebake_all()
	await process_frame
	print("\nrebuild status: %s" % dock._status.text.strip_edges())
	if dock._status.text.find("unavailable") == -1:
		_fail("rebuild without a plugin should report that baking is unavailable")

	# Auto-bake must have been left on for the rebuild to actually happen.
	if not dock._auto.button_pressed:
		_fail("rebuild left auto-bake off")

	dock.queue_free()
	await process_frame

	# The dock calls plugin.set_auto_bake() and plugin.bake_previews(); confirm
	# the plugin defines them, or the calls would be silently skipped.
	var plugin_script: Script = load("res://addons/materialx/plugin.gd")
	if plugin_script == null:
		_fail("could not load plugin.gd")
		return
	var defined := {}
	for m in plugin_script.get_script_method_list():
		defined[m.name] = true
	for needed in ["set_auto_bake", "bake_previews"]:
		if not defined.has(needed):
			_fail("plugin.gd does not define %s(), so the dock's call is a no-op" % needed)
	print("plugin exposes set_auto_bake + bake_previews: %s" % (
		defined.has("set_auto_bake") and defined.has("bake_previews")))


func _list(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if f.get_extension().to_lower() == "mtlx":
			out.append(dir_path.path_join(f))
	return out


func _first(arr: PackedStringArray, n: int) -> PackedStringArray:
	return arr.slice(0, mini(n, arr.size()))


func _fail(msg: String) -> void:
	_failures += 1
	print("  FAIL: %s" % msg)
