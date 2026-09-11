class_name DotP2PSignallerLoopback
extends DotP2PSignaller

## Two or more signallers in one process, wired to each other. For suites and split screen.
##
## Not a mock: it implements the same four verbs and the same message shape, so the lobby,
## the election and the handshake sequence above it are the real ones. What it replaces is
## the network, which is the part a suite cannot have.

## Every loopback signaller in this process, by code.
##
## Static, and the one piece of global state in this addon. It is acceptable here for the
## reason the family's no-autoload rule exists to protect: nothing outside a test ever
## constructs one, and the alternative -- a registry object every test has to thread
## through -- makes the test harder to read without making anything safer.
static var _switchboards: Dictionary = {}

var id: StringName = &""
var _code: String = ""
var _joined := false


func _init(p_id: StringName) -> void:
	id = p_id


func host(code: String, info: Dictionary) -> DotResult:
	if _switchboards.has(code):
		return DotResult.fail(DotError.CODE_STATE, "that code is already in use")
	_switchboards[code] = {"peers": {id: self}, "info": info}
	_code = code
	_joined = true
	return DotResult.success(code)


func join(code: String, info: Dictionary) -> DotResult:
	if not _switchboards.has(code):
		return DotResult.fail(DotError.CODE_INVALID, "no session with that code")
	var board: Dictionary = _switchboards[code]
	var peers: Dictionary = board["peers"]
	if peers.has(id):
		return DotResult.fail(DotError.CODE_STATE, "already joined")
	peers[id] = self
	_code = code
	_joined = true

	# Everybody already in is told, and the joiner is told about everybody. Both halves
	# matter: a joiner who is announced but told nothing sits in an empty lobby, and one
	# who is told everything but announced to nobody is invisible to the host.
	for other_id in peers.keys():
		if other_id == id:
			continue
		(peers[other_id] as DotP2PSignallerLoopback).received.emit({
			"from": String(id), "kind": "joined", "payload": info
		})
		received.emit({"from": String(other_id), "kind": "present", "payload": {}})
	return DotResult.success(null)


func send(to: StringName, kind: StringName, payload: Dictionary) -> DotResult:
	if not _joined or not _switchboards.has(_code):
		return DotResult.fail(DotError.CODE_STATE, "not in a session")
	var peers: Dictionary = (_switchboards[_code] as Dictionary)["peers"]
	var message := {"from": String(id), "kind": String(kind), "payload": payload.duplicate(true)}
	if to == &"":
		for other_id in peers.keys():
			if other_id != id:
				(peers[other_id] as DotP2PSignallerLoopback).received.emit(message)
		return DotResult.success(null)
	if not peers.has(to):
		return DotResult.fail(DotError.CODE_INVALID, "'%s' is not in this session" % to)
	(peers[to] as DotP2PSignallerLoopback).received.emit(message)
	return DotResult.success(null)


func leave() -> void:
	if not _switchboards.has(_code):
		return
	var board: Dictionary = _switchboards[_code]
	var peers: Dictionary = board["peers"]
	peers.erase(id)
	for other_id in peers.keys():
		(peers[other_id] as DotP2PSignallerLoopback).received.emit({
			"from": String(id), "kind": "left", "payload": {}
		})
	if peers.is_empty():
		_switchboards.erase(_code)
	_joined = false


func connected() -> bool:
	return _joined


func signaller_name() -> String:
	return "loopback"


## Forgets every session. A suite calls this between tests.
##
## Static state that survives a test is the bug game-hungario's dedicated suite shipped:
## it wrote achievements to `user://`, the totals accumulated across runs, and it started
## failing on its ninth run for a reason that had nothing to do with the code.
static func reset_all() -> void:
	_switchboards.clear()
