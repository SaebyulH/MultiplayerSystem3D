# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Class-based team FPS (TF2-style hero shooter) built in **Godot 4.7** (Forward Plus renderer) using the **netfox 1.35.3** addon for rollback netcode. There are no tests or linter — validation is done by running the game.

## Running the game

There is no build step, test suite, or lint command. The project is opened and run in the Godot editor, or launched headless/from the CLI:

```sh
# Launch the game (main scene is res://world/main.tscn)
godot --path .

# Headless server (for dedicated-server testing)
godot --path . --headless
```

Multiplayer is tested by running multiple instances: one **Host** (the host is also a player, peer ID 1), then additional clients that **Join** using the IP or the 6-char base-62 join code shown in the menu. The default port is `8080` (`NetworkManager.SERVER_PORT`). Bots can be added at runtime via the `add_bot_spi` / `add_bot_sci` / `add_bot_ffa` input actions (server only).

## Autoloads (singletons)

Defined in `project.godot` under `[autoload]`:

- **NetworkManager** (`network/network_manager.gd`) — game-specific wrapper. Creates the ENet server/client, instantiates the game scene, and tears down connections back to the main menu.
- **Leaderboard** (`ui/leaderboard_singleton.gd`) — server-authoritative score tracking (kills/deaths/damage/heals/killstreaks). Clients never write directly; they call `request_*()` which sends an RPC to peer 1.
- **GameManager** (`singletons/game_manager.gd`) — a tiny global holder: `spawn_parent` (node all Players live under) and `game_mode_component`. `Map` populates these on `_enter_tree`.
- **NetworkTime, NetworkTimeSynchronizer, NetworkRollback, NetworkEvents, NetworkPerformance** — provided by netfox (see `addons/netfox/`). Do not edit.
- **Console** — in-game console addon (`addons/console/`).

## Networking model: rollback + server-authoritative split

The project deliberately splits simulation responsibility:

- **Movement, jumping, crouch, dash, shoulder-charge** are **rollback-simulated**. Inputs (`input_dir`, `jump_input`, `crouch`, `dash_input`, `charge_trigger_dir`) are rollback-synced through the `RollbackSynchronizer` on the Player; `Player._rollback_tick()` re-simulates deterministically. `PlayerInput._gather()` is connected to `NetworkTime.before_tick_loop` and fills these once per tick.
- **Firing, reload, weapon switching, damage, status effects** are **server-authoritative RPC**. The owning client polls `primary/secondary/tertiary_fire_held` in `_physics_process` (NOT in the rollback tick) and sends `fire_intent` to the server; the server re-validates and is the only place ammo is deducted.

Consequence: fire-held flags must **never** be added to the `RollbackSynchronizer` input properties — netfox stomps them on re-simulation ticks. See the header comments in `player/player_input.gd` and `player/weapon_controller.gd`.

Other conventions:

- **Player name == `str(network_id)`** for human players (`entity_id` == `name`), and `"bot_N"` for bots. `GameManager.find_player(id)` looks up by node name.
- **Server is peer 1**, and the host is also a player. Bots are fully server-authoritative (`is_bot` set before `add_child`).
- Player authority is wired in `Player._enter_tree`: humans get authority over their `player_input`/`body`, the server keeps authority on the rest.

## Player & character architecture

- `player/player.gd` (`class_name Player`) is a `CharacterBody3D`. Movement is Quake/Source-style (ground friction vs. `_air_accelerate`), with stamina, dash/dash-jump, crouch/slide, double-jump, and a server-driven shoulder-charge carry/stun.
- `Player.Team` enum is `{ SPI, SCI, FFA }` (FFA = damage anyone). `TEAM_COLORS`: SCI blue, SPI red.
- **Characters vs. Classes** are both `Resource`s:
  - `Class` (`player/class.gd`) lists `primary_weapons` / `secondary_weapons` / `melee_weapons` and `characters`.
  - `Character` (`player/character.gd`) carries stat multipliers (health, speed, regen, etc.), an `abilities` list, and a `character_scene` world model.
- Character models are cosmetic: the built-in mannequin always drives animation via `AnimationTree`; a spawned character model copies its pose per-bone by name (`_copy_mannequin_pose`).
- Team tinting / wallhack outlines / health-bar reveal are **purely client-side** (`Player._update_visibility`), driven by status-effect flags, and never networked.

## Weapon architecture

- `Weapon` (`weapon/weapon.gd`) is a `Resource` containing an `Array[WeaponFire]`. Each `WeaponFire` has an `ActionType`: `SHOOT`, `ADS`, `SHIELD`, or `SIGNAL`.
- `WeaponController` (`player/weapon_controller.gd`) owns the active loadout and all fire/reload/switch state. `set_weapons()` is the only correct runtime entry point; it deep-copies resources and resets state.
- Weapons live in `weapon/` grouped by role (`assault_weapons/`, `assassin_weapons/`, `assistance_weapons/`, `tf2/`, etc.). Projectiles are in `weapon/projectiles/`.

## Game modes

`components/game_mode_component.gd` (`GameModeComponent`) is a server-side state machine:

- `GameMode` enum: `ESCORT`, `DOMINATION`, `KOTH`, `HYBRID`, `CONTROL`, `DEATHMATCH`.
- `PhaseState` enum: `WAITING_FOR_PLAYERS → SETUP → OBJECTIVE_LOCKED → ACTIVE → OVERTIME → ROUND_END → MATCH_END`.
- Mode logic is delegated to sub-nodes created in `_create_mode_nodes()`: `EscortMode`, `HybridMode`, `KothMode`, `DominationMode`, `DeathmatchMode` (`components/*_mode.gd`). Each exposes `get_sync_state()` / `apply_sync_state()` / `tick()`.
- State is pushed to clients at 10 Hz via `_rpc_sync_state` (`SYNC_INTERVAL`). Objective nodes (`ControlPoint`, `PayloadNode`) self-register with the component via `register_control_point` / `register_payload`.
- `DeathmatchMode` polls the `Leaderboard` singleton rather than tracking kills itself.

## Status effects

`components/status_effect/status_effect_manager.gd` (`StatusEffectManager`) is server-authoritative: effects tick only on the server, remaining times are pushed to clients via RPC. Effect types (`bleed`, `burn`, `stun`, `slow`, `gravity_flip`, `invincible`, `pinned`, `poison`, `enlarge`, etc.) are subclasses of `StatusEffect` under `components/status_effect/effects/`.

## Maps

`maps/` contains map scenes. Each has a `Map` node (`maps/map.gd`) that auto-discovers spawn `Marker3D`s by name (contains `spawn`, plus `spi`/`sci` team label; unlabeled spawns are added to both pools for FFA) and holds a `GameModeComponent` child. `despawn_location` is where dead players are parked.

## Key conventions & gotchas

- **Godot shares `Resource`/sub-resource instances across scene instances.** Per-player state that mutates must be duplicated per instance — the code does this for weapons (`duplicate(true)` in `set_weapons`), collider `Shape3D`s, `AnimationTree.tree_root`, and team-tint materials. Follow the same pattern when adding new per-instance mutable state.
- **The server (peer 1) is the authority for score, ammo, damage, effects, and game-mode state.** Client code should gate mutations behind `multiplayer.is_server()` or go through a `request_*`/`fire_intent`-style RPC.
- Sound effects go through `AudioPool` (`effects/audio_pool.gd`), a pooled one-shot player — use it instead of spawning a fresh `AudioStreamPlayer` per event (footsteps, hits, muzzle blasts).
- `.claude/Strafing.txt` contains the original design note for the Quake/Source air-strafe movement math.
