# Dedicated-server migration

> **Status: P5 complete; P6 verification/deploy assets in place.** The default
> boot is the local 3D shell with no external service: HostServer opens the host
> menu and boots an in-process listen server into the chosen map; JoinParty has
> LAN discovery and Direct IP tabs, both using the match-session handshake.
> `--legacy-p2p` keeps the old auto-host path. Match sessions have stable player
> IDs, local map loading with SHA-256, prediction, reconnect/resume, single-use
> resume tokens, heartbeat/reaper, host migration, RPC authority/owner checks,
> rate limits, and allowlists. The C `lobbyd` is optional (`--lobby=...`).
>
> Remaining operational work: the chunked join state / spawn ACK (#127), the
> map-ready barrier (#126), lobbyd's control channel and child re-adoption
> (#129), LAN announce signing (#133 — accepted risk; the join is still
> handshake-validated), and the 10-match/64-player benchmark + soak (below).
>
> **2026-11-17 local-flow slice:** the default shell now has a one-per-process
> title gate, a stored process build, a HostServer "Match Menu" (Globe),
> 2D staging room, COUNTDOWN/LOADING/ACTIVE transitions with a `MAP_READY`
> barrier, pause menu and results overlay. The party service, host drag-team
> assignment, immediate host migration and live lobbyd status are still not
> implemented; see `ref/NEW_EVENT_FLOW.txt` phases 6–7 and
> `05-known-issues.md` #140–#147.

The netcode is being moved from "every player hosts their own server, peer 1 is
host + party leader" to **dedicated match servers behind a central lobby**. The
game feel stays the same: netfox rollback predicts the local player at 90 Hz,
combat stays server-authoritative.

## Binding decisions

1. **Server-authoritative simulation, client prediction.** The dedicated server
   runs movement and combat; the owning client predicts its own movement and
   reconciles against server state. Combat RPCs remain server-authoritative.
2. **One headless Godot process per match**, plus a small C `lobbyd` for the
   server browser, short codes, admission, signed grants, port allocation, and
   child-process supervision.
3. **Desktop clients over UDP/ENet.** WebSocket/TCP is deliberately rejected for
   gameplay because its head-of-line stalls are unacceptable at 90 Hz.
4. **Scale target:** ≤10 concurrent matches, ≤64 concurrent players, one region.
   Default cap is 16 players per match (`MatchProtocol.DEFAULT_MAX_PLAYERS`).
5. **Keep the 3D lobby.** `maps/main_menu_world.tscn` is used both as a local
   shell (Create Match / browse) and as the networked staging map on the match
   server (loadout, team, Start Match).
6. **Reconnect resumes into the live match.** A dropped player's slot is
   reserved; score, team, and loadout survive.

## Feasibility summary

- **Pure C match server: rejected.** The simulation is GDScript + Jolt, including
  a 10k-line bot AI. Reimplementing it in C would not reproduce collisions
  exactly, so client prediction and server authority would disagree.
- **Headless Godot match server: chosen.** It reuses every simulation line, so
  prediction stays exact by construction. Cost is memory/CPU per process and
  map-load time; measure before scaling past the target.
- **C lobby/supervisor: chosen.** A few thousand lines, negligible CPU/RAM, and
  it keeps process lifecycle out of the game.
- Measured acceptance targets live in the plan and are repeated in
  `05-known-issues.md` when the benchmark harness lands.

## What exists now (P3)

| File | Purpose |
|---|---|
| `network/session_protocol.gd` | Shared wire constants: protocol version, build id, error codes, phase enum, ports, liveness/reconnect/join-state limits, `SERVER_PEER_ID`. |
| `network/match_manifest.gd` | Build-time map manifest: SHA-256 per map scene and `MapData`, canonical manifest SHA, local verification helpers. |
| `tools/map_manifest.gd` / `.tscn` | Headless generator/verifier for `maps/manifest.json`. |
| `maps/manifest.json` | Generated manifest (35 entries as of P0). Regenerate whenever a map or `MapData` changes. |
| `astrofar/.gdignore` | Keeps the reference project out of the main Godot import. |
| `export_presets.cfg` | Linux Dedicated Server preset (`dedicated_server=true`, embedded PCK, text scenes **not** converted to binary). No client preset yet. |
| `network/network_manager.gd` | `Role` enum (`LEGACY_P2P`, `OFFLINE`, `CLIENT`, `DEDICATED_SERVER`, `LISTEN_SERVER`), `is_dedicated_server()`, `create_offline_peer()`, `boot_offline_lobby()`, `boot_listen_server()`, `boot_dedicated_server()`. `create_server()` now takes port/max-clients/fallback so a dedicated bind failure exits instead of silently becoming an offline peer. |
| `world/main.gd` | Command-line boot router (`--server`, `--listen-server`, `--offline`, `--connect=host[:port]`, `--legacy-p2p`, `--port=N`). Default remains legacy P2P. |
| `world/world_1.gd` | Dedicated server skips the kill feed, dev menu, spectator controller and HUD/menu visibility, and tells `SpawnManager` not to add a peer-1 player. |
| `world/spawn_manager.gd` | `spawn_local_player` flag: false on a dedicated server. |
| `world/loadout_menu.gd` | `--auto-loadout` test hook (ignored on a dedicated server); stable-id refresh on `welcome`. |
| `network/match_session.gd` | Autoload. Stable-id handshake (`hello`/`welcome`), server roster, node-readiness gate, phase broadcast, client owner binding. |
| `world/world_1.gd` | Match sessions reduce the world `MultiplayerSpawner` to the player scene and load the map locally on clients (hash-verified). Map swaps arrive as `MatchSession.phase_changed`. |
| `player/player.gd` | `player_id` / `owner_peer_id`, `bind_owner_peer()`, `owning_peer_id()`, `is_owned_by_local_peer()`. Prediction is enabled only for the local player on a client. |
| `player/player_input.gd` | `--test-move` test hook (ignored in normal play). |
| `player/player.tscn` | `enable_input_broadcast=false`; state intervals tuned in `Player._ready`. |
| `server/lobbyd/lobbyd.c` + `sha256.c` | C lobby/allocator/supervisor: HTTP JSON API, short codes, UDP port allocation, HMAC-SHA256 grants, `fork`/`execv` of one headless Godot per match, child reaping, SIGTERM drain. |
| `server/lobbyd/Makefile` / `smoke.sh` / `run_dev.sh` | Build, API smoke test (no Godot), and the WSL dev runner that spawns the Windows Godot binary. |
| `network/lobby_client.gd` | Autoload `LobbyClient`: create/list/join HTTP calls; disabled unless `--lobby=http://host:port` is set. |
| `network/join_grant.gd` | HMAC-SHA256 grant verification on the match server (`MATCH_SECRET` or `--match-secret=`). Empty secret = dev accept-all. |
| `network/match_session.gd` | Also hosts `request_start_match` (server re-checks the sender is the room host) and sends the grant in `hello`. |
| `world/match_browser.gd` | Server browser popup, built on `get_tree().root`; lists lobbyd matches, joins by row or code. |
| `world/host_server_area.gd` | Lobby shell: "Create Match" allocates via lobbyd. Lobby staging: "Start Match" opens the map picker. Legacy P2P unchanged. |
| `world/join_party_area.gd` | Lobby enabled: opens the browser; legacy: keeps the IP/code popup. |
| `world/host_menu.gd` | Start Match while connected as a client sends `MatchSession.request_start_match` to the server instead of calling `load_match_map` locally. |

Verified commands (Windows dev, headless):

```sh
# Dedicated server on a dev port
"C:/tools/godot/godot_console.exe" --path . --headless -- --server --port=7770

# Offline 3D lobby shell
"C:/tools/godot/godot_console.exe" --path . --headless --quit-after 240 -- --offline

# Direct-IP client (auto-confirms a loadout so it spawns without input;
# --test-move walks forward and prints the position in the [NTSYNC] line)
"C:/tools/godot/godot_console.exe" --path . --headless --quit-after 900 -- \
    --connect=127.0.0.1:7770 --auto-loadout --test-move
```

Verified on the P2 branch: the client builds the staging map locally, sends
`hello`, receives a stable player id, binds input authority to its own peer,
spawns via the loadout hook, and walks under server simulation without any
`Node not found` RPC errors. Two clients joined the same server; each saw the
other's Player node (`SpawnParent = ["Map", "2", "3"]`) and both moved.

Known remaining join noise: while a joining client is still building its world,
public `MultiplayerSynchronizer` traffic for nodes it has not spawned yet is
dropped by the engine with `Ignoring sync data from non-authority or for missing
node` (#127). It is non-fatal and converges once the nodes exist, but it is the
reason the chunked join state / spawn acknowledgement is still on the list.

`05-known-issues.md` #124/#125 record what the handshake does **not** yet
cover: existing-player state is still pushed by the old `rpc_sync_full_state`
path after node readiness, and there is no `map_ready` barrier on a map swap
(#126).

## No-service local play (default)

Launching with no flags boots the local 3D shell on an `OfflineMultiplayerPeer`
(the offline peer reports `unique_id=1`, so the local player is the leader).

- **Host Match** (`HostServer` zone, the Globe) opens `world/globe_menu.gd`.
  Its Start Match tab picks the target map; CREATE MATCH stores it in
  `GameManager.pending_match_map` and boots a listen server into the **lobby
  staging map**, not directly into the match map. The staging room then owns
  team/bot/ready/start controls. The old `host_menu.tscn` path is legacy.
  Start reaches the match through `NetworkManager.start_staging_match()`:
  COUNTDOWN -> LOADING + `MAP_READY` barrier -> ACTIVE -> respawn.
- **Ports:** the listen server tries `8080`, `8081`, … up to 16 ports and keeps
  the first free one. A second host on one machine therefore hosts on 8081
  instead of exiting. A local host failure (no free port) returns to the shell.
- **Join Match** (`JoinParty` zone) opens a two-tab popup:
  - **LAN**: `LanDiscovery.discover()` probes UDP `7355-7370` on `127.0.0.1`,
    every local /24 broadcast and `255.255.255.255`, and lists hosts (map,
    players/max, state, IP:port). Each host answers on `7355 + (port - 8080)`
    with a JSON announce and a per-process instance id (so the same host found
    at both localhost and its LAN IP appears once). The list refreshes every 2 s.
  - **Direct IP**: `IP[:port]` or a 5-char join code (port defaults to 8080).
  Both join with `join_party(..., use_match_session=true)`, so stable ids,
  local maps, heartbeat and resume apply.
- **Start Match** in staging opens the map picker; a listen host loads the map
  directly, a dedicated host sends `request_start_match`.
- **No lobbyd, no WSL, no second process.** lobbyd is only needed for the
  central server browser (`--lobby=...`). `--no-discovery` disables the LAN
  announce/probe.

Test hooks:

| Flag | Purpose |
|---|---|
| `--test-host-local [--test-host-map=res://maps/X.tscn]` | boot the shell, then host a listen server (optionally into a chosen map) |
| `--test-lan` | boot the shell, discover, print the LAN list, exit |
| `--no-discovery` | disable LAN announce and probe |

Teardown detail: `_remove_game_scene()` uses `queue_free()` **without**
`remove_child()`. Detaching the world first makes `Node.multiplayer` null while
netfox's deferred `process_settings` is still queued, which throws
`get_unique_id on a null value` during the shell → listen-server transition
(`05-known-issues.md` #132).

## C lobby (`lobbyd`)

Build and run inside WSL2 (the Windows Godot binary is spawned through interop;
the Windows client reaches the WSL HTTP server through localhost forwarding):

```sh
cd server/lobbyd
make
bash run_dev.sh                    # port 18080, secret dev-secret, spawns Godot
./lobbyd --no-spawn --port 18081   # API-only, for smoke.sh / curl
bash smoke.sh                      # create/list/detail/join/leave assertions
```

HTTP API (loopback, no TLS in dev; terminate TLS at a proxy in production):

| Endpoint | Purpose |
|---|---|
| `GET /healthz` | liveness |
| `GET /metrics` | live match count |
| `GET /v1/matches` | browser rows: id, code, endpoint, players, max, state |
| `POST /v1/matches` | create → allocate UDP port, spawn the server, return endpoint + grant |
| `GET /v1/matches/{code\|id}` | detail |
| `POST /v1/matches/{code}/join` | join grant |
| `POST /v1/matches/{id}/leave` | decrement the grant count |

Grant token: `base64url(payload).base64url(HMAC-SHA256(secret, payload_b64))`,
payload `{"v":1,"m":<match_id>,"p":0,"e":<exp>,"n":"<nonce>"}`. The match
server rejects it before adding a player (`BAD_TOKEN`). lobbyd allocates UDP
ports `7000-7019`, passes the secret to the child, and reaps the child on exit.

Client routes:

```sh
# Lobby-enabled 3D shell (browse/create zones active)
"...godot_console.exe" --path . -- --lobby=http://127.0.0.1:18080

# Headless vertical-slice tests
"...godot_console.exe" --path . --headless --quit-after 1500 -- \
    --lobby=http://127.0.0.1:18080 --lobby-create --auto-loadout --test-move
"...godot_console.exe" --path . --headless --quit-after 900 -- \
    --lobby=http://127.0.0.1:18080 --lobby-join=ABCDE --auto-loadout --test-move
```

Verified on P3: lobbyd creates and spawns match servers, a Windows client
connects with a validated grant, loads the staging map locally, spawns and
moves; a second client joins by code and sees both players; the host starts
`castle` through `request_start_match` and every peer loads it locally with no
node-not-found errors; the API smoke test passes.

**Dev-only security:** lobbyd passes the HMAC secret to the Windows child on
argv because WSL interop drops `MATCH_SECRET` from its environment (#128), and
with no secret configured the match server accepts any join. Do not expose this
setup publicly; P5 moves the secret off argv and requires one for lobby-spawned
servers. lobbyd has no control channel yet, so the browser's player count is a
count of issued grants and the phase is always `staging`; it also does not
re-adopt live children after a restart (#129).

## Map manifest workflow

Maps are static and large (`maps/bind.tscn` is ~46 MB) and must never cross
ENet. Every peer loads the map from its own build; the handshake carries only
the path plus the expected SHA-256, and a mismatch is rejected before loading.

```sh
# Regenerate after adding or editing a map or MapData resource:
"C:/tools/godot/godot_console.exe" --path . --headless res://tools/map_manifest.tscn

# Verify the shipped manifest (CI / pre-export):
"C:/tools/godot/godot_console.exe" --path . --headless res://tools/map_manifest.tscn -- --check
```

Rules:

- **Regenerate the manifest in the same build that ships the maps.** The exported
  dedicated server and the client must come from the same export.
- **Keep `convert_text_resources_to_binary` disabled** in the dedicated-server
  export preset. Converting `.tscn` to binary changes the file bytes and the
  hashes stop matching (see `05-known-issues.md` #123).
- Do not hand-edit `maps/manifest.json`. The tool owns it.
- `.scn` maps are included; `main_menu_world.tscn` is included because it is the
  staging map.

## Protocol rules

- `MatchProtocol.VERSION` is the handshake version. **Bump it on any RPC shape
  change, netfox configuration change, or join-state schema change.** The client
  and server reject mismatches before any message can be misdispatched.
- `MatchProtocol.BUILD_ID` is version + git hash + manifest SHA in a release
  build; development builds use `"dev"`. Replace the constant at export time
  once the export pipeline exists.
- Error codes are numeric so the C supervisor can log them without a shared
  string table.
- The server is always peer 1; use `MatchProtocol.SERVER_PEER_ID` in client code
  instead of a bare `rpc_id(1, ...)`.

## Reconnect, resume and liveness

- **Resume token:** the server issues `base64url(payload).base64url(HMAC)` on
  every `welcome`, payload `{"v":2,"t":"resume","m":match_id,"p":player_id,"e":exp,"n":nonce}`, and rotates it on each resume. The client stores it in
  `MatchSession.resume_token` and sends it in `hello` after reconnecting.
- **Reserved slot:** on `peer_disconnected` the server keeps the Player node,
  marks the roster entry `RESERVED`, stops that player's sync, and broadcasts
  `set_reserved(true)` so every peer despawns the body. Score, team, and
  loadout live on the node and survive.
- **Resume:** a valid token rebinds the slot to the new ENet peer
  (`bind_peer(player_id, new_peer)`), re-enables sync visibility, respawns the
  Player via the now-reliable `rpc_reset`, sends a fresh `welcome`, and syncs
  existing-player state. The client rebinds input authority and HUD.
- **Tick domain:** the client's world is not rebuilt, so `NetworkTime` is
  stopped during the drop and restarted after the resume; the existing
  rollback synchronizers are reset with `_reset_rollback_history()` **after**
  `start()` (same rule as `_reinit_time`). Without that, input and state stay
  frozen at the pre-drop tick.
- **Liveness:** clients send `heartbeat` every 0.5 s. The server reaps a peer
  it has not heard from in 10 s even if its UDP socket is still open, which
  takes the same reserve path. A reserved slot expires after 90 s; the Player
  node is freed and the leaderboard entry removed.
- **Client reconnect:** `_server_disconnected` starts a retry loop (2 s apart,
  bounded by the 90 s grace) and shows the loading screen. Once `welcome`
  arrives the loop restarts the tick loop and hides it.

Test hooks (debug only):

| Flag | Purpose |
|---|---|
| `--test-drop-after=N` | close the client transport after N s |
| `--test-silent-after=N` | stop heartbeats after N s (server reaps it) |
| `--test-no-reconnect` | drop and return to the lobby instead of resuming |
| `--test-resume-grace=N` | server override for the 90 s grace |

Verified: forced drop resumes the same player id with state/input/movement
restored; a silent client is reaped and resumes; a non-reconnecting client's
slot expires and the Player is freed.

## P5 hardening rules

- **Server-only mutations use `@rpc("authority", ...)`.** `Player.rpc_reset`,
  `_spawn_ragdoll`, `rpc_cheat_death`, pins, fall sounds, ragdoll impulses,
  projectile `hide_model`, and every `Leaderboard` mutation/snapshot.  The old
  `any_peer` + `if is_server()` pattern let a client invoke the method on the
  server; the annotation is the gate.
- **Owner-initiated `any_peer` RPCs gate on `Player.is_rpc_sender_allowed()`**
  (local/server, authority peer, or owning peer): `fire_intent`,
  `calligraphy_release`, ability casts, weapon switch, ADS, charge, shield,
  signal, recoil, empty click, self-knockback.  `owner_peer_id` is replicated in
  the Player's root `MultiplayerSynchronizer` so remote peers can evaluate it.
- **Server-authoritative visual/sound RPCs are `authority`** (hitscan tracer,
  muzzle flash, shot/hit sounds, damage numbers are sender-gated because their
  node authority is the owning peer).
- **Rate limits:** fire intents 240/s, ability casts 60/s per player; the
  heartbeat/pre-auth reapers bound idle connections (20 s pre-auth, 10 s
  heartbeat, 90 s reserved).
- **Single-use resume tokens:** each welcome issues a nonce and the server
  remembers it; only the latest token resumes a slot.
- **Allowlists:** server-start maps must be a `MapData.map_scene_path`; loadout
  paths must be under `res://weapon/`, `res://player/characters/`, or
  `res://player/player_classes/`.
- **Dev cheats are debug-build only.** `_dev_request_is_owner()` returns false
  in release, so god mode/noclip/ammo/stamina/team requests are rejected.

**Host migration:** when the host's reserved slot expires, the server promotes the
lowest surviving **connected** player and broadcasts `host_player_id`; a host
that reconnects inside the grace keeps the role.  A player who joins an
empty-host room becomes host in `hello`.

Still open: LAN announce signing (#133), server-side body-rotation clamping,
and lobbyd's control channel (#129).

## P6 verification and deployment assets

```sh
# Cross-process smoke: manifest, shell boot, host into castle, join + fire,
# LAN discovery, forced-drop resume.  Launches the Windows Godot binary.
powershell -ExecutionPolicy Bypass -File tests/net/run_net_smoke.ps1

# Linux dedicated export (needs the Godot 4.7 Linux export templates)
GODOT=/path/to/godot bash server/build_linux.sh

# Deployment: build/install/systemd/env
cat server/README.md
```

The net smoke passes on the Windows dev machine.  Full coverage, the tool-harness
status table, and the test-hook reference live in
[`tests/net/README.md`](../tests/net/README.md).  The existing
`verify_payload_path` and `verify_toon_world_swap` harnesses fail (map-authoring
and material tooling, tracked as #135/#136); they do not exercise netcode.
**Not yet run:** the 10-match / 64-player CPU/RSS benchmark, the UDP
loss/latency matrix, and the 60-minute soak — they need the target VPS and a
separate load generator.  The benchmark pass/fail targets are in the migration
plan and the P0 notes.

## Migration phases

| Phase | Scope | Exit gate |
|---|---|---|
| P0 | Protocol constants, map manifest, reference isolation, harness skeleton | Baseline reproduces; manifest check passes |
| P1 | `--server` / `--listen-server` / `--offline` boot routes, headless export preset, server skips UI/visual setup | Headless server + 1 client plays |
| P2 | Stable player IDs, handshake, chunked join state, local map load + hash, per-player prediction | 4 clients, late join, map start, no map bytes on wire |
| P3 | C `lobbyd`, browser/codes, process supervision, 3D lobby conversion | 10 matches / 64 players create/join/start/teardown |
| P4 | Resume tokens, reserved slots, authority rebind, heartbeat/reaper | Kill/relaunch restores score/team/loadout |
| P5 | RPC audit, rate limits, allowlists, `_sync_mag` fix | Spoofed sender / tampered loadout rejected |
| P6 | Linux export, systemd, reverse proxy, soak, benchmarks | Targets met |

## Invariants for the new system

- **Player identity is separate from peer identity.** `player_id` is stable across
  reconnect and is the node name and score key; `owner_peer_id` is the current
  ENet peer and is rebindable. Never derive identity from `str(name).to_int()`.
- **Owner authority is re-applied, not inferred.** `Player.owner_peer_id`'s
  setter and `bind_owner_peer()` re-run `_apply_input_authority()` so a client's
  copy of a Player (including the replicated spawn property and a resume rebind)
  always names the real ENet peer as authority; the owning client then calls
  `rollback_sync.process_settings()`, because netfox only rebuilds its per-peer
  property ownership there. See `02-netcode.md`.
- **Maps are local assets.** Only the path and hash go on the wire.
- **The server is the only tick reference.** Clients start `NetworkTime` after
  the map load settles; the server never re-seeds mid-match.
- **Map start is a controlled transition.** `phase_changed(LOADING)` → local load
  → `map_ready` → server swaps → `ACTIVE`, with a 15 s deadline.
- **Join state is bounded and pull-paced.** Chunked, one in flight, ACKed,
  checksummed, applied atomically.
- **Liveness is explicit.** Heartbeats plus a reaper catch frozen peers whose
  UDP socket is still open.
- **Every `any_peer` RPC validates the sender owns the target player.**

## References

- `astrofar/docs/NETCODE.md` and `astrofar/tests/` — the reliability patterns this
  migration borrows: heartbeat/reaper, protocol versioning, bounded join state,
  cross-process failure-injection tests.
- `diplomatic-domination/server/` — the C lobby/supervisor shape and capacity
  numbers.
- `02-netcode.md` — the rollback/RPC split that must survive the migration.
- `03-event-flow.md` — current connection ordering invariants; most will be
  replaced by this part, but the rollback tick-domain rules still apply.
