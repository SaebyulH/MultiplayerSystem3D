extends Control


## Heavy boot-time resources, preloaded on a background thread so the loading
## screen can show real progress.  Preloading them (with the default
## CACHE_MODE_REUSE) puts them in the resource cache, so the later load() calls
## in world_1.gd / loadout_menu.gd / spawn_manager.gd become instant cache hits.
const PRELOAD_PATHS: Array[String] = [
	"res://maps/main_menu_world.tscn",
	"res://world/spawn_manager.tscn",
	"res://world/spawn_bot_menu.tscn",
	"res://player/player_classes/assault.tres",
	"res://player/player_classes/assassin.tres",
	"res://player/player_classes/assistance.tres",
]

## Fraction of the loading bar that the resource preload covers; the remaining
## span is filled by boot-time checkpoints (server start, world load, spawns).
const PRELOAD_FRACTION := 0.7


func _ready() -> void:
	_boot()


func _boot() -> void:
	var loading: LoadingScreen = $LoadingScreen
	loading.visible = true
	await _preload_resources(loading)

	# Boot straight into the 3D lobby: auto-host a server and load the main-menu
	# world.  boot_to_lobby is async and reports checkpoints as it goes.
	await NetworkManager.boot_to_lobby()
	loading.set_progress(1.0)
	loading.set_status("")

	# Keep the loading screen up through the first rendered frames so the D3D12
	# shader compilation happens behind it, then hide.
	await get_tree().process_frame
	await get_tree().process_frame
	loading.visible = false


func _preload_resources(loading: LoadingScreen) -> void:
	var count := PRELOAD_PATHS.size()
	for i in count:
		var path: String = PRELOAD_PATHS[i]
		loading.set_status("Loading %s…" % path.get_file())
		var err := ResourceLoader.load_threaded_request(path)
		if err != OK:
			# Threaded load unavailable — fall back to a synchronous (still cached) load.
			load(path)
			loading.set_progress(float(i + 1) / float(count) * PRELOAD_FRACTION)
			continue
		while true:
			var progress: Array = []
			var status := ResourceLoader.load_threaded_get_status(path, progress)
			match status:
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					var frac := 0.0
					if progress.size() >= 2:
						var stages := int(progress[0])
						var stage := int(progress[1])
						if stages > 0:
							frac = clampf(float(stage) / float(stages), 0.0, 1.0)
					loading.set_progress((float(i) + frac) / float(count) * PRELOAD_FRACTION)
				ResourceLoader.THREAD_LOAD_LOADED:
					ResourceLoader.load_threaded_get(path)
					break
				ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
					push_warning("Preload failed: %s" % path)
					break
			await get_tree().process_frame
		loading.set_progress(float(i + 1) / float(count) * PRELOAD_FRACTION)
	loading.set_status("")


# The 2D main menu is bypassed (kept on disk but no longer instanced).  These
# are kept as no-ops because NetworkManager still calls them on scene transitions.
func hide_main_menu():
	pass


func show_main_menu():
	pass
