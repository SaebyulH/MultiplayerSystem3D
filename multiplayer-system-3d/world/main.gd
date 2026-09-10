extends Control


func _ready() -> void:
	# Boot straight into the 3D lobby: auto-host a server and load the
	# main-menu world.  Deferred so the root Control finishes setting up first.
	NetworkManager.call_deferred("boot_to_lobby")


# The 2D main menu is bypassed (kept on disk but no longer instanced).  These
# are kept as no-ops because NetworkManager still calls them on scene transitions.
func hide_main_menu():
	pass

func show_main_menu():
	pass
