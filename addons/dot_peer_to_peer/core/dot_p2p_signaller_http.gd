class_name DotP2PSignallerHttp
extends DotP2PSignaller

## A rendezvous over plain HTTP: post what you have, poll for what you have not.
##
## [b]Polling rather than a socket, and that is a deliberate trade.[/b] A WebSocket is
## better in every way except one: it needs a server that speaks WebSocket, and this exists
## so that a deployment with nothing but a static host and a tiny endpoint can still get two
## players together. It uses dot-core's [DotHttp], which uses [HTTPRequest]
## unconditionally, because a browser has no [HTTPClient] at all.
##
## The poll is short-lived by design: signalling ends when the peers are connected, and a
## game that polls for the whole match has turned a serverless design into a server with
## extra steps and a request every two seconds.
##
## The endpoint is four routes and any language can serve them:
## [codeblock]
## POST <base>/host    {code, id, info}      -> 200
## POST <base>/join    {code, id, info}      -> 200 {peers: [...]}
## POST <base>/send    {code, from, to, kind, payload}
## GET  <base>/poll?code=&id=&since=         -> {messages: [...], cursor}
## [/codeblock]

const CHANNEL := "p2p"

var base_url: String = ""
var id: StringName = &""

## Seconds between polls while establishing. Not a match-long setting.
var poll_interval_sec: float = 1.0

var _http: DotHttp = null
var _code: String = ""
var _cursor: int = 0
var _joined := false

## Whether the last request to the rendezvous failed, so an outage is logged on its EDGES:
## [method poll] runs every [member poll_interval_sec], and a WARN per poll while the
## server is down is a line a second that buries the one saying when it started.
var _failing := false


func _init(p_base_url: String, p_id: StringName, http: DotHttp = null) -> void:
	base_url = p_base_url.rstrip("/")
	id = p_id
	_http = http


func host(code: String, info: Dictionary) -> DotResult:
	var res := await _post("host", {"code": code, "id": String(id), "info": info})
	if not res.ok:
		return res
	_code = code
	_joined = true
	return DotResult.success(code)


func join(code: String, info: Dictionary) -> DotResult:
	var res := await _post("join", {"code": code, "id": String(id), "info": info})
	if not res.ok:
		return res
	_code = code
	_joined = true

	var body: Variant = res.value
	if body is Dictionary:
		for peer in (body as Dictionary).get("peers", []):
			received.emit({"from": str(peer), "kind": "present", "payload": {}})
	return DotResult.success(null)


func send(to: StringName, kind: StringName, payload: Dictionary) -> DotResult:
	if not _joined:
		return DotResult.fail(DotError.CODE_STATE, "not in a session")
	return await _post("send", {
		"code": _code,
		"from": String(id),
		"to": String(to),
		"kind": String(kind),
		"payload": payload,
	})


## Fetches anything waiting. A game calls this on a timer while establishing.
##
## Explicit rather than a built-in loop, because the caller is the only one who knows when
## signalling is finished -- and a signaller that polls on its own is one that carries on
## after the session no longer needs it.
func poll() -> DotResult:
	if not _joined or _http == null:
		return DotResult.success(0)
	var url := "%s/poll?code=%s&id=%s&since=%d" % [base_url, _code, id, _cursor]
	var res: DotResult = await _http.get_json(url)
	_note("poll", res)
	if not res.ok:
		return res
	var body: Variant = res.value
	if not (body is Dictionary):
		return DotResult.success(0)
	var d := body as Dictionary
	_cursor = int(d.get("cursor", _cursor))
	var messages: Array = d.get("messages", [])
	for m in messages:
		if m is Dictionary:
			received.emit(m)
	return DotResult.success(messages.size())


func leave() -> void:
	_joined = false
	_code = ""
	_cursor = 0


func connected() -> bool:
	return _joined


func signaller_name() -> String:
	return "http:%s" % base_url


func _post(route: String, body: Dictionary) -> DotResult:
	if _http == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"no HTTP client",
			"DotHttp is a Node and has to be placed by the host, like everything else here"
		)
	# Awaited into a variable first. `await x.f().ok` binds the await to the property
	# access rather than to the call, so the coroutine is never awaited at all -- which is
	# in this family's own list of traps.
	var res: DotResult = await _http.post_json("%s/%s" % [base_url, route], body)
	_note(route, res)
	return res


## WARN when the rendezvous starts failing, DEBUG while it goes on, INFO when it answers
## again. WARN rather than ERROR because nothing is lost yet -- a poll is retried and a
## player can try to host again -- but a session that cannot meet anybody looks, from
## inside the game, exactly like nobody being online.
func _note(route: String, res: DotResult) -> void:
	if res.ok:
		if _failing:
			_failing = false
			DotLog.info(CHANNEL, "the rendezvous is answering again", {"url": base_url})
		return

	var fields := {
		"url": base_url,
		"route": route,
		"code": res.code(),
		"error": res.error.message if res.error != null else "",
	}

	if _failing:
		DotLog.debug(CHANNEL, "the rendezvous is still failing", fields)
	else:
		_failing = true
		DotLog.warn(CHANNEL, "the rendezvous is not answering", fields)
