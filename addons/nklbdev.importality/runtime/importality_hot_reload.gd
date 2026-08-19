class_name ImportalityHotReload
extends Node

## Development-only hot reload for source `.kritalayers` bundles.
##
## The service discovers `.kritalayers` files under `res://`, watches them for
## external changes, and forces ResourceLoader to reload the source through
## ImportalityKritaLayersRuntimeLoader. That loader refreshes an existing cached
## SpriteFrames instance in place when possible, so current AnimatedSprite2D
## consumers do not need project-specific glue.

signal asset_reloaded(path: String, resource: Resource)
signal asset_reload_failed(path: String, message: String)

const RUNTIME_LOADER = preload("krita_layers_runtime_loader.gd")

@export var enabled := true
@export_range(0.05, 5.0, 0.05) var poll_interval := 0.25
@export_range(0.05, 2.0, 0.05) var settle_delay := 0.20
@export_range(0.25, 10.0, 0.25) var hash_verification_interval := 1.0
@export var scan_project := true

var _loader: ResourceFormatLoader
var _timer: Timer
var _files: Dictionary = {}
var _pending: Dictionary = {}
var _last_hash_check_ms := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not enabled:
		return
	if not OS.has_feature("editor"):
		enabled = false
		return

	_loader = RUNTIME_LOADER.new()
	ResourceLoader.add_resource_format_loader(_loader, true)

	_timer = Timer.new()
	_timer.wait_time = poll_interval
	_timer.one_shot = false
	_timer.autostart = true
	_timer.timeout.connect(_poll)
	add_child(_timer)
	_poll()

func _exit_tree() -> void:
	if _timer:
		_timer.stop()
	if _loader:
		ResourceLoader.remove_resource_format_loader(_loader)
	_loader = null
	_timer = null

func watch(path: String) -> void:
	if not _is_krita_layers(path):
		return
	var signature := _signature(path)
	if signature.is_empty():
		return
	_files[path] = signature
	_files[path]["hash"] = _file_hash(path)

func unwatch(path: String) -> void:
	_files.erase(path)
	_pending.erase(path)

func reload(path: String) -> bool:
	if not enabled or not _is_krita_layers(path):
		return false
	var loaded := ResourceLoader.load(
		path,
		"SpriteFrames",
		ResourceLoader.CACHE_MODE_REPLACE,
	)
	if loaded is SpriteFrames:
		var signature := _signature(path)
		if not signature.is_empty():
			signature["hash"] = _file_hash(path)
			_files[path] = signature
		_pending.erase(path)
		asset_reloaded.emit(path, loaded)
		return true

	var message := "Resource did not load as SpriteFrames: %s" % path
	asset_reload_failed.emit(path, message)
	return false

func _poll() -> void:
	if not enabled:
		return

	if scan_project:
		_discover_files()

	var now_ms := Time.get_ticks_msec()
	for path in _files.keys():
		var current := _signature(path)
		if current.is_empty():
			continue
		var previous: Dictionary = _files[path]
		if not _signature_equal(current, previous):
			_pending[path] = {
				"signature": current,
				"first_seen_ms": now_ms,
				"last_attempt_ms": 0,
			}

	if now_ms - _last_hash_check_ms >= int(hash_verification_interval * 1000.0):
		_last_hash_check_ms = now_ms
		for path in _files.keys():
			var hash := _file_hash(path)
			if hash.is_empty():
				continue
			var previous_hash := str((_files[path] as Dictionary).get("hash", ""))
			if not previous_hash.is_empty() and hash != previous_hash:
				_pending[path] = {
					"signature": _signature(path),
					"first_seen_ms": now_ms,
					"last_attempt_ms": 0,
				}
			_files[path]["hash"] = hash

	for path in _pending.keys().duplicate():
		var pending: Dictionary = _pending[path]
		var stable_signature := _signature(path)
		if stable_signature.is_empty():
			continue
		if not _signature_equal(stable_signature, pending["signature"]):
			pending["signature"] = stable_signature
			pending["first_seen_ms"] = now_ms
			pending["last_attempt_ms"] = 0
			continue
		if now_ms - int(pending["first_seen_ms"]) < int(settle_delay * 1000.0):
			continue
		if now_ms - int(pending["last_attempt_ms"]) < 250:
			continue
		pending["last_attempt_ms"] = now_ms
		if reload(path):
			print("[Importality] Hot-reloaded %s" % path)
		else:
			push_warning("[Importality] Hot-reload deferred for %s; keeping previous resource." % path)

func _discover_files() -> void:
	var discovered: Dictionary = {}
	_scan_directory("res://", discovered)
	for path in discovered.keys():
		if not _files.has(path):
			_files[path] = discovered[path]
	for path in _files.keys().duplicate():
		if not discovered.has(path):
			_files.erase(path)
			_pending.erase(path)

func _scan_directory(path: String, output: Dictionary) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		if not file_name.to_lower().ends_with(".kritalayers"):
			continue
		var file_path := path.path_join(file_name)
		var signature := _signature(file_path)
		if not signature.is_empty():
			output[file_path] = signature
	for directory_name in dir.get_directories():
		if directory_name in [".godot", ".git"]:
			continue
		_scan_directory(path.path_join(directory_name), output)

func _is_krita_layers(path: String) -> bool:
	return path.get_extension().to_lower() == "kritalayers"

func _signature(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	return {
		"mtime": FileAccess.get_modified_time(path),
		"size": FileAccess.get_size(path),
		"hash": str((_files.get(path, {}) as Dictionary).get("hash", "")),
	}

func _file_hash(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)

func _signature_equal(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("mtime", 0)) == int(b.get("mtime", 0)) \
		and int(a.get("size", -1)) == int(b.get("size", -1))
