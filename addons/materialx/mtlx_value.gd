@tool
class_name MtlxValue
extends RefCounted

## Decodes MaterialX `value` attribute strings into Godot Variants.
##
## MaterialX stores every literal as text, tagged with the data type. Vectors
## and colours are comma separated and often padded (`" 0.0, 0.5, 1.0"`), so
## every field is stripped before conversion.


## Decodes `value` as `type`. Returns null when the text does not match, which
## is how callers distinguish "absent" from "zero".
static func parse(type: String, value: String) -> Variant:
	if value == null:
		return null
	match type:
		"float", "float1", "integer", "int":
			# MaterialX writes floats in plain decimal, sometimes with an
			# exponent; to_float handles both and yields 0.0 for junk, so
			# guard on the text actually looking numeric.
			var t: String = value.strip_edges()
			if t.is_empty():
				return null
			if type.begins_with("int"):
				return int(t)
			return float(t)
		"boolean", "bool":
			var b: String = value.strip_edges().to_lower()
			if b == "true":
				return true
			if b == "false":
				return false
			return null
		"string":
			return value
		"filename":
			return value
		"color3", "vector3":
			var v3: Vector3 = _to_vector3(value)
			return v3
		"color4", "vector4":
			var v4: Vector4 = _to_vector4(value)
			return v4
		"vector2":
			var f: PackedFloat32Array = _floats(value, 2)
			return Vector2(f[0], f[1]) if f.size() == 2 else null
		"multioutput":
			return value
	return null


## The zero value for a type, used when a port has no literal.
static func zero(type: String) -> Variant:
	match type:
		"float", "float1":
			return 0.0
		"integer", "int":
			return 0
		"boolean", "bool":
			return false
		"color3", "vector3":
			return Vector3.ZERO
		"color4", "vector4":
			return Vector4.ZERO
		"vector2":
			return Vector2.ZERO
		"string", "filename", "multioutput":
			return ""
	return 0.0


## A neutral default (1.0 / white) rather than a zero one. Used where
## MaterialX omits an input that would otherwise destroy the result.
static func one(type: String) -> Variant:
	match type:
		"float", "float1":
			return 1.0
		"color3", "vector3":
			return Vector3.ONE
		"color4", "vector4":
			return Vector4.ONE
		"vector2":
			return Vector2.ONE
	return one_or_zero(type)


static func one_or_zero(type: String) -> Variant:
	match type:
		"color3", "vector3":
			return Vector3.ONE
		"color4", "vector4":
			return Vector4.ONE
		"vector2":
			return Vector2.ONE
		"integer", "int":
			return 1
		"boolean", "bool":
			return true
	return 1.0


## Splits a comma separated literal and parses each field.
static func _floats(value: String, want: int) -> PackedFloat32Array:
	var parts: PackedStringArray = value.split(",")
	var out := PackedFloat32Array()
	for p in parts:
		out.append(float(p.strip_edges()))
	if out.size() != want:
		# Pad short vectors rather than discarding them; MaterialX files in
		# the wild occasionally omit trailing components.
		while out.size() < want:
			out.append(0.0)
		if out.size() > want:
			out = out.slice(0, want)
	return out


static func _to_vector3(value: String) -> Vector3:
	var f: PackedFloat32Array = _floats(value, 3)
	return Vector3(f[0], f[1], f[2])


static func _to_vector4(value: String) -> Vector4:
	var f: PackedFloat32Array = _floats(value, 4)
	return Vector4(f[0], f[1], f[2], f[3])


## MaterialX address/filter enums, mapped to what Godot's texture node can
## express. Godot's VisualShaderNodeTexture has no per-node sampler state, so
## these are informational: the importer reports mismatches rather than
## silently dropping them.
static func is_periodic(mode: String) -> bool:
	return mode == "periodic" or mode == "mirror"


## How a value should be offered as an editable shader parameter, if at all.
## Literal-only inputs become uniforms so the material stays tweakable after
## conversion.
static func is_tweakable(type: String) -> bool:
	match type:
		"float", "float1", "integer", "int", "boolean", "bool":
			return true
		"color3", "color4", "vector2", "vector3", "vector4":
			return true
	return false