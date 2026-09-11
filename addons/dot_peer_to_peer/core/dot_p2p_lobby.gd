class_name DotP2PLobby
extends RefCounted

## Who is in the session, who is hosting, and who hosts next.
##
## [b]Peer-to-peer is a lobby problem before it is a transport problem.[/b] The transport
## half is a dozen calls into an engine module; everything that actually goes wrong — two
## people joining the same slot, a code that was already used, a host leaving and nobody
## agreeing who takes over, two peers that both think they are the host — is here, and none
## of it involves a socket.
##
## This class deliberately holds no connection at all. It is the state a
## [DotP2PSession] keeps and the suite drives it directly.

## Somebody arrived or left.
signal membership_changed(members: PackedStringArray)

## The host changed, and who it is now.
signal host_changed(from_id: StringName, to_id: StringName)

const CHANNEL := "p2p"

## An alphabet with no character that can be misread aloud.
##
## [b]This matters more than the code length.[/b] 0 and O, 1 and I and l, and to a lesser
## extent 5 and S, are the commonest support request any game with a join code has — a
## player reads their code out over voice chat and the other person types a different one.
## Removing them costs about a bit and a half per character.
const ALPHABET := "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

var code: String = ""
var host_id: StringName = &""

## member id -> [code]{name, ready, joined_at, latency_ms, stable}[/code].
var members: Dictionary = {}

var max_peers: int = 8


## Builds a join code from a stream.
##
## Takes a roll source rather than calling [method @GlobalScope.randi] so a suite can
## produce a known code, and so a host that generates one from a session seed produces the
## same code if it has to be rebuilt.
static func make_code(length: int, roll: Callable) -> String:
	var out := ""
	for i in range(maxi(4, length)):
		var u: float = clampf(float(roll.call(i)), 0.0, 0.999999)
		out += ALPHABET[int(u * float(ALPHABET.length()))]
	return out


## Whether [param candidate] could be a code this lobby issued.
##
## Checked before anything is looked up, so a malformed code is a refusal rather than a
## lookup — and a lookup is the thing an attacker would use to find out which codes exist.
static func is_code_shaped(candidate: String, length: int) -> bool:
	if candidate.length() != length:
		return false
	for i in range(candidate.length()):
		if not ALPHABET.contains(candidate[i]):
			return false
	return true


func add_member(id: StringName, name: String, now_ms: int) -> DotResult:
	if members.has(id):
		return DotResult.fail(DotError.CODE_STATE, "'%s' is already in this session" % id)
	if members.size() >= max_peers:
		return DotResult.fail(DotError.CODE_QUOTA, "the session is full")
	members[id] = {
		"name": name,
		"ready": false,
		"joined_at": now_ms,
		"latency_ms": 0,
		"stable": true,
	}
	# [b]Adding a member deliberately does NOT decide who hosts.[/b] The obvious
	# convenience -- "if nobody is hosting, this one is" -- makes the answer depend on the
	# order two messages happened to arrive in, and a joiner who adds itself before its
	# signaller has delivered "here is who is already here" declares itself host of
	# somebody else's session. It cost exactly that in this addon's own suite. The session
	# sets `host_id` when it hosts, and elects otherwise.
	membership_changed.emit(member_ids())
	return DotResult.success(null)


func remove_member(id: StringName) -> void:
	if not members.has(id):
		return
	members.erase(id)
	membership_changed.emit(member_ids())


func member_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id in members.keys():
		out.append(String(id))
	# Sorted as Strings, never as StringNames. Godot compares StringNames by their interned
	# pointer, so a sort over them gives two peers two different orders -- which in dot-net
	# gave two clients two different wire ids for one message type and was invisible until a
	# real browser connected. Every peer here has to agree about this order, because the
	# host election is derived from it.
	out.sort()
	return out


func has(id: StringName) -> bool:
	return members.has(id)


func set_ready(id: StringName, ready: bool) -> void:
	if members.has(id):
		(members[id] as Dictionary)["ready"] = ready


func all_ready() -> bool:
	if members.is_empty():
		return false
	for id in members.keys():
		if not bool((members[id] as Dictionary).get("ready", false)):
			return false
	return true


func note_latency(id: StringName, ms: int) -> void:
	if members.has(id):
		(members[id] as Dictionary)["latency_ms"] = ms


## Marks a peer as unreliable, which excludes it from becoming host.
func note_unstable(id: StringName, stable: bool) -> void:
	if members.has(id):
		(members[id] as Dictionary)["stable"] = stable


# --- Host election ----------------------------------------------------------

## Who should host, computed from the member list alone.
##
## [b]Every peer computes this, and nobody is asked.[/b] That is the whole design: an
## election that requires agreement needs a round of messages, and the moment a host
## disappears is exactly the moment messages are not arriving. A pure function of a list
## every peer already has produces the same answer everywhere with no traffic at all — and
## two peers that both think they are the host is a split session that neither of them can
## detect.
##
## The order is: stable before unstable, then longest in the session, then the lowest id as
## a tie-break. Longest-joined rather than lowest latency, because latency is measured
## differently by everybody and a value two peers disagree about is a value that can elect
## two hosts.
func elect_host(exclude: StringName = &"") -> StringName:
	var best: StringName = &""
	var best_stable := false
	var best_joined := 0

	for raw in member_ids():
		var id := StringName(raw)
		if id == exclude:
			continue
		var m: Dictionary = members[id]
		var stable := bool(m.get("stable", true))
		var joined := int(m.get("joined_at", 0))

		if best == &"":
			best = id
			best_stable = stable
			best_joined = joined
			continue
		if stable != best_stable:
			if stable:
				best = id
				best_stable = stable
				best_joined = joined
			continue
		if joined < best_joined:
			best = id
			best_joined = joined
			continue
		if joined == best_joined and String(id) < String(best):
			# The final tie-break is deterministic and total, so there is never a case
			# where two peers pick differently. Comparing Strings, for the reason above.
			best = id
	return best


## Elects and applies a new host. Returns who it is now.
func migrate_from(gone: StringName) -> StringName:
	var previous := host_id
	remove_member(gone)
	var next := elect_host()
	host_id = next
	if next != previous:
		host_changed.emit(previous, next)
		DotLog.info(CHANNEL, "host migrated", {"from": String(previous), "to": String(next)})
	return next


func is_host(id: StringName) -> bool:
	return host_id == id


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("lobby %s: %d of %d" % [code if code != "" else "<no code>", members.size(), max_peers])
	for raw in member_ids():
		var id := StringName(raw)
		var m: Dictionary = members[id]
		out.append("  %-20s %s%s%s %d ms" % [
			str(m.get("name", raw)),
			"HOST " if id == host_id else "     ",
			"ready " if bool(m.get("ready", false)) else "      ",
			"" if bool(m.get("stable", true)) else "unstable ",
			int(m.get("latency_ms", 0)),
		])
	return out
