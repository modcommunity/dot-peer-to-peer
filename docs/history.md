# History

What building dot-peer-to-peer found. Three forms of one bug: an answer that depended on which message arrived first. The rules are in [design.md](design.md).

## The session announced itself before it could hear the reply

`join()` called `signaller.join()` and *then* connected its handler, and the loopback signaller delivers "here is who is already here" synchronously inside that call. The joiner ended up alone in a lobby with two people in it. The family has the lesson twice already: nothing may be sent to a peer before it says it can receive (dot-server's signon), and a signal is not a state. Bind first, then announce.

## It did not wait for the answer

`host()` and `join()` called `signaller.host()` / `join()` without `await`, and `DotP2PSignallerHttp`'s are coroutines. In Godot 4.7 that is not a late result but a script error ("Trying to call an async function without await") that aborts `host()` and hands the caller null with the session idle. Every test used the loopback signaller, which answers synchronously, so the one real signaller had never worked. The suite's "The HTTP signaller answers later" section now runs it over a `DotHttp` that answers a frame later.

## `add_member` decided who hosts

The convenience "if nobody is hosting, this one is" made the answer depend on which of two messages arrived first, so a joiner that added itself before its signaller had spoken declared itself host of somebody else's session. It survived the fix to the first bug. The lobby now decides nothing about hosting.
