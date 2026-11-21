extends Node

## Minimal HTTP client for `lobbyd` (`server/lobbyd/lobbyd.c`).
##
## Enabled by default against the deployed VPS lobby.  `--lobby=http://host:port`
## overrides the URL and `--no-lobby` disables it.  It only handles metadata:
## create, browse, join.  Gameplay is a direct ENet connection to the returned
## endpoint.

signal configured_changed

const DEFAULT_BASE_URL := "http://104.248.149.78:18080"
const HTTP_TIMEOUT_SECONDS := 3.0
## create waits for lobbyd's child server to bind UDP, so it needs a longer
## budget than a browse/join request.
const CREATE_TIMEOUT_SECONDS := 15.0

## Empty means the lobby is disabled and the legacy in-world flow is used.
var base_url: String = ""

## Most recent transport/HTTP failure.  `list_matches()` returns an empty array
## on failure, so callers read this to distinguish "no matches" from "VPS down".
var last_error: String = ""

var _http: HTTPRequest


func configure(url: String) -> void:
	base_url = url.strip_edges().trim_suffix("/")
	configured_changed.emit()


func is_enabled() -> bool:
	return base_url != ""


func create_match() -> Dictionary:
	return await request("POST", "/v1/matches", CREATE_TIMEOUT_SECONDS)


func list_matches() -> Array:
	var result := await request("GET", "/v1/matches")
	var matches: Variant = result.get("matches", [])
	return matches if matches is Array else []


func join_by_code(code: String) -> Dictionary:
	return await request("POST", "/v1/matches/%s/join" % code.strip_edges().to_upper())


func request(method: String, path: String, timeout_seconds: float = HTTP_TIMEOUT_SECONDS) -> Dictionary:
	last_error = ""
	if base_url == "":
		last_error = "VPS lobby disabled"
		return {"error": last_error}
	if _http == null or not is_instance_valid(_http):
		_http = HTTPRequest.new()
		add_child(_http)
		_http.process_mode = Node.PROCESS_MODE_ALWAYS
	_http.timeout = timeout_seconds
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		last_error = "lobby request already in flight"
		return {"error": last_error}

	var http_method := HTTPClient.METHOD_GET
	if method == "POST":
		http_method = HTTPClient.METHOD_POST
	var err := _http.request(base_url + path, PackedStringArray(["Accept: application/json"]), http_method)
	if err != OK:
		last_error = "request failed (%d)" % err
		return {"error": last_error}

	var result: Array = await _http.request_completed
	var transport_result: int = result[0]
	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	if transport_result != HTTPRequest.RESULT_SUCCESS:
		last_error = _transport_error_text(transport_result)
		return {"error": last_error}
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed is Dictionary:
		var dict := parsed as Dictionary
		if response_code >= 200 and response_code < 300:
			return dict
		if not dict.has("error"):
			dict["error"] = "HTTP %d" % response_code
		last_error = str(dict["error"])
		return dict
	last_error = "HTTP %d" % response_code
	return {"error": last_error}


func _transport_error_text(code: int) -> String:
	match code:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "VPS unreachable"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "DNS lookup failed"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "VPS connection error"
		HTTPRequest.RESULT_TIMEOUT:
			return "VPS timeout"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "VPS no response"
		_:
			return "VPS request failed (%d)" % code
