extends SceneTree

## Regression test for the dependency walker.
##
## Two bugs, both found while hardening the addon:
##
##   1. MtlxDocument.elements holds *top-level* nodes only, so an <image> inside
##      a <nodegraph> -- an ordinary way to author one -- was never reported.
##      Godot would then not reload the material when that texture changed.
##   2. Only paths relative to the .mtlx were reported, while the emitter also
##      resolves through the configured texture roots. A texture found that way
##      was used by the shader but invisible to the editor's dependency graph.
##
## The stand-in files are .tres rather than .png on purpose: an image source
## needs an import pass before ResourceLoader will see it, and this runs without
## the editor. The dependency walker only resolves paths and does not care what
## they point at, so a loadable resource is all it needs.

const Loader := preload("res://addons/materialx/mtlx_format_loader.gd")

const ROOT := "res://.dep_test"
const SHARED := "res://.dep_test_shared"
const MTLX := ROOT + "/nested.mtlx"

var _failures := 0


func _init() -> void:
	_mkdir(ROOT)
	_mkdir(SHARED)
	_write_resource(ROOT + "/top_tex.tres")
	_write_resource(ROOT + "/nested_tex.tres")
	_write_resource(SHARED + "/shared_tex.tres")
	_write_mtlx()

	var loader: MtlxFormatLoader = Loader.new()
	loader.texture_roots = PackedStringArray([SHARED])

	print("=== .mtlx written to %s ===" % MTLX)
	var deps: PackedStringArray = loader._get_dependencies(MTLX, false)
	print("dependencies reported (%d):" % deps.size())
	for d in deps:
		print("  %s" % d)

	# 1. the top-level image
	_expect(deps.has(ROOT + "/top_tex.tres"),
		"top-level <image> reported")
	# 2. the image nested inside the nodegraph -- the actual bug
	_expect(deps.has(ROOT + "/nested_tex.tres"),
		"<image> inside a <nodegraph> reported")
	# 3. a texture that only resolves through the texture roots
	_expect(deps.has(SHARED + "/shared_tex.tres"),
		"texture found via texture_roots reported")

	# The old code built the whole shader graph just to answer this; it should
	# now answer without one. A file with no surfacematerial proves it, because
	# the old version bailed out and reported nothing at all.
	var no_surface := ROOT + "/no_surface.mtlx"
	var f := FileAccess.open(no_surface, FileAccess.WRITE)
	f.store_line('<?xml version="1.0"?>')
	f.store_line('<materialx version="1.0">')
	f.store_line('  <image name="i" type="color3">')
	f.store_line('    <input name="file" type="filename" value="top_tex.tres"/>')
	f.store_line('  </image>')
	f.store_line('</materialx>')
	f = null
	var deps2: PackedStringArray = loader._get_dependencies(no_surface, false)
	print("\nno-surfacematerial file still reports its textures: %d" % deps2.size())
	_expect(deps2.has(ROOT + "/top_tex.tres"),
		"dependencies do not require a convertible material")

	_cleanup()
	print("\n--- %s ---" % ("dependencies OK" if _failures == 0 else "%d failure(s)" % _failures))
	quit(1 if _failures > 0 else 0)


func _write_mtlx() -> void:
	var f := FileAccess.open(MTLX, FileAccess.WRITE)
	f.store_line('<?xml version="1.0"?>')
	f.store_line('<materialx version="1.0">')
	# A plain top-level image.
	f.store_line('  <image name="top" type="color3">')
	f.store_line('    <input name="file" type="filename" value="top_tex.tres"/>')
	f.store_line('  </image>')
	# An image wrapped in a nodegraph -- walked by el.children, not el itself.
	f.store_line('  <a name="graph" type="multioutput">')
	f.store_line('    <input name="out" type="multioutput"/>')
	f.store_line('    <image name="deep" type="color3">')
	f.store_line('      <input name="file" type="filename" value="nested_tex.tres"/>')
	f.store_line('    </image>')
	f.store_line('    <output name="out" type="multioutput">')
	f.store_line('      <input name="out1" type="color3" interstage="true"/>')
	f.store_line('    </output>')
	f.store_line('  </a>')
	# Only findable through the texture roots.
	f.store_line('  <image name="shared" type="color3">')
	f.store_line('    <input name="file" type="filename" value="shared_tex.tres"/>')
	f.store_line('  </image>')
	f.store_line('</materialx>')
	f = null


func _write_resource(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_line('[gd_resource type="Environment" format=3]')
	f.store_line('')
	f.store_line('[environment]')
	f.store_line('')
	f = null


func _mkdir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


func _cleanup() -> void:
	for d in [ROOT, SHARED]:
		var abs_dir: String = ProjectSettings.globalize_path(d)
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(abs_dir.path_join(f))
		DirAccess.remove_absolute(abs_dir)


func _expect(cond: bool, what: String) -> void:
	if cond:
		print("  OK: %s" % what)
	else:
		_failures += 1
		print("  FAIL: %s" % what)
