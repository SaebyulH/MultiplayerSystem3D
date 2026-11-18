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
chosen map on the first free port in `8080-8095`.  The Match Menu's FIND MATCH
tab lists LAN servers (UDP `7355-7370`) and accepts `ip[:port]` / a code.
Nothing else is required.

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

## Deploying to the VPS ("update the VPS")

The live dedicated match server runs on a DigitalOcean droplet. **This is the
exact procedure to run when asked to "update the VPS".**

| Item | Value |
|---|---|
| Host | `godot-server-debian-13` |
| IP | `104.248.149.78` |
| SSH | `ssh -i ~/.ssh/dd_deploy root@104.248.149.78` (key auth, no password) |
| Binary | `/opt/ms3d/server/multiplayer-system-3d-server` (`ms3d:ms3d`, `0755`) |
| Env | `/etc/ms3d/server.env` — `PORT=7000`, `MATCH_ID=local-1`, `MATCH_SECRET=…` |
| Unit | `multiplayer-system-3d-server.service` (enabled; runs `--headless -- --server --port=7000 --match-id=local-1 --no-discovery`) |
| Backup | `/opt/ms3d/server/multiplayer-system-3d-server.bak` (previous release) |

`lobbyd` is **not** deployed on this host — only the one match server.

### Steps

1. **Confirm the local build is newer than the deployed one.** `git log -1
   --format=%ci` must be later than the binary's mtime on the VPS
   (`ls -l /opt/ms3d/server/`). Skip the rest if it is not; deploying a stale
   build looks successful and changes nothing.
2. **Export.** Linux export templates 4.7.2 are installed locally.

   ```sh
   GODOT=/c/tools/godot/godot_console.exe bash server/build_linux.sh
   # prints the sha256 of build/linux/multiplayer-system-3d-server.x86_64 (~1.5 GB)
   ```

3. **Upload beside the live binary** (never over it; the running process is
   killed by overwriting in place on some filesystems). Upload is ~1.5 GB and
   takes 10–20 minutes.

   ```sh
   scp -i ~/.ssh/dd_deploy build/linux/multiplayer-system-3d-server.x86_64 \
       root@104.248.149.78:/opt/ms3d/server/multiplayer-system-3d-server.new
   ```

4. **Verify the upload hash before touching the service.** The remote hash must
   equal the hash `build_linux.sh` printed.

   ```sh
   ssh -i ~/.ssh/dd_deploy root@104.248.149.78 \
       'sha256sum /opt/ms3d/server/multiplayer-system-3d-server.new'
   ```

5. **Swap and restart.** Keep the previous binary as `.bak` (one-generation
   rollback). The server is briefly down between stop and start.

   ```sh
   ssh -i ~/.ssh/dd_deploy root@104.248.149.78 \
     'set -e; systemctl stop multiplayer-system-3d-server; cd /opt/ms3d/server; \
      mv multiplayer-system-3d-server multiplayer-system-3d-server.bak; \
      mv multiplayer-system-3d-server.new multiplayer-system-3d-server; \
      chown ms3d:ms3d multiplayer-system-3d-server; chmod 755 multiplayer-system-3d-server; \
      systemctl start multiplayer-system-3d-server'
   ```

6. **Verify.**

   ```sh
   ssh -i ~/.ssh/dd_deploy root@104.248.149.78 \
     'systemctl status multiplayer-system-3d-server --no-pager | head -8; \
      ss -lunp | grep 7000; \
      journalctl -u multiplayer-system-3d-server -n 15 --no-pager'
   ```

   Expected: `active (running)`, one `*:7000` UDP listener owned by
   `multiplayer-sys`. **The `godotty.gdextension` load errors in the journal are
   pre-existing noise** — they appear on every release build and are not caused
   by the deploy.

### Rollback

```sh
ssh -i ~/.ssh/dd_deploy root@104.248.149.78 \
  'cd /opt/ms3d/server; mv multiplayer-system-3d-server multiplayer-system-3d-server.failed; \
   mv multiplayer-system-3d-server.bak multiplayer-system-3d-server; \
   systemctl restart multiplayer-system-3d-server'
```

### Notes

- Droplet: 2 GB RAM (server peaks near 900 MB against the unit's 1 G cap),
  50 GB disk (a deploy needs ~3 GB free for old + new + backup).
- The server env sets `MATCH_SECRET`, but as of `docs/05-known-issues.md` #149
  the join-grant check is advisory, so direct-IP joins are accepted. Do not
  assume authenticated joins until #149 is closed.
- Never deploy from a dirty tree without saying so — the exported binary embeds
  whatever scripts are on disk, not the last commit.

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
