# Design

Why dot-peer-to-peer is shaped the way it is. The one-line rules are in [CLAUDE.md](../CLAUDE.md).

## Why it is not a transport in dot-core

dot-core's own reasoning against a WebRTC transport is that the module ships as an optional GDExtension rather than in standard templates, so a transport there would be untestable in a default install. That is right, and it is why this is a separate repository: **an addon that cannot be tested in a default install must not be one every project depends on.** What makes it testable here is that the untestable part is small. Everything that actually goes wrong with peer-to-peer is in the lobby, and the lobby has no socket in it.

## The transport is never named

A script that mentions an absent class does not fail at runtime; it fails to **compile**, and every script that references it goes down too, as a cascade of errors in files nobody touched. So `DotP2PSession` uses `ClassDB.class_exists`, `ClassDB.can_instantiate`, `ClassDB.instantiate` and `_peer.call("close")`, and the `WebRTCMultiplayerPeer` identifier appears only as a string. `DotTransportENet` reaches ENet the same way for the same reason on web. The suite's "A build with no WebRTC says so" section proves the file still parses and answers on a machine with no extension, which is the dev machine.

## The election is the whole design

```
stable before unstable, then longest in the session, then lowest id
```

**Every peer computes it; nobody is asked.** An election that needs agreement needs a round of messages, and the moment a host disappears is exactly when messages are not arriving. A pure function of a list every peer already has gives the same answer everywhere with no traffic.

- **`DotP2PLobby.member_ids()` sorts Strings, never StringNames.** Godot compares StringNames by interned pointer, so a sort over them gives two peers two orders. That bug gave two dot-net clients two wire ids for one message type; here it would elect two hosts.
- **Longest-joined, not lowest latency.** Latency is measured differently by everybody, and a value two peers disagree about can elect two hosts.
- **A host claim is checked against the election before it is believed.** A peer that declares itself host is how a session is stolen; a claim the election disagrees with is logged and ignored.
- **The lobby decides nothing about hosting.** `add_member` does not make the first member host; `DotP2PSession` sets `host_id` when it hosts and elects otherwise, and the suite asserts a fresh lobby has no host ([history](history.md#add_member-decided-who-hosts)).

## Bind first, then announce, and await

`DotP2PSession` connects its handlers before calling `signaller.join()`, because the loopback signaller answers "here is who is already here" synchronously inside that call. It awaits `signaller.host()` / `join()`, because `DotP2PSignallerHttp`'s are coroutines; so `host()` and `join()` are coroutines and callers **await them**. An await on a plain value does not suspend, so this costs nothing with a synchronous signaller. ([history](history.md#the-session-announced-itself-before-it-could-hear-the-reply))

## The three uncomfortable facts, and where each one lives

| | |
| --- | --- |
| **P2P needs a server to start.** | `DotP2PSignaller`. Signalling is a few kilobytes once; what P2P removes is the *game traffic*. |
| **Without a relay, 5–15% of pairs cannot connect.** | `DotP2PConfig.relay_servers`, empty by default, with the failure fast and named rather than a spinner. |
| **A host is a player and can cheat.** | `DotP2PConfig.Trust`, three values, with `SANDBOXED` recommended for anything with a persistent reward attached. |

None of them is hidden behind a default that looks like it works. A deployment that ships without a relay is making a decision, and the log says so once, at boot, where it can still be acted on.

## The pieces

| | |
| --- | --- |
| `DotP2PConfig` | Rendezvous, ICE, codes, migration, and the trust model. A `DotConfig`. |
| `DotP2PLobby` | Members, readiness, codes, and the election. No connection in it. |
| `DotP2PSignaller` | `host`, `join`, `send`, `leave`: where offers and answers are exchanged. |
| `DotP2PSignallerLoopback` | Several in one process. Suites and split screen. |
| `DotP2PSignallerHttp` | Post and poll, over `DotHttp`, for a deployment with a URL. |
| `DotP2PSession` | The node a game holds. The only file that touches a transport. |

## Decisions

**The join code alphabet** is `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`: no 0/O, no 1/I/l. This matters more than the length: a player reads their code aloud and the other person types a different one, which is the commonest support request any game with a join code has. It costs about a bit and a half per character. Codes are checked for shape before anything is looked up: a better answer for a typo, and not a way to enumerate sessions.

**The local id is not a hardware id.** `OS.get_unique_id()` pushes an error and then returns the empty string on web and iOS (which is why dot-core has `DotPlatform.has_unique_id()`), and a hardware id in a lobby is a permanent identifier a stranger can collect, which is the reason dot-user is pseudonymous per scope.

**The signaller going away is not the session going away.** Connected peers do not need the rendezvous; treating its loss as the end drops everybody because a web server restarted. `_on_signaller_lost` logs at info and does nothing else.

**`DotP2PSignallerHttp.poll()` is called by the game, not by itself.** A self-polling signaller carries on after the session no longer needs it, and a game that polls for the whole match has turned a serverless design into a server with extra steps. Only the caller knows when signalling is finished.

**The loopback signaller has static state, and `reset_all()`.** The one piece of global state in the addon: the alternative, a registry every test threads through, makes tests harder to read without making anything safer. `reset_all()` exists because state that survives a test makes a suite fail on its ninth run for reasons unrelated to the code (game-hungario's dedicated suite did exactly that through `user://`).

## Deliberately not here

- **A rendezvous server.** Four routes, any language. Shipping one would mean shipping a deployment.
- **NAT traversal.** ICE is what the engine's WebRTC does; this configures it and is honest about what it cannot do.
- **Replication.** dot-net is the netcode. This produces a `MultiplayerPeer` and a membership list.
- **Anything that trusts a host**, by construction, and **an anti-cheat**: a host that runs the simulation can lie about all of it. The honest answers are a dedicated server or `SANDBOXED`.
