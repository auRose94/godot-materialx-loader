extends SceneTree

## Reproduces the "auto-bake runs forever" report and checks it is fixed.
##
## The symptom: a material whose bake fails is never "baked", so it stays in the
## stale set forever. The plugin re-checks every ten seconds, so the whole
## library gets re-queued on every pass and the bake appears never to finish.
##
## Two things are checked here:
##
##   1. A failing material is left alone for FAILURE_BACKOFF, so repeated
##      start() calls do not re-queue it.
##   2. Editing the file clears the backoff, so an edit is still worth retrying.
##
## The bake is made to fail on purpose: a .mtlx with no surfacematerial cannot
## convert, which is a permanent failure with no GPU involved, so this runs
## headless.

const AutoBaker := preload("res://addons/materialx/mtlx_auto_baker.gd")
const Baker := preload("res://addons/materialx/mtlx_preview_baker.gd")

const DIR := "res://.baker_backoff"
const BAD := DIR + "/broken.mtlx"

var _failures := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	_write_broken_mtlx()

	var baker: MtlxAutoBaker = AutoBaker.new()
	baker.name = "MtlxAutoBaker"
	baker.source_dirs = PackedStringArray([DIR])
	root.add_child(baker)
	await process_frame

	print("fixture: %s (a .mtlx with no <surfacematerial>)" % BAD.get_file())
	print("stale before: %d" % AutoBaker.collect_stale(DIR).size())

	# --- pass 1: the material is attempted and fails ---
	baker.start(PackedStringArray([DIR]))
	print("\npass 1: queued = %d" % baker.get("_total"))
	_expect(int(baker.get("_total")) == 1, "the broken material is queued")
	await _drain(baker)

	print("pass 1: stats = %s" % baker.stats())
	_expect(int(baker.get("_baked")) == 0, "nothing baked (the material is broken)")
	_expect(int(baker.get("_failed")) == 1, "the failure was counted")
	_expect(baker.backed_off().size() == 1, "the material is now in backoff")

	# --- pass 2: must be a no-op, not a fresh queue ---
	# This is the runaway. Without backoff, the plugin's periodic re-check would
	# start baking the whole library again on every single pass, forever.
	#
	# Asserted on is_running()/the progress counter rather than _total: start()
	# returns before touching _total when it finds nothing stale, so _total is
	# still holding pass 1's value and says nothing about this pass.
	var done_after_pass1: int = baker.get("_done")
	baker.start(PackedStringArray([DIR]))
	print("\npass 2: running = %s, done = %d (was %d)" % [
		baker.is_running(), baker.get("_done"), done_after_pass1])
	_expect(baker.is_running() == false, "nothing was queued on the next pass")

	await _drain(baker)
	_expect(int(baker.get("_done")) == done_after_pass1,
		"the backed-off material was not attempted again")

	baker.start(PackedStringArray([DIR]))
	_expect(baker.is_running() == false, "still not queued on a third pass")

	# --- editing the file clears the backoff ---
	# There is no FileAccess.set_modified_time in 4.x, so touch it externally.
	# The clock is only second-granular, so also verify the stamp actually moved
	# rather than assuming it did.
	var abs_bad: String = ProjectSettings.globalize_path(BAD)
	var mtime_before: int = FileAccess.get_modified_time(BAD)
	OS.execute("touch", [abs_bad])
	await process_frame
	var mtime_after: int = FileAccess.get_modified_time(BAD)
	print("\ntouch: mtime %d -> %d" % [mtime_before, mtime_after])
	if mtime_after == mtime_before:
		print("  (filesystem timestamp granularity too coarse; poking the "
			+ "recorded stamp instead)")
		# White-box: put the recorded stamp out of date, which is the state the
		# code would be in had the file actually changed.
		var entry: Dictionary = baker.get("_failures")[BAD]
		entry["mtime"] = mtime_before - 60
		baker.get("_failures")[BAD] = entry

	print("backoff cleared: %s" % str(baker.backed_off().is_empty()))
	_expect(baker.backed_off().is_empty(),
		"editing the file clears the backoff, so it is retried")

	baker.start(PackedStringArray([DIR]))
	print("pass 3: queued = %d (expect 1)" % baker.get("_total"))
	_expect(int(baker.get("_total")) == 1, "the edited material is retried")
	await _drain(baker)

	_cleanup()
	print("\n--- %s ---" % (
		"backoff works" if _failures == 0 else "%d failure(s)" % _failures))
	quit(1 if _failures > 0 else 0)


## Waits for the queue to drain and the in-flight bake to release.
func _drain(baker: MtlxAutoBaker) -> void:
	var guard := 0
	var going: bool = true
	while going and guard < 600:
		await process_frame
		guard += 1
		going = baker.is_running() or bool(baker.get("_busy"))


## Valid XML, so the parser is happy, but there is no <surfacematerial>, which
## is a conversion failure the emitter reports rather than crashes on.
func _write_broken_mtlx() -> void:
	var f := FileAccess.open(BAD, FileAccess.WRITE)
	f.store_line('<?xml version="1.0" encoding="utf-8"?>')
	f.store_line('<materialx version="1.38">')
	f.store_line('  <standard_surface name="SR_broken" type="surfaceshader">')
	f.store_line('    <input name="base_color" type="color3" value="1, 0, 0" />')
	f.store_line('  </standard_surface>')
	f.store_line('</materialx>')
	f = null


func _cleanup() -> void:
	for dir in [DIR]:
		var abs_dir: String = ProjectSettings.globalize_path(dir)
		for f in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute(abs_dir.path_join(f))
		DirAccess.remove_absolute(abs_dir)


func _expect(cond: bool, what: String) -> void:
	if cond:
		print("  OK: %s" % what)
	else:
		_failures += 1
		print("  FAIL: %s" % what)
