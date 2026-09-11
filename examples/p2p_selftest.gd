extends Node

## Exercises dot-peer-to-peer with no network and, on this machine, no WebRTC either.
##
## [b]That is not a gap in the suite — it is the shape of the addon.[/b] Everything that
## actually goes wrong with peer-to-peer is in the lobby: two people joining the same slot,
## a code that was already used, a host leaving and nobody agreeing who takes over, two
## peers that both think they are the host. None of that involves a socket, all of it is a
## pure function of a member list, and every one of those is checked here.
##
## The transport half is checked for the one thing that matters on a build without the
## extension: that asking about it is a refusal with a reason rather than a crash or a
## script that will not compile.
##
## [codeblock]
## godot --headless --path . res://examples/p2p_selftest.tscn
## [/codeblock]

const SECTIONS := 7
const CHECKS := 71

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-peer-to-peer self-test")
	_line("")

	_test_config_is_honest()
	_test_codes()
	_test_lobby()
	_test_election()
	_test_signalling()
	_test_session()
	_test_transport_absence()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


# --- 1 ----------------------------------------------------------------------

func _test_config_is_honest() -> void:
	_section("The configuration says the uncomfortable things out loud")

	var c := DotP2PConfig.new()
	_check(c.validate().ok, "a default configuration validates")

	# The one nobody puts in their marketing. Five to fifteen per cent of pairs cannot
	# find a direct path, and with no relay those players simply cannot play together.
	_check(
		not c.has_relay(),
		"and ships with no relay, which means some pairs will not connect"
	)
	c.relay_servers = ["turn:relay.example:3478"]
	_check(c.has_relay(), "configuring one says so")
	_check(c.ice_servers().size() == 2, "and it reaches the ICE list beside the STUN server")

	c.relay_username = "u"
	c.relay_password = "p"
	_check(
		c.sensitive_keys().has("relay_password"),
		"a relay password is refused from the environment and argv, like every other secret here"
	)
	var ice: Dictionary = c.ice_servers()[1]
	_check(ice.has("credential"), "while still reaching the ICE list, which is the only place it goes")

	c.code_length = 3
	_check(not c.validate().ok, "a three-character join code is refused as guessable")
	c.code_length = 6

	c.migrate_host = true
	c.host_timeout_sec = 1.0
	_check(c.validate().ok, "a one-second host timeout is allowed")
	c.max_peers = 1
	_check(not c.validate().ok, "and a session for one is not a session")

	_check(c.describe_lines().size() >= 4, "it describes itself")


# --- 2 ----------------------------------------------------------------------

func _test_codes() -> void:
	_section("Join codes, and the characters that are not in them")

	var code := DotP2PLobby.make_code(6, func(i: int) -> float: return float(i) / 6.0)
	_check(code.length() == 6, "a code is the length asked for")

	# The commonest support request any game with a join code has is somebody reading it
	# aloud and the other person typing a different one.
	var banned := "01OIl5S".replace("5", "").replace("S", "")
	var clean := true
	for i in range(200):
		var c := DotP2PLobby.make_code(8, func(_j: int) -> float: return randf())
		for ch in banned:
			if c.contains(ch):
				clean = false
	_check(clean, "and never contains 0, 1, O, I or l, which cannot be read aloud reliably")

	_check(DotP2PLobby.is_code_shaped("K7M4PX", 6), "a well-formed code is recognised")
	_check(not DotP2PLobby.is_code_shaped("K7M4P", 6), "a short one is not")
	_check(not DotP2PLobby.is_code_shaped("K7M4PO", 6), "nor one with a letter that is not in the alphabet")
	_check(not DotP2PLobby.is_code_shaped("", 6), "nor an empty one")

	# Shape is checked before anything is looked up: a lookup is how somebody finds out
	# which codes exist, and "that is not a code" is a better answer for a typo anyway.
	var s := _session(&"a")
	var res := s.join("nope", "Ada")
	_check(not res.ok, "a malformed code is refused")
	_check(
		res.error.message.contains("not a join code"),
		"by shape, before anything has been asked about whether it exists"
	)
	s.queue_free()


# --- 3 ----------------------------------------------------------------------

func _test_lobby() -> void:
	_section("The lobby, which is where peer-to-peer actually goes wrong")

	var l := DotP2PLobby.new()
	l.max_peers = 3
	_check(l.add_member(&"ada", "Ada", 100).ok, "somebody joins")
	# Deliberately NOT "and so becomes the host". A lobby that fills in an empty host
	# makes the answer depend on which of two messages arrived first, and a joiner who
	# adds itself before its signaller has said who is already here declares itself host
	# of somebody else's session. That is exactly what this suite caught.
	_check(l.host_id == &"", "and the lobby does not decide by itself who is hosting")
	_check(l.elect_host() == &"ada", "though the election would name them")
	_check(not l.add_member(&"ada", "Ada again", 110).ok, "the same id cannot join twice")

	l.add_member(&"bob", "Bob", 200)
	l.add_member(&"cyd", "Cyd", 300)
	_check(l.members.size() == 3, "three are in")
	_check(not l.add_member(&"dee", "Dee", 400).ok, "and a fourth is refused when it is full")

	var seen := []
	l.membership_changed.connect(func(ids: PackedStringArray) -> void: seen.append(ids.size()))
	l.remove_member(&"cyd")
	_check(seen == [2], "leaving announces the new membership")

	_check(not l.all_ready(), "nobody is ready")
	l.set_ready(&"ada", true)
	_check(not l.all_ready(), "one is not all")
	l.set_ready(&"bob", true)
	_check(l.all_ready(), "and both is")

	var empty := DotP2PLobby.new()
	_check(not empty.all_ready(), "an empty lobby is not 'all ready', which is the answer that starts a match with nobody in it")

	_check(l.describe_lines().size() == 3, "it describes itself, one line per member")


# --- 4 ----------------------------------------------------------------------

func _test_election() -> void:
	_section("Everybody elects the same host, and nobody is asked")

	var l := DotP2PLobby.new()
	l.add_member(&"zoe", "Zoe", 100)
	l.add_member(&"ada", "Ada", 200)
	l.add_member(&"bob", "Bob", 300)

	_check(l.elect_host() == &"zoe", "the longest in the session hosts")
	_check(l.elect_host(&"zoe") == &"ada", "and excluding them gives the next")

	# The whole reason it is a pure function: the moment a host disappears is exactly the
	# moment messages are not arriving, so an election that needs agreement needs a round
	# of messages that cannot happen.
	var mirror := DotP2PLobby.new()
	mirror.add_member(&"bob", "Bob", 300)
	mirror.add_member(&"zoe", "Zoe", 100)
	mirror.add_member(&"ada", "Ada", 200)
	_check(
		mirror.elect_host() == l.elect_host(),
		"a second peer with the same members in a different order elects the same host"
	)

	l.note_unstable(&"zoe", false)
	_check(
		l.elect_host() == &"ada",
		"an unreliable peer is passed over, however long it has been here"
	)
	l.note_unstable(&"zoe", true)

	var tied := DotP2PLobby.new()
	tied.add_member(&"bbb", "B", 100)
	tied.add_member(&"aaa", "A", 100)
	_check(
		tied.elect_host() == &"aaa",
		"and two who joined in the same millisecond are broken by id, deterministically"
	)

	var changes := []
	l.host_changed.connect(func(from: StringName, to: StringName) -> void: changes.append([from, to]))
	var next := l.migrate_from(&"zoe")
	_check(next == &"ada", "a host leaving hands over to the elected successor")
	_check(l.host_id == &"ada", "which the lobby then believes")
	_check(changes.size() == 1, "announcing it once")
	_check(not l.has(&"zoe"), "and the old host is gone")

	l.migrate_from(&"ada")
	l.migrate_from(&"bob")
	_check(l.elect_host() == &"", "an empty session elects nobody, rather than a stale id")


# --- 5 ----------------------------------------------------------------------

func _test_signalling() -> void:
	_section("A rendezvous, which peer-to-peer cannot do without")

	DotP2PSignallerLoopback.reset_all()

	var a := DotP2PSignallerLoopback.new(&"ada")
	var b := DotP2PSignallerLoopback.new(&"bob")

	var a_got := []
	var b_got := []
	a.received.connect(func(m: Dictionary) -> void: a_got.append(m))
	b.received.connect(func(m: Dictionary) -> void: b_got.append(m))

	_check(a.host("ABC123", {"name": "Ada"}).ok, "a session is announced")
	_check(not b.host("ABC123", {}).ok, "and a second session cannot take the same code")
	_check(not b.join("ZZZZZZ", {}).ok, "joining a code nobody has is refused")

	_check(b.join("ABC123", {"name": "Bob"}).ok, "joining a real one works")
	_check(a_got.size() == 1 and a_got[0]["kind"] == "joined", "the host is told somebody joined")
	_check(
		b_got.size() == 1 and b_got[0]["kind"] == "present",
		"and the joiner is told who is already there, which is the half that is usually missing"
	)

	a_got.clear()
	_check(a.send(&"bob", &"offer", {"sdp": "x"}).ok, "a message is sent to one peer")
	_check(b_got.size() == 2, "and arrives")
	_check(not a.send(&"nobody", &"offer", {}).ok, "sending to somebody who is not there is refused")

	b_got.clear()
	a.send(&"", &"hello", {})
	_check(b_got.size() == 1, "a broadcast reaches the others")
	_check(a_got.is_empty(), "and not the sender")

	b.leave()
	_check(a_got.size() == 1 and a_got.back()["kind"] == "left", "leaving is announced")
	_check(not b.connected(), "and the leaver knows it has left")

	DotP2PSignallerLoopback.reset_all()
	# Static state that survives a test is the bug game-hungario's dedicated suite shipped:
	# it wrote to user://, the totals accumulated across runs, and it started failing on
	# its ninth run for a reason that had nothing to do with the code.
	var c := DotP2PSignallerLoopback.new(&"cyd")
	_check(c.host("ABC123", {}).ok, "and the code is free again after a reset")


# --- 6 ----------------------------------------------------------------------

func _test_session() -> void:
	_section("Two sessions in one process")

	DotP2PSignallerLoopback.reset_all()

	var host := _session(&"ada")
	var guest := _session(&"bob")

	var code_res := host.host("Ada")
	_check(code_res.ok, "hosting produces a join code")
	var code: String = code_res.value
	_check(DotP2PLobby.is_code_shaped(code, 6), "which is well formed")
	_check(host.is_host(), "and the host is the host")
	_check(host.lobby.members.size() == 1, "with one member")

	_check(guest.join(code, "Bob").ok, "the guest joins")
	_check(host.lobby.members.size() == 2, "and the host sees them")
	_check(guest.lobby.members.size() == 2, "and they see the host")
	_check(not guest.is_host(), "the guest is not the host")

	# A peer that declares itself host is how a session is stolen. The election is a pure
	# function every peer can compute, so a claim is never believed over the arithmetic.
	(guest.signaller as DotP2PSignallerLoopback).send(&"", &"host", {})
	_check(
		host.lobby.host_id != guest.local_id,
		"a peer claiming to be host is refused, because the election says otherwise"
	)

	var ended := []
	guest.ended.connect(func(r: DotResult) -> void: ended.append(r))
	host.leave()
	(host.signaller as DotP2PSignallerLoopback).leave()
	_check(
		guest.lobby.host_id == guest.local_id,
		"the host leaving makes the remaining peer the host, with no round of messages"
	)

	_check(host.describe()["code"] == code, "a session describes itself")
	_check(host.describe_lines().size() > 3, "in lines as well")

	host.queue_free()
	guest.queue_free()


# --- 7 ----------------------------------------------------------------------

func _test_transport_absence() -> void:
	_section("A build with no WebRTC says so, rather than failing to compile")

	# This is the check that matters most on this machine, because this machine has no
	# WebRTC extension -- and a script that NAMES an absent class does not fail at
	# runtime, it fails to COMPILE, taking every script that references it down as an
	# apparently unrelated cascade. Everything here goes through ClassDB by string.
	var present := DotP2PSession.available()
	_check(true, "asking whether WebRTC is available does not crash (it is %s)" % present)

	if not present:
		var why := DotP2PSession.unavailable_reason()
		_check(why != "", "and an unavailable build explains itself")
		_check(
			why.contains("GDExtension") or why.contains("browser"),
			"naming which of the two reasons it is, because they have different answers"
		)

		var s := _session(&"solo")
		var res := s.create_peer()
		_check(not res.ok, "creating a peer is a refusal rather than a crash")
		_check(res.code() == DotError.CODE_UNSUPPORTED, "with CODE_UNSUPPORTED")
		_check(res.error.detail != "", "and the reason travels with it")
		_check(s.peer() == null, "and nothing was built")
		s.queue_free()
	else:
		var s := _session(&"solo")
		var res := s.create_peer()
		_check(res.ok, "a build with WebRTC builds a peer")
		_check(s.peer() != null, "and holds it")
		s.queue_free()

	var no_meeting := _session(&"lonely")
	no_meeting.signaller = null
	var refused := no_meeting.host("Nobody")
	_check(not refused.ok, "hosting with no signaller is refused")
	_check(
		refused.error.message.contains("nowhere to meet"),
		"because peer-to-peer needs a server to start, whatever the marketing says"
	)
	no_meeting.queue_free()


# --- Harness ---------------------------------------------------------------

func _session(id: StringName) -> DotP2PSession:
	var s := DotP2PSession.new()
	s.config = DotP2PConfig.new()
	s.local_id = id
	s.register_as_service = false
	s.signaller = DotP2PSignallerLoopback.new(id)
	add_child(s)
	s.setup()
	return s


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
