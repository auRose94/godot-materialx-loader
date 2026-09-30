class_name MtlxTestKit
extends RefCounted

## Shared helpers for the test suite.
##
## The tests must not assume a particular folder name, because the point of
## this repository is that the addon works in a project it has never seen. So
## instead of a hardcoded "res://materials", every test asks this kit where the
## materials are.
##
## Three ways to choose, in priority order:
##
##   1. An explicit path on the command line:
##        godot-mono --headless --script tests/mtlx_corpus_check.gd -- res://assets/mat
##   2. A MATERIALX_TEST_DIR environment variable, for CI.
##   3. The first folder under res:// that contains any .mtlx at all.
##
## Pointing a test at your own library is the intended way to use this against a
## real project, which is a better check than the handful of files in demo/.

## Every .mtlx under res://, whatever the folder layout.
static func all_mtlx(dir: String = "") -> PackedStringArray:
	var found := PackedStringArray()
	var start: String = dir if dir != "" else primary_dir()
	_walk(start, found)
	found.sort()
	return found


## A slice of the library, for tests that only need a sample.
static func first(n: int, dir: String = "") -> PackedStringArray:
	var all := all_mtlx(dir)
	return all.slice(0, mini(n, all.size()))


## Folders holding at least one .mtlx.
static func material_dirs() -> PackedStringArray:
	var dirs := PackedStringArray()
	_walk_dirs("res://", dirs, 0)
	dirs.sort()
	return dirs


## Where to look by default: an override if given, else the first folder that
## actually contains a material.
static func primary_dir() -> String:
	var user_args := OS.get_cmdline_user_args()
	if not user_args.is_empty() and DirAccess.dir_exists_absolute(user_args[0]):
		return user_args[0]
	var from_env := OS.get_environment("MATERIALX_TEST_DIR")
	if from_env != "" and DirAccess.dir_exists_absolute(from_env):
		return from_env
	var dirs := material_dirs()
	if not dirs.is_empty():
		return dirs[0]
	# Nothing found: still a valid answer, so the tests fail with a clear
	# message rather than a null dereference.
	return "res://"


static func _walk(dir: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.get_extension().to_lower() == "mtlx":
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_walk(dir.path_join(sub), out)


## Depth-limited, because "every folder in a big project" is not what the tests
## want when they are only looking for a starting point.
static func _walk_dirs(dir: String, out: PackedStringArray, depth: int) -> void:
	if depth > 4:
		return
	var d := DirAccess.open(dir)
	if d == null:
		return
	var has_mtlx := false
	for f in d.get_files():
		if f.get_extension().to_lower() == "mtlx":
			has_mtlx = true
			break
	if has_mtlx:
		out.append(dir)
	for sub in d.get_directories():
		_walk_dirs(dir.path_join(sub), out, depth + 1)
