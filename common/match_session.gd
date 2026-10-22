class_name MatchSession
extends RefCounted
## Session-scoped multiplayer config (static, survives scene changes without an
## Autoload). Configured by the Hangar before entering the battle scene.

enum Mode { LOCAL, ONLINE }

static var mode: int = Mode.LOCAL
static var server_url: String = "http://127.0.0.1:8080"
static var match_id: String = ""
static var team: int = 0
static var token: String = ""   # secret from create/join; authorizes submits
## Live match (short server clock, pushed over the live WebSocket) instead of
## async polling. `live_url` is the server-advertised wss:// URL, or "" to
## derive it from server_url (LiveClient.derive_url).
static var live: bool = false
static var live_url: String = ""
static var seed: int = 12345
static var squad: Array[UnitData] = []
