extends SceneTree

## Headless test runner:
##   godot --headless --path godot -s res://tests/test_runner.gd
##
## Discovers every `test_*.gd` suite under res://tests, runs each `test_*`
## method (awaiting the async ones), and exits non-zero on any failure, so it
## slots straight into CI. A script error raised while a test runs fails that
## test too — GDScript aborts the function silently otherwise.

var _failures: Array[String] = []
var _passed := 0
var _current := ""
var _errors := ErrorCapture.new()


class ErrorCapture:
	extends Logger
	var messages: Array[String] = []
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		messages.append("%s (%s:%d %s)" % [rationale if not rationale.is_empty() else code, file, line, function])
		_mutex.unlock()

	func take() -> Array[String]:
		_mutex.lock()
		var out := messages.duplicate()
		messages.clear()
		_mutex.unlock()
		return out


func _initialize() -> void:
	OS.add_logger(_errors)
	_run.call_deferred()


func _run() -> void:
	var filter := OS.get_environment("TEST_FILTER")
	var dir := DirAccess.open("res://tests")
	var files := Array(dir.get_files()).filter(func(f): return f.begins_with("test_") and f.ends_with(".gd") and f != "test_runner.gd" and f != "test_base.gd")
	files.sort()
	for file in files:
		var script: GDScript = load("res://tests/" + file)
		for method in script.get_script_method_list():
			var name: String = method["name"]
			if not name.begins_with("test_"):
				continue
			if not filter.is_empty() and not (file + ":" + name).contains(filter):
				continue
			var suite: Node = script.new()
			suite.set("runner", self)
			root.add_child(suite)
			_current = "%s:%s" % [file, name]
			_errors.take()
			var before := _failures.size()
			await suite.call(name)
			for e in _errors.take():
				fail("script error: " + e)
			if _failures.size() == before:
				_passed += 1
				print("  ok   ", _current)
			suite.queue_free()
			await process_frame
			_errors.take()
	print("\n%d passed, %d failed" % [_passed, _failures.size()])
	for f in _failures:
		printerr("FAIL ", f)
	OS.remove_logger(_errors)
	quit(1 if not _failures.is_empty() else 0)


func fail(message: String) -> void:
	_failures.append("%s — %s" % [_current, message])
	printerr("  FAIL ", _current, " — ", message)
