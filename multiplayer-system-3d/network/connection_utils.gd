class_name ConnectionUtils
## Stateless helpers shared by the (now-bypassed) 2D main menu and the 3D
## lobby interaction popups: base-62 join codes, LAN IP detection, and map
## scanning.  Pure static methods — no autoload registration required.

const SERVER_PORT: int = 8080

# ─────────────────────────────────────────────
#  Base-62 Join Code  (0-9 A-Z a-z)
# ─────────────────────────────────────────────
#  62^6 ≈ 56.8 billion > 2^32 (IPv4 address space),
#  so every IP fits in exactly 6 characters.

const B62: String = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
const CODE_LENGTH: int = 6


static func ip_to_code(ip: String) -> String:
	var parts := ip.split(".")
	if parts.size() != 4:
		return ""
	var value: int = 0
	for i in range(4):
		value = (value << 8) | clampi(parts[i].to_int(), 0, 255)
	return _b62_encode(value)


static func code_to_ip(code: String) -> String:
	if code.length() != CODE_LENGTH:
		return ""
	var value := _b62_decode(code)
	if value < 0:
		return ""
	var a := (value >> 24) & 0xFF
	var b := (value >> 16) & 0xFF
	var c := (value >>  8) & 0xFF
	var d :=  value        & 0xFF
	return "%d.%d.%d.%d" % [a, b, c, d]


static func _b62_encode(value: int) -> String:
	var result := ""
	var v := value
	for _i in range(CODE_LENGTH):
		result = B62[v % 62] + result
		v /= 62
	return result


static func _b62_decode(code: String) -> int:
	var value: int = 0
	for ch in code:
		var idx := B62.find(ch)
		if idx == -1:
			return -1
		value = value * 62 + idx
	return value


## True if text looks like a join code (6 B62 chars, no dots/colons).
static func looks_like_code(text: String) -> bool:
	if text.length() != CODE_LENGTH:
		return false
	if "." in text or ":" in text:
		return false
	for ch in text:
		if B62.find(ch) == -1:
			return false
	return true


# ─────────────────────────────────────────────
#  IP Detection
# ─────────────────────────────────────────────

## Returns local IPv4 addresses most likely to be reachable on a LAN,
## ordered best-first, with 127.0.0.1 appended last as a fallback.
static func detect_ips() -> Array[String]:
	var detected: Array[String] = []
	var all := IP.get_local_addresses()

	var scored: Array[Dictionary] = []
	for addr in all:
		if addr.begins_with("127."):     continue
		if addr.begins_with("169.254."): continue
		if addr.begins_with("0."):       continue
		var s := _score_ip(addr)
		if s >= 0:
			scored.append({"ip": addr, "score": s})

	scored.sort_custom(_compare_ip_scores)

	for entry in scored:
		detected.append(entry["ip"])

	if not "127.0.0.1" in detected:
		detected.append("127.0.0.1")

	return detected


static func _compare_ip_scores(a: Dictionary, b: Dictionary) -> bool:
	return a["score"] > b["score"]


static func _score_ip(addr: String) -> int:
	var parts := addr.split(".")
	if parts.size() != 4:
		return -1

	var a := parts[0].to_int()
	var b := parts[1].to_int()
	var c := parts[2].to_int()

	# Known virtual / VPN adapters — negative scores
	if a == 192 and b == 168 and c == 56:                   return -100  # VirtualBox Host-Only
	if a == 192 and b == 168 and c == 0:                    return -80   # VMware Host-Only
	if a == 192 and b == 168 and c in [40, 137, 220, 221, 222]: return -70   # VMware NAT
	if a == 172 and b >= 17 and b <= 31:                    return -50   # Docker bridges
	if a == 25:                                             return -60   # Hamachi VPN
	if a == 100 and b >= 64 and b <= 127:                   return -60   # Tailscale / CGN

	# Real LAN adapters — positive scores
	if a == 192 and b == 168:                                return 100   # Home / office LAN
	if a == 10:                                             return 80    # Corporate LAN
	if a == 172 and b >= 16 and b <= 31:                    return 60    # Sometimes LAN

	if a >= 1 and a <= 223:                                 return 40    # Public IP
	return 0


# ─────────────────────────────────────────────
#  Map Scanning
# ─────────────────────────────────────────────

## Lists every *.tscn under res://maps (excluding the lobby world), sorted by
## display name.  Each entry is { "display_name": String, "path": String }.
static func scan_maps() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open("res://maps")
	if dir == null:
		return out

	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.ends_with(".tscn") and f != "main_menu_world.tscn":
			out.append({
				"display_name": f.trim_suffix(".tscn"),
				"path": "res://maps/" + f,
			})
		f = dir.get_next()
	dir.list_dir_end()

	out.sort_custom(func(a, b): return a["display_name"] < b["display_name"])
	return out
