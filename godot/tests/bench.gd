extends SceneTree

## Times the table's busiest moments, frame by frame, on the CPU — dealing, an
## opponent's turn coming and going, the player's turn, a trick, and a whole
## hand at a solo table. Not part of the test suite:
##   godot --headless --fixed-fps 60 --path godot -s res://tests/bench.gd


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var bench: Node = load("res://tests/bench_steps.gd").new()
	root.add_child(bench)
	await bench.run()
	quit(0)
