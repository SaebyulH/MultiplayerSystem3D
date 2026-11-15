#!/usr/bin/env bash
# API smoke test for lobbyd.  Runs with --no-spawn, so it needs no Godot.
#
#   make smoke
#
set -euo pipefail

BIN="${BIN:-./lobbyd}"
PORT="${PORT:-18081}"
SECRET="${SECRET:-smoke-secret}"

"$BIN" --bind 127.0.0.1 --port "$PORT" --secret "$SECRET" --no-spawn \
	--log-dir /tmp/ms3d-lobbyd-smoke >/tmp/ms3d-lobbyd-smoke.log 2>&1 &
LOBBY_PID=$!
cleanup() { kill "$LOBBY_PID" 2>/dev/null || true; wait "$LOBBY_PID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 100); do
	if curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null; then break; fi
	sleep 0.05
done

python3 - "$PORT" <<'PY'
import json, sys, urllib.request

port = int(sys.argv[1])
base = f"http://127.0.0.1:{port}"

def call(method, path):
    req = urllib.request.Request(base + path, method=method)
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())

status, created = call("POST", "/v1/matches")
assert status == 201, (status, created)
for key in ("match_id", "code", "endpoint", "grant"):
    assert key in created, created
assert created["host"] is True
assert len(created["code"]) == 5
assert created["endpoint"].startswith("127.0.0.1:")
assert "." in created["grant"]

status, listed = call("GET", "/v1/matches")
assert status == 200
assert any(m["code"] == created["code"] for m in listed["matches"]), listed

status, detail = call("GET", f"/v1/matches/{created['code']}")
assert status == 200 and detail["match_id"] == created["match_id"], detail

status, joined = call("POST", f"/v1/matches/{created['code']}/join")
assert status == 200 and joined["host"] is False, (status, joined)
assert joined["players"] == 2, joined

status, left = call("POST", f"/v1/matches/{created['match_id']}/leave")
assert status == 200 and left["players"] == 1, (status, left)

status, _ = call("GET", "/v1/matches/NOPE1")
assert status == 404, status

status, second = call("POST", "/v1/matches")
assert status == 201
assert second["code"] != created["code"], "codes must be unique"
assert second["endpoint"] != created["endpoint"], "ports must be unique"

print("lobbyd smoke: OK")
PY
