# dot-peer-to-peer

Sessions players host for each other, and an honest account of what that costs.

**The distributable is `addons/dot_peer_to_peer/`.** It requires [dot-core](../dot-core), a separate repository, and nothing else. WebRTC is optional and is reached without being named.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## Why this exists, and why dot-core said it should not

dot-core's own "things deliberately not here" said, of a WebRTC transport: *"the module ships as an optional GDExtension rather than in standard templates, so a transport implementation would be untestable in a default install."* That is exactly right, and it is why this is a separate repository rather than a fifth transport in dot-core: **an addon that cannot be tested in a default install must not be one every project depends on.**

What makes it testable here is that the untestable part is small. Everything that actually goes wrong with peer-to-peer is in the lobby, and the lobby has no socket in it.

## The transport is never named, and that is not caution

A script that mentions an absent class does not fail at runtime. It fails to **compile**, and every script that references *it* goes down with it, as a cascade of errors in files nobody touched — which this tree already knows from the other end, where a Git checkout left a text file where an addon symlink should have been and seventy scripts stopped parsing.

So: `ClassDB.class_exists`, `ClassDB.can_instantiate`, `ClassDB.instantiate`, and `_peer.call("close")`. No `WebRTCMultiplayerPeer` identifier anywhere. `DotTransportENet` reaches ENet the same way for the same reason on web, and the suite's last section exists to prove this file still parses and answers on a machine with no extension at all — which is this machine.

## The election, which is the whole design

```
stable before unstable, then longest in the session, then lowest id
```

**Every peer computes it; nobody is asked.** An election that needs agreement needs a round of messages, and the moment a host disappears is exactly the moment messages are not arriving. A pure function of a list every peer already has gives the same answer everywhere with no traffic.

Two consequences are load-bearing:

- **`member_ids()` sorts Strings, never StringNames.** Godot compares StringNames by their interned pointer, so a sort over them gives two peers two different orders. That exact bug gave two clients two different wire ids for one message type in dot-net and was invisible until a real browser — the first peer that was a separate program — connected. Here it would elect two hosts.
- **Longest-joined rather than lowest latency.** Latency is measured differently by everybody, and a value two peers disagree about is a value that can elect two hosts.

A host *claim* is checked against the election before it is believed. A peer that declares itself host is how a session is stolen, and there is never a reason to believe a claim over arithmetic every peer can do.

## What building it found

**The session announced itself before it could hear the reply.** `join()` called `signaller.join()` and *then* connected its handler — and the loopback signaller delivers "here is who is already here" synchronously, inside that call. The joiner ended up alone in a lobby with two people in it. This family has the lesson twice already: *"nothing may be sent to a peer before it says it can receive"* (dot-server's signon) and *"a signal is not a state"* (game-playground's black screen). Bind first, then announce.

**And it did not wait for the answer.** `host()` and `join()` called `signaller.host()`/`join()` without `await`, and `DotP2PSignallerHttp`'s are coroutines (a POST). In Godot 4.7 that is not a late result: it is a SCRIPT ERROR, "Trying to call an async function without await", which aborts `host()` and hands the caller null with the session still idle. Every test used the loopback signaller, which answers synchronously, so the one real signaller had never worked. Both are awaited now, which makes `host()` and `join()` coroutines — **await them** — and costs nothing with a synchronous signaller, since an await on a plain value does not suspend. The suite's section 8 runs the real HTTP signaller over a `DotHttp` that answers a frame later.

**And `add_member` quietly decided who hosts.** The convenience — "if nobody is hosting, this one is" — makes the answer depend on which of two messages arrived first, so a joiner that added itself before its signaller had spoken declared itself host of somebody else's session. It is the same bug as the first one wearing different clothes, and it survived the fix to the first one. The lobby now decides nothing; `DotP2PSession` sets `host_id` when it hosts and elects otherwise, and the suite asserts a fresh lobby has **no** host.

## The three uncomfortable facts, and where each one lives

| | |
| --- | --- |
| **P2P needs a server to start.** | `DotP2PSignaller`. Signalling is a few kilobytes once; what P2P removes is the *game traffic*. |
| **Without a relay, 5–15% of pairs cannot connect.** | `DotP2PConfig.relay_servers`, empty by default, with the failure fast and named rather than a spinner. |
| **A host is a player and can cheat.** | `DotP2PConfig.Trust`, three values, with `SANDBOXED` recommended for anything with a persistent reward attached. |

None of them is hidden behind a default that looks like it works. A deployment that wants to ship without a relay is making a decision, and the log says so once, at boot, where it can still be acted on.

## The pieces

| | |
| --- | --- |
| `DotP2PConfig` | Rendezvous, ICE, codes, migration, and the trust model. A `DotConfig`. |
| `DotP2PLobby` | Members, readiness, codes, and the election. No connection in it. |
| `DotP2PSignaller` | Four verbs. Where offers and answers are exchanged. |
| `DotP2PSignallerLoopback` | Several in one process. Suites and split screen. |
| `DotP2PSignallerHttp` | Post and poll, over `DotHttp`, for a deployment with a URL. |
| `DotP2PSession` | The node a game holds. The only file that touches a transport. |

## Decisions

### The join code alphabet

`23456789ABCDEFGHJKLMNPQRSTUVWXYZ`. No 0/O, no 1/I/l. **This matters more than the length**: a player reads their code aloud and the other person types a different one, which is the commonest support request any game with a join code has. It costs about a bit and a half per character.

Codes are checked for shape before anything is looked up: a better answer for a typo, and not a way to enumerate which sessions exist.

### The local id is not a hardware id

`OS.get_unique_id()` is deliberately unused. It **pushes an error and then returns the empty string** on web and iOS — a red line on a page a player has open, naming a function nobody called on purpose, which is why dot-core grew `DotPlatform.has_unique_id()`. And a hardware id in a lobby is a permanent identifier a stranger can collect, which is the whole reason dot-user is pseudonymous per scope.

### The signaller going away is not the session going away

Once peers are connected they do not need the rendezvous. Treating its loss as the end is how a game drops everybody because a web server restarted. `_on_signaller_lost` logs at info and does nothing else.

### `DotP2PSignallerHttp.poll()` is called by the game, not by itself

A signaller that polls on its own carries on after the session no longer needs it, and a game that polls for the whole match has turned a serverless design into a server with extra steps and a request every two seconds. The caller is the only one who knows when signalling is finished.

### The loopback signaller has static state, and a `reset_all()`

The one piece of global state in this addon, and it is there because the alternative — a registry every test threads through — makes the test harder to read without making anything safer. `reset_all()` exists because state that survives a test is the bug game-hungario's dedicated suite shipped: it wrote to `user://`, totals accumulated across runs, and it began failing on its ninth run for a reason that had nothing to do with the code.

## Things deliberately not here

- **A rendezvous server.** Four routes, any language. Shipping one would mean shipping a deployment.
- **A NAT traversal implementation.** ICE is what the engine's WebRTC does; this configures it and is honest about what it cannot do.
- **Replication.** dot-net is the netcode. This produces a `MultiplayerPeer` and a membership list; what travels over it is not this addon's business.
- **Anything that trusts a host.** By construction. See `Trust`.
- **An anti-cheat.** A host that runs the simulation can lie about all of it. The only honest answers are a dedicated server or `SANDBOXED`.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 120 godot --headless --path . res://examples/p2p_selftest.tscn
```

8 sections, 87 checks, none of which needs a network or the WebRTC extension. **The last section is the one to keep**: it asserts that asking about an absent transport is a refusal with a reason rather than a crash, which is the only thing a machine without the extension can prove and is exactly the thing that would otherwise break silently.
