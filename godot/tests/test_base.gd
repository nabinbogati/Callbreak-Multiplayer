class_name TestBase
extends Node

## Assertions shared by every suite. Failures are reported to the runner rather
## than thrown, so one bad expectation does not hide the rest of a test.

var runner: SceneTree


func expect_true(value: bool, message := "expected true") -> void:
	if not value:
		runner.fail(message)


func expect_eq(actual, expected, message := "") -> void:
	if typeof(actual) != typeof(expected) and not (_is_num(actual) and _is_num(expected)):
		runner.fail("%s expected %s, got %s" % [message, var_to_str(expected), var_to_str(actual)])
	elif actual != expected:
		runner.fail("%s expected %s, got %s" % [message, var_to_str(expected), var_to_str(actual)])


func expect_near(actual: float, expected: float, tolerance: float, message := "") -> void:
	if absf(actual - expected) > tolerance:
		runner.fail("%s expected %s ± %s, got %s" % [message, expected, tolerance, actual])


func expect_same_set(actual: Array, expected: Array, message := "") -> void:
	var a := actual.duplicate()
	var b := expected.duplicate()
	a.sort()
	b.sort()
	if a != b:
		runner.fail("%s expected set %s, got %s" % [message, b, a])


## Waits, frame by frame, until [param predicate] holds or [param timeout_s]
## passes. Returns whether it held.
func wait_until(predicate: Callable, timeout_s := 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().process_frame
	return predicate.call()


func _is_num(v) -> bool:
	return v is int or v is float
