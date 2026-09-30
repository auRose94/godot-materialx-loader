#!/usr/bin/env -S godot-mono --headless --script
extends SceneTree

## Verifies that a .mtlx loads through the registered ResourceFormatLoader,
## i.e. that load("res://.../Anything.mtlx") yields a VisualShader without any
## explicit conversion step.

const FormatLoader := preload("res://addons/materialx/mtlx_format_loader.gd")
const TestKit := preload("res://tests/mtlx_test_kit.gd")

## How many materials to try. A handful proves the loader works; the whole
## library is covered by mtlx_corpus_check.
const SAMPLE := 5

var PATHS: PackedStringArray = TestKit.first(SAMPLE)


func _init() -> void:
	var bad := 0
	if PATHS.is_empty():
		print("FAIL: no .mtlx found; point the suite at a folder of materials")
		quit(1)
		return
	print("sampling %d material(s) from %s\n" % [PATHS.size(), TestKit.primary_dir()])

	# Without the loader registered, a .mtlx is not a loadable resource.
	var raw: Variant = ResourceLoader.load(PATHS[0], "", ResourceLoader.CACHE_MODE_IGNORE)
	print("before registering: load() returned %s" % ("null (expected)" if raw == null else str(raw)))

	var loader: MtlxFormatLoader = FormatLoader.install(PackedStringArray([TestKit.primary_dir()]))
	print("registered loader: %s" % loader.get_class())

	for path in PATHS:
		var res: Variant = ResourceLoader.load(path)
		if res == null:
			print("FAIL: %s did not load" % path)
			bad += 1
			continue
		if not (res is VisualShader):
			print("FAIL: %s loaded as %s, expected VisualShader" % [path, res.get_class()])
			bad += 1
			continue
		var shader: VisualShader = res
		var nodes: int = shader.get_node_list(1).size()
		var conns: int = shader.get_node_connections(1).size()
		var code: String = shader.code
		var ok: bool = nodes > 0 and conns > 0 and not code.is_empty()
		print("  %-24s -> VisualShader, %d nodes, %d conns, %d bytes code  %s" % [
			path.get_file(), nodes, conns, code.length(), "OK" if ok else "INCOMPLETE"])
		if not ok:
			bad += 1

	ResourceLoader.remove_resource_format_loader(loader)
	print("\n--- %s ---" % ("format loader works" if bad == 0 else "%d failures" % bad))
	quit(1 if bad > 0 else 0)