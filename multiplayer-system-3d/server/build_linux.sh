#!/usr/bin/env bash
# Export the Linux Dedicated Server preset.
#
# Requires the Godot 4.7 export templates for Linux.  The exporter is the same
# Godot binary used to run the editor; pass it with GODOT=/path/to/godot.
#
#   GODOT=/mnt/c/tools/godot/godot_console.exe bash server/build_linux.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="$ROOT/build/linux/multiplayer-system-3d-server.x86_64"

mkdir -p "$(dirname "$OUT")"
"$GODOT" --headless --path "$ROOT" \
	--export-release "Linux Dedicated Server" "$OUT"

test -f "$OUT" || { echo "export produced no binary: $OUT" >&2; exit 1; }
sha256sum "$OUT"
