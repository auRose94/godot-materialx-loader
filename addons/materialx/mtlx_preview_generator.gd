@tool
class_name MtlxPreviewGenerator
extends EditorResourcePreviewGenerator

## Shows .mtlx files as material thumbnails in the FileSystem dock.
##
## ## Why the sphere is drawn on the CPU
##
## EditorResourcePreview generates previews on a worker thread
## (`EditorResourcePreview::_thread` -> `_iterate` -> `_generate_preview`), so a
## generator cannot build a Viewport, add scene nodes, or drive the rendering
## server the way a main-thread preview can. The image is therefore shaded by
## hand in MtlxThumbnail, which keeps this class to nothing but the adapter.
##
## The generator claims every "VisualShader", which is the type
## ResourceFormatLoader reports for .mtlx. A hand-written .tres holding a
## VisualShader is not handled by _generate_from_path (it returns null for any
## path that is not .mtlx), so those keep whatever preview they had.

const Thumbnail := preload("res://addons/materialx/mtlx_thumbnail.gd")
const Baker := preload("res://addons/materialx/mtlx_preview_baker.gd")


func _handles(type: String) -> bool:
	return type == "VisualShader"


func _can_generate_small_preview() -> bool:
	return true


func _generate_from_path(path: String, size: Vector2i, _metadata: Dictionary) -> Texture2D:
	if path.get_extension().to_lower() != "mtlx":
		return null

	# Prefer a real GPU bake when one exists: that is the actual converted
	# shader, so it cannot disagree with how the material looks in a scene.
	# Baked previews are written on the main thread because a preview worker
	# cannot build a Viewport; loading the PNG is safe from here.
	var baked: Image = Baker.load_baked(path)
	if baked != null and not baked.is_empty():
		if baked.get_size() != size:
			baked.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
		return ImageTexture.create_from_image(baked)

	var image: Image = Thumbnail.render(path, maxi(size.x, size.y))
	if image == null:
		return null
	return ImageTexture.create_from_image(image)