This is the **peer-to-peer** asset for TMC's **Dot** collection. It adds sessions players host for each other: join codes, readiness, deterministic host migration, and an honest account of what NAT will not do for you.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

## Peer-to-peer is a lobby problem before it is a transport problem

The transport half is a dozen calls into an engine module. Everything that actually goes wrong is in the lobby: two people joining the same slot, a code that was already used, a host leaving and nobody agreeing who takes over, **two peers that both think they are the host**. None of it involves a socket.

`DotP2PLobby` holds no connection at all, which is why every one of those is checked by a headless suite.

## The host election is a pure function, and nobody is asked

```gdscript
lobby.elect_host()     # stable first, then longest here, then lowest id
```

Every peer computes it from a member list they all already have. An election that requires *agreement* needs a round of messages, and the moment a host disappears is precisely the moment messages are not arriving.

The tie-break is total and deterministic, because two peers picking differently is a split session that neither of them can detect. Longest-joined rather than lowest latency: latency is measured differently by everybody, and a value two peers disagree about is a value that can elect two hosts.

## Three honest things this asset will not hide

**Peer-to-peer needs a server to start.** Two machines behind two routers cannot find each other without something both can reach. What P2P removes is the server carrying the *game traffic*, which is the expensive part. The rendezvous is a few kilobytes, once.

**Without a relay, some pairs simply cannot connect.** Somewhere between five and fifteen per cent: symmetric NAT on both sides, carrier-grade NAT, and some corporate and mobile networks. `relay_servers` is empty by default because a relay costs bandwidth and nobody can choose that for you; with none configured, those pairs fail **quickly and by name** rather than hanging, because "we could not find a route to that player" is something a person can act on and a spinner is not.

**A host is a player, and can cheat.** There is no version of this where that is untrue, so the only question is what a game exposes. `DotP2PConfig.Trust` makes it a decision: host-authoritative (right for co-op among friends), verified (catches a careless host, not a determined one), or sandboxed, where nothing leaves the session: no records, no statistics, no leaderboard. **A host who can cheat and a leaderboard are not two features. They are one exploit.**

## The transport is never named

Godot's WebRTC ships as an optional GDExtension on native and is built into the web export. On a desktop build without it, every WebRTC class is simply **absent**, and a script that so much as *mentions* the identifier fails to compile, taking every script that references it down as a cascade of errors in files nobody touched.

So everything goes through `ClassDB.instantiate` by string, exactly the way dot-core reaches ENet on web. A build without it still parses, still runs, and says which of the two reasons it is:

```gdscript
if not DotP2PSession.available():
    push_warning(DotP2PSession.unavailable_reason())
```

## The join code alphabet matters more than its length

`23456789ABCDEFGHJKLMNPQRSTUVWXYZ`, with no 0, O, 1, I or l. A player reading their code aloud and the other person typing a different one is the commonest support request any game with a join code has. Six characters from that alphabet is about a billion codes.

A code is checked for **shape** before anything is looked up, which is both a better answer for a typo and not a way to find out which sessions exist.

## Using it

```gdscript
var p2p := DotP2PSession.new()
p2p.config = my_config
p2p.signaller = DotP2PSignallerHttp.new(url, my_id, http)
add_child(p2p)
p2p.setup()

var code = (await p2p.host("Ada")).value   # show this to a friend
await p2p.join("K7M4PX", "Bob")                # or type theirs
```

`DotP2PSignaller` is four verbs. A loopback one ships for suites and split screen; an HTTP one ships for anything with a URL and four routes. A backbone, a lobby service, or a WebSocket the game already has are all subclasses.

## Installing

Copy `addons/dot_peer_to_peer/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable it in **Project → Project Settings → Plugins**.

## Dependencies

[dot-core](https://github.com/modcommunity/dot-core). Nothing else. WebRTC is optional and is reached without being named.

## Licence

MIT. See [LICENSE](LICENSE).
