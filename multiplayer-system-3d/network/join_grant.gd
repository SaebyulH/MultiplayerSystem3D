extends RefCounted
class_name JoinGrant

## Verifies the HMAC-SHA256 join grant issued by `lobbyd`.
##
## Token: `<base64url(payload)>.<base64url(hmac_sha256(secret, payload_b64))>`
## Payload: {"v":1,"m":<match_id>,"p":<player_id>,"e":<unix_expiry>,"n":"<nonce>"}
##
## The match server reads the secret from `MATCH_SECRET` (set by lobbyd on the
## child process) or `--match-secret=`.  With no secret configured the server
## accepts any token: that is the direct `--connect` dev path, and it is logged
## as a warning by the caller.  Never run a public server without a secret.

const Protocol := preload("res://network/session_protocol.gd")


static func configured_secret() -> String:
	var secret := OS.get_environment("MATCH_SECRET")
	if secret != "":
		return secret
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--match-secret="):
			return arg.substr("--match-secret=".length())
	return ""


static func is_configured() -> bool:
	return configured_secret() != ""


## `expected_match_id` empty means "do not bind the token to a match id".
static func validate(token: String, expected_match_id: String = "") -> bool:
	var secret := configured_secret()
	if secret == "":
		return true  # dev: no secret, no signature check
	var parts := token.split(".")
	if parts.size() != 2:
		_reject("token is not payload.signature")
		return false
	var payload_b64 := parts[0]
	var signature := _b64url_decode(parts[1])
	if signature.is_empty():
		_reject("empty signature")
		return false
	var expected := _hmac(secret, payload_b64)
	if expected.is_empty() or expected.size() != signature.size():
		_reject("signature length")
		return false
	# Constant-time compare.
	var diff := 0
	for i in expected.size():
		diff |= expected[i] ^ signature[i]
	if diff != 0:
		_reject("signature mismatch (secret differs?)")
		return false

	var payload_bytes := _b64url_decode(payload_b64)
	if payload_bytes.is_empty():
		_reject("payload base64")
		return false
	var payload_text := payload_bytes.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(payload_text)
	if not parsed is Dictionary:
		_reject("payload JSON")
		return false
	var payload := parsed as Dictionary
	if int(payload.get("v", 0)) != 1:
		_reject("payload version")
		return false
	if int(payload.get("e", 0)) < int(Time.get_unix_time_from_system()):
		_reject("expired")
		return false
	# JSON numbers parse as float in GDScript, so compare as integers: "3.0"
	# must match "3".
	if expected_match_id != "":
		if not expected_match_id.is_valid_int() \
				or int(payload.get("m", -1)) != int(expected_match_id):
			_reject("match id %s != %s" % [payload.get("m", "?"), expected_match_id])
			return false
	return true


static func _reject(reason: String) -> void:
	if OS.is_debug_build():
		print("[GRANT] rejected: ", reason)


## Issue a resume token for a specific player in a specific match.  Signed with
## the same secret as the join grant; with no secret (direct dev) the token is
## unsigned and only the payload is checked.
static func issue_resume(match_id: String, player_id: int) -> String:
	var payload := {
		"v": 2,
		"t": "resume",
		"m": int(match_id) if match_id.is_valid_int() else match_id,
		"p": player_id,
		"e": int(Time.get_unix_time_from_system()) + Protocol.RESUME_TOKEN_TTL_SECONDS,
		"n": "%d-%d" % [Time.get_ticks_usec(), randi()],
	}
	var payload_b64 := _b64url_encode(JSON.stringify(payload).to_utf8_buffer())
	var secret := configured_secret()
	if secret == "":
		return payload_b64 + "."
	var signature := _hmac(secret, payload_b64)
	return payload_b64 + "." + _b64url_encode(signature)


## Validated resume payload: {player_id, nonce} or {}.
## With a secret configured the signature must verify; without one, the payload
## is trusted (dev only).
static func resume_data(token: String, expected_match_id: String) -> Dictionary:
	var parts := token.split(".")
	if parts.size() != 2:
		return {}
	var payload_b64 := parts[0]
	var secret := configured_secret()
	if secret != "":
		var signature := _b64url_decode(parts[1])
		var expected := _hmac(secret, payload_b64)
		if expected.is_empty() or expected.size() != signature.size():
			return {}
		var diff := 0
		for i in expected.size():
			diff |= expected[i] ^ signature[i]
		if diff != 0:
			return {}
	var payload_bytes := _b64url_decode(payload_b64)
	if payload_bytes.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(payload_bytes.get_string_from_utf8())
	if not parsed is Dictionary:
		return {}
	var payload := parsed as Dictionary
	if int(payload.get("v", 0)) != 2 or str(payload.get("t", "")) != "resume":
		return {}
	if int(payload.get("e", 0)) < int(Time.get_unix_time_from_system()):
		return {}
	if expected_match_id != "":
		if not expected_match_id.is_valid_int() or int(payload.get("m", -1)) != int(expected_match_id):
			return {}
	return {
		"player_id": int(payload.get("p", 0)),
		"nonce": str(payload.get("n", "")),
	}


static func resume_player_id(token: String, expected_match_id: String) -> int:
	return int(resume_data(token, expected_match_id).get("player_id", 0))


static func _b64url_encode(data: PackedByteArray) -> String:
	var normal := Marshalls.raw_to_base64(data)
	return normal.replace("+", "-").replace("/", "_").replace("=", "")


static func _hmac(secret: String, message: String) -> PackedByteArray:
	var ctx := HMACContext.new()
	if ctx.start(HashingContext.HASH_SHA256, secret.to_utf8_buffer()) != OK:
		return PackedByteArray()
	ctx.update(message.to_utf8_buffer())
	return ctx.finish()


static func _b64url_decode(text: String) -> PackedByteArray:
	var normal := text.replace("-", "+").replace("_", "/")
	while normal.length() % 4 != 0:
		normal += "="
	return Marshalls.base64_to_raw(normal)
