#!/usr/bin/env -S godot-mono --headless --script
extends SceneTree

## Runs the emitter over every .mtlx in the library and summarises the result:
## failures, missing textures, unsupported nodes, and what had to be dropped.

const Emitter := preload("res://addons/materialx/mtlx_emitter.gd")
const TestKit := preload("res://tests/mtlx_test_kit.gd")

var DIR: String = TestKit.primary_dir()

var _ok := 0
var _failed: Array = []
var _notes: Dictionary = {}
var _dropped: Dictionary = {}
var _missing: Dictionary = {}
var _no_output: Array = []
var _node_total := 0
var _conn_total := 0
var _normal_maps := 0
var _constant_normals := 0


func _init() -> void:
	var files := _list(DIR)
	print("converting %d file(s) from %s\n" % [files.size(), DIR])

	for path in files:
		_convert(path)

	print("\n=== summary ===")
	print("converted ok      : %d" % _ok)
	print("failed            : %d" % _failed.size())
	print("total nodes       : %d" % _node_total)
	print("total connections : %d" % _conn_total)
	print("NORMAL_MAP from a texture  : %d" % _normal_maps)
	print("NORMAL_MAP from a constant : %d" % _constant_normals)

	if not _notes.is_empty():
		print("\nunsupported / approximation notes:")
		_print_counts(_notes)
	if not _dropped.is_empty():
		print("\ndropped surface inputs (input -> how many materials):")
		_print_counts(_dropped)
	if not _missing.is_empty():
		print("\nmissing textures:")
		_print_counts(_missing)
	if not _no_output.is_empty():
		print("\nWARNING: no ALBEDO/METALLIC/ROUGHNESS wired (%d):" % _no_output.size())
		for p in _no_output.slice(0, 10):
			print("   ", p.get_file())

	if not _failed.is_empty():
		print("\nfailures:")
		for p in _failed.slice(0, 15):
			print("   ", p.get_file())

	quit(0)


func _convert(path: String) -> void:
	var r: MtlxEmitter.Result = Emitter.build_file(path)
	if not r.ok:
		_failed.append(path)
		return
	_ok += 1

	var ids: Array = r.shader.get_node_list(1)
	var conns: Array = r.shader.get_node_connections(1)
	_node_total += ids.size()
	_conn_total += conns.size()

	for n in r.notes:
		_notes[n] = int(_notes.get(n, 0)) + 1
	for k in r.dropped.keys():
		var key: String = "%s (%s)" % [k, r.dropped[k]]
		_dropped[key] = int(_dropped.get(key, 0)) + 1
	for t in r.missing_textures:
		_missing[t] = int(_missing.get(t, 0)) + 1

	# Every connection must reference a node that exists, or Godot drops it
	# silently when the resource loads.
	var known := {0: true, 1: true}
	for id in ids:
		known[id] = true
	for c in conns:
		var d: Dictionary = c
		if not known.has(d["from_node"]) or not known.has(d["to_node"]):
			_failed.append(path)
			print("DANGLING in ", path.get_file())
			return

	# At least one of ALBEDO / METALLIC / ROUGHNESS should be driven, or the
	# material cannot render.
	var wired := false
	for c in conns:
		var d2: Dictionary = c
		if int(d2["to_node"]) == 0 and int(d2["to_port"]) in [
				GodotMap.OUT_ALBEDO, GodotMap.OUT_METALLIC, GodotMap.OUT_ROUGHNESS]:
			wired = true
			break
	if not wired:
		_no_output.append(path)

	# Count how many materials actually reach NORMAL_MAP, and whether the
	# value is a texture sample rather than a constant.
	for c in conns:
		var d3: Dictionary = c
		if int(d3["to_node"]) != 0 or int(d3["to_port"]) != GodotMap.OUT_NORMAL_MAP:
			continue
		var src_node: VisualShaderNode = r.shader.get_node(1, int(d3["from_node"]))
		if src_node is VisualShaderNodeTexture:
			_normal_maps += 1
		else:
			_constant_normals += 1
		break

	if r.shader.code.is_empty():
		print("NO CODE generated for ", path.get_file())


func _list(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if f.get_extension().to_lower() == "mtlx":
			out.append(dir_path.path_join(f))
	return out


func _print_counts(d: Dictionary) -> void:
	var keys: Array = d.keys()
	keys.sort_custom(func(a, b): return int(d[a]) > int(d[b]))
	for k in keys:
		print("  %4d  %s" % [int(d[k]), k])