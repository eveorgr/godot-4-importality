extends SceneTree

const BUNDLE := "res://fixtures/contract.kritalayers"
const SAVE_COPY := "res://fixtures/reloaded_copy.tres"
const VISIBILITY_META_KEY := &"importality.krita.layers.visibility_rules"

func _fail(message: String) -> void:
	push_error("[FAIL] " + message)
	quit(1)

func _pass(message: String) -> void:
	print("[PASS] " + message)

func _require(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
	_pass(message)

func _ready() -> void:
	var resource := load(BUNDLE)
	_require(resource != null, "Importality can load the .kritalayers resource")
	_require(resource is SpriteFrames, "Krita Layers imports to SpriteFrames")

	var frames: SpriteFrames = resource
	var expected := [
		"BODY/base",
		"BODY/*base",
		"FACE/*neutral",
		"FACE/smile",
		"+DETAILS/*none",
		"+DETAILS/cut_face",
	]
	for animation_name in expected:
		_require(frames.has_animation(animation_name), "animation survives import: %s" % animation_name)

	_require(frames.get_animation_speed("FACE/smile") > 0.0, "animation speed survives import")
	_require(frames.get_animation_loop("FACE/smile"), "repeat_count=2 is represented as a looping animation")
	_require(frames.get_frame_count("FACE/smile") == 1, "frame count survives import")
	_require(frames.get_frame_duration("FACE/smile", 0) > 0.0, "frame duration survives import")

	var visibility_rules: Variant = frames.get_meta(VISIBILITY_META_KEY, null)
	_require(visibility_rules is Dictionary, "Visibility Rules metadata is attached generically to the imported resource")
	_require((visibility_rules as Dictionary).get("schema", "") == "krita-sprite-visibility-rules/v1", "Visibility Rules schema survives import")
	_require(((visibility_rules as Dictionary).get("groups", []) as Array).size() == 1, "Visibility Rules group count survives import")

	var save_error := ResourceSaver.save(frames, SAVE_COPY, ResourceSaver.FLAG_BUNDLE_RESOURCES)
	_require(save_error == OK, "imported SpriteFrames can be persisted")
	var reloaded := load(SAVE_COPY)
	_require(reloaded is SpriteFrames, "persisted SpriteFrames can be reloaded")
	var reloaded_frames: SpriteFrames = reloaded
	_require(reloaded_frames.has_animation("+DETAILS/cut_face"), "animation survives persistence/reload")
	_require(reloaded_frames.get_meta(VISIBILITY_META_KEY, null) is Dictionary, "metadata survives persistence/reload")

	_pass("Importality Krita Layers Godot smoke complete")
	quit(0)
