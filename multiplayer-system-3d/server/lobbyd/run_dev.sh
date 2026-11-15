#!/usr/bin/env bash
# Build and run lobbyd for local development.
#
# Run this inside WSL2.  The match server it spawns is the Windows Godot binary
# (WSL interop), so the Windows client can reach 127.0.0.1:<udp port> directly.
# The HTTP lobby is reachable from Windows through WSL localhost forwarding.
#
#   ./run_dev.sh
#   LOBBY_SECRET=dev-secret ./run_dev.sh --port 18080
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

GODOT_WIN="${GODOT_WIN:-/mnt/c/tools/godot/godot_console.exe}"
PROJECT_WIN="${PROJECT_WIN:-C:/Users/saeby/Documents/MultiplayerSystem3D/multiplayer-system-3d}"
LOG_DIR="${LOG_DIR:-/tmp/ms3d-matches}"

make

exec ./lobbyd \
	--bind 127.0.0.1 \
	--port "${LOBBY_PORT:-18080}" \
	--advertise-host "${LOBBY_ADVERTISE:-127.0.0.1}" \
	--godot "$GODOT_WIN" \
	--project "$PROJECT_WIN" \
	--log-dir "$LOG_DIR" \
	"$@"
