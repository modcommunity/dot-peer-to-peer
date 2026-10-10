# dot-peer-to-peer

Sessions players host for each other over WebRTC: a lobby with join codes and a host election every peer computes alone, signallers (loopback, HTTP), and a session node, with an honest account of what peer-to-peer costs (a rendezvous, a relay, a host who can cheat).

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to peer-to-peer.

**The distributable is `addons/dot_peer_to_peer/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). WebRTC is an optional GDExtension and is reached without being named.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: why it is separate from dot-core, the unnamed transport, the election, bind-then-announce, the three costs, codes, ids, signallers, what is not here |
| [docs/history.md](docs/history.md) | touching `host()`, `join()` or the lobby: three ordering bugs |

## Layout

| Path | What |
| --- | --- |
| `core/dot_p2p_config.gd` | `DotP2PConfig`: rendezvous, ICE, `relay_servers`, codes, migration, `Trust` |
| `core/dot_p2p_lobby.gd` | `DotP2PLobby`: members, readiness, codes (`ALPHABET`), `member_ids()`, `elect_host()` |
| `core/dot_p2p_signaller.gd` | `DotP2PSignaller`: `host`, `join`, `send`, `leave` |
| `core/dot_p2p_signaller_loopback.gd` | in-process signalling; static switchboards, `reset_all()` |
| `core/dot_p2p_signaller_http.gd` | post and poll over `DotHttp`; the game calls `poll()` |
| `runtime/dot_p2p_session.gd` | `DotP2PSession`: the node a game holds, the only file touching a transport |
| `examples/p2p_selftest.tscn` | the suite: no network, no WebRTC needed |

Paths except `examples/` are in `addons/dot_peer_to_peer/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/p2p_selftest.tscn`. Keep the "A build with no WebRTC says so" section: asking about an absent transport must be a refusal with a reason, which is the only thing a machine without the extension can prove. The transport itself is not exercised by any suite here.

## Rules that bite

- Never write the `WebRTCMultiplayerPeer` identifier; use `ClassDB` and `call()`. [design](docs/design.md#the-transport-is-never-named)
- The host is elected by arithmetic every peer does (stable, longest-joined, lowest id); never by a message, never by latency. [design](docs/design.md#the-election-is-the-whole-design)
- Sort member ids as Strings, never StringNames. [design](docs/design.md#the-election-is-the-whole-design)
- Check a host claim against the election; the lobby itself never decides who hosts. [design](docs/design.md#the-election-is-the-whole-design)
- Connect handlers before calling the signaller; `await` every signaller call, and await `host()` / `join()`. [design](docs/design.md#bind-first-then-announce-and-await)
- No relay by default and a host can cheat: say so at boot, never hide it behind a default. [design](docs/design.md#the-three-uncomfortable-facts-and-where-each-one-lives)
- Never use `OS.get_unique_id()` for the local id. [design](docs/design.md#decisions)
- Losing the signaller does not end the session; the game, not the signaller, decides when to stop polling. [design](docs/design.md#decisions)
- Call `DotP2PSignallerLoopback.reset_all()` between tests. [design](docs/design.md#decisions)

Deliberately not here: a rendezvous server, NAT traversal, replication, trusting a host, anti-cheat. [design](docs/design.md#deliberately-not-here)
