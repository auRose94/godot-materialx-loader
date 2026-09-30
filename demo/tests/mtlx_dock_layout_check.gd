extends SceneTree

## Regression guard for the dock that hid the editor's bottom tab bar.
##
## A dock's minimum size is taken from its content. When the MaterialX dock
## stacked a 256px preview and a 240px log under its controls, its minimum
## height exceeded the bottom panel, which pushed the panel's tab bar off the
## bottom of the window -- making Output, Debugger, Shader Editor and FileSystem
## unreachable unless the dock was closed first.
##
## This asserts the dock now asks for a small, scrollable height.

const Converter := preload("res://addons/materialx/mtlx_converter.gd")

## The bottom panel is at its smallest useful size on a 720p window.
const PANEL_HEIGHT := 200
const PANEL_WIDTH := 320


func _init() -> void:
	var bad := 0

	var dock: Control = Converter.new()
	root.add_child(dock)

	await process_frame

	var min_size: Vector2 = dock.get_combined_minimum_size()
	print("dock minimum size: %s" % min_size)
	print("bottom panel height: %d" % PANEL_HEIGHT)

	if min_size.y > PANEL_HEIGHT:
		print("FAIL: dock wants %d px vertically, more than the panel's %d" % [min_size.y, PANEL_HEIGHT])
		bad += 1
	else:
		print("  OK: fits within the panel height")

	if min_size.x > PANEL_WIDTH:
		print("NOTE: dock wants %d px wide" % min_size.x)

	# The content must be scrollable, otherwise a short panel would clip it.
	var scroll: ScrollContainer = _find_scroll(dock)
	if scroll == null:
		print("FAIL: no ScrollContainer found -- content cannot scroll")
		bad += 1
	else:
		print("  OK: content is inside a ScrollContainer")

	# The live preview must actually be shown. A bare SubViewport renders
	# off-screen and draws nothing, so it needs a TextureRect (or a
	# SubViewportContainer) to be visible -- otherwise the panel shows an empty
	# gap where the preview should be.
	var rect: TextureRect = _find(dock, "TextureRect")
	if rect == null:
		print("FAIL: live preview has no TextureRect, so the SubViewport never displays")
		bad += 1
	elif rect.texture == null:
		print("FAIL: the preview TextureRect has no texture")
		bad += 1
	else:
		print("  OK: preview displayed via TextureRect (%s)" % rect.texture.get_class())

	# Shrink the dock to a short panel and confirm the content is still reachable.
	dock.custom_minimum_size = Vector2(0, 0)
	dock.size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	await process_frame

	if scroll == null:
		print("FAIL: cannot continue without a ScrollContainer")
		quit(1)
		return

	var vh: int = scroll.get_v_scroll_bar().max_value - scroll.get_v_scroll_bar().page
	print("\nat %d px tall the content overflows by %d px and scrolls" % [PANEL_HEIGHT, vh])
	if vh <= 0:
		print("NOTE: content already fits, no scrolling needed")

	dock.queue_free()
	print("\n--- %s ---" % ("dock layout OK" if bad == 0 else "%d failures" % bad))
	quit(1 if bad > 0 else 0)


func _find_scroll(node: Node) -> ScrollContainer:
	if node is ScrollContainer:
		return node
	for c in node.get_children():
		var found: ScrollContainer = _find_scroll(c)
		if found != null:
			return found
	return null


## Depth-first search for the first node of the given class name.
func _find(node: Node, cls: String) -> TextureRect:
	if node.get_class() == cls:
		return node as TextureRect
	for c in node.get_children():
		var found: TextureRect = _find(c, cls)
		if found != null:
			return found
	return null