class_name ServerConfig
extends RefCounted
## Where the game connects, and which addresses it is allowed to connect to.
##
## PRODUCTION_URL is intentionally empty: set it to the public HTTPS address
## of the deployed server (deploy/.env TT_DOMAIN, e.g. "https://play.example.com")
## before making a store build. Release builds connect only to that address
## and only over TLS; debug builds (editor, tests) may use any server,
## including plain http:// on a LAN.

## TODO(human): the production server address, e.g. "https://play.example.com".
const PRODUCTION_URL := ""
const DEV_URL := "http://127.0.0.1:8080"


## True in exported release builds.
static func is_release() -> bool:
	return not OS.is_debug_build()


## The server a fresh install should talk to.
static func default_url() -> String:
	if PRODUCTION_URL != "":
		return PRODUCTION_URL
	return "" if is_release() else DEV_URL


## Whether players may type their own server address (never in release).
static func allow_custom_server() -> bool:
	return not is_release()


## Whether this build may talk to `url` (REST or live). Release builds
## require TLS: iOS App Transport Security blocks cleartext anyway, and
## account secrets must never cross the network unencrypted.
static func url_allowed(url: String) -> bool:
	var u := url.strip_edges().to_lower()
	if u.begins_with("https://") or u.begins_with("wss://"):
		return true
	if is_release():
		return false
	return u.begins_with("http://") or u.begins_with("ws://")
