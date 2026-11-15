# Dedicated server & lobby

Two independent pieces:

- **Match server** — one headless Godot process per match.  `--server --port=N
  --match-id=...`; peer 1 is the authority and is **not** a player.  Join grants
  are validated with `MATCH_SECRET` (environment) or `--match-secret=`.
- **`lobbyd`** — optional C lobby/allocator/supervisor.  It serves the server
  browser, allocates UDP ports `7000-7019`, spawns a match server per room, and
  issues HMAC grants.  Not needed for local LAN play.

Full architecture and protocol: [`../docs/07-dedicated-server.md`](../docs/07-dedicated-server.md).

## Local (no lobby, no WSL)

```sh
"C:/tools/godot/godot_console.exe" --path .
```

HostServer opens the host menu; Start boots a listen server directly into the
chosen map on the first free port in `8080-8095`.  JoinParty lists LAN servers
(UDP `7355-7370`) or accepts `ip[:port]` / a code.  Nothing else is required.

## Build the Linux dedicated server

1. Install the Godot 4.7 **Linux export templates** (Editor → Manage Export
   Templates), or place them in the engine's template directory.
2. Export:

```sh
GODOT=/path/to/godot bash server/build_linux.sh
# build/linux/multiplayer-system-3d-server.x86_64
```

The preset lives in `export_presets.cfg` (`dedicated_server=true`, embedded PCK,
text scenes **not** converted to binary so `maps/manifest.json` keeps matching).

## systemd

```sh
sudo useradd --system --home /opt/ms3d --shell /usr/sbin/nologin ms3d
sudo install -d -o ms3d -g ms3d /opt/ms3d/server
sudo install -m 0755 build/linux/multiplayer-system-3d-server.x86_64 \
    /opt/ms3d/server/multiplayer-system-3d-server
sudo install -d /etc/ms3d
sudo install -m 0600 server/systemd/server.env.example /etc/ms3d/server.env
sudo editor /etc/ms3d/server.env          # set MATCH_SECRET, PORT, MATCH_ID
sudo install -m 0644 server/systemd/multiplayer-system-3d-server.service \
    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now multiplayer-system-3d-server
```

One process hosts one match.  For multiple matches, run the C lobby supervisor
instead; see `lobbyd/README` content in `docs/07-dedicated-server.md`.

## Security notes

- Set `MATCH_SECRET` in the environment file; a server started without it
  accepts any join.  Do not expose such a server publicly.
- `lobbyd` currently passes the secret on the child's argv for the
  WSL/Windows-interop dev path (#128); a production Linux deploy should use the
  environment file and `--no-discovery`.
- LAN discovery is unauthenticated metadata; the join is still validated by the
  handshake (#133).

## Smoke test

```sh
powershell -ExecutionPolicy Bypass -File tests/net/run_net_smoke.ps1
```

Covers manifest validity, shell boot, host into a map, join + fire, LAN
discovery, and forced-drop resume.  Requires the Windows dev machine (the
script launches the Windows Godot binary).
