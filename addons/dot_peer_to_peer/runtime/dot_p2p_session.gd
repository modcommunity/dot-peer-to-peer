class_name DotP2PSession
extends Node

## A peer-to-peer session: a lobby, a signaller, and a transport nobody may name.
##
## [codeblock]
## var p2p := DotP2PSession.new()
## p2p.config = my_config
## p2p.signaller = DotP2PSignallerHttp.new(url)
## add_child(p2p)
##
## var res := p2p.host("Ada")          # returns a join code
## # or
## p2p.join("K7M4PX", "Bob")
## [/codeblock]
##
## [b]The transport is reached through [method ClassDB.instantiate] and never by name.[/b]
## Godot's WebRTC ships as an optional GDExtension on native platforms and is built into
## the web export, so on a desktop build without it every WebRTC class is simply absent —
## and a script that so much as [i]mentions[/i] the identifier fails to compile. dot-core's
## `DotTransportENet` reaches ENet exactly this way for the same reason on web, and
## dot-core's own notes said a WebRTC transport "would be untestable in a default install".
## This is where it went, built so that an install without it still parses, still runs,
## and says what is missing.

const SERVICE := &"dot_p2p"
const CHANNEL := "p2p"

## The session is up and the game may start.
signal ready_to_play(code: String)

## Somebody joined or left.
signal membership_changed(members: PackedStringArray)

## The host changed under us.
signal host_changed(from_id: StringName, to_id: StringName)

## It ended, and why.
signal ended(res: DotResult)

@export var config: DotP2PConfig = null

@export var register_as_service: bool = true

## Where offers and answers go. Any [DotP2PSignaller].
var signaller: DotP2PSignaller = null

## This peer's own id. Pseudonymous, and not an account id.
##
## [b]Never an account id, for the reason dot-user exists.[/b] A join code is shared in
## public — in a chat, on a stream — and the ids in a lobby are visible to everybody in it.
## An account id there is a permanent identifier a stranger can collect.
var local_id: StringName = &""

var lobby: DotP2PLobby = null

var _peer: Object = null
var _started_ms := 0
var _state: StringName = &"idle"
var _last_seen: Dictionary = {}


func _init() -> void:
	lobby = DotP2PLobby.new()


func setup() -> DotResult:
	if config == null:
		config = DotP2PConfig.new()
	var res := config.validate()
	if not res.ok:
		return res.wrap("p2p config")
	lobby.max_peers = config.max_peers

	if local_id == &"":
		local_id = _make_local_id()

	if register_as_service:
		DotRegistry.register(SERVICE, self)
	return DotResult.success(null)


func _exit_tree() -> void:
	leave()
	if register_as_service:
		DotRegistry.unregister_instance(SERVICE, self)


## A stable-enough pseudonymous id for this machine and session.
##
## `OS.get_unique_id()` is deliberately not used. It **pushes an error and then returns the
## empty string** on web and iOS — a red line on the page a player has open, naming a
## function nobody called on purpose — which is why dot-core grew
## `DotPlatform.has_unique_id()`. And a hardware id in a lobby is a permanent identifier a
## stranger can collect, which is the whole reason dot-user is pseudonymous per scope.
func _make_local_id() -> StringName:
	var bytes := PackedByteArray()
	for _i in range(8):
		bytes.append(randi() % 256)
	return StringName(bytes.hex_encode())


# --- Capability -------------------------------------------------------------

## Whether this build can do peer-to-peer at all.
##
## Asked, never assumed — the family's rule, and here the call itself is the damage: a
## script naming an absent class does not fail at runtime, it fails to compile, taking
## every script that references it down as an apparently unrelated cascade.
static func available() -> bool:
	return ClassDB.class_exists("WebRTCMultiplayerPeer") and ClassDB.can_instantiate(
		"WebRTCMultiplayerPeer"
	)


## Why it is not available, in words a person can act on.
static func unavailable_reason() -> String:
	if available():
		return ""
	if DotPlatform.is_web():
		return "this browser or export template has no WebRTC"
	return (
		"the WebRTC GDExtension is not installed in this build; "
		+ "it ships separately from the engine on desktop"
	)


# --- Hosting and joining ----------------------------------------------------

## Starts a session and returns its join code.
func host(display_name: String) -> DotResult:
	var guard := _precheck()
	if not guard.ok:
		return guard

	var index := 0
	var code := DotP2PLobby.make_code(config.code_length, func(_i: int) -> float:
		index += 1
		return randf()
	)

	# Bound BEFORE announcing. A signaller can deliver its first message inside the call
	# that announces us -- the loopback one does, synchronously -- and a handler connected
	# afterwards never sees it. This family already has the lesson twice: "nothing may be
	# sent to a peer before it says it can receive", and "a signal is not a state".
	_bind_signaller()
	var res := signaller.host(code, {"name": display_name, "max": config.max_peers})
	if not res.ok:
		return res.wrap("announcing the session")

	lobby.code = code
	lobby.add_member(local_id, display_name, Time.get_ticks_msec())
	lobby.host_id = local_id
	_state = &"hosting"
	_started_ms = Time.get_ticks_msec()

	if not config.has_relay():
		# Said once, at the point it can still be acted on, and not as an error. Between
		# five and fifteen per cent of pairs cannot find a direct path, and with no relay
		# configured those players will fail -- which is a deployment decision, not a bug,
		# and one somebody should make deliberately.
		DotLog.info(
			CHANNEL,
			"no relay configured: peers behind strict NAT will not be able to join",
			{"code": code}
		)

	ready_to_play.emit(code)
	return DotResult.success(code)


## Joins an existing session by code.
func join(code: String, display_name: String) -> DotResult:
	var guard := _precheck()
	if not guard.ok:
		return guard

	var tidy := code.strip_edges().to_upper()
	if not DotP2PLobby.is_code_shaped(tidy, config.code_length):
		# Refused on shape before anything is looked up. A lookup is how an attacker finds
		# out which codes exist, and "that is not a code" is a better answer for a player
		# who typed one wrong than "no such session".
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' is not a join code" % code,
			"codes are %d characters from an unambiguous alphabet" % config.code_length
		)

	# Bound first, for the reason host() is. The loopback signaller delivers "here is who
	# is already here" inside join(), synchronously, and a handler connected after the
	# call never sees any of it -- which leaves a joiner alone in a lobby that has four
	# people in it.
	_bind_signaller()
	var res := signaller.join(tidy, {"name": display_name})
	if not res.ok:
		return res.wrap("joining")

	lobby.code = tidy
	lobby.add_member(local_id, display_name, Time.get_ticks_msec())
	# Never assumed. A joiner is the host only if the election says so, which it does only
	# when it turns out to be alone -- and until the signaller has said who is here, it
	# cannot know that it is not.
	_settle_host()
	_state = &"joining"
	_started_ms = Time.get_ticks_msec()
	return DotResult.success(null)


func leave() -> void:
	if signaller != null:
		signaller.leave()
	if _peer != null and is_instance_valid(_peer):
		# Called through the string, like everything else about the peer.
		_peer.call("close")
		_peer = null
	_state = &"idle"


func state() -> StringName:
	return _state


func is_host() -> bool:
	return lobby.is_host(local_id)


func _precheck() -> DotResult:
	if signaller == null:
		return DotResult.fail(DotError.CODE_STATE, "no signaller: there is nowhere to meet")
	if config == null:
		return DotResult.fail(DotError.CODE_STATE, "not set up")
	if _state != &"idle":
		return DotResult.fail(DotError.CODE_STATE, "already in a session")
	return DotResult.success(null)


## Works out who hosts, when nobody has said.
##
## Only ever fills an empty answer: a host that has been established is not re-elected
## every time somebody joins, which would hand the session to whoever has been here
## longest the moment a latecomer arrives.
func _settle_host() -> void:
	if lobby.host_id != &"" and lobby.has(lobby.host_id):
		return
	var elected := lobby.elect_host()
	if elected == lobby.host_id:
		return
	var previous := lobby.host_id
	lobby.host_id = elected
	host_changed.emit(previous, elected)


func _bind_signaller() -> void:
	if not signaller.received.is_connected(_on_signal):
		signaller.received.connect(_on_signal)
	if not signaller.disconnected.is_connected(_on_signaller_lost):
		signaller.disconnected.connect(_on_signaller_lost)


# --- The transport, never named ---------------------------------------------

## Builds the multiplayer peer, if this build has one.
##
## Returns a failure rather than null so the reason travels. A game that cannot do
## peer-to-peer should say which of the two reasons it is — no extension, or no browser
## support — because they have different answers and a player can act on both.
func create_peer() -> DotResult:
	if not available():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"this build cannot do peer-to-peer",
			unavailable_reason()
		)

	# ClassDB.instantiate, never `WebRTCMultiplayerPeer.new()`. The identifier does not
	# exist in a build without the extension and a script that mentions it fails to
	# COMPILE -- taking every script that references this one down with it, as a cascade
	# of errors in files nobody touched. Exactly how dot-core reaches ENet on web.
	var peer: Object = ClassDB.instantiate("WebRTCMultiplayerPeer")
	if peer == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "WebRTC would not instantiate")
	_peer = peer
	return DotResult.success(peer)


## The engine peer, for a game to hand to its own multiplayer API. Null when there is none.
func peer() -> Object:
	return _peer


# --- Signalling -------------------------------------------------------------

func _on_signal(message: Dictionary) -> void:
	var from := StringName(str(message.get("from", "")))
	var kind := str(message.get("kind", ""))
	var payload: Dictionary = message.get("payload", {})
	_last_seen[from] = Time.get_ticks_msec()

	match kind:
		"joined":
			var res := lobby.add_member(from, str(payload.get("name", from)), Time.get_ticks_msec())
			if res.ok:
				_settle_host()
				membership_changed.emit(lobby.member_ids())
		"present":
			lobby.add_member(from, str(payload.get("name", from)), Time.get_ticks_msec())
			_settle_host()
			membership_changed.emit(lobby.member_ids())
		"left":
			_on_peer_gone(from)
		"host":
			# A host announcement is taken only from the peer the election already agrees
			# on. A peer that simply declares itself host is how a session is stolen, and
			# the election is a pure function every peer can compute for itself -- so there
			# is never a reason to believe a claim over the arithmetic.
			var expected := lobby.elect_host()
			if from != expected:
				DotLog.warn(
					CHANNEL,
					"a peer claimed to be host and the election says otherwise",
					{"claimed": String(from), "elected": String(expected)}
				)
				return
			var previous := lobby.host_id
			lobby.host_id = from
			if previous != from:
				host_changed.emit(previous, from)
		"ready":
			lobby.set_ready(from, bool(payload.get("ready", true)))
		_:
			pass


func _on_peer_gone(id: StringName) -> void:
	var was_host := lobby.is_host(id)
	if not was_host or not config.migrate_host:
		lobby.remove_member(id)
		membership_changed.emit(lobby.member_ids())
		return

	var previous := lobby.host_id
	var next := lobby.migrate_from(id)
	membership_changed.emit(lobby.member_ids())
	if next == &"":
		ended.emit(DotResult.fail(DotError.CODE_STATE, "everybody has left"))
		return
	host_changed.emit(previous, next)
	if next == local_id and signaller != null:
		# The new host says so once. Everybody else has already worked it out, so this is
		# a confirmation rather than an instruction -- and it is checked against the
		# election on the receiving side for exactly that reason.
		signaller.send(&"", &"host", {})


func _on_signaller_lost(reason: String) -> void:
	# The rendezvous going away is not the session going away. Once peers are connected
	# they do not need it, and treating its loss as an end is how a game drops everybody
	# because a web server restarted.
	DotLog.info(CHANNEL, "the signaller disconnected", {"why": reason, "state": String(_state)})


func _process(_delta: float) -> void:
	if _state == &"idle" or config == null:
		return

	if _state == &"joining" and Time.get_ticks_msec() - _started_ms > int(
		config.connect_timeout_sec * 1000.0
	):
		_state = &"idle"
		var why := "could not reach the host"
		if not config.has_relay():
			why += "; no relay is configured, so peers behind strict NAT cannot connect"
		ended.emit(DotResult.fail(DotError.CODE_TIMEOUT, why))
		return

	if not config.migrate_host or lobby.host_id == local_id:
		return
	var seen := int(_last_seen.get(lobby.host_id, _started_ms))
	if Time.get_ticks_msec() - seen > int(config.host_timeout_sec * 1000.0):
		_on_peer_gone(lobby.host_id)


func note_seen(id: StringName) -> void:
	_last_seen[id] = Time.get_ticks_msec()


# --- Reporting --------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"state": String(_state),
		"code": lobby.code,
		"members": lobby.members.size(),
		"host": String(lobby.host_id),
		"is_host": is_host(),
		"available": available(),
		"has_relay": config.has_relay() if config != null else false,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("dot-p2p  %s" % _state)
	if not available():
		out.append("  UNAVAILABLE: %s" % unavailable_reason())
	out.append("  me      %s" % local_id)
	if signaller != null:
		out.append("  meet    %s" % signaller.signaller_name())
	out.append_array(lobby.describe_lines())
	if config != null:
		out.append_array(config.describe_lines())
	return out
