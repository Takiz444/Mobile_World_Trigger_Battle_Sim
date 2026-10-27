class_name NetProtocol
extends RefCounted
## Wire-protocol version shared by client and server. Store builds stay on
## players' phones for weeks, so the server must tell old builds to update
## instead of failing in odd ways.
##
## Bump VERSION on any change to request/response shapes, the live message
## set, or the combat rules (the server resolves turns, but clients replay
## and preview with the same code). Raise MIN_SUPPORTED when the server
## drops support for older clients.
##
## The client checks GET /health on connect (GameConnection) and sends its
## version in the live "hello"; the server answers an outdated client with
## {type: "error", code: "outdated"}.

const VERSION := 2
const MIN_SUPPORTED := 2


static func is_supported(client_version: int, min_supported: int = MIN_SUPPORTED) -> bool:
	return client_version >= min_supported
