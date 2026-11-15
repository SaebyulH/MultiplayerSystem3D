# Netcode tests

One cross-process smoke script; no unit tests or linter.  The project is
validated by running it.

```powershell
powershell -ExecutionPolicy Bypass -File tests/net/run_net_smoke.ps1
```

Uses the Windows Godot binary at `C:/tools/godot/godot_console.exe` and a local
host on the first free port in the `8092` range.  Logs are written to
`$env:TEMP\net-smoke`.

## What it covers

1. `maps/manifest.json` matches the build (`--check`).
2. Default boot is the local shell with no server and no script errors.
3. Host into `res://maps/castle.tscn` (`--test-host-local --test-host-map=...`).
4. Client joins; asserts `input_auth=true` and server-authoritative ammo sync
   (`--test-fire`).
5. LAN discovery finds the host and reports `castle`.
6. Forced transport drop → reconnect with a single-use resume token
   (`--test-drop-after`, `--test-resume-grace=5`).

## Status

| Harness | Result |
|---|---|
| `tests/net/run_net_smoke.ps1` | pass |
| `tools/map_manifest.tscn -- --check` | pass |
| `tools/verify_brush_entities.tscn` | pass |
| `tools/verify_payload_path.tscn` | 2 failures (#135, map-authoring fixture) |
| `tools/verify_toon_world_swap.tscn` | 1 failure (#136, material converter) |
| `tools/rim_layer_check.tscn` | exit 0 (netfox teardown warnings are noise) |

Run a tool harness directly:

```sh
"C:/tools/godot/godot_console.exe" --path . --headless res://tools/<name>.tscn
# exit code is the number of failed assertions
```

## Not covered

- 10-match / 64-player CPU/RSS benchmark, UDP loss/latency matrix, 60-minute soak.
- UI button paths (host menu, LAN list, Direct IP) — headless hooks drive the
  same network calls, not the clicks.
- Post-resume firing (#137).
- Late-join sync-warning storm / chunked join state (#127).
- Map-start readiness barrier (#126).

## Debug test hooks

| Flag | Effect |
|---|---|
| `--test-host-local [--test-host-map=...]` | boot the shell, then host a listen server (optionally into a map) |
| `--test-lan` | scan the LAN range, print servers, exit |
| `--test-fire` | hold primary fire |
| `--test-move` | walk forward; adds `pos=` to the `[NTSYNC]` line |
| `--test-drop-after=N` | force a transport drop after N seconds |
| `--test-silent-after=N` | stop heartbeats after N seconds (server reaper) |
| `--test-no-reconnect` | drop without resuming; server grace expiry |
| `--test-resume-grace=N` | server override for the 90 s resume grace |
| `--no-discovery` | disable LAN announce/probe |
