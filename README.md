# Trion Tactics (World Trigger Battle Sim)

Cross-platform online turn-based strategy game built in **Godot 4.6**.
Simultaneous-execution 3v3 skirmishes in a 3D city, with free movement and
time-based turns, based on the *World Trigger* Away Mission Test Battle
Simulation Exercise.

See `Project Docs/GDDV1.pdf` for the full design document.

## Feature-Based Structure

```
/project.godot
/common/           # Shared resources, math, and data definitions
    /hex_grid/     # Hexagonal grid math (axial coords, pathfinding, mesh)
    /data/         # Core Resource/RefCounted definitions
    /combat/       # Deterministic continuous-time turn engine + shared match runner
    /net/          # JSON codec, HTTP client, HTTP server
/entities/         # Units, actors (future)
/ui/
    /timeline/     # two 6-second lanes per character (the planning UI)
    /event_log/    # On-screen combat log panel
    /hangar/       # pre-match deck-builder (Trigger Holder + Trion budget)
/levels/
    /board/        # 3D city diorama (board + camera + controller)
/server/           # Headless REST backend (async multiplayer)
/test/             # Headless smoke / networking tests
/addons/           # Third-party plugins
```

Naming: `snake_case` for files/folders, `PascalCase` for node names.

## Implemented So Far

### How a turn works
- **Free movement.** Characters stand anywhere on the street, inside a
  building on a floor, or on a roof (`common/map/city_geometry.gd`). A tapped
  destination is routed around buildings (A* on a fine grid + string
  pulling); entering a building, stairs, and Grasshopper jumps take time.
- **Time, not tokens.** Each turn every character gets **6 seconds** and two
  lanes that run side by side (`common/data/turn_plan.gd`): **Movement**
  (Move, Jump, Wait) and **Actions** (attacks, Shield, Look, Bagworm, Spider,
  Wait). Every action takes time (`TriggerCard.action_time`, e.g. Kogetsu
  1.8 s, Ibis 2.4 s); a lane must fit in the turn.
- **Stamina = speed.** Stamina talents raise a character's tempo: every
  action takes less time and it walks faster, so more fits in a turn.
- **Resolution** (`common/combat/turn_engine.gd`): both squads' plans play out
  at once in 0.05 s steps. Attacks land when their wind-up ends, all against
  the same moment; moves that would bump into someone wait (the same rule for
  everyone, whatever the order). The server records a fog-filtered frame
  every 0.25 s that the client replays smoothly.

### Data Definitions — `common/data/`
- `trigger_card.gd` (action time, reach in metres, traits), `unit_data.gd`
  (8-slot Trigger Holder + Trion budget, tempo), `plan_action.gd`,
  `turn_plan.gd` (the two time lanes, timing, validation), `trigger_library.gd`
  (13-card catalog + Move / Look / Wait).

### Global State — `common/squad_store.gd` / `common/match_session.gd`
- `SquadStore` — static player squad (survives Hangar → Battle).
- `MatchSession` — static online config (mode, server URL, match id, team).

### City Map — `common/map/map_data.gd`
- **Every match uses a random part of the city:** a rectangle covering about
  half the sheet (`MapData.SECTION_SHARE`), with a random position and shape
  (at least 18 hexes a side). Faster games, and no two maps alike. The server
  picks it separately from the hidden match seed and sends it to clients
  (`map` in the match state); it is saved with the match.
- The 32×32 flat-top hex map from `Project Docs/Map refrence with building.png`,
  traced hex by hex: the scan's hex lattice was fitted and every hex classified
  as street or building, so streets and building footprints match the sheet
  (472 building hexes in 40 blocks; the sheet is point-symmetric, so it's fair).
- The sheet is top-down and shows no heights: each block is split into
  rectangular segments (towers with lower wings), each with its own height
  (1–4 floors), mirrored across the map so both sides stay fair. Edit the
  digits in `LAYOUT` to change them (keep a segment's hexes the same digit).
- The map sheet is drawn on a hex lattice, which only shapes the buildings;
  play itself is continuous (positions in metres, no tiles).
- Spawns: random open street spots (one connected street area); nobody,
  friend or foe, starts within about 5 m of anyone else (at least
  `MatchRunner.SPAWN_MIN_DISTANCE` ≈ 6.9 m apart, never relaxed on a
  playable map), each facing its most open street. Derived from the hidden match seed, so the server can
  rebuild a match but players can't predict enemy positions.

### Squad & Talents — `common/data/talents.gd`
- Three playable characters: **Assassin** (blades, stealth, jump),
  **Sniper** (Egret / Ibis), **Scout** (Hound / Asteroid, Spider, Lead Bullet).
- Every squad has the same **talent pool** (`Talents.POINTS` = 9) to spread
  over its characters: **Stamina** (+10% speed: actions take less time, faster on foot), **HP** (+15 Trion),
  **ATK** (+1 damage per hit), at most 4 points per stat. Stats are derived
  from talents on the server; client-sent stats are only checked, never
  trusted. The squad (loadouts + talents) is saved in `user://squad.json`.

### Combat Resolution — `common/combat/`
- `unit_state.gd` (position, level, facing angle), `match_state.gd` (squads,
  city, Spider wires), `combat_event.gd` (timestamped).
- `turn_engine.gd` — the deterministic continuous-time turn (see above).
  An attack targets an enemy character and only goes off if the attacker's
  team sees the target at that moment and has a clear line (Viper curves
  around buildings); melee needs the target within reach on the same level.
  Failed shots read the same whatever the reason, so they reveal nothing.
- Triggers: Scorpion strikes around shields, Raygust shields while swinging,
  Viper curves, Hound homes (+hit, beats a moving target's dodge), Egret /
  Ibis are long-range snipers (Ibis pierces shields), Lead Bullet roots the
  target for 3 s, Grasshopper jumps onto roofs, Spider strings a wire your
  team gets +defense / +dodge on. A **Shield** is held for as long as you
  choose; standing still behind it is a **Full Guard** (all round, x1.5).
  Shooting on the move is less accurate; moving targets dodge straight shots.
- `visibility.gd` — per-character vision and fog of war (GDD 4.3): a short
  all-round **detection radius** (3.5 m) and a long **sight cone** (15.6 m,
  ±45°) in the facing direction. Scopes and height extend the sight range.
  Line of sight is traced in 3D against the real building boxes (the same
  geometry that's rendered), so nobody sees through a building; characters
  inside buildings see and are seen only near the outer wall. Unseen enemies
  show as radar pings a few metres off; Bagworm hides from radar until close.
- **Look** keeps a character watching a point, even while it walks.
- `match_runner.gd` — squad placement, the turn recorder (shared by the
  server and local play), winner detection, and the "Stand Ground + Shield"
  AFK fallback.

### Networking — `common/net/`
- `plan_codec.gd` — JSON (de)serialization for squads, plans, and results
  (cards travel by name against the shared catalog).
- `http_backend.gd` — awaitable Godot HTTP client (create/join/submit/get).
- `http_server.gd` — minimal HTTP/1.1 JSON server over `TCPServer`.

### Headless Backend — `server/server.gd`
- REST API: `GET /health`, `POST /match/create`, `POST /match/{id}/join`,
  `POST /match/{id}/submit`, `GET /match/{id}`, `POST /account/matches`
  (resume a running match after a restart).
- Create/join return a secret per-player `token`; submits are attributed to a
  team by token only, and must name the current `turn`. Tokens and account
  secrets travel in the JSON body or an `Authorization: Bearer` header,
  never in the URL.
- Security model (regression-tested in `test/security_test.gd`): the server
  picks every match seed and never sends it (it drives the hit rolls); radar
  ping offsets are keyed with a per-match secret; failed attacks reveal
  nothing about unseen units; enemy Spider wires are sent only when in sight;
  account secrets are stored hashed; names are stripped of markup; per-client
  limits on account creation, match creation, and failed logins; responses
  are written without blocking the server loop.
- Accounts + ranked matchmaking: `POST /account/register`, `GET /account/{id}`,
  `GET /leaderboard`, `POST /queue` (pairs the waiting player closest in
  rating), `GET /queue/{ticket}`, `POST /queue/{ticket}/cancel`. Ranked results
  update both players' hidden Elo rating (K=32). The Hangar's **Live Battle** /
  **Async Ranked** buttons register once per server (saved in
  `user://account.json`) and queue.
- Validates every squad (standard stats, slot rules, Trion budget) and plan
  (only equipped cards, reachable routes, both lanes inside the 6-second turn) before accepting it.
- Server-authoritative deterministic resolution via `MatchRunner`, with
  server-enforced fog of war: `GET /match/{id}?token=…` returns only that
  team's view (own units, enemies in sight, radar pings) and replay
  frames filtered the same way. The opponent's plans and the full state never
  leave the server. Clients catch up on missed turns from the history.
- Matches persist to disk (`TT_DATA_FILE`, default `user://matches.json`) and
  survive restarts; turn timer (default 12h, GDD 3.1) auto-fills missing plans
  with the "Stand Ground + Shield" fallback.

### Live Competitive Play — `common/net/ladder.gd`, `live_hub.gd`, `live_client.gd`
- **Live Battle** is the main ranked mode: both players online, a server-run
  turn clock (60 s for turn 1, 40 s after), early resolve when both lock in,
  and auto-lock of the current plan at the buzzer. Results are pushed over a
  WebSocket (`TT_LIVE_PORT`, default `TT_PORT + 1`) instead of polled.
- 8-turn cap with a tiebreak (units standing, then Trion left, else draw);
  surrender; a player auto-filled 2 turns in a row forfeits (AFK).
- **Trophies & arenas** on top of the hidden rating: ±20–40 per match, arena
  floors, season soft reset (`POST /admin/season/reset`, needs `TT_ADMIN_KEY`).
- Matchmaking pairs by hidden rating with a search window that widens while
  waiting; live and async queues are separate.
- Reconnects resync automatically; `POST /account/delete` deletes an account
  (App Store requirement).
- Launch plan, App Store checklist, and scaling path:
  `docs/multiplayer/LAUNCH_PLAN.md`.
- **Surrender** button in battle (two taps to confirm) in every mode.

### Persistence — `server/db/`
- `GameStore` interface; the server keeps live state in memory and writes
  only changed records behind itself. Pick a backend with `TT_STORE`:
  `json` (one file, default for dev), `dir` (one file per record, the
  single-server production default), `postgrest` (Postgres through PostgREST;
  schema in `deploy/db/`). Postgres writes are batched, coalesced, and
  retried through outages.
- Old tickets and unjoined matches are pruned; finished matches leave memory
  after `TT_MATCH_RETENTION_SEC` (default 24 h) but stay in the store.

### Connection layer — `common/net/`
- `GameConnection` (client): server choice, version handshake against
  `NetProtocol` (old builds are told to update), Online / Offline / Update
  status, account recovery, and the matchmaking flow. `HttpBackend` is the
  transport: concurrent requests, timeouts, GET retries.
- Server hardening (`HttpServer`, `LiveHub`): body/header size limits,
  request timeouts, per-client rate limit (`TT_TRUST_PROXY=1` behind Caddy),
  WebSocket keepalive with dead-link detection, 4 MB resync buffers.

### Board — `levels/board/`
- `city_board.gd` — the dressed street (asphalt, sidewalks, avenue markings,
  lamps), the buildings, free picking (street or roof), and planning overlays
  (routes, range circles, target markers, Spider wires).
- `city_buildings.gd` + `building.gdshader` — rectangular building segments
  with window-grid facades, floor lines, parapets, and rooftop equipment.
- `board_units.gd` — low-poly agents with a role weapon; they glide between
  replay frames, turn to their facing, flash on hits, and bail out. Hidden or
  indoor characters show as x-ray silhouettes; radar pings show unseen enemies.
- `board_camera.gd` — camera clamped to the map and framed around the UI.
- `match_controller.gd` — local (vs AI) and online match orchestration. Local
  play keeps the real match hidden and replays only our team's view of it, the
  same pipeline as online, so the planning UI never knows more than you do.

### UI — `ui/timeline/`, `ui/event_log/`, `ui/hangar/`
- Timeline: unit tabs, the two 6-second lanes on a ruler (blocks as wide as
  the time they take), action cards, hold-time stepper for Shield / Wait.
- Event log: color-coded, auto-scrolling combat log.
- Hangar: talent points panel + Trigger Holder deck-builder with Trion budget + async multiplayer
  host/join controls.

## Run It

**Local play:** open the project in Godot and press F5 (main scene is the Hangar).

**Flow:**
1. **Squad Setup (Hangar)** — spend the talent points and configure each
   character's Trigger Holder, then **Start Match** (local vs AI), **Host
   Online Match** / **Join** (friendly match by ID), **Live Battle** (live
   trophy ladder), or **Async Ranked** (correspondence).
2. **Battle** — tap a character (top tab or on the board): the camera zooms
   in and the spotlight shows exactly what it can see. Tap an action card: it
   goes on the end of its lane (Movement or Actions). Aim it on the board:
   tap the street or a roof for a move (tap a building again for lower
   floors), an enemy for an attack, a spot for Look / Spider. Blocks are as
   wide as the time they take; each lane must fit in 6 seconds. Then
   **Submit Turn** and watch both squads' plans play out together.
3. Turns advance until one squad bails out entirely; a victory/defeat overlay
   offers Rematch or Return to Hangar.

**Vision:** every character's vision is drawn as one shape: the detection
circle plus the sight cone. For the selected character it is also the
spotlight: everything that character can't see is dimmed. The rest of the
squad's are faint, so you can see where everyone is looking. Badges over each
character (pinned to the screen edge when off screen) show where your troops
are and which way they face; tap one to command that character. The shapes
come from 3D physics raycasts against the buildings (the rules use exact
ray-vs-box math on the same geometry, and the smoke test checks the two
agree). Rooftops see farther; stand by an outer wall to see out of a building.

**Controls:** mouse — scroll to zoom, middle-drag to pan, right-drag to
rotate, right-click a block to remove it. Touch — drag to pan, pinch to
zoom, twist to rotate, tap to select, double-tap a block to remove it. The UI scales
to the screen (1280×720 base, landscape).

## Run the Async Backend (Phase 3)

```bash
godot --headless --path . res://server/server.tscn
# optional env vars:
#   TT_PORT=9090               change the port (default 8080)
#   TT_TURN_TIMEOUT_SEC=60     turn timer before auto-fill (default 43200 = 12h)
#   TT_DATA_FILE=matches.json  where matches are saved (default user://matches.json)
#   TT_LIVE_PORT=8081          live WebSocket port (default TT_PORT + 1)
#   TT_PUBLIC_LIVE_URL=wss://play.example.com/live   advertised to clients
#   TT_ADMIN_KEY=<secret>      enables /admin endpoints (season reset)
#   TT_STORE=dir TT_DATA_DIR=store   one file per record (or postgrest + TT_DB_URL)
```

**Production:** `deploy/` has a Docker image and a Compose stack with Caddy
for automatic HTTPS/WSS (required on iOS):

```bash
cp deploy/.env.example deploy/.env   # set TT_DOMAIN, TT_ADMIN_KEY
docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build
```

PowerShell example: `$env:TT_PORT="9090"; godot --headless --path . res://server/server.tscn`

Then in two game clients, point the Hangar's **Server URL** at the server:
one player **Hosts** (copies the match ID), the other **Joins** with that ID.
Each turn both players submit; when both plans are locked in (or the timer
expires), the server resolves deterministically and both clients replay it.

## Tests (headless)

```bash
godot --headless --path . res://test/rules_test.tscn   # combat rules + server validation
godot --headless --path . res://test/smoke_test.tscn   # local multi-turn flow
godot --headless --path . res://test/net_test.tscn     # backend create/join/submit/resolve
godot --headless --path . res://test/online_test.tscn  # full online client flow
godot --headless --path . res://test/live_test.tscn    # live ladder, clock, AFK, trophies, surrender
godot --headless --path . res://test/store_test.tscn   # persistence: restart, Postgres (fake), outage
godot --headless --path . res://test/security_test.tscn  # abuse / cheating regressions (rules + server)
godot --headless --path . res://test/stress_test.tscn    # random plans over many turns: client and server agree
```

CI (`.github/workflows/tests.yml`) runs all suites and builds the server image.

Each prints `PASS`/`FAIL` and exits non-zero on failure.

**Visual check** (opens a window, saves a PNG of the battle scene):

```bash
godot --path . res://test/screenshot.tscn -- out.png [ortho_size] [pitch_deg] [turns]
```

After adding new `class_name` scripts, run `godot --headless --editor --quit --path .`
once so Godot registers them before running headless tests.

## Next Up

- Launch blockers and next steps are tracked in `docs/multiplayer/LAUNCH_PLAN.md`
  (IP licensing, Sign in with Apple / Steam login, Keychain, store exports).
- Before a store build: set `ServerConfig.PRODUCTION_URL`
  (`common/net/server_config.gd`) and fill `common/net/blocked_names.txt`.
- Real-time spectating over the live channel (GDD 2.2).
- Phase 4 polish: low-poly models, toon shaders, and balancing action times,
  Trion weights, and penchant modifiers from playtests.
- Scale-out: the JSON store suits one server; Postgres + match workers for
  many (see the launch plan).
