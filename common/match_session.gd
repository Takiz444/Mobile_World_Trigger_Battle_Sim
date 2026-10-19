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
static var seed: int = 12345
static var squad: Array[UnitData] = []
