# 01 — Boot Sequence: Press Play → Playing

A precise, ordered walkthrough of everything that happens from pressing Play to standing in a playable lobby/match, plus the join / leave / map-swap transitions. This is the highest-traffic part of the codebase: most "it won't start / can't move / players invisible" bugs live here.

> File names: the world script is `world/world_1.gd` (scene `world/world1.tscn`). The loadout menu is `world/loadout_menu.gd`. `class_select.gd` exists only under `backup/` — its role was merged into `loadout_menu.gd`.
>
> **2026-11-17: the default/offline and match-session flow changed.** The
> default shell now shows a one-per-process title gate, spawns with a stored
> process build, uses the HostServer Area3D as the Match Menu, and routes
> create/join through a staging room. The old "mandatory Loadout screen on
> world creation" description below applies to `--legacy-p2p` and to the old
> listen/direct paths that have not been migrated. See Stage 13.

---

## Stage 0 — Engine boot + autoload `_ready` order

`project.godot` instantiates the autoloads **in order**; `_ready` runs in the same order, which matters:

0. `MatchSession` (`network/match_session.gd`) — stable player id, server roster, `hello`/`welcome` handshake, node-readiness gate, phase broadcast. First so `NetworkManager` can initialize a client/server match session during boot.
1. `NetworkManager` (`network/network_manager.gd`) — connects the three session-lifetime `SceneMultiplayer` signals **once** (`connected_to_server`, `server_disconnected`, `connection_failed`), guarded by `is_connected()` so they survive peer teardown.
2. `Console`
3. `Leaderboard` — server-authoritative score autoload.
4. `NetworkTime` / 5. `NetworkTimeSynchronizer` / 6. `NetworkRollback` — netfox core.
7. `NetworkEvents` (`addons/netfox/network-events.gd:75-85`) — connects `on_server_start → NetworkTime.start`, `on_server_stop → NetworkTime.stop`, `on_client_start → NetworkTime.start`, `on_client_stop → NetworkTime.stop`, then `_set_enabled(true)` which wires `mp.connected_to_server → _handle_connected_to_server` and starts `_process`.
8. `NetworkPerformance`
9. `GameManager` — tiny holder (`spawn_parent`, `game_mode_component`, `spawn_manager`, `lobby_bots`).

The engine then loads the main scene `res://world/main.tscn` (a `Control` root `"Main"` + a `LoadingScreen` instance, `world/main.tscn:6-16`).

**Key invariant:** `NetworkEvents` (autoload 7) loads *after* `NetworkTime` (autoload 4), so its `_ready` can safely `connect(NetworkTime.start)`.

---

## Stage 1 — `world/main.gd` boot

`world/main.gd:22-23` — `_ready()` → `_boot()`.

`world/main.gd` — `_boot()` reads `OS.get_cmdline_user_args()` and routes:

| Flags (after `--`) | Path |
|---|---|
| `--server [--port=N]` | `NetworkManager.boot_dedicated_server()` — headless match server; peer 1 is **not** a player; returns without hiding the loading screen (there is no local UI). |
| `--listen-server [--port=N]` | `NetworkManager.boot_listen_server()` — host + play in one process; fails loudly if the port is taken. |
| `--offline` | `NetworkManager.boot_offline_lobby()` — local 3D lobby shell on `OfflineMultiplayerPeer`. |
| `--connect=host[:port]` | `NetworkManager.join_party()` — direct-IP dev client; the join flow owns the loading screen. |
| `--lobby=http://host:port` | Configures `LobbyClient` and boots the offline 3D shell; the HostServer zone creates a match through lobbyd and the Match Menu's FIND MATCH tab lists lobbyd matches. |
| `--lobby-create` | Creates a match through lobbyd, then connects to the returned endpoint with its grant. |
| `--lobby-join=CODE` | Joins a lobbyd match by code, then connects with its grant. |
| `--match-id=N` | Set by lobbyd on a dedicated server; bound into the join-grant check. |
| `--test-host-local [--test-host-map=res://maps/X.tscn]` | Boots the local shell, then starts an in-process listen server (test hook for the Host Match flow). |
| `--test-lan` | Boots the shell, scans the LAN discovery range, prints servers, exits. |
| `--no-discovery` | Disables the LAN announce/probe sockets. |
| **no flags (default)** | `NetworkManager.boot_offline_lobby()` — local 3D shell with no external service. HostServer opens the Match Menu: START MATCH creates a listen server in-process, FIND MATCH joins LAN/direct via the match-session handshake. |
| `--legacy-p2p` | `NetworkManager.boot_to_lobby()` — old auto-host P2P behaviour. |

`--auto-loadout` is a test hook for headless runs: it confirms the initial random loadout so a client actually spawns without mouse input. It is ignored on a dedicated server.

Common steps:
1. `$LoadingScreen` shown.
2. `await _preload_resources(...)` — **parallel** threaded-loads all 6 heavy paths up front (`main_menu_world.tscn`, `spawn_manager.tscn`, `spawn_bot_menu.tscn`, the 3 `.tres` class resources) so later `load()` calls are cache hits. Requesting them together makes boot time roughly the *max* load instead of the sum.
3. The route above runs. `boot_to_lobby` is a **direct `await`**, *not* `call_deferred` — older `CLAUDE.md` text describing a deferred call is stale.
4. Sets progress 1.0, waits two `process_frame`s (to let D3D12 shaders compile behind the screen), hides the loading screen.

A dedicated server still preloads the player scene and staging map because it runs the real simulation; `world_1.gd` is what skips the local-player UI (`GameMenu` hidden, no kill feed, no dev menu, no spectator controller) and tells `SpawnManager` not to add a peer-1 player.

`LoadingScreen.report()` no-ops unless `LoadingScreen.current` is set (which happens in `ui/loading_screen.gd:36-39`).

---

## Stage 2 — `boot_to_lobby()`: become host (or offline fallback)

`network/network_manager.gd` — `boot_to_lobby()`:
- Guard `if game_scene != null: return` (anti-double-boot).
- `create_server()`, `Leaderboard.reset()`, `LoadingScreen.report(0.75)`.
- `await get_tree().process_frame` (line 99) — **this frame lets `NetworkEvents._process` observe the server** (see Stage 2b).
- `await load_game_scene(LOBBY_MAP_PATH)`.

`network/network_manager.gd:create_server()`:
- `is_hosting_game = true`.
- `apply_tick_rate(...)` — **always**, before the peer is assigned, because this is also what derives the tick-count limits (`NetworkRollback._history_limit`, `NetworkTime._max_ticks_per_frame`) from `HISTORY_SECONDS`/`CATCHUP_SECONDS`. The offline fallback below needs those as much as a real server does. See `02-netcode.md` §8.
- `ENetMultiplayerPeer.create_server(8080)`; on success set `multiplayer_peer`.
- On failure (port 8080 already taken by another local instance) it sets an **`OfflineMultiplayerPeer`** and **manually calls `NetworkTime.start()`** (line 39). This is required because `NetworkEvents.is_server()` returns `false` for `OfflineMultiplayerPeer` (`network-events.gd:64-65`), so `on_server_start` never fires and the rollback loop would never run — the second local instance's lobby would be unable to move without this manual start.

### Stage 2b — where `NetworkTime` actually starts (ENet path)

`NetworkEvents._process` (`addons/netfox/network-events.gd:93-107`) polls `is_server()` **once per frame**. The first frame after `create_server()` sets the peer, it sees the `false → true` transition and emits `on_server_start` → `NetworkTime.start()`.

`NetworkTime.start()` (`addons/netfox/network-time.gd:409-461`) resets `_tick`, marks peer 1 synced (`_synced_peers[1] = true`), starts `NetworkTimeSynchronizer`, and — because we are the server — goes straight to active state without awaiting initial sync. This runs during the `await process_frame` at line 99, i.e. **before** `world1.tscn` is instantiated.

---

## Stage 3 — `load_game_scene()` → `world1.tscn` `_ready` (host/client split)

`network/network_manager.gd` — `load_game_scene(map_path)`:
- `LoadingScreen.report(0.8)`, `await process_frame`.
- `game_scene = preload(GAME_SCENE).instantiate()`, set `game_scene.map_path = map_path`.
- `get_tree().current_scene.add_child(game_scene)`, `hide_main_menu()`.

`world/world_1.gd:12-45` — `_ready()`:
- line 13: `GameManager.spawn_parent = %SpawnParent`.
- lines 16-17: adds a `KillFeed` node.
- lines 21-22: `PlayerInput.ui_open = true`, `Input.set_mouse_mode(MOUSE_MODE_VISIBLE)`.
- **line 24: `if NetworkManager.is_hosting_game:`** — the branch that separates host from client:
  - **Host:** `load(map_path).instantiate()` named `"Map"` added to `spawn_parent` (27-29); `load("res://world/spawn_manager.tscn").instantiate()` with `player_scene` set, `add_child` (34-38); `GameManager.spawn_manager = sm`; re-adds `GameManager.lobby_bots` (40-45).
  - **Client** (`is_hosting_game == false`): **none of this runs** — no map, no `SpawnManager`; everything replicates from the host.
- **After the split:** `world_1._ready()` creates the dev hacks menu (`world/dev_menu.gd`) and adds it to the world root — never to `SpawnParent`, so it is not replicated. `setup(loadout_menu)` wires the bot-edit return path. The menu is debug-build-only (`OS.is_debug_build()`, matching the console addon) and toggled with the **`0` key**; see Stage 12 for its `ui_open` ownership.
- `world_1._ready()` then creates the local `SpectatorController` (`world/spectator_controller.gd`) — another world-root sibling, never replicated — which owns the spectator camera and target cycling. It is idle until the local player's replicated `is_spectating` flag turns on; see `02-netcode.md` §5.

`world/world1.tscn:95-97` defines the `MultiplayerSpawner` (`spawn_path = "../SpawnParent"`) with 13 `_spawnable_scenes` uids (player + all maps, including lobby `uid://cgnm6fpurb2b2`).

**The lobby also carries a dev Asset Viewer zone.** `AssetViewer` (`world/asset_viewer_area.gd`) is the same Area3D pattern as `PracticeRange`: it tracks local players, owns a crosshair `InteractionPrompt` ("E ASSET VIEWER"), and opens `world/asset_viewer.gd` lazily on first use. The menu is a local CanvasLayer that renders effects, agents, weapons and animations in its own `own_world_3d` SubViewport — no node, RPC or synchronizer touches gameplay or the replication path. See Stage 13.4b.

**Practice dummies spawn while the map is added.** Any map may carry a `PracticeTargetSpawn` marker: its `_ready` runs inside the host's `spawn_parent.add_child(map)` at line 27-29, before `SpawnManager` exists, needs only `GameManager.spawn_parent` and `player.tscn`, and guards on `multiplayer.has_multiplayer_peer() and multiplayer.is_server()`. The lobby has both: its `PracticeDummy` marker spawns a fixed-respawn standing dummy, and `PracticeRange` spawns a separate run target when a run starts and frees it when the run ends. Either way the dummy is a normal Player added to `SpawnParent`, so the world spawner (already alive) replicates it to joiners. Clients never spawn; map teardown (`_exit_tree`) frees the marker dummy, which is what clears old dummies on a map swap. While a range run is live, `PracticeRange` grants every real player inside the zone infinite ammo (`Player.set_range_infinite_ammo`, a separate override from the dev hack) and revokes it when the run ends, the player leaves, or the map is torn down. The zone prompt's second line shows the last and best completion times, mirrored to clients by the progress/result broadcasts.

---

## Stage 4 — `SpawnManager._ready` → local player (still despawned)

`world/spawn_manager.gd:12-18` — `_ready()`:
- connects `peer_connected`/`peer_disconnected`.
- `_add_player_to_game(1)` (line 15) — **hardcoded peer 1**; the host is also a player.
- `randomize()`. Bot spawning/editing lives in the dev menu's Bots tab now; `SpawnManager` no longer instantiates or toggles a menu. New bots start at **skill 1.0** (`SpawnManager.DEFAULT_BOT_SKILL`), and the list row itself carries team, a general Skill slider, and a triangular **Advanced** disclosure that expands to show every `BotController.BOT_TRAIT_KEYS` slider at once — including the Stage 7 **Self-preservation** axis, which scales how early a hurt bot takes cover or breaks contact. A manual bot's team, skill and trait overrides are written back to `GameManager.lobby_bots`, so they survive return-to-lobby; auto-fill bots are session-only.

`world/spawn_manager.gd:54-62` — `_add_player_to_game(1)`: `entity_id = str(1)`, instantiate `player_scene`, `name = "1"`, `set_multiplayer_authority(1)`, `spawn_manager = self`, `add_child` to `spawn_parent`, position `(0,100,0)`, `Leaderboard.request_add_player`.

`player/player.gd:417-489` — `Player._ready()`: sets up skins/mannequin/animation-tree/collider duplication, `add_to_group("players")`, then **`despawn()` at line 489**. `despawn()` (`player/player.gd:743-761`) hides the body, disables the collider, parks at `GameManager.get_despawn_position()`, sets `spawned = false`.

**So the player exists but is invisible and inert** until a loadout is confirmed.

---

## Stage 5 — loadout menu

`world/loadout_menu.gd:82-140` — `_ready()`:
- `player_id = str(multiplayer.get_unique_id())`.
- Loads the 3 `Class` `.tres` (104-113), builds the character picker.
- On first load (`_initial_selection_done` static, lines 16, 134-138) picks a random character + weapons; on later loads selects `character[0]` to avoid re-randomizing on return-to-lobby.

The menu's `CanvasLayer` starts visible, so the loadout screen covers the world on boot.

**Layout (2026-11-18).** `AGENTS // LOADOUT` header; three full-height columns:
left = **YOUR TEAM** roster (local player TEAL, otherwise team colour); centre =
the 3D agent preview filling the column, with operative index, corner brackets
and a floating class-grouped **agent strip** over its lower edge (no picker
popup — clicking an agent applies it immediately); right = a fixed-height Anton
name block (long names shrink, never reflow), the class label **under** the
name, and a scrolling **infographic** (description, trait badges, six 20-pip
attribute bars with TEAL/AMBER/BASE colouring; weapon hover swaps in a
thumbnail + stat rows; ability hover swaps in the ability icon, description and
cooldown/cast rows), then three stacked **weapon slots** and the action stack.
The four numbered **ability tiles** float in their own collapsible INK_2 band
over the bottom of the preview (above the agent strip).  Hovering a different
agent card swaps the preview to that model AND weapon rendered as a blue
hologram (unlit ~0.18-alpha blue `material_override` with strong emission and a
rim) and shows SWITCHING TO above the name. The ghost holds a weapon the
hovered class actually offers (`_weapon_for_character`: keep the current display
if the class has it, otherwise its first primary), never the previous agent's
gun. All colours and fonts come
from `UITheme`; the confirm action is **LOCK IN** (RED). Clicking a weapon slot
opens a popover of that class column; hovering a popover row or the slot itself
puts the weapon in the preview model's in-game hold pose, and the last hovered
weapon stays displayed. Drag spins the model; the mouse wheel zooms it.

The screen is also opened by the staging room's `EDIT LOADOUT` button. In that
case `set_staging_mode(true)` raises the CanvasLayer above staging (layer 8 vs
5), and confirm returns to staging with `PlayerInput.ui_open` still true and
the mouse visible rather than capturing input for gameplay. `respawn` is
already false there via `world.should_loadout_respawn()`.

The same instance doubles as the dev menu's bot editor. `open_for_bot(name)` snapshots the
local player's pending selection (character, three weapons, randomize-on-death), points
`player_id` at the bot, hides Leave Party / randomize-on-death, and preselects the bot's
current character and weapons (weapons by `display_name` — bots hold deep copies). Confirm
calls the normal `_request_loadout` for the bot and therefore respawns it; cancel (Esc/H)
or a confirm both restore the snapshot via `_finish_bot_edit()`, which emits
`bot_edit_finished` so the dev menu reopens on its Bots tab.

**Team and skill are deliberately not in this editor.** They are edited in the Bots list
(`world/spawn_bot_menu.gd`): a team `OptionButton`, a general Skill `HSlider`, and a
triangular **▶ ADVANCED / ▼ ADVANCED** toggle that reveals a row for every
`BotController.BOT_TRAIT_KEYS` trait at once (the eighth is **Self-preservation**). A per-row RESET clears overrides. The dev menu's Bots tools row also has a
**Randomize bot skills** button; it rolls each bot's master skill and stable style seed
and clears overrides. Skill/trait edits redraw `Style` immediately and are server-local
(bots only simulate on peer 1).

### Portrait assets behind the agent strip

The strip's cards draw `Character.portrait` (`ui/kill_feed.gd`, `world/spawn_bot_menu.gd` and `world/game_menu.gd` read the same field), which is a pre-rendered 256×256 transparent PNG in `character_portraits/`. Those PNGs are produced **offline** by `player/character_portrait_generator.gd` — not at runtime, so nothing on the boot path regenerates them and a missing one is simply a blank icon.

The generator lights each portrait with the **editor's own per-scene preview sun and environment**, because the character `.tscn` files contain no lights at all. It reads those settings back out of `res://.godot/editor/<scene>-editstate-<md5>.cfg`, which is machine-local and gitignored — so a portrait regenerated on another machine (or after a cache wipe) is lit by the engine defaults instead and still looks plausible. See `05-known-issues.md` #58, and #59 for the `uid=` stripping the same `ResourceSaver.save()` does to `player/characters/*.tres`.

### The live character preview

`world/loadout_menu.tscn` — a `SubViewportContainer` + `SubViewport` (`CharacterViewport`) instances `world/character_subviewport_preview.tscn`; `world/loadout/loadout_preview_rig.gd` (`PreviewRig`) builds the agent under it. **It uses the real player rig, not a re-creation.** A detached `player.tscn` is instantiated (its root never enters the tree, so `Player._ready` never runs); only its `Body` subtree is kept under a pivot — the mannequin skeleton, the full `AnimationTree` blend tree, the aim `CCDIK3D`, both `CopyTransformModifier3D`s, `RotationDir`, `WeaponTilt` and the real `GunAttach` mount. `PlayerUI`, synchronizers, the camera, the physical-bone simulator and the damage/health labels are freed, every script that dereferences the Player parent (`Body`, `AnimationTree`, `Recoil`, `WeaponTilt`) is cleared, and the blend tree is duplicated so instances do not share it. `Character.character_scene` is parented like `Player._spawn_character_model` (mannequin transform) and mirrors the mannequin's bones via the same by-name pose copy. The weapon is instantiated with `weapon_offset/rotation/scale`, the `WeaponModel` vs legacy parenting rule and the weapon toon — the exact `WeaponController.spawn_weapon_model` path, on the real `GunAttach`.

The rig renders `UPDATE_ONCE` at 30 Hz while the screen is visible (a `0.033 s` timer; stopped when the menu hides), so the walk cycle is visible without paying a per-frame second-World3D render. Camera distance comes from the character's visual AABB (weapon excluded, so hovering never re-zooms). LMB drag **orbits the camera** around the agent on a sphere (elevation clamped to −0.25..1.25 rad); the rig itself is never rotated, so the character and the ground grid stay upright/level. RMB drag pans the model in the camera plane and the wheel adjusts a clamped zoom. `character_subviewport_preview.tscn` carries a transparent `Ground` plane shaded by `assets/materials/preview_grid.gdshader` (0.5 m cells, a major line every 2 m, `fwidth` anti-aliasing, faded past ~7 m); the rig drops it to the model's foot line and pans it with the agent (the grid travels with the character under RMB pan). The `PREVIEW: STANDING / WALKING / RUNNING` button at the preview's bottom-right cycles the animation state. Selecting a new agent rebuilds the rig; a weapon hover only swaps the weapon.

**The tree is driven to match the in-game armed pose, or to the locomotion cycle, per preview mode.** There is no local Player to feed `animation_tree.gd`, so the rig writes the same parameters that script would: `WalkBlendSpace`/`CrouchBlendSpace`/`SprintBlendSpace` at `(0, -1)` (forward) in walk/run, `(0, 0)` when standing; `CrouchWalkSprintBlend3` is 1 in run and 0 otherwise; `JumpBlend = 0`. **`HoldBlend` is 1 when the weapon has a `human_anims` library** — the rig registers the library on the mannequin AnimationPlayer and assigns its `HOLD` animation to the blend tree's `HoldAnim` node exactly as `WeaponController._set_hold_anim` does, so the arms are on the weapon just like in combat. That chain has no locomotion, so in walking/running modes the **leg bones are copied from a second hidden mannequin** playing `walk/walk_w` or `sprint/sprint_w`, and everything above the hips stays on the hold tree. Weapons without a human library keep `HoldBlend = 0` and use the tree's own locomotion. The hold and `a_pose` clips point the body toward +X of the rig (which read as "looking right" only when the tree had no parameter driver); the walk clips face `-Z`, and the extracted aim IK runs on top in both modes. The pose copy runs on every render tick, not only on `skeleton_updated`, because the armed hold pose can be static while the leg source animates. No facing-correction yaw is applied; drag orbit is the only authored rotation.

**The preview's whole appearance lives in that one scene.** `own_world_3d` gives the SubViewport its own `World3D`, so it inherits no environment and no lights from the lobby — `character_subviewport_preview.tscn` carries its own `WorldEnvironment` plus a `DirectionalLight3D` and two `OmniLight3D`s. Because the character materials are `painted_toon.gdshader` (whose `light()` override replaces the built-in direct-light path), what those lights do is the entire lit side of the model; the shadow side comes from the shader's `shadow_wrap` and the ambient the environment supplies. Before 2026-09-30 the scene had **no** environment, so its shadow side had no ambient at all and the darker characters (juggernaut, stalker) read as near-black. The current settings (sky `energy_multiplier` 0.65, sun 0.9, omnis 1.1/0.9 at range 5 — retuned 2026-11-18 for a less blown-out preview) lift the juggernaut's mean pixel luminance `0.090` → `0.144` and the ghost's `0.307` → `0.331`, with highlight clipping essentially unchanged (`4.14%` → `4.33%` and `23.09%` → `23.66%`).

**Tune this by the sky's `energy_multiplier`, not `ambient_light_energy`.** Measured 2026-09-30: with `ambient_light_source = AMBIENT_SOURCE_SKY`, changing `ambient_light_energy` from 0.0 to 3.0 produced a **pixel-identical** render, while the sky material's `energy_multiplier` moves it directly. `ambient_light_energy` is the lever the Godot inspector suggests and it does nothing here — an earlier pass tuned it to 1.3 and concluded the ambient was working when the visible change was coming entirely from the lights.

Two things about that environment are load-bearing:

- **Its sky is a light source, not a background.** `background_mode` is `BG_CLEAR_COLOR`, so Godot skips the sky *draw* on a transparent viewport while still using the sky as the ambient/reflection source. Turning `transparent_bg` off on the SubViewport would make the procedural sky render as an opaque backdrop — see `05-known-issues.md` #84.
- **It is a hand-maintained twin of the portrait generator's environment** (`character_portrait_generator.gd:_build_preview_environment()`, 353-385). The generator derives its sky from the editor's machine-local editstate; the live preview hardcodes its colours in the scene. They are not shared code, so a change to one does not reach the other.

---

## Stage 6 — confirm loadout → first spawn

`world/loadout_menu.gd:850-869` — `_on_confirm_pressed()`:
- validates selections; sets `visible = false` (via `visibility_changed` signal → `_on_visibility_changed` at 143-157 syncs `_canvas.visible`).
- `world.class_selected = true` (`world` = `$"../../.."` = World1).
- `PlayerInput.ui_open = false`, `Input.set_mouse_mode(MOUSE_MODE_CAPTURED)` (863-864).
- Server: `_request_loadout(...)` directly (867); client: `_request_loadout.rpc_id(1, ...)` (869).

`world/loadout_menu.gd:876-915` — `_request_loadout()` (server):
- validates sender id vs `tpid`; `GameManager.find_player(tpid)`; `WeaponController.apply_loadout(...)`; `player.set_character(...)`; stores loadout paths.
- **`player.rpc_reset.rpc(player._get_spawn_position())`** (915).

> **A loadout must be applied with `WeaponController.apply_loadout()`, never `set_weapons()` + `current_weapon_index = 0`.** The bare pair looks equivalent but is not: assigning `_weapons` spawns the model for the *old* index, the index write then starts a 0.1 s put-away animation, and the `rpc_reset()` above calls `reset()`, which zeroes `_switch_phase` before that timer can elapse — so the model swap never happens and the previous slot's gun stays in hand while every other value is already on the new one. `apply_loadout()` is the only place that sequences array → index → model spawn correctly. See `05-known-issues.md` #48.

The same rule governs the other apply sites — `_apply_loadout` (client, `:918-934`), `Player._randomize_weapons_from_class` / `_rpc_sync_randomized_loadout` (`player/player.gd:862-908`), `rpc_sync_full_state` (`player/player.gd:574-592`) and `SpawnManager._apply_bot_weapons` (`world/spawn_manager.gd:226-237`). `set_weapons()` remains the only correct *assignment* primitive (`_ready()` uses it directly, deliberately unadorned).

`player/player.gd:501-534` — `rpc_reset(pos)`: `despawn()`, `respawn_timer = respawn_time` (**default 1.0 s**, `player/player.gd:17`), `_spawn_pending_position = pos`, resets health/weapons/effects.

`player/player.gd:854-867` — `_physics_process`: decrements `respawn_timer`; when it hits 0 and `_spawn_pending_position != ZERO`, applies the position and calls `spawn()`. `spawn()` (`765-804`) shows the body, re-enables collider, applies the camera for the local peer, plays the weapon pull-out.

**First real spawn happens ~1 s after confirm** (the `respawn_timer` window).

---

## Stage 7 — Join flow: `join_party(ip)` → client

`world/globe_menu.gd` — the Match Menu's **FIND MATCH** tab is the only join entry point: REFRESH builds LAN cards (`LanDiscovery.discover()`) and, when `LobbyClient` is enabled, lobbyd cards; the DIRECT row resolves `ip[:port]` or a 6-char code (`_on_join_ip`) and JOIN LOCAL dials `127.0.0.1`. Every path closes the menu and calls `NetworkManager.join_party(address, port, use_session)`.

`network/network_manager.gd` — `join_party(host_ip, port)`:
- `LoadingScreen.show_screen(0.1, "Connecting…")` — re-shows the boot loading screen to mask the connect-time spike (see Stage 8 / `05-known-issues.md` #18).
- `_remove_game_scene()` **first** (frees the joiner's solo world1, SpawnManager, players, lobby map + its spawner).
- `create_client(host_ip, port)`; on error, `return_to_lobby()` (which hides the loading screen).

`network/network_manager.gd` — `create_client()`: `is_hosting_game = false`, `_terminate_connection()` (stop NetworkTime + close/null old peer), `ENetMultiplayerPeer.create_client`, set peer.

`network/network_manager.gd` — `_on_connected_to_server()` is a **coroutine** that runs the whole client start-up in order: `await enter_existing_game_scene()`, `await _await_settled()`, `await _adopt_server_tick_rate()`, then `NetworkTime.start()` and a poll for the initial sync, then `LoadingScreen.hide_screen()`. See `03-event-flow.md` for why that order is load-bearing — the clock sync must happen on the far side of the world-load stall, not during it.

---

## Stage 8 — `enter_existing_game_scene()` + map replication

`network/network_manager.gd` — `enter_existing_game_scene()`: instantiate `world1.tscn`, add as child of `current_scene`, `hide_main_menu()`, report loading checkpoints, then await two `process_frame`s — the same "keep it up through the first rendered frames" pattern as boot (`world/main.gd:39-41`), so connect-time map/player replication + D3D12 shader compilation happen behind the screen. **No `map_path`, no map load, no SpawnManager** — because `world_1.gd:24`'s `if is_hosting_game:` is false on a client.

**It does not hide the loading screen.** That moved to the end of `_on_connected_to_server()` when the tick-domain work landed (`05-known-issues.md` #18), so that the world build, the settle wait, the tick-rate handover and the clock sync all complete before the screen comes down. Every early return in that coroutine must hide the screen itself — one that doesn't is an unrecoverable hang, because nothing else will.

The client's own `MultiplayerSpawner` (`world1.tscn:95-97`) then receives the host's replicated `"Map"` node and existing `Player` nodes into its `SpawnParent`.

`maps/map.gd:12-33` — `Map._enter_tree()` (runs on the client when the replicated map arrives, and on the host at initial load): sets `GameManager.game_mode_component = $GameModeComponent`, finds the HUD and calls `setup_gmc()`, discovers spawn markers.

`world/hud/hud_controller.gd:127-139` — `setup_gmc()`: awaits a frame, grabs `game_mode_component`, wires signals, builds the panel registry, `_switch_to_mode`. In the lobby `game_mode == MAIN_MENU` (enum 6) → `_menu_mode = true` (210-222) so no mode HUD shows.

### Client `NetworkTime.start()` — now `NetworkManager`-owned

`NetworkManager._on_connected_to_server` (connected in autoload 1's `_ready`) runs **before** `NetworkEvents._handle_connected_to_server` (connected in autoload 7's `_ready`) — Godot emits in connection order. netfox used to start `NetworkTime` from its own `on_client_start` listener, which fired *inside* the join stall; `join_party()` disconnects that listener and `_on_connected_to_server()` starts the loop itself once the join has settled:

```
_on_connected_to_server()
  await enter_existing_game_scene()   # world1 built; the big stall is behind us
  await _await_settled()              # 2 consecutive frames under SETTLE_FRAME_SECONDS
  await _adopt_server_tick_rate()     # reliable RPC; falls back to the local default
  NetworkTime.start()                 # short round trip -> a correct tick origin
  LoadingScreen.hide_screen()         # moved here from enter_existing_game_scene()
```

The client's `NetworkTime.start()` then awaits `NetworkTimeSynchronizer.on_initial_sync` before emitting ticks — replicated players arrive but don't tick until the clock syncs. Starting the clock sync *after* the stall is what keeps the seeded tick origin correct; see `03-event-flow.md` and `05-known-issues.md` #18.

---

## Stage 9 — Host side: late-joiner spawn + state sync

`world/spawn_manager.gd:26-33` — `_peer_connected(network_id)`: `_add_player_to_game(network_id)` (creates the joiner's Player under SpawnParent, authority = their id), then `_sync_existing_players_to_peer(network_id)`.

`world/spawn_manager.gd:36-45` — `_sync_existing_players_to_peer()`: **awaits one frame** (line 37, so the MultiplayerSpawner tree sync settles), then for each already-spawned player not equal to the joiner, `rpc_sync_full_state.rpc_id(peer_id, ...)` + pushes permanent status-effect markers. `rpc_sync_full_state` (`player/player.gd:539-573`) applies weapons/character first, then `spawn()`.

The one-frame defer is fragile: existing players' `rpc_reset` already fired before the joiner connected, so without this defer they'd replicate despawned/invisible.

---

## Stage 10 — Leave flow: `return_to_lobby()` (full ordering)

Entry points: `world/post_match.gd:177-190` (results overlay **auto countdown** and its RETURN button), `world/pause_menu.gd` (Leave), `world/staging_room.gd` (Leave), `world/world_1.gd` (Leave Party), `world/loadout_menu.gd` (Leave Party), `network_manager.gd` (`_on_connection_failed`, `_server_disconnected`).

`network/network_manager.gd` — `return_to_lobby()`, in exact order:
1. `_lifecycle_epoch += 1`, capture `epoch` — cancels a superseded rehost.
2. `Input.set_mouse_mode(MOUSE_MODE_VISIBLE)`.
3. `_terminate_connection()`: `NetworkTime.stop()` (full stop, resets `_state` to INACTIVE), `mp.multiplayer_peer.close()`, `mp.multiplayer_peer = null`. Closing the peer first frees port 8080.
4. `_remove_game_scene()`: `queue_free` only (never detach first, #132) + `game_scene = null`.
5. `_rehost_after_stop_observed(epoch, role)` — awaits two process frames, then boots `boot_offline_lobby()` (CLIENT/OFFLINE/LISTEN_SERVER) or `boot_to_lobby()` (LEGACY_P2P).

**Why the two-frame wait is the crux:** `NetworkEvents._process` polls `is_server()` once per frame, tracking a `_is_server` boolean.

- A synchronous teardown + `create_server()` hides the `true → false` transition, so `on_server_start` never re-fires and the re-host's loop never starts.
- The default shell re-hosts to an **offline peer**, which starts its own loop in `create_offline_peer()`. If it starts while `_is_server` is still true, the next poll emits `on_server_stop` → `NetworkTime.stop()` and kills that loop.

`SceneTree` emits `process_frame` before node `_process`, so a *single* await (or the old `call_deferred`) still lands inside the next poll — which is why the results overlay's auto-leave (running from `post_match._process`, after the autoload's poll) left movement dead (`05-known-issues.md` #154). Two full frames guarantee one complete poll with no server peer present before the new loop starts. See `03-event-flow.md`.

---

## Stage 11 — Lobby → match map swap: `load_match_map()`

`world/host_server_area.gd:16-21` — builds HostMenu; `_unhandled_input` (69-77) opens it only if the local player is inside **and** `_is_leader()` (`get_unique_id() == 1`, 53-54).

`world/host_menu.gd:509-524` — `_on_start_pressed()`: applies team assignments to each `Player.team`, `_autofill_bots()` if checked, `close()`, then `NetworkManager.load_match_map(_selected_map.map_scene.resource_path)`.

`network/network_manager.gd` — `load_match_map()`:
- guard `multiplayer.is_server()` (120).
- `Leaderboard.reset()`.
- `GameManager.game_mode_component = null` (130, clears dangling ref before free).
- `remove_child(old_map)` + **`queue_free()` (never `free()`)** (131-133, so the spawner receives the removal event).
- `load(map_path).instantiate()`, name `"Map"`, `add_child` to `spawn_parent` (135-137 — spawner replicates the addition; `map.gd._enter_tree` re-points `game_mode_component` + re-runs `setup_gmc()`).
- respawn players: `for child in spawn_parent: if child is Player: child.rpc_reset.rpc(child._get_spawn_position())` (141-143, after the new map exists).

---

## Stage 12 — `PlayerInput.ui_open` / mouse-mode inventory

`ui_open` gates rollback input (the player can't move in menus) and is consumed by `player_input.gd:73-83`, `hud_controller.gd:96`, `player_ui.gd:742`, `ability_manager.gd`, `dev_menu.gd`.

| Location | `ui_open` | Mouse mode |
|---|---|---|
| `world/world_1.gd:21-22` (world1 `_ready`) | `true` | `VISIBLE` |
| `world/world_1.gd:59-61` (H toggles loadout) | `= loadout_menu.visible` | `VISIBLE` if open else `CAPTURED` |
| `world/world_1.gd:62-68` (Esc closes loadout) | `false` | `CAPTURED` |
| `world/loadout_menu.gd:863-864` (confirm) | `false` | `CAPTURED` |
| `world/dev_menu.gd` (`0` open / close) | `true` / `= loadout_menu.visible` | `VISIBLE` / `CAPTURED` |
| `world/dev_menu.gd` → bot loadout edit | stays `true` (the loadout screen owns it) | `VISIBLE` |
| `world/host_menu.gd:65-66 / 71-72` | `true` / `false` | `VISIBLE` / `CAPTURED` |
| `network/network_manager.gd` (return_to_lobby) | (unchanged) | `VISIBLE` |
| `player/player_input.gd:123-132` (click-to-capture / Esc-to-release) | read-only gate | `CAPTURED` / `VISIBLE` |

`world_1._sync_flow_ui()` may only reclaim input (clear `ui_open` + capture the
mouse) when no other screen owns it. Its guard lists the loadout menu, pause
menu, staging/title and — since 2026-11-17 — `dev_menu.is_open()`. Without the
dev-menu clause, a live match's 250 ms flow tick cleared `ui_open` right after
the `0` press, so the menu stayed visible with the mouse still captured.

The dev menu refuses to open when `ui_open` is already true (the initial loadout screen,
the Host/Join popups), so it never steals input from another menu. `HostServer`
(`globe_menu.open_menu`) makes the same check before opening; previously the areas could
stack a popup on top of another menu and clear `ui_open` when it closed.

---

## Fragile / order-dependent items (see `03-event-flow.md` for the full list)

1. **The two-frame re-host wait is load-bearing** (`network_manager.gd:return_to_lobby` → `_rehost_after_stop_observed`). One frame is not enough; the stale `on_server_stop` kills the new loop.
2. **Offline fallback needs the manual `NetworkTime.start()`** (`network_manager.gd`).
3. **`CLAUDE.md` was stale** — boot is now `await NetworkManager.boot_to_lobby()` (direct, `world/main.gd:33`), and `class_select.gd` no longer exists outside `backup/`.
4. **Peer-1 hardcoding everywhere** — `spawn_manager.gd:15`, `131`; `leaderboard_singleton.gd:236-258`; `loadout_menu.gd:869`; `host_server_area.gd:53-54`. Collapses if the server is ever not peer 1.
5. **`NetworkManager` owns the client's `NetworkTime.start()`** — netfox's `on_client_start` listener is disconnected in `join_party()`, and the start lives at the end of the `_on_connected_to_server()` coroutine, after the settle wait and the tick-rate adoption.
6. **`_sync_existing_players_to_peer` one-frame defer** (`spawn_manager.gd:37`).
7. **`map_path` only set on the host path** (`network_manager.gd`).
8. **`_request_loadout` sender validation** (`loadout_menu.gd:879-881`) depends on human ids always being `str(network_id)`.
9. **First spawn ~1 s delay** (`player.gd:17`, `503`).
10. **`loadout_menu.gd:859-860` comment drift** — the sync is via `visibility_changed`, not `_process`.

---

## Stage 13 — Non-blocking local flow (title, match menu, staging, pause, results)

Implemented 2026-11-17. Applies when `world_1._new_flow_eligible()` is true:
- role `OFFLINE` (default/--offline/--lobby shell), or
- role `LISTEN_SERVER`/`CLIENT` with `MatchSession.role != NONE` (match session).

`--legacy-p2p` and legacy P2P joins keep the old mandatory Loadout flow.

### 13.1 Title
`world/title_screen.gd` is a local CanvasLayer created by `world_1.gd`. It is
shown only on an OFFLINE boot when `GameManager.title_seen` is false. It owns
`ui_open` and the mouse and gives the lobby a full-screen dark cover; no 3D
content is created or moved. Click/Enter/Space emits `start_requested`, is
consumed, and frees the layer.

Visually it is the map thumbnail pipeline reused as a backdrop: a `MapData`
image (2fort, or the first playable map) at 38 % opacity, a vertical ink
gradient, the Anton wordmark, a red rule, and a pulsing
"CLICK TO DEPLOY". All fonts and colours come from `UITheme`.

`world_1._on_title_start()` sets `title_seen`, applies
`GameManager.local_loadout` (or rolls one through `player/loadout_profile.gd`),
and calls `Player.rpc_spawn_now()` so the local player appears without the
normal 1 s respawn countdown. Returning to the lobby does not show the title
again; the stored build is applied and the player spawns immediately.

### 13.2 Build store
`GameManager.local_loadout` is a process-local dictionary of resource paths
(`class_path`, `character_path`, `primary_path`, `secondary_path`,
`melee_path`, `randomize_on_death`). The Loadout screen restores it on open and
writes it on confirm. It is not saved to disk yet.

### 13.3 Match Menu (HostServer is the globe)
`world/host_server_area.gd` no longer opens `host_menu.tscn`. It opens
`world/globe_menu.gd` on the existing HostServer Area3D, with a crosshair HUD
prompt (`ui/interaction_prompt.gd`: keycap `E` + "MATCH MENU"). The menu has
three tabs:
- **Start Match** — a map-card grid built from `MapData.map_image`
  thumbnails (the source is `ConnectionUtils.scan_map_data()`); hovering or
  selecting a card fills the briefing panel with the large preview, map name,
  mode badge and mode description. `CREATE MATCH` starts an in-process listen
  server in the lobby map (or a lobbyd match when `LobbyClient` is enabled).
- **Find Match** — merged LAN (`LanDiscovery`) and lobbyd cards. LAN rows show
  the map thumbnail when the announced map name matches a `MapData`; the
  direct-IP field remains, using the 6-character `ConnectionUtils` IP code.
- **Party** — disabled placeholder; the party service is not implemented.

`scan_map_data()` ignores entries with no gameplay mode, so tool scenes
(`map_thumbnail_generator`) can never be listed as playable maps.

`GameManager.pending_match_map` carries the selected target into the staging
world. `MatchSession.target_map_path` broadcasts it to joined peers.

### 13.4 Staging room (agent select)
`world/staging_room.gd` is a local CanvasLayer shown while
`MatchSession.phase` is STAGING/COUNTDOWN/LOADING, or while a client is waiting
to JOIN IN PROGRESS. The staging map is still the 3D lobby map; the room is
only an overlay.

Layout:
- The selected map's `MapData.map_image` is a full-screen background at ~42 %
  opacity behind an ink scrim.
- Header: map name, mode + description, phase, player count, LEAVE.
- Map row: a large preview plus a horizontal **map-card picker** (host only).
- Roster columns in canonical order **SPI → SCI → FFA**, but only the teams the
  selected map's mode uses are shown: **Deathmatch → FFA only**, every other
  mode → **SPI and SCI**. With no map selected the team layout (SPI/SCI) is the
  default. Each column has a colour header, a player count, `+ BOT` (host) and
  a `JOIN` button (`CURRENT`, disabled, on the local player's team). The server
  normalizes anyone on a hidden team onto a valid one (balanced, ties to the
  first column) every refresh, and again on START. Roster cards show the
  player's character portrait (from the replicated
  `Player._loadout_character_path`), name, agent, HOST/BOT/YOU tags, and
  READY/WAITING.
- The screen is **fully opaque**: an ink base covers the whole viewport, the
  map thumbnail is drawn over it and dimmed by the scrim. The staging map's 3D
  view (and the local player's body) must never be visible between panels.
- Bottom: **SELECT AGENT** strip grouped by the three classes, `EDIT LOADOUT`,
  and `LOCK IN` (the READY flag), then JOIN IN PROGRESS / START GAME.

While the overlay is open, `GameManager.suppress_gameplay_hud` is set so the
player HUD (health/ammo/ability discs) and the mode HUD/kill feed cannot show
through the scrim. It is a local, non-dev flag: the dev-menu hide toggles and a
world swap reset it independently.

Picking an agent applies the build immediately through
`world_1.apply_local_loadout(build, false)` — `LoadoutProfile.build_for_character`
keeps a weapon the new class still offers, otherwise takes the first of each
column. `EDIT LOADOUT` opens the Loadout screen in `staging_mode`: the menu is
raised above the staging layer and confirm returns to staging with `ui_open`
and the mouse still visible instead of capturing input for gameplay.

Client-host staging actions go through `MatchSession` RPCs:
`request_set_staging_map`, `request_add_bot`, `request_set_ready`,
`request_set_team` (direct SPI/SCI/FFA join), `request_switch_team` (legacy
toggle), `request_start_match`, `request_end_match`, and
`request_join_in_progress`. The server re-checks `host_player_id` where needed.

### 13.4b Asset Viewer (dev)
`world/asset_viewer_area.gd` opens `world/asset_viewer.gd` on E. It is a local
dev tool with two tabs sharing one 3D preview:

- **Effects** — the four live scene effects (`effects/muzzle_flash.tscn`,
  `bullet_impact.tscn`, `explosion.tscn`, `rocket_impact/rocket_impact.tscn`)
  plus every `ToonExplosion.effect_catalog()` (32) and `ToonTrail.catalog()`
  (32) preset. The shared PREVIEW SPEED slider (persistent across both tabs,
  with a numeric `×` readout) and a SCALE slider drive the running effect.
  Both persist across effect selections (`SCALE` is user state, not a
  per-entry default; every entry's authored default is `1.0`) and both have a
  RESET button that appears only while the value differs from its default.
  LOOP re-fires one-shots. Toon trails are painted by a nozzle that follows
  the cursor over the preview, with an AUTO FLIGHT toggle that flies a looping
  path. The cursor plane sits 1.5 m behind the stage point (away from the
  camera) so the trail reads at depth instead of in the viewer's face.
  **MANNEQUIN FOR SCALE** adds a stock mannequin beside the stage as a
  real-world size reference; it is hidden on the Agents tab. The orbit, pan
  and zoom you set are preserved when switching to another effect — only the
  first entry into the Effects tab frames the camera.
- **Agents** — every `Character` under `res://player/characters`, every
  `Weapon` under the weapon folders (class restrictions ignored; grouped into
  ASSAULT / ASSASSIN / ASSISTANCE / SHARED / TF2 / OTHER with counts), plus a
  **NO WEAPON** row that empties the hand. A **locomotion preview** drives the
  real AnimationTree: a continuous joystick sets the walk/crouch/sprint blend
  direction and CROUCH / WALK / SPRINT buttons set the ground state; a RESET
  appears when the pad/state differ from forward-walk. This path forces
  `HoldBlend` to `0.0`. Below it are the mannequin's full animation list
  (including the equipped weapon's injected human-anim library) and the weapon
  model's own animation list. Playing a weapon clip **also plays its paired
  human clip**, resolved through the weapon model's `WeaponAnimGroup`
  (`gun_anim` → `human_anim`), so shoot/reload/hold previews match in-game.
  LOOP applies to whichever clip is playing; human and weapon clips are
  mutually exclusive (choosing one stops the other).

Implementation notes:
- `world/loadout/loadout_preview_rig.gd` gained an `EFFECT` view mode (the
  pivot is hidden, the camera keeps orbit/pan/zoom and looks at a `_focus`
  point), `screen_to_stage()` (container UV → camera-plane world point), and raw
  animation browsing. Raw clips set `AnimationTree.active = false`; the source
  `Animation` is duplicated into a runtime `__viewer` library so loop mode never
  mutates the shared GLB resource, and the library is removed on stop.
- `world/asset_viewer_catalog.gd` owns the explicit scene-effect list and lazily
  scans characters/weapons.
- `world/asset_viewer/effect_preview.gd` spawns and loops the effect nodes.
  The impact normal is captured once when an effect is selected, so orbiting
  the camera does not make the burst snap back to face the viewer on every
  loop; selecting the effect again re-captures it. `toon_trail.gd`,
  `toon_explosion.gd` and `rocket_impact.gd` gained a `speed_scale` export
  (default 1.0), and `bullet_impact.gd` gained `auto_release` so the preview
  instance never enters the gameplay impact pool.
- RMB pan is **camera-plane panning**, shared by both tabs: the rig offsets the
  agent pivot / effect focus along the camera's own right/up axes
  (`_base_focus + basis.x * _pan.x + basis.y * _pan.y`). The effect focus keeps
  the 0.6 m stage height, so the first drag cannot snap the camera down and the
  drag direction stays correct after orbiting. World X/Y panning was wrong as
  soon as `_orbit_yaw` changed.
- Orbit/zoom is stateful for the whole session. Wheel zoom is multiplicative
  over `ZOOM_MIN = 0.1` .. `ZOOM_MAX = 8.0` (shared with the loadout screen).
  `enter_effect_view()` resets pan/focus only when it actually enters from
  character mode; switching effects keeps the camera, and re-showing the tab
  never re-frames it. Camera state is **not** carried between tabs: entering
  Agents calls `reset_character_view()` (its own default orbit/zoom), and
  entering Effects clears the framing flag so the next entry re-frames once
  with the effect's default distance.
- The agents tab shares the same speed value as the effects tab, and the scale
  value persists across effects. Lists use TEAL group headers, a subtle
  alternating row tint and panel chrome from `UITheme`; sliders print their
  numeric value (`speed ×`, `scale`) and show a RESET button only while the
  value is not the default. Status lines above the animation lists show
  `LOCOMOTION` / `SYNCED TO WEAPON` / `PLAYING <clip>` so the current preview
  mode is never ambiguous.
- **Animation speed covers both playback paths.** Raw clips use
  `AnimationPlayer.speed_scale`. `AnimationTree` has no `speed_scale` in Godot
  4.7, so a non-1.0 preview speed puts that tree into
  `ANIMATION_CALLBACK_MODE_PROCESS_MANUAL` and the rig's `_process` calls
  `advance(delta * speed)` while the render timer runs; returning to 1.0
  restores IDLE processing. The loadout screen never calls
  `set_animation_speed`, so its tree stays automatic.
- The menu keeps `class_select` (H) swallowed while open so the loadout screen
  cannot stack on top.

### 13.5 Countdown and map-ready barrier
`NetworkManager.start_staging_match(path)` sets COUNTDOWN, waits 5 s, sets
LOADING with path + SHA-256, swaps the map locally, waits for
`MatchSession.await_map_ready()` (all connected peers ACK via `MAP_READY`;
deadline `MAP_MATCH_DEADLINE_SECONDS`), then sets ACTIVE and `rpc_reset`s the
players. `MatchSession.notify_map_ready()` is sent by `world_1` after a client
installs a LOADING map.

**`MatchSession.set_phase()` now sets the server's own `phase` before the
call_remote broadcast.** Previously the host stayed in STAGING while clients
were told ACTIVE, and the client `welcome` carried the stale phase.

### 13.6 Pause, results, return
`world/pause_menu.gd` opens on Esc when an ACTIVE match has a spawned local
player and no other menu owns input. It shows the local agent portrait + name
and has RESUME, CHANGE AGENT / LOADOUT, LEAVE MATCH and a host-only END MATCH.
There is no settings page.

`world/post_match.gd` opens on `MatchSession.Phase.RESULTS`, shows the winner
label carried by `MatchSession.result_text` and the authoritative
`Leaderboard` stats as a team-coloured scoreboard (portrait, K/D/DMG), then
returns after 10 s. `GameModeComponent.match_won` is wired to
`NetworkManager.end_match()` on the server (including dedicated servers via
`world_1.on_match_map_loaded()`).

### 13.8 UI theme
`ui/ui_theme.gd` is autoloaded as **`UITheme`** (after `GameManager`). Its
`_ready()` installs one `Theme` on the root Window, which cascades to every
Control in the game (CanvasLayer children included). It also owns the palette
constants, the Switzer UI font set and Anton display face, style builders
(`panel_style`, `card_style`, `button_style`, `tab_style`, `slider`), and the
shared widgets used by
the shell: `map_card`, `character_card`, `roster_card`, `stat_row`, `badge`,
`display_label`, `section_label`, `body_label`. New screens must use these
instead of local colours. The written spec is
[`DESIGN_STYLE_GUIDE.txt`](DESIGN_STYLE_GUIDE.txt).

`return_to_lobby()` sets the server phase to CLOSED when leaving a RESULTS
session (so clients skip the resume path), and a LISTEN_SERVER host now
returns to the OFFLINE shell rather than the legacy P2P boot.

### 13.7 Test hooks
- `--test-title-start` dismisses the title automatically.
- `--test-staging-start` + optional `--test-staging-map=res://maps/X.tscn`
  starts a staging match from a host boot.
- `--test-end-match` ends an active host match after 6 s.
- `--test-leaderboard` opens the leaderboard after 1 s so a headless/movie run
  can inspect it.
- `--test-loadout-open` opens the character-select screen after 1.5 s so a
  movie run can inspect it without pressing `H`.
- `--test-staging-map=res://maps/X.tscn` also sets the staging target when
  combined with `--test-host-local` *without* `--test-staging-start`, so an
  idle staging screen shows that map's mode-dependent team columns.
- `--test-range-autokill` (server, debug builds) starts a lobby target run and
  kills the PracticeRange dummy every 2 s, for checking death/respawn
  replication from a second connected peer.
