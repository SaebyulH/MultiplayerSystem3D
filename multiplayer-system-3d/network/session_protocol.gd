extends RefCounted
class_name MatchProtocol

## Wire-level constants shared by the desktop client, the dedicated match server,
## and the C lobby supervisor (`server/lobbyd`).
##
## Everything here is part of the network contract.  Bump [constant VERSION] on
## any RPC shape change, netfox configuration change, or join-state schema
## change; the client and server reject each other on a mismatch before any
## message can be misdispatched.  See `docs/07-dedicated-server.md`.

## Handshake version.  The C supervisor keeps the same integer.
## v2: `welcome` carries a resume token and `hello` accepts one.
const VERSION: int = 2

## Build identity.  `BUILD_ID` is version + git hash + map-manifest SHA in a
## release export; development builds fall back to the constant below.  It is
## sent in `hello` and must match on both ends.
const BUILD_ID: String = "dev"

## The server is always peer 1.  Kept as a named constant so client code stops
## hard-coding `rpc_id(1, ...)` scattered across the project.
const SERVER_PEER_ID: int = 1

## First stable player id.  Peer ids are transport-local and change on every
## reconnect; player ids are assigned by the lobby and survive a resume.
const FIRST_PLAYER_ID: int = 2
const MAX_PLAYER_ID: int = 65

## Default cap per match.  64 concurrent players total across <=10 matches is
## the sizing target; individual matches default to 16.
const DEFAULT_MAX_PLAYERS: int = 16

## Match server ports.  UDP carries gameplay; the supervisor's control socket
## is loopback-only and never exposed.
const MATCH_UDP_PORT_MIN: int = 7000
const MATCH_UDP_PORT_MAX: int = 7019
const MATCH_CONTROL_PORT_MIN: int = 9000
const MATCH_CONTROL_PORT_MAX: int = 9019

## LAN discovery (no central service).  Each host binds `base + (game_port -
## MATCH_UDP_PORT_MIN)`, so multiple hosts on one machine get distinct ports.
const LAN_DISCOVERY_PORT_BASE: int = 7355
const LAN_DISCOVERY_PORT_RANGE: int = 16
const LAN_PROBE_MAGIC: String = "MS3D_PROBE1"
const LAN_ANNOUNCE_MAGIC: String = "MS3D_ANNOUNCE1"

## Development defaults, loopback-only.
const DEV_MATCH_UDP_PORT: int = 7770
const DEV_CONTROL_PORT: int = 9070

## Liveness.  A client that stops heartbeating is reaped even if its UDP socket
## is still open (frozen tab / hung process), modelled on the astrofar reaper.
const HEARTBEAT_INTERVAL: float = 0.5
const PEER_TIMEOUT: float = 10.0
## A client builds its world before sending `hello`, which can take several
## seconds on a cold/slow machine.  Do not reap it before that.
const PREAUTH_TIMEOUT_SECONDS: float = 20.0
const SUPERVISOR_HEARTBEAT_INTERVAL: float = 1.0
const SUPERVISOR_HEARTBEAT_TIMEOUT: float = 10.0

## Reconnect.  A dropped player's slot is reserved for this long before it is
## abandoned; the Player node is not freed in that window.
const RESUME_GRACE_SECONDS: float = 90.0
const RESUME_TOKEN_TTL_SECONDS: int = 900

## Bounded join state.  Dynamic state only, never map bytes.
const JOIN_STATE_CHUNK_BYTES: int = 4096
const JOIN_STATE_MAX_BYTES: int = 1024 * 1024
const JOIN_STATE_CHUNK_TIMEOUT: float = 2.0
const JOIN_STATE_CHUNK_RETRIES: int = 3

## Map loading.  Maps live on disk on every peer; the wire carries only the id
## and hash.  `bind.tscn` alone is ~46 MB and must never cross ENet.
const MAP_MANIFEST_PATH: String = "res://maps/manifest.json"
const MAP_MATCH_DEADLINE_SECONDS: float = 15.0

## Room lifecycle reported by the match server to the supervisor and clients.
enum Phase {
	ALLOCATING,
	STARTING,
	STAGING,
	COUNTDOWN,
	LOADING,
	ACTIVE,
	RESULTS,
	DRAINING,
	CLOSED,
	CRASHED,
}

## `session_error` codes.  Numeric so the C supervisor can log them without a
## shared string table.
enum ErrorCode {
	BAD_MESSAGE = 1,
	UNSUPPORTED_VERSION = 2,
	BUILD_MISMATCH = 3,
	MATCH_FULL = 4,
	MATCH_STARTED = 5,
	BAD_TOKEN = 6,
	SESSION_EXPIRED = 7,
	RATE_LIMIT = 8,
	MAP_MISMATCH = 9,
	PHASE_BUSY = 10,
	SERVER_BUSY = 11,
}

## Ids for the gameplay control messages carried over Godot RPC.  netfox input
## and state traffic is separate; this enum only covers the session layer.
enum Message {
	HELLO = 1,
	WELCOME = 2,
	JOIN_STATE_HEADER = 3,
	JOIN_STATE_CHUNK = 4,
	JOIN_STATE_ACK = 5,
	JOIN_STATE_DONE = 6,
	BIND_PEER = 7,
	HEARTBEAT = 8,
	REQUEST_START_MATCH = 9,
	MAP_READY = 10,
	PHASE_CHANGED = 11,
	SESSION_ERROR = 12,
}
