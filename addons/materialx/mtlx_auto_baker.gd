@tool
class_name MtlxAutoBaker
extends Node

## Keeps the FileSystem thumbnails in step with the real shader, automatically.
##
## The thumbnails the user cares about are the GPU renders produced by
## MtlxPreviewBaker, not the CPU approximation. Baking them by hand is a chore
## and easy to forget, so this does it on its own.
##
## ## Why it is not a one-shot
##
## Godot caches each thumbnail in two places:
##
## * on disk, as `<editor cache>/resthumb-<md5>.{png,txt}`, keyed on the .mtlx's
##   MD5, so an *unchanged* file keeps its old thumbnail indefinitely;
## * in memory for the rest of the session, with no API to clear it.
##
## So after baking, the stale on-disk entry is deleted (invalidate_preview_cache).
## A thumbnail that has not been generated yet is then simply generated from the
## bake. One that was already generated in this session keeps the old image until
## the next refresh -- unavoidable from script, and it self-corrects next launch.
##
## ## Scheduling
##
## One material per frame. Baking is GPU work; doing a whole library at once
## would stall the editor for seconds.
##
## ## Why failures back off
##
## collect_stale() is driven by "is there a PNG?". A material whose bake fails
## therefore stays stale forever, so a periodic retry would re-queue it on every
## pass -- and a failure that affects everything (a lost GPU context, a viewport
## with no framebuffer) would spin for the whole editor session, looking exactly
## like a bake that never finishes. A failed material is now left alone for
## FAILURE_BACKOFF, unless the file itself changes.

const BAKER := preload("res://addons/materialx/mtlx_preview_baker.gd")

## How long to leave a material alone after a failed bake.
const FAILURE_BACKOFF_MS := 120000
## A bake that has not returned within this long is assumed wedged.
const BAKE_TIMEOUT_MS := 15000

signal progress(done: int, total: int, current: String)
signal finished(baked: int, failed: int)

## Set false to stop baking entirely.
@export var enabled: bool = true
## Folders to scan. Empty means "work out where the materials are", which the
## plugin fills in from the editor's FileSystem; it is not a fixed folder name.
@export var source_dirs: PackedStringArray = PackedStringArray()
## Edge length of the baked render, in pixels.
@export var size: int = 128

var _queue: PackedStringArray = PackedStringArray()
var _total: int = 0
var _done: int = 0
var _baked: int = 0
var _failed: int = 0
## True while a material is mid-render; _process re-enters every frame, so this
## stops a second bake starting before the first has read its pixels back.
var _busy: bool = false
## The material currently in flight, and when it started. Watchdog state.
var _in_flight: String = ""
var _busy_since: int = 0
## path -> {"at": msec, "mtime": int}. See FAILURE_BACKOFF_MS.
var _failures: Dictionary = {}
var _viewport: SubViewport
var _running: bool = false


func _ready() -> void:
	# The bake renders into a SubViewport, so it needs a main-thread context.
	_viewport = SubViewport.new()
	_apply_viewport_size()
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)


func _apply_viewport_size() -> void:
	if _viewport != null:
		_viewport.size = Vector2i(size, size)


## Collects every material whose bake is missing or older than its source, and
## starts working through them. Safe to call repeatedly.
func start(dirs: PackedStringArray = PackedStringArray()) -> void:
	if not enabled or _running:
		return
	var scan_dirs: PackedStringArray = dirs if not dirs.is_empty() else source_dirs

	var stale := PackedStringArray()
	for dir in scan_dirs:
		for path in collect_stale(dir):
			if not _is_backed_off(path):
				stale.append(path)

	if stale.is_empty():
		return

	_queue = stale
	_total = _queue.size()
	_done = 0
	_baked = 0
	_failed = 0
	_running = true
	set_process(true)


## Stops after the material currently in flight.
func stop() -> void:
	enabled = false
	_queue.clear()
	_running = false
	_busy = false
	_in_flight = ""
	set_process(false)


## Drives the queue, one material per call.
##
## _process must not await directly: it is re-entered every frame, so awaiting
## inside it would start the same material several times over. Each call instead
## picks one item, hands it to a worker coroutine, and returns immediately.
func _process(_delta: float) -> void:
	if not _running:
		set_process(false)
		return

	# A preview_size change in Project Settings should take effect without a
	# restart. Cheap enough to check every frame while baking.
	if _viewport.size != Vector2i(size, size):
		_apply_viewport_size()

	if _busy:
		# Watchdog. A bake that never returns would leave _busy set, which makes
		# _process return early forever: baking stops silently, _running stays
		# true, and start() then refuses to queue anything again. That presents as
		# a bake stuck at the same number forever.
		if Time.get_ticks_msec() - _busy_since > BAKE_TIMEOUT_MS:
			var wedged: String = _in_flight
			_busy = false
			_in_flight = ""
			_record_failure(wedged)
			_failed += 1
			_done += 1
			progress.emit(_done, _total, wedged.get_file())
			_maybe_finish()
		return

	if _queue.is_empty():
		_finish()
		return

	var path: String = _queue[_queue.size() - 1]
	_queue.remove_at(_queue.size() - 1)
	_busy = true
	_in_flight = path
	_busy_since = Time.get_ticks_msec()
	_bake_one(path)


func _bake_one(path: String) -> void:
	# Two frames per material: one to set the render up, one to read it back.
	await RenderingServer.frame_post_draw
	var err: Error = OK
	if _viewport == null:
		err = ERR_CANT_CREATE
	else:
		err = await BAKER.bake(_viewport, path, source_dirs)
	await RenderingServer.frame_post_draw

	# Whatever happened above, the slot must be released or baking stops for
	# good. GDScript has no finally, so this is the single exit point.
	_busy = false
	_in_flight = ""

	if err == OK:
		_baked += 1
		# Make sure Godot does not keep serving the old CPU-approximation
		# thumbnail on the next launch.
		BAKER.invalidate_preview_cache(path)
	else:
		_failed += 1
		_record_failure(path)

	_done += 1
	progress.emit(_done, _total, path.get_file())
	_maybe_finish()


func _maybe_finish() -> void:
	if _queue.is_empty():
		_finish()


func _finish() -> void:
	_running = false
	set_process(false)
	finished.emit(_baked, _failed)


## Remembers that `path` failed, so it is not retried immediately.
##
## The recorded modification time is what makes this recoverable: if the file
## changes the backoff is dropped, because an edit is a genuine reason to try
## again rather than a glitch to be ridden out.
func _record_failure(path: String) -> void:
	if path == "":
		return
	_failures[path] = {
		"at": Time.get_ticks_msec(),
		"mtime": FileAccess.get_modified_time(path),
	}


func _is_backed_off(path: String) -> bool:
	if not _failures.has(path):
		return false
	var entry: Dictionary = _failures[path]
	if int(entry.get("mtime", -1)) != FileAccess.get_modified_time(path):
		# The file changed since the failure: worth another attempt.
		_failures.erase(path)
		return false
	return Time.get_ticks_msec() - int(entry.get("at", 0)) < FAILURE_BACKOFF_MS


## Materials under `dir` that need baking: no PNG yet, or one older than the .mtlx.
static func collect_stale(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.get_extension().to_lower() != "mtlx":
			continue
		var path: String = dir.path_join(f)
		if not BAKER.is_baked(path):
			out.append(path)
	return out


func is_running() -> bool:
	return _running


## Materials currently in the retry backoff, for diagnostics.
func backed_off() -> PackedStringArray:
	var out := PackedStringArray()
	for path in _failures:
		if _is_backed_off(path):
			out.append(path)
	return out


func stats() -> Dictionary:
	return {
		"done": _done,
		"total": _total,
		"baked": _baked,
		"failed": _failed,
		"running": _running,
		"busy": _busy,
		"backed_off": _failures.size(),
	}
