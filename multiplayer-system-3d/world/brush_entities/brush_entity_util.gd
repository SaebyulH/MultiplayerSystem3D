extends RefCounted
class_name BrushEntityUtil

## Shared helpers for the TrenchBroom brush entities under `world/brush_entities/`.
##
## Stateless and static, like [ConnectionUtils] — not an autoload. Everything here is
## either build-time (target wiring) or a one-line guard that several entity scripts
## would otherwise each have to get right on their own.
##
## See `docs/06-trenchbroom-entities.md` for the authoring side and `docs/02-netcode.md`
## §9 for the sync model these entities follow.


## True when [param node]'s peer is a client that has a host to ask for state.
##
## Takes the asking node rather than reading a global, because `multiplayer` is a [Node]
## property — there is no global of that name, and these helpers are static.
##
## The test is [b]peer id, not `is_server()`[/b]. An **offline peer reports `is_server()`
## as false while still being peer 1** — `NetworkEvents` documents exactly that — so a
## second instance sitting in a lobby would try to RPC itself. Peer 1 is the host by
## definition in this project, which is the same rule the HostServer zone gates on and
## the same trap called out in `world/special_entities/health_pack_spawner.gd`.
##
## A map rendered with no peer at all (the thumbnail generator) also falls through to
## the host branch, which is the other half of why this is not an unconditional
## `rpc_id(1, ...)`.
static func should_pull_state(node: Node) -> bool:
	return node.multiplayer.has_multiplayer_peer() and node.multiplayer.get_unique_id() != 1


## Hooks the round-start reset for [param node], calling [param callable] with the new
## [enum GameModeComponent.PhaseState] on every transition.
##
## `Map._enter_tree()` (`maps/map.gd`) sets the global before any descendant's `_ready`,
## so it is live on every path a map is built — boot, `load_match_map`, and a client's
## spawner-driven instantiation. It is *not* cleared when the lobby tears its world down,
## though, so a freed component still compares unequal to null in GDScript;
## `is_instance_valid` is the check that actually holds. With no component there are
## simply no phase events and the entity never round-resets, which is the MAIN_MENU case.
##
## Callers must treat their handler as **strictly idempotent**: the host sees every
## transition twice — once from the `phase_changed.emit` in `_transition_phase`, and
## again through the `call_local` `_rpc_sync_phase` it fires immediately after.
static func connect_round_reset(node: Node, callable: Callable) -> void:
	var gmc := GameManager.game_mode_component
	if not is_instance_valid(gmc):
		return
	if gmc.phase_changed.is_connected(callable):
		return
	gmc.phase_changed.connect(callable)


## Wires [param source]'s `trigger` signal to the `use()` method of every entity in the
## same map carrying [param target_name] as its `targetname`.
##
## This replaces Qodot's `QodotMap.connect_signals()`, which func_godot dropped outright
## — nothing in `addons/func_godot/` wires entities together. It is called from a
## source entity's `_func_godot_build_complete()`, which the assembler invokes **deferred**
## (`entity_assembler.gd:267-268`), so by the time it runs every entity in the map exists
## and is in the tree.
##
## [b]The connection is made with `CONNECT_PERSIST` and therefore only exists after the
## mapper rebuilds the map [i]and saves the scene[/i].[/b] Both endpoints are owned by
## `edited_scene_root` (`entity_assembler.gd:347`), which is what lets it serialize into
## `maps/*.tscn`. A rebuild that is not saved loses the link.
##
## [b]Nothing here gates on the server.[/b] The connection is a plain local signal
## connection and exists on every peer — which is precisely why a source entity must gate
## its own `trigger` emission on `multiplayer.is_server()`. Calling this again at runtime
## is safe: the `is_connected` guard makes it a no-op.
##
## The target method is hardcoded to `use()`, as Qodot hardcoded it. Only
## [MovingBrush] defines one today, so a mover is the only useful target.
static func link_targets(source: Node, target_name: String) -> void:
	if target_name.is_empty():
		return

	var targets := find_targets(source, target_name)
	if targets.is_empty():
		push_warning(
			"%s: target '%s' matches no entity in this map — nothing will happen when it fires."
			% [source.name, target_name]
		)
		return

	for target in targets:
		if not target.has_method("use"):
			push_warning(
				"%s: target '%s' (%s) has no use() — it cannot be triggered."
				% [source.name, target.name, target.get_class()]
			)
			continue
		var callable := Callable(target, "use")
		if source.is_connected("trigger", callable):
			continue
		source.connect("trigger", callable, CONNECT_PERSIST)


## Every node under the same [FuncGodotMap] whose `targetname` equals
## [param target_name]. Group membership is deliberately not used: `node_groups` on an
## entity definition already puts arbitrary names into the Godot group namespace, and a
## build-time name lookup should not be able to collide with that.
static func find_targets(node: Node, target_name: String) -> Array[Node]:
	var out: Array[Node] = []
	var root := _map_root(node)
	if root == null:
		return out

	# `owned = false`: the generated nodes carry `owner`, but a walk that depends on it
	# would silently find nothing if that ever changed. Searching the whole subtree is
	# cheap and happens once per map build.
	for candidate in root.find_children("*", "", true, false):
		if "targetname" in candidate and String(candidate.get("targetname")) == target_name:
			out.append(candidate)
	return out


## Converts a vector authored in **TrenchBroom's axes** into **Godot's**.
##
## TrenchBroom is Z-up and Godot is Y-up, and a mapper types into the axes they can see — so
## a property meaning "up" is `"0 0 128"` in the editor and has to arrive as
## `Vector3(0, 128, 0)` in the engine. func_godot does exactly this for its own vector
## properties: `origin` is swapped at `entity_assembler.gd:224` and a per-axis `scale` at
## `:209`, both `(x, y, z) -> (y, z, x)`.
##
## [b]A custom `class_properties` vector gets no such treatment.[/b] The parser hands the
## typed value over in the order it was written, so every brush-entity property that
## describes a [i]direction or displacement[/i] — `move_translation`, `axis`, `velocity`,
## `move_scale` — has to opt in explicitly. Skipping it is silent: the entity builds, the
## value looks right in TrenchBroom, and the thing moves sideways.
##
## [b]Rotation angles are the exception and must not be swapped.[/b] `move_rotation` is a
## (pitch, yaw, roll) triple, and "yaw about the up axis" means the same rotation in both
## engines even though the two engines give the up axis a different name.
static func to_godot_axes(vec: Vector3) -> Vector3:
	return FuncGodotUtil.id_to_opengl(vec)


## Multiplier converting a length authored in TrenchBroom **map units** into **Godot
## units**, for the map [param node] belongs to.
##
## [`FuncGodotMapSettings.inverse_scale_factor`] defaults to 32, meaning brush coordinates
## are divided by 32 on the way in: a 58-unit player bounding box (`player_spawn.tres`'s
## `size`) is 1.8 Godot units. Entity *origins* are already converted by the geometry
## generator, but `class_properties` vectors are parsed straight out of the `.map` text by
## `parser.gd` and arrive in raw map units — so any offset property has to be converted
## explicitly, or a mapper's `"0 0 128"` would travel 128 Godot units instead of 4.
##
## Only meaningful during a build; the fallback is the default factor for the case where
## the node is somehow outside a [FuncGodotMap].
static func map_units(node: Node) -> float:
	var root := _map_root(node)
	if root is FuncGodotMap and (root as FuncGodotMap).map_settings:
		return (root as FuncGodotMap).map_settings.scale_factor
	return 1.0 / 32.0


## The [FuncGodotMap] an entity was built under, or `null` when the node is not inside one
## — which means this is not a map build and there is nothing to wire.
##
## func_godot parents every entity it builds under its [FuncGodotMap] node, and
## `use_groups_hierarchy` can add further [Node3D] group levels below that, so the
## ancestor walk is required rather than a single `get_parent()`.
static func _map_root(node: Node) -> Node:
	var current := node.get_parent()
	while current != null:
		if current is FuncGodotMap:
			return current
		current = current.get_parent()
	return null
