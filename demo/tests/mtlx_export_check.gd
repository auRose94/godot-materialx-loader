extends SceneTree

## Guards the project-wide conversion into the export folder.
##
## This is the scope that produces a browsable library: every .mtlx in the
## project converted into one flat folder of ShaderMaterial .tres, which the
## FileSystem dock previews by itself. Ways it could silently break:
##
## - flattening must not lose materials: a duplicate basename gets a numbered
##   suffix, never an overwrite
## - the conversion must never read res://addons or its own export folder as
##   sources, or a re-run converts garbage into itself
## - a dry run must write nothing, so a bulk write stays behind the checkbox
## - repeating a real run must be idempotent: same names, no accumulating
##   suffixes, or regenerating the library renames half of it

const Converter := preload("res://addons/materialx/mtlx_converter.gd")
const Config := preload("res://addons/materialx/mtlx_config.gd")

const KEY := "materialx/export_path"
## Sources the check creates. The demo also has real .mtlx files
## (res://materials/*.mtlx and hero_staging/materials/Grid_Paint.mtlx), so the
## exact plan below counts those too -- see _counts.
const SRC_ROOT := "res://export_check_src"
## Where the check converts into. res://export_check_out/zz holds a source
## deliberately, to prove the conversion never reads its own output area.
const OUT_ROOT := "res://export_check_out"

## Synthetic sources plus the demo's own .mtlx files.
var _expected_files := [
	"res://export_check_src/a/Foo.mtlx",
	"res://export_check_src/b/Foo.mtlx",
	"res://export_check_src/c/Bar.mtlx",
	"res://hero_staging/materials/Grid_Paint.mtlx",
	"res://materials/Glass.mtlx",
	"res://materials/Gold.mtlx",
	"res://materials/Grid_Paint.mtlx",
	"res://materials/Rubber.mtlx",
]
## Scan order is sorted and deterministic, so renaming lands on the later
## claimant of each name: b/Foo after a/Foo, the demo's Grid_Paint after the
## hero staging copy.
var _expected_targets := [
	"res://export_check_out/Foo.tres",
	"res://export_check_out/Foo-2.tres",
	"res://export_check_out/Bar.tres",
	"res://export_check_out/Grid_Paint.tres",
	"res://export_check_out/Glass.tres",
	"res://export_check_out/Gold.tres",
	"res://export_check_out/Grid_Paint-2.tres",
	"res://export_check_out/Rubber.tres",
]

var _bad := 0


func _init() -> void:
	_forget()
	_cleanup()
	_make_sources()

	await _test_source_dirs_exclude()
	await _test_dry_run_writes_nothing()
	await _test_real_run_writes_materials()
	await _test_repeated_run_is_idempotent()

	# Leave the demo project as it started: no export path chosen, and no
	# artifact trees from this check anywhere on disk.
	_cleanup()
	_forget()
	ProjectSettings.save()

	print("\n--- %s ---" % ("export OK" if _bad == 0 else "%d failure(s)" % _bad))
	quit(1 if _bad > 0 else 0)


func _forget() -> void:
	if ProjectSettings.has_setting(KEY):
		ProjectSettings.set_setting(KEY, null)


func _cleanup() -> void:
	for path in [SRC_ROOT, OUT_ROOT]:
		if DirAccess.dir_exists_absolute(path):
			_remove_tree(path)


## Depth-first delete: this Godot has no DirAccess.remove_recursive, and the
## check must clean up after itself even when a previous run crashed halfway.
func _remove_tree(root: String) -> void:
	var d: DirAccess = DirAccess.open(root)
	if d == null:
		return
	for sub in d.get_directories():
		_remove_tree(root.path_join(sub))
	for f in d.get_files():
		var err: Error = d.remove(f)
		if err != OK:
			print("  FAIL: could not delete %s/%s (err %d)" % [root, f, err])
	var parent: DirAccess = DirAccess.open(root.get_base_dir())
	if parent != null:
		parent.remove(root.get_file())


## Copies one real corpus file as the three synthetic sources, so the
## conversion walks and saves real material content. All same-name pairs are
## deliberately identical content: the check is about naming, not variety.
func _make_sources() -> void:
	var gold := FileAccess.get_file_as_string("res://materials/Gold.mtlx")
	_write_file("res://export_check_src/a/Foo.mtlx", gold)
	_write_file("res://export_check_src/b/Foo.mtlx", gold)
	_write_file("res://export_check_src/c/Bar.mtlx", gold)
	# Lives under the export folder, so it must be excluded from the scan.
	_write_file("res://export_check_out/zzz/Skip.mtlx", gold)


func _write_file(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f = null


## The dock runs without a plugin, so source discovery falls to the
## filesystem walk; the exported folder-and-addons exclusions must hold in
## that mode too.
func _test_source_dirs_exclude() -> void:
	var dock = await _fresh_dock()
	var dirs: PackedStringArray = dock._source_dirs(OUT_ROOT)
	_expect(dirs.has("res://export_check_src/a"),
		"the walk finds .mtlx folders recursively")
	var excluded := false
	for d in dirs:
		if d == OUT_ROOT or d.begins_with(OUT_ROOT + "/"):
			excluded = true
		if d == "res://addons" or d.begins_with("res://addons/"):
			excluded = true
	_expect(not excluded,
		"the export folder and res://addons are never treated as sources")
	dock.free()
	await process_frame


func _test_dry_run_writes_nothing() -> void:
	var dock = await _fresh_dock()
	dock._export.text = OUT_ROOT
	dock._on_convert_project()
	_expect(dock._status.text.contains("would convert 8 material(s)"),
		"the dry run plans the whole project: %s" % dock._status.text)
	_expect(dock._status.text.contains("2 renamed for duplicate names"),
		"duplicate basenames are renamed, not lost")
	_expect(dock._log.text.contains("export_check_src/a/Foo.mtlx -> export_check_out/Foo.tres"),
		"the log shows the exact mapping")
	_expect(dock._log.text.contains("export_check_out/Foo-2.tres")
		and dock._log.text.contains("export_check_out/Grid_Paint-2.tres"),
		"and both duplicate claimants get a numbered suffix")
	_expect(not FileAccess.file_exists(OUT_ROOT + "/Foo.tres"),
		"the dry run wrote nothing")
	dock.free()
	await process_frame


func _test_real_run_writes_materials() -> void:
	var dock = await _fresh_dock()
	dock._export.text = OUT_ROOT
	dock._dry_run = false
	dock._on_convert_project()
	_expect(dock._status.text.contains("converted 8 material(s) into %s" % OUT_ROOT),
		"the real run converts the whole project: %s" % dock._status.text)
	_expect(dock._status.text.contains("0 failed"),
		"and nothing fails")
	for t in _expected_targets:
		if not FileAccess.file_exists(t):
			_expect(false, "expected output %s" % t)
	_expect(Config.export_path() == "",
		"conversion itself does not write the export path; only a commit does")

	# The library is meant to be loaded by the game: what lands there is a
	# ShaderMaterial, not a bare shader.
	var mat: Resource = load(OUT_ROOT + "/Foo.tres")
	_expect(mat is ShaderMaterial and mat.shader != null,
		"the exported .tres is a usable ShaderMaterial")
	dock.free()
	await process_frame


func _test_repeated_run_is_idempotent() -> void:
	var dock = await _fresh_dock()
	dock._export.text = OUT_ROOT
	dock._dry_run = false
	dock._on_convert_project()
	_expect(dock._status.text.contains("2 renamed for duplicate names"),
		"a re-run maps each source to the same suffixed name again")
	for t in _expected_targets:
		if not FileAccess.file_exists(t):
			_expect(false, "the re-run kept %s" % t)
	_expect(not FileAccess.file_exists(OUT_ROOT + "/Foo-3.tres"),
		"no accumulating suffixes across conversions")
	dock.free()
	await process_frame


## Builds the dock as the editor would, with no plugin behind it. Untyped on
## purpose: the check must not depend on global class-name resolution.
##
## Waits a frame, because _ready has not fired yet while the SceneTree script
## is still in _init.
func _fresh_dock():
	var dock = Converter.new()
	root.add_child(dock)
	await process_frame
	return dock


func _expect(cond: bool, what: String) -> bool:
	if cond:
		print("  OK: %s" % what)
	else:
		_bad += 1
		print("  FAIL: %s" % what)
	return cond