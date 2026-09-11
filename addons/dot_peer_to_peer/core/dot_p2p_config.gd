@tool
class_name DotP2PConfig
extends DotConfig

## Everything a peer-to-peer session needs to be told, including the honest parts.
##
## [b]Read [member relay_servers] and [member trust] before shipping anything with this
## in it.[/b] Both are places where the comfortable default is a lie, and this addon
## would rather be awkward than quietly wrong.

@export_group("Rendezvous")

## Where offers, answers and candidates are exchanged.
##
## [b]Peer-to-peer needs a server to start.[/b] Two machines behind two routers cannot
## find each other without something both can reach — that is what signalling is, and no
## amount of "serverless" marketing removes it. What P2P removes is the server carrying
## the *game traffic*, which is the expensive part; the rendezvous is a few kilobytes
## once per session.
@export var signalling_url: String = ""

## How long to wait for the other side before giving up, in seconds.
##
## Short on purpose. A connection that is going to work usually works in two or three
## seconds; one that is going to fail often fails by never answering at all, and a player
## staring at "connecting…" for forty seconds concludes the game is broken rather than
## that their router is.
@export_range(1.0, 120.0, 0.5) var connect_timeout_sec: float = 12.0

@export_group("NAT")

## STUN servers: how a peer learns its own public address.
##
## Enough on its own for a large majority of pairs and not for all of them.
@export var stun_servers: Array[String] = ["stun:stun.l.google.com:19302"]

## TURN servers, which relay when a direct path cannot be found.
##
## [b]Empty by default, and that is the honest failure this addon will not hide.[/b]
## Somewhere between five and fifteen per cent of pairs cannot establish a direct path —
## symmetric NAT on both sides, carrier-grade NAT, some corporate and mobile networks —
## and for those the only answer is a relay. A relay costs bandwidth, which is why nobody
## ships one by default and why "peer-to-peer so we do not need servers" is not a complete
## plan.
##
## With none configured, [DotP2PSession] fails those pairs [i]quickly and by name[/i]
## rather than hanging, because "we could not find a route to that player" is a thing a
## person can act on and a spinner is not.
@export var relay_servers: Array[String] = []

## Credentials for the relay, if it needs them. Refused from the environment and argv.
@export var relay_username: String = ""
@export var relay_password: String = ""

@export_group("The lobby")

## How many characters a join code has.
##
## Six from an unambiguous alphabet is about a billion codes, which is enough that
## guessing one is not a strategy — and [b]the alphabet matters more than the length[/b]:
## 0/O and 1/I/l read aloud over voice chat are the commonest support request any game
## with a join code has.
@export_range(4, 16, 1) var code_length: int = 6

@export_range(2, 64, 1) var max_peers: int = 8

## Whether the lobby is listed anywhere, or only reachable by its code.
@export var discoverable: bool = false

@export_group("Host migration")

## Whether the session elects a new host when the old one leaves.
##
## On. The alternative is a session that ends because one person's connection dropped,
## which in a co-operative game is everybody's evening.
@export var migrate_host: bool = true

## Seconds of silence before a host is considered gone.
##
## Long enough not to fire on a hiccup, short enough that a game does not sit dead. A
## migration that fires too eagerly is worse than one that fires late: two peers that both
## think they are the host is a split session, and neither of them can tell.
@export_range(1.0, 120.0, 0.5) var host_timeout_sec: float = 8.0

@export_group("Trust")

## What the host is allowed to decide.
##
## [b]A peer-to-peer host is a player's own machine and it can cheat.[/b] There is no
## version of this addon in which that is untrue, so the only question is what a game
## exposes to it. See [enum Trust].
@export var trust: Trust = Trust.HOST_AUTHORITATIVE

enum Trust {
	## The host decides everything. Fast, simple, and the host can cheat freely.
	##
	## Right for a co-operative game among friends, which is most of what P2P is for.
	HOST_AUTHORITATIVE,
	## Peers verify what they can and disagree loudly.
	##
	## Catches a careless host and not a determined one. Worth having because most cheating
	## is careless, and because a disagreement a game can see is a session it can end.
	VERIFIED,
	## The host runs the simulation and nothing leaves the session.
	##
	## No records, no statistics, no entitlements, no leaderboard. What this addon
	## recommends for anything with a persistent reward attached, because a host who can
	## cheat and a leaderboard are not two features — they are one exploit.
	SANDBOXED,
}


func env_prefix() -> String:
	return "DOT_P2P_"


func cli_prefix() -> String:
	return "--p2p-"


## A relay password in the environment ends up in `ps` output and in bug reports.
func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["relay_password", "relay_username"])


func validate() -> DotResult:
	if code_length < 4:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"a join code of %d characters is guessable" % code_length
		)
	if max_peers < 2:
		return DotResult.fail(DotError.CODE_INVALID, "a session for fewer than two")
	if migrate_host and host_timeout_sec < 1.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"a host timeout under a second will fire on a hiccup",
			"two peers that both think they are the host is a split session"
		)
	return DotResult.success(null)


## The ICE server list, in the shape the engine's WebRTC wants.
func ice_servers() -> Array:
	var out := []
	for url in stun_servers:
		out.append({"urls": url})
	for url in relay_servers:
		var entry := {"urls": url}
		if relay_username != "":
			entry["username"] = relay_username
			entry["credential"] = relay_password
		out.append(entry)
	return out


## Whether a pair that cannot find a direct path has anywhere to fall back to.
func has_relay() -> bool:
	return not relay_servers.is_empty()


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("p2p: up to %d peers, %d-character codes" % [max_peers, code_length])
	out.append("  stun    %d, relay %d%s" % [
		stun_servers.size(),
		relay_servers.size(),
		"  (pairs behind strict NAT will fail)" if relay_servers.is_empty() else "",
	])
	out.append("  trust   %s" % ["host authoritative", "verified", "sandboxed"][trust])
	out.append("  migrate %s" % ("yes, after %.1fs" % host_timeout_sec if migrate_host else "no"))
	return out
