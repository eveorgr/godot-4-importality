class_name ImportalityKritaLayersRuntimeLoader
extends ResourceFormatLoader

## Runtime loader for `.kritalayers` v2 development hot-reload.
##
## The editor importer still produces Godot's normal imported resource. This
## loader is deliberately runtime-safe: it reads the source ZIP directly,
## decodes PNG frames in memory, and returns SpriteFrames. That lets a running
## development build observe Krita saves without invoking editor-only APIs.

const SCHEMA := "importality.krita.layers/v2"
const VISIBILITY_META_KEY := &"importality_krita_layers_visibility_rules"
const PLAYBACK_META_KEY := &"importality_krita_layers_playback"
const SOURCE_META_KEY := &"importality_krita_layers_source"
const RUNTIME_OPTION_META_KEY := &"importality_krita_layers_runtime"

const _DIRECTIONS := ["forward", "reverse", "ping_pong", "ping_pong_reverse"]

func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["kritalayers"])

func _get_resource_type(path: String) -> String:
	return "SpriteFrames" if path.get_extension().to_lower() == "kritalayers" else ""

func _handles_type(type: StringName) -> bool:
	return type.is_empty() or type == &"SpriteFrames"

func _recognize_path(path: String, type: StringName) -> bool:
	if path.get_extension().to_lower() != "kritalayers":
		return false
	return type.is_empty() or type == &"SpriteFrames"

func _exists(path: String) -> bool:
	return FileAccess.file_exists(path)

func _load(
	path: String,
	_original_path: String,
	_use_sub_threads: bool,
	cache_mode: int,
) -> Variant:
	var built := _build_resource(path)
	if built.error != OK:
		push_error("Importality Krita Layers runtime load failed for %s: %s" % [path, built.message])
		return built.error

	# CACHE_MODE_REPLACE is used by the hot-reload service. Keep the original
	# SpriteFrames instance alive when possible so existing consumers update in
	# place instead of holding stale resources.
	if cache_mode == ResourceLoader.CACHE_MODE_REPLACE or cache_mode == ResourceLoader.CACHE_MODE_REPLACE_DEEP:
		var cached := ResourceLoader.get_cached_ref(path)
		if cached is SpriteFrames:
			_copy_sprite_frames(built.resource as SpriteFrames, cached as SpriteFrames)
			return cached

	return built.resource

func _build_resource(path: String) -> Dictionary:
	var archive := ZIPReader.new()
	var open_error := archive.open(ProjectSettings.globalize_path(path))
	if open_error != OK:
		open_error = archive.open(path)
	if open_error != OK:
		return _failure(open_error, "Could not open .kritalayers bundle")

	var manifest_buffer := archive.read_file("manifest.json")
	if manifest_buffer.is_empty():
		archive.close()
		return _failure(ERR_INVALID_DATA, "Bundle is missing manifest.json")

	var parsed: Variant = JSON.parse_string(manifest_buffer.get_string_from_utf8())
	if not parsed is Dictionary:
		archive.close()
		return _failure(ERR_PARSE_ERROR, "manifest.json is not a JSON object")

	var manifest: Dictionary = parsed
	var validation_error := _validate_manifest(manifest)
	if not validation_error.is_empty():
		archive.close()
		return _failure(ERR_INVALID_DATA, validation_error)

	var canvas: Dictionary = manifest["canvas"]
	var canvas_size := Vector2i(int(canvas["width"]), int(canvas["height"]))
	var fps := maxf(1.0, float((manifest["animation"] as Dictionary)["fps"]))
	var sprite_frames := SpriteFrames.new()
	for animation_name: StringName in sprite_frames.get_animation_names():
		sprite_frames.remove_animation(animation_name)

	var playback_meta: Dictionary = {}

	for slot_value: Variant in manifest["slots"]:
		var slot: Dictionary = slot_value
		var raw_slot := str(slot["raw_name"]).strip_edges()
		for variant_value: Variant in slot["variants"]:
			var variant: Dictionary = variant_value
			var raw_variant := str(variant["raw_name"]).strip_edges()
			var animation_name := StringName("%s/%s" % [raw_slot, raw_variant])
			var playback: Dictionary = variant["playback"]
			sprite_frames.add_animation(animation_name)
			sprite_frames.set_animation_speed(animation_name, fps)
			sprite_frames.set_animation_loop(animation_name, int(float(playback["repeat_count"])) == 0)
			playback_meta[String(animation_name)] = playback.duplicate(true)

			for frame_value: Variant in variant["frames"]:
				var frame: Dictionary = frame_value
				var archive_file := str(frame["file"])
				var png_buffer := archive.read_file(archive_file)
				if png_buffer.is_empty():
					archive.close()
					return _failure(ERR_FILE_NOT_FOUND, "Missing frame: %s" % archive_file)

				if _sha256_buffer(png_buffer) != str(frame["sha256"]).to_lower():
					archive.close()
					return _failure(ERR_FILE_CORRUPT, "Frame SHA-256 mismatch: %s" % archive_file)

				var image := Image.new()
				var image_error := image.load_png_from_buffer(png_buffer)
				if image_error != OK:
					archive.close()
					return _failure(image_error, "Failed to decode %s: %s" % [archive_file, error_string(image_error)])
				if image.get_size() != canvas_size:
					archive.close()
					return _failure(ERR_INVALID_DATA, "Frame %s is %s, expected %s" % [archive_file, image.get_size(), canvas_size])

				var texture := ImageTexture.create_from_image(image)
				if texture == null:
					archive.close()
					return _failure(ERR_CANT_CREATE, "Failed to create texture for %s" % archive_file)

				sprite_frames.add_frame(
					animation_name,
					texture,
					maxf(1.0, float(frame["duration_frames"])),
				)

	archive.close()

	var visibility_rules: Variant = manifest.get("visibility_rules", {})
	if visibility_rules is Dictionary:
		sprite_frames.set_meta(VISIBILITY_META_KEY, visibility_rules)
	sprite_frames.set_meta(PLAYBACK_META_KEY, playback_meta)
	sprite_frames.set_meta(SOURCE_META_KEY, str(manifest.get("source", path.get_file())))
	sprite_frames.set_meta(RUNTIME_OPTION_META_KEY, {"fps": fps, "canvas_size": canvas_size})
	return {"error": OK, "message": "", "resource": sprite_frames}

func _copy_sprite_frames(source: SpriteFrames, target: SpriteFrames) -> void:
	for animation_name: StringName in target.get_animation_names():
		target.remove_animation(animation_name)

	for animation_name: StringName in source.get_animation_names():
		target.add_animation(animation_name)
		target.set_animation_loop(animation_name, source.get_animation_loop(animation_name))
		target.set_animation_speed(animation_name, source.get_animation_speed(animation_name))
		for index in range(source.get_frame_count(animation_name)):
			target.add_frame(
				animation_name,
				source.get_frame_texture(animation_name, index),
				source.get_frame_duration(animation_name, index),
			)

	for meta_name in target.get_meta_list():
		target.remove_meta(meta_name)
	for meta_name in source.get_meta_list():
		target.set_meta(meta_name, source.get_meta(meta_name))

func _validate_manifest(manifest: Dictionary) -> String:
	if str(manifest.get("schema", "")) != SCHEMA:
		return "Unsupported schema: %s" % manifest.get("schema", "")
	if not manifest.get("canvas") is Dictionary:
		return "Manifest canvas is missing"
	var canvas: Dictionary = manifest["canvas"]
	if int(canvas.get("width", 0)) <= 0 or int(canvas.get("height", 0)) <= 0:
		return "Manifest canvas size must be positive"
	if not manifest.get("animation") is Dictionary:
		return "Manifest animation block is missing"
	if float((manifest["animation"] as Dictionary).get("fps", 0.0)) <= 0.0:
		return "Manifest FPS must be positive"
	if not manifest.get("slots") is Array or (manifest["slots"] as Array).is_empty():
		return "Manifest must contain at least one slot"

	var seen_slots: Dictionary = {}
	var seen_animations: Dictionary = {}
	for slot_value: Variant in manifest["slots"]:
		if not slot_value is Dictionary:
			return "Slot entry is not an object"
		var slot: Dictionary = slot_value
		var slot_name := str(slot.get("name", "")).strip_edges()
		if not _valid_name(slot_name):
			return "Invalid slot name: %s" % slot_name
		var additive := bool(slot.get("additive", false))
		var raw_slot := str(slot.get("raw_name", "")).strip_edges()
		if raw_slot != (("+" if additive else "") + slot_name):
			return "Invalid raw slot name: %s" % raw_slot
		var slot_id := _normalize_id(slot_name)
		if seen_slots.has(slot_id):
			return "Normalized slot collision: %s" % slot_id
		seen_slots[slot_id] = true
		if not slot.get("variants") is Array or (slot["variants"] as Array).is_empty():
			return "Slot has no variants: %s" % slot_name

		var seen_variants: Dictionary = {}
		var defaults := 0
		for variant_value: Variant in slot["variants"]:
			if not variant_value is Dictionary:
				return "Variant entry is not an object"
			var variant: Dictionary = variant_value
			var variant_name := str(variant.get("name", "")).strip_edges()
			if not _valid_name(variant_name):
				return "Invalid variant name: %s" % variant_name
			var is_default := bool(variant.get("default", false))
			defaults += int(is_default)
			if defaults > 1:
				return "More than one default variant in %s" % slot_name
			var raw_variant := str(variant.get("raw_name", "")).strip_edges()
			if raw_variant != (("*" if is_default else "") + variant_name):
				return "Invalid raw variant name: %s" % raw_variant
			var variant_id := _normalize_id(variant_name)
			if seen_variants.has(variant_id):
				return "Normalized variant collision: %s/%s" % [slot_id, variant_id]
			seen_variants[variant_id] = true
			var animation_name := "%s/%s" % [raw_slot, raw_variant]
			if seen_animations.has(animation_name):
				return "Duplicate animation: %s" % animation_name
			seen_animations[animation_name] = true

			if not variant.get("playback") is Dictionary:
				return "Playback metadata missing for %s" % animation_name
			var playback: Dictionary = variant["playback"]
			if str(playback.get("direction", "")) not in _DIRECTIONS:
				return "Invalid playback direction for %s" % animation_name
			var repeat_count := float(playback.get("repeat_count", -1))
			if repeat_count < 0.0 or not is_equal_approx(repeat_count, floor(repeat_count)):
				return "Invalid repeat_count for %s" % animation_name
			if not variant.get("frames") is Array or (variant["frames"] as Array).is_empty():
				return "No frames for %s" % animation_name
			for frame_value: Variant in variant["frames"]:
				if not frame_value is Dictionary:
					return "Frame entry is not an object"
				var frame: Dictionary = frame_value
				var archive_path := str(frame.get("file", ""))
				if not _safe_archive_path(archive_path):
					return "Unsafe frame path: %s" % archive_path
				if int(frame.get("duration_frames", 0)) <= 0:
					return "Invalid frame duration: %s" % archive_path
				var sha := str(frame.get("sha256", "")).to_lower()
				if sha.length() != 64 or not sha.is_valid_hex_number():
					return "Invalid frame SHA-256: %s" % archive_path
	return ""

func _valid_name(value: String) -> bool:
	return not value.is_empty() and _normalize_id(value) != ""

func _normalize_id(value: String) -> String:
	var normalized := value.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	while normalized.contains("__"):
		normalized = normalized.replace("__", "_")
	return normalized.trim_prefix("_").trim_suffix("_")

func _safe_archive_path(value: String) -> bool:
	if value.is_empty() or value.begins_with("/") or value.contains("\\"):
		return false
	for part: String in value.split("/", true):
		if part.is_empty() or part == "." or part == "..":
			return false
	return true

func _sha256_buffer(buffer: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(buffer) != OK:
		return ""
	return context.finish().hex_encode()

func _failure(error: Error, message: String) -> Dictionary:
	return {"error": error, "message": message}
