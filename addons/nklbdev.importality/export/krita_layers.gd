@tool
extends "_.gd"
## Importality exporter for `.kritalayers` v2.
##
## `.kritalayers` is a source-application-independent bundle produced by the
## companion Krita Python plugin. It contains manifest.json and full-canvas PNG
## frames, plus optional source metadata such as Visibility Rules.

const ImportalityOptions = preload("../options.gd")
const SCHEMA := "importality.krita.layers/v2"
const VISIBILITY_META_KEY := &"importality.krita.layers.visibility_rules"
const DIRECTIONS: Array[String] = ["forward", "reverse", "ping_pong", "ping_pong_reverse"]

static var _LOGICAL_NAME_REGEX := RegEx.create_from_string("^[\\p{L}\\p{N}_][\\p{L}\\p{N}_ -]*$")
static var _SHA256_REGEX := RegEx.create_from_string("^[0-9a-f]{64}$")

func _init() -> void:
	super("Krita Layers", PackedStringArray(["kritalayers"]), [], [])

func get_options() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for option: Dictionary in super.get_options():
		var option_name: StringName = option.get(&"name", &"")
		if option_name == ImportalityOptions.SPLIT_LAYERS or option_name == ImportalityOptions.LAYERS_ANIMATION_NAME_FORMAT:
			continue
		output.append(option)
	return output

func _normalize_id(value: String) -> String:
	var normalized := value.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	while normalized.contains("__"):
		normalized = normalized.replace("__", "_")
	return normalized.trim_prefix("_").trim_suffix("_")

func _is_logical_name(value: String) -> bool:
	return not value.is_empty() and _LOGICAL_NAME_REGEX.search(value) != null and not _normalize_id(value).is_empty()

func _is_safe_archive_path(value: String) -> bool:
	if value.is_empty() or value.begins_with("/") or value.contains("\\"):
		return false
	for part: String in value.split("/", true):
		if part.is_empty() or part == "." or part == "..":
			return false
	return true

func _sha256_buffer(buffer: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(buffer) != OK:
		return ""
	return context.finish().hex_encode()

func _direction_from_manifest(value: String) -> int:
	match value:
		"forward": return _Common.AnimationDirection.FORWARD
		"reverse": return _Common.AnimationDirection.REVERSE
		"ping_pong": return _Common.AnimationDirection.PING_PONG
		"ping_pong_reverse": return _Common.AnimationDirection.PING_PONG_REVERSE
	return -1

func _export(res_source_file_path: String, options: Dictionary) -> ExportResult:
	var result := ExportResult.new()
	var archive := ZIPReader.new()
	var archive_error := archive.open(ProjectSettings.globalize_path(res_source_file_path))
	if archive_error != OK:
		result.fail(archive_error, "Failed to open Krita layer bundle %s: %s" % [res_source_file_path, error_string(archive_error)])
		return result

	var manifest_result := _read_manifest(archive)
	if manifest_result.error != OK:
		archive.close()
		result.fail(manifest_result.error, manifest_result.message)
		return result
	var manifest: Dictionary = manifest_result.manifest
	var canvas: Dictionary = manifest["canvas"]
	var canvas_size := Vector2i(int(canvas["width"]), int(canvas["height"]))
	var fps := maxf(1.0, float((manifest["animation"] as Dictionary)["fps"]))
	var images: Array[Image] = []
	var animation_specs: Array[Dictionary] = []
	var seen_animation_names: Dictionary = {}

	for slot_value: Variant in manifest["slots"]:
		var slot: Dictionary = slot_value
		var raw_slot_name := str(slot["raw_name"]).strip_edges()
		for variant_value: Variant in slot["variants"]:
			var variant: Dictionary = variant_value
			var raw_variant_name := str(variant["raw_name"]).strip_edges()
			var animation_name := "%s/%s" % [raw_slot_name, raw_variant_name]
			if seen_animation_names.has(animation_name):
				archive.close()
				result.fail(ERR_INVALID_DATA, "Duplicated Krita layer animation: %s" % animation_name)
				return result
			seen_animation_names[animation_name] = true
			var playback: Dictionary = variant["playback"]
			var frame_specs: Array[Dictionary] = []
			for frame_value: Variant in variant["frames"]:
				var frame: Dictionary = frame_value
				var image_result := _read_frame(archive, frame, canvas_size)
				if image_result.error != OK:
					archive.close()
					result.fail(image_result.error, image_result.message)
					return result
				var image_index := images.size()
				images.append(image_result.image)
				frame_specs.append({"image_index": image_index, "duration": maxf(1.0, float(frame["duration_frames"])) / fps})
			animation_specs.append({
				"name": animation_name,
				"frames": frame_specs,
				"direction": _direction_from_manifest(str(playback["direction"])),
				"repeat_count": int(float(playback["repeat_count"])),
			})

	archive.close()
	if images.is_empty():
		result.fail(ERR_INVALID_DATA, "Krita layer bundle has no images")
		return result

	var sprite_sheet_builder = _create_sprite_sheet_builder(options)
	var build_result = sprite_sheet_builder.build_sprite_sheet(images)
	if build_result.error:
		result.fail(ERR_BUG, "Krita layer sprite sheet build failed", build_result)
		return result

	var animation_library := _Common.AnimationLibraryInfo.new()
	for animation_spec: Dictionary in animation_specs:
		var animation := _Common.AnimationInfo.new()
		animation.name = animation_spec["name"]
		animation.direction = animation_spec["direction"]
		animation.repeat_count = animation_spec["repeat_count"]
		for frame_spec: Dictionary in animation_spec["frames"]:
			var frame := _Common.FrameInfo.new()
			frame.sprite = build_result.sprite_sheet.sprites[frame_spec["image_index"]]
			frame.duration = frame_spec["duration"]
			animation.frames.append(frame)
		animation_library.animations.append(animation)

	if manifest.has("visibility_rules") and manifest["visibility_rules"] is Dictionary:
		result.metadata[VISIBILITY_META_KEY] = manifest["visibility_rules"]

	result.success(build_result.atlas_image, build_result.sprite_sheet, animation_library)
	return result

func _read_manifest(archive: ZIPReader) -> Dictionary:
	var buffer := archive.read_file("manifest.json")
	if buffer.is_empty():
		return {"error": ERR_INVALID_DATA, "message": "Krita layer bundle has no manifest.json"}
	var parsed: Variant = JSON.parse_string(buffer.get_string_from_utf8())
	if not (parsed is Dictionary):
		return {"error": ERR_PARSE_ERROR, "message": "Krita layer manifest is not a JSON object"}
	var manifest: Dictionary = parsed
	var validation_error := _validate_manifest(manifest)
	if not validation_error.is_empty():
		return {"error": ERR_INVALID_DATA, "message": validation_error}
	return {"error": OK, "message": "", "manifest": manifest}

func _read_frame(archive: ZIPReader, frame: Dictionary, canvas_size: Vector2i) -> Dictionary:
	var archive_file := str(frame["file"])
	if not _is_safe_archive_path(archive_file):
		return {"error": ERR_INVALID_DATA, "message": "Unsafe frame archive path: %s" % archive_file}
	var png_buffer := archive.read_file(archive_file)
	if png_buffer.is_empty():
		return {"error": ERR_FILE_NOT_FOUND, "message": "Missing frame: %s" % archive_file}
	if _sha256_buffer(png_buffer) != str(frame["sha256"]).to_lower():
		return {"error": ERR_FILE_CORRUPT, "message": "Frame SHA-256 mismatch: %s" % archive_file}
	var image := Image.new()
	var image_error := image.load_png_from_buffer(png_buffer)
	if image_error != OK:
		return {"error": image_error, "message": "Failed to decode %s: %s" % [archive_file, error_string(image_error)]}
	if image.get_size() != canvas_size:
		return {"error": ERR_INVALID_DATA, "message": "Frame %s is %s, expected %s" % [archive_file, image.get_size(), canvas_size]}
	return {"error": OK, "message": "", "image": image}

func _validate_manifest(manifest: Dictionary) -> String:
	if str(manifest.get("schema", "")) != SCHEMA:
		return "Unsupported Krita layer bundle schema: %s" % manifest.get("schema", null)
	if not (manifest.get("canvas") is Dictionary): return "Krita layer manifest has no canvas object"
	var canvas: Dictionary = manifest["canvas"]
	if int(canvas.get("width", 0)) <= 0 or int(canvas.get("height", 0)) <= 0:
		return "Krita layer canvas size must be positive"
	if not (manifest.get("animation") is Dictionary): return "Krita layer manifest has no animation object"
	if float((manifest["animation"] as Dictionary).get("fps", 0.0)) <= 0.0:
		return "Krita layer manifest FPS must be positive"
	if not (manifest.get("slots") is Array) or (manifest["slots"] as Array).is_empty():
		return "Krita layer manifest slots must be a non-empty array"
	var seen_slots: Dictionary = {}
	var seen_animations: Dictionary = {}
	for slot_value: Variant in manifest["slots"]:
		if not (slot_value is Dictionary): return "Krita layer manifest contains a non-object slot"
		var slot: Dictionary = slot_value
		var slot_name := str(slot.get("name", "")).strip_edges()
		if not _is_logical_name(slot_name): return "Invalid Krita layer slot name: %s" % slot_name
		var additive := bool(slot.get("additive", false))
		var raw_slot := str(slot.get("raw_name", "")).strip_edges()
		if raw_slot != (("+" if additive else "") + slot_name): return "Slot marker metadata does not match raw_name: %s" % raw_slot
		var normalized_slot := _normalize_id(slot_name)
		if seen_slots.has(normalized_slot): return "Normalized slot collision: %s" % normalized_slot
		seen_slots[normalized_slot] = true
		if not (slot.get("variants") is Array) or (slot["variants"] as Array).is_empty(): return "Krita layer slot has no variants: %s" % slot_name
		var seen_variants: Dictionary = {}
		var default_count := 0
		for variant_value: Variant in slot["variants"]:
			if not (variant_value is Dictionary): return "Krita layer manifest contains a non-object variant"
			var variant: Dictionary = variant_value
			var variant_name := str(variant.get("name", "")).strip_edges()
			if not _is_logical_name(variant_name): return "Invalid Krita layer variant name: %s" % variant_name
			var is_default := bool(variant.get("default", false))
			default_count += int(is_default)
			if default_count > 1: return "Krita layer slot has more than one default: %s" % slot_name
			var raw_variant := str(variant.get("raw_name", "")).strip_edges()
			if raw_variant != (("*" if is_default else "") + variant_name): return "Variant marker metadata does not match raw_name: %s" % raw_variant
			var normalized_variant := _normalize_id(variant_name)
			if seen_variants.has(normalized_variant): return "Normalized variant collision: %s/%s" % [normalized_slot, normalized_variant]
			seen_variants[normalized_variant] = true
			if str(variant.get("blend_mode", "")).to_lower() != "normal" or int(variant.get("opacity", -1)) != 255:
				return "Top-level exported variants must use normal blend and opacity 255"
			if not (variant.get("playback") is Dictionary): return "Krita layer variant has no playback object"
			var playback: Dictionary = variant["playback"]
			var direction := str(playback.get("direction", ""))
			if direction not in DIRECTIONS or _direction_from_manifest(direction) < 0: return "Invalid playback direction: %s" % direction
			var repeat_value: Variant = playback.get("repeat_count", -1)
			if typeof(repeat_value) != TYPE_INT and typeof(repeat_value) != TYPE_FLOAT: return "repeat_count must be a JSON number"
			var repeat_number := float(repeat_value)
			if is_nan(repeat_number) or is_inf(repeat_number) or repeat_number < 0.0 or not is_equal_approx(repeat_number, floor(repeat_number)):
				return "repeat_count must be a non-negative integer-valued JSON number"
			if not (variant.get("frames") is Array) or (variant["frames"] as Array).is_empty(): return "Krita layer variant frames must be a non-empty array"
			var animation_name := "%s/%s" % [raw_slot, raw_variant]
			if seen_animations.has(animation_name): return "Duplicate Krita layer animation: %s" % animation_name
			seen_animations[animation_name] = true
			for frame_value: Variant in variant["frames"]:
				if not (frame_value is Dictionary): return "Krita layer manifest contains a non-object frame"
				var frame: Dictionary = frame_value
				if not _is_safe_archive_path(str(frame.get("file", ""))): return "Unsafe frame archive path: %s" % frame.get("file", "")
				if int(frame.get("duration_frames", 0)) <= 0: return "Frame duration must be positive: %s" % frame.get("file", "")
				if _SHA256_REGEX.search(str(frame.get("sha256", "")).to_lower()) == null: return "Frame has invalid SHA-256 metadata: %s" % frame.get("file", "")
	return ""
