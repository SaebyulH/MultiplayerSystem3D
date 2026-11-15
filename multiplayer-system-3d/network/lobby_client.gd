extends Node

## Minimal HTTP client for `lobbyd` (`server/lobbyd/lobbyd.c`).
##
## Disabled unless a lobby URL is configured (`--lobby=http://host:port` or the
## lobby zones).  It only handles metadata: create, browse, join.  Gameplay is a
## direct ENet connection to the returned endpoint.

signal configured_changed

## Empty means the lobby is disabled and the legacy in-world flow is used.
var base_url: String = ""

var _http: HTTPRequest


func configure(url: String) -> void:
	base_url = url.strip_edges().trim_suffix("/")
	configured_changed.emit()


func is_enabled() -> bool:
	return base_url != ""


func create_match() -> Dictionary:
	return await request("POST", "/v1/matches")


func list_matches() -> Array:
	var result := await request("GET", "/v1/matches")
	var matches: Variant = result.get("matches", [])
	return matches if matches is Array else []


func join_by_code(code: String) -> Dictionary:
	return await request("POST", "/v1/matches/%s/join" % code.strip_edges().to_upper())


func request(method: String, path: String) -> Dictionary:
	if base_url == "":
		return {"error": "lobby disabled"}
	if _http == null or not is_instance_valid(_http):
		_http = HTTPRequest.new()
		_http.timeout = 5.0
		add_child(_http)
		_http.process_mode = Node.PROCESS_MODE_ALWAYS
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return {"error": "lobby request already in flight"}

	var http_method := HTTPClient.METHOD_GET
	if method == "POST":
		http_method = HTTPClient.METHOD_POST
	var err := _http.request(base_url + path, PackedStringArray(["Accept: application/json"]), http_method)
	if err != OK:
		return {"error": "request failed (%d)" % err}

	var result: Array = await _http.request_completed
	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed is Dictionary:
		var dict := parsed as Dictionary
		if response_code >= 200 and response_code < 300:
			return dict
		if not dict.has("error"):
			dict["error"] = "HTTP %d" % response_code
		return dict
	return {"error": "HTTP %d" % response_code}
