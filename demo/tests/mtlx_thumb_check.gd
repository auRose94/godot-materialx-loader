#!/usr/bin/env -S godot-mono --headless --script
extends SceneTree

## Renders preview thumbnails for a few .mtlx files and reports timing plus
## whether the output actually carries the material's colour.
##
## Exercises MtlxThumbnail directly, which is where the rendering lives; the
## EditorResourcePreviewGenerator adapter can only be instantiated by the editor.

const OUT_DIR := "user://"
const TestKit := preload("res://tests/mtlx_test_kit.gd")

const SAMPLE := 6
var CASES: PackedStringArray = TestKit.first(SAMPLE)
const SIZE := 128


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var total := 0
	var made := 0

	for path in CASES:
		var t0: int = Time.get_ticks_msec()
		var img: Image = MtlxThumbnail.render(path, SIZE)
		var ms: int = Time.get_ticks_msec() - t0
		total += ms

		if img == null:
			print("  %-30s NULL" % path.get_file())
			continue
		made += 1

		# A shaded sphere with real maps should use many luminance values; a
		# flat colour would be a handful.
		var luma_buckets: int = _distinct_luma(img)
		var mean: Color = _mean_color(img)
		var maps: Dictionary = MtlxThumbnail.collect_maps(
			MtlxDocument.load_from_file(path),
			MtlxDocument.load_from_file(path).find_surface(
				MtlxDocument.load_from_file(path).materials[0]),
			path.get_base_dir())
		print("  %-30s %4d ms  mean %.2f/%.2f/%.2f  %3d luma  maps: albedo=%s rough=%s normal=%s" % [
			path.get_file(), ms, mean.r, mean.g, mean.b, luma_buckets,
			"yes" if maps["albedo_img"] != null else "no",
			"yes" if maps["rough_img"] != null else "no",
			"yes" if maps["normal_img"] != null else "no"])

		img.save_png(OUT_DIR + path.get_file().replace(".mtlx", "_thumb.png"))

	print("\n%d/%d previews, %d ms total at %dx%d" % [made, CASES.size(), total, SIZE, SIZE])
	quit(0)


func _mean_color(img: Image) -> Color:
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0.0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c: Color = img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
			n += 1.0
	return Color(r / n, g / n, b / n)


func _distinct_luma(img: Image) -> int:
	var seen: Dictionary = {}
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c: Color = img.get_pixel(x, y)
			seen[int(c.get_luminance() * 32.0)] = true
	return seen.size()