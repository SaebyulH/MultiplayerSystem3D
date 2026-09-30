extends Node3D

## One-off diagnostic for the wood projectile's "drifts upward" report.
##
## Launches `wood.tscn` exactly the way WeaponController._spawn_projectile does —
## from head height, at the speed authored on the scene — over a flat layer-1
## floor, and logs the trajectory.  Answers one question: does the scene rise on
## its own, or only against real map geometry?
##
## Run:
##   "C:/tools/godot/godot_console.exe" --path . --headless res://verification/wood_projectile_probe.tscn

const SCENE_PATH := "res://weapon/projectiles/scenes/wood.tscn"
## _spawn_projectile launches from %Head, roughly 1.65 m above the feet.
const SPAWN_HEIGHT := 1.65
const SPEED := 12.0
const SECONDS := 6.0
const REPORT_INTERVAL := 0.5


func _ready() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 1
	var ground_shape := CollisionShape3D.new()
	var slab := BoxShape3D.new()
	slab.size = Vector3(60.0, 1.0, 60.0)
	ground_shape.shape = slab
	ground.add_child(ground_shape)
	ground.position = Vector3(0.0, -0.5, 0.0)
	add_child(ground)

	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("could not load " + SCENE_PATH)
		get_tree().quit(1)
		return

	var projectile: RigidBody3D = scene.instantiate()
	projectile.global_transform = Transform3D(Basis(), Vector3(0.0, SPAWN_HEIGHT, 0.0))
	projectile.linear_velocity = Vector3(0.0, 0.0, -SPEED)
	add_child(projectile)

	var start_y: float = projectile.global_position.y
	var peak_y := start_y
	var t := 0.0
	var next_report := 0.0
	print("t      y       dy      vy      speed  contacts")
	while t < SECONDS:
		await get_tree().physics_frame
		t += 1.0 / 60.0
		if not is_instance_valid(projectile):
			print("projectile freed at t=%.2f" % t)
			break
		peak_y = maxf(peak_y, projectile.global_position.y)
		if t >= next_report:
			next_report += REPORT_INTERVAL
			print("%.2f  %7.3f  %+7.3f  %+7.3f  %6.2f  %d" % [
				t,
				projectile.global_position.y,
				projectile.global_position.y - start_y,
				projectile.linear_velocity.y,
				projectile.linear_velocity.length(),
				projectile.get_contact_count(),
			])

	print("peak y %.3f (rise %+.3f from spawn)" % [peak_y, peak_y - start_y])
	get_tree().quit(0)
