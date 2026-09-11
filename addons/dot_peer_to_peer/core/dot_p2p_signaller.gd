class_name DotP2PSignaller
extends RefCounted

## How two peers exchange the handful of messages they need to find each other.
##
## [b]Peer-to-peer needs a server to start, and no amount of marketing removes that.[/b]
## Two machines behind two routers cannot find each other without something both can
## reach. What peer-to-peer removes is the server carrying the *game traffic*, which is
## the expensive part; signalling is a few kilobytes once per session.
##
## The interface is deliberately tiny -- four verbs -- because every deployment has a
## different answer for where the rendezvous lives: a backbone, a lobby service, a
## WebSocket the game already has, a QR code and a clipboard. Two ship here:
## [DotP2PSignallerLoopback] for a suite, and [DotP2PSignallerHttp] for anything with a
## URL.

## Something arrived for us. [code]{from, kind, payload}[/code].
signal received(message: Dictionary)

## The signaller's own connection went away. Not the game's.
signal disconnected(reason: String)


## Announces a session and returns its code.
func host(_code: String, _info: Dictionary) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "this signaller cannot host")


## Asks to join a session by code.
func join(_code: String, _info: Dictionary) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "this signaller cannot join")


## Sends one message to one peer, or to everybody when [param to] is empty.
func send(_to: StringName, _kind: StringName, _payload: Dictionary) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "this signaller cannot send")


## Stops. A signaller is finished with once the peers are connected.
##
## [b]Worth actually calling.[/b] The rendezvous is needed to establish a session and not
## to run one, and a game that holds the connection open for the whole match has turned
## its serverless design into a server with extra steps.
func leave() -> void:
	pass


func connected() -> bool:
	return false


func signaller_name() -> String:
	return "none"
