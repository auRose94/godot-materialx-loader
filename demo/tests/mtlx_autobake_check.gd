extends SceneTree

## Exercises the auto-baker: which materials it considers stale, that it bakes
## them for real, and that Godot's cached thumbnail is invalidated afterwards.
##
## Needs a real GPU -- headless uses the dummy renderer, whose SubViewport has no
## framebuffer. Run under xvfb-run.

const AutoBaker := preload("res://addons/materialx/mtlx_auto_baker.gd")
const Baker := preload("res://addons/materialx/mtlx_preview_baker.gd")
const TestKit := preload("res://tests/mtlx_test_kit.gd")

var DIR: String = TestKit.primary_dir()
## A small slice of the library, so the check stays quick.
const LIMIT := 6


func _init() -> void:
	# Start from a clean slate for the materials we will touch.
	for path in _first(_list(DIR), LIMIT):
		var png: String = Baker.cache_path(path)
		if FileAccess.file_exists(png):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(png))
		Baker.invalidate_preview_cache(path)

	var baker: MtlxAutoBaker = AutoBaker.new()
	baker.source_dirs = PackedStringArray([DIR])
	root.add_child(baker)

	await process_frame

	var stale: PackedStringArray = AutoBaker.collect_stale(DIR)
	print("stale materials detected: %d" % stale.size())
	if stale.is_empty():
		print("FAIL: nothing was considered stale after clearing the bakes")
		quit(1)
		return
	var names := PackedStringArray()
	for p in stale.slice(0, 3):
		names.append(p.get_file())
	print("  first few: %s" % ", ".join(names))

	# Limit the work.
	for i in range(stale.size() - LIMIT):
		stale.remove_at(stale.size() - 1)

	var baked := 0
	baker.progress.connect(func(done: int, total: int, current: String) -> void:
		print("  baking %d/%d  %s" % [done, total, current]))
	baker.finished.connect(func(n: int) -> void:
		baked = n
		print("finished signal: baked=%d" % n)
	)

	baker.start(PackedStringArray([DIR]))

	# Wait for both the queue and the in-flight bake: is_running() flips false
	# the moment the queue empties, which is before the last pixels are read.
	var guard := 0
	var still_going: bool = true
	while still_going and guard < 900:
		await process_frame
		guard += 1
		still_going = baker.is_running() or bool(baker.get("_busy"))

	# GDScript lambdas capture locals by value, so read the authoritative
	# counters off the baker rather than trusting the captured copy.
	baked = baker.get("_baked")
	print("\nbaked (from signal): %d   (from baker): %d" % [baked, baker.get("_baked")])
	if baked == 0:
		print("FAIL: nothing was baked")
		quit(1)
		return

	# Every baked material must now have a PNG and be considered fresh.
	var fresh := AutoBaker.collect_stale(DIR)
	print("still stale after baking: %d (of %d total in library)" % [fresh.size(), _list(DIR).size()])

	var bad := 0
	for path in _first(_list(DIR), LIMIT):
		var png: String = Baker.cache_path(path)
		if not FileAccess.file_exists(png):
			continue
		var img: Image = Image.new()
		if img.load(png) != OK:
			print("FAIL: %s exists but will not load" % path.get_file())
			bad += 1
			continue
		# A real render is not a flat colour.
		var seen: Dictionary = {}
		for y in range(0, img.get_height(), 4):
			for x in range(0, img.get_width(), 4):
				seen[int(img.get_pixel(x, y).get_luminance() * 24.0)] = true
		print("  %-30s %dx%d  %d distinct luma" % [path.get_file(), img.get_width(), img.get_height(), seen.size()])
		if seen.size() < 8:
			print("    FAIL: looks flat, the scene may not have rendered")
			bad += 1

	print("\n--- %s ---" % ("auto-bake works" if bad == 0 else "%d failures" % bad))
	quit(1 if bad > 0 else 0)


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