#!/usr/bin/env -S godot-mono --headless --script
extends SceneTree

## Exercises the texture import fixer in dry-run mode and verifies that a
## converted shader survives a save/load round trip.
##
## Both halves degrade gracefully on a library that has no textures at all,
## rather than indexing an empty array: a script error inside SceneTree._init()
## never reaches quit(), so the process hangs instead of failing.

const Fixer := preload("res://addons/materialx/mtlx_texture_fixer.gd")
const TestKit := preload("res://tests/mtlx_test_kit.gd")
const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")

const OUT := "user://mtlx_roundtrip.tres"

## How many materials to round-trip. Enough to cover the shapes present without
## writing a .tres for a whole library.
const ROUND_TRIP := 3


func _init() -> void:
	var bad := 0

	bad += _check_fixer_dry_run()
	bad += _check_round_trip()

	print("\n--- %s ---" % ("all checks passed" if bad == 0 else "%d failures" % bad))
	quit(1 if bad > 0 else 0)


## Reports the import usage the fixer infers, and that a dry run writes nothing.
func _check_fixer_dry_run() -> int:
	var bad := 0

	# The fixer only has something to say about a material that references a
	# texture, so find the first one that does rather than taking materials[0].
	var textured: String = ""
	var usage: Dictionary = {}
	for path in TestKit.all_mtlx():
		var candidate: Dictionary = Fixer.scan(path)
		if not candidate.is_empty():
			textured = path
			usage = candidate
			break

	if textured == "":
		print("=== texture import fixer ===")
		print("  no material in this library references a texture; skipping")
		return bad

	print("=== texture usage inferred for %s ===" % textured.get_file())
	var keys: Array = usage.keys()
	keys.sort()
	for k in keys:
		print("  %-52s %s" % [k.get_file(), Fixer.Usage.keys()[usage[k]]])

	var changes := {}
	for k in keys:
		var c: Dictionary = Fixer.apply(k, usage[k], false)
		if not c.is_empty():
			changes[k] = c
	print("\nwould change %d of %d texture import settings:" % [changes.size(), keys.size()])
	for k in changes:
		var bits := PackedStringArray()
		for opt in changes[k]:
			bits.append("%s=%s" % [opt, changes[k][opt]])
		print("  %-40s %s" % [k.get_file(), ", ".join(bits)])

	# Confirm nothing was written: a dry run must be side-effect free.
	var sample: String = keys[0]
	var before: String = FileAccess.get_file_as_string(sample + ".import")
	Fixer.apply(sample, usage[sample], false)
	var after: String = FileAccess.get_file_as_string(sample + ".import")
	if before != after:
		print("FAIL: dry run modified an .import file")
		bad += 1
	else:
		print("\ndry run left .import files untouched  OK")
	return bad


## A shader written to disk and read back must be the same graph. This is what
## makes "Convert .mtlx to .tres" safe to hand to a build.
func _check_round_trip() -> int:
	var bad := 0
	print("\n=== save/load round trip ===")

	var files := TestKit.first(ROUND_TRIP)
	if files.is_empty():
		print("  no materials found; nothing to round-trip")
		return bad

	for path in files:
		var r: MtlxEmitter.Result = Emitter.build_file(path)
		if not r.ok:
			print("FAIL: build ", path, ": ", r.message)
			bad += 1
			continue

		var before_nodes: int = r.shader.get_node_list(1).size()
		var before_conns: int = r.shader.get_node_connections(1).size()

		# A distinct path per material: ResourceLoader caches by path, so
		# reusing one would hand back the previously loaded shader.
		var out: String = OUT.replace(".tres", "_" + path.get_file() + ".tres")
		if ResourceSaver.save(r.shader, out) != OK:
			print("FAIL: could not save ", path)
			bad += 1
			continue

		var loaded: VisualShader = load(out)
		if loaded == null:
			print("FAIL: could not load back ", path)
			bad += 1
			continue

		var after_nodes: int = loaded.get_node_list(1).size()
		var after_conns: int = loaded.get_node_connections(1).size()
		var code: String = loaded.code

		var ok: bool = after_nodes == before_nodes \
			and after_conns == before_conns and not code.is_empty()
		print("  %-22s nodes %d->%d  conns %d->%d  code %d bytes  %s" % [
			path.get_file(), before_nodes, after_nodes,
			before_conns, after_conns, code.length(),
			"OK" if ok else "MISMATCH"])
		if not ok:
			bad += 1

		DirAccess.remove_absolute(ProjectSettings.globalize_path(out))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT))
	return bad
