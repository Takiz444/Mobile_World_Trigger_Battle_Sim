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

## 3: credentials moved out of URLs (Authorization header / body), the match
##    seed is no longer sent, `turn` is mandatory on submit, account resume.
## 4: three-character squads with talent points; random spawns.
## 5: vision is a detection radius plus one sight cone.
## 6: detection radius 2.
## 7: each match is played on a random section of the city ("map" field).
## 8: free movement in continuous space and time-based turns (no hexes, no AT).
## 9: matchmaking ready check (ticket status "found" + POST /queue/{t}/accept),
##    queue heartbeats, Glicko-2 ratings.
const VERSION := 9
const MIN_SUPPORTED := 9


static func is_supported(client_version: int, min_supported: int = MIN_SUPPORTED) -> bool:
	return client_version >= min_supported
