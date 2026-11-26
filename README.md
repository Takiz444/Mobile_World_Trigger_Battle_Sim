# Trion Tactics (World Trigger Battle Sim)

Cross-platform online turn-based strategy game built in **Godot 4.6**.
Simultaneous-execution 3v3 skirmishes in a low-poly **Tokyo** (real districts
built from OpenStreetMap), with free movement and time-based turns, based on
the *World Trigger* Away Mission Test Battle Simulation Exercise.

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
  building on its ground floor, or on a roof (`common/map/city_geometry.gd`). A tapped
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

### The Battlefield: Tokyo — `common/map/tokyo_map.gd`
- **The city is Tokyo**, built from official and open map data in a
  low-poly style: every building footprint and its **measured height** from
  **Project PLATEAU** (MLIT's 3D city model of the 23 wards), checked against
  the **GSI** national base map; streets, railways, water, parks and street
  furniture from **OpenStreetMap**. Twelve real districts ship with the game (`common/map/tokyo/`):
  Shibuya (Scramble Crossing), Shinjuku (Kabukicho), Akihabara, Ginza,
  Asakusa (Kaminarimon & the Sumida), Ikebukuro, Ueno (Ameyoko), Roppongi,
  Harajuku, Nihonbashi, Shimokitazawa, and Shiba (Tokyo Tower & Kamiyacho).
  Each is a square of real city 800–960 m a side at **1 game unit = 2.5 m**,
  turned so its main street grid runs along the screen axes.
- **Every match is fought in a battle zone** in the built-up city (at least
  half of the zone's blocks covered by buildings: no empty grounds): a set
  of whole city blocks
  the **size and shape of the original battle map** (the 32×32 hex sheet:
  about 2,730 square units, 48.5 × 56.3, roughly 130 m across; zones are
  never longer than 1.6 to 1) with a border you can read on the ground:
  - small streets and footpaths around and between its blocks are in the
    zone at full width (the border runs along the far curb),
  - avenues, highways and railways are a hard edge (the border runs along
    the near curb) unless the zone takes the blocks on both sides,
  - big parks are their own blocks; a park too big for a zone is divided
    along footpaths (drawn on the ground),
  - medians and traffic islands count as road, so no zone grabs a strip of
    an avenue; by a river the zone takes a strip of water along the bank.
  - zones are **as rectangular as the blocks allow**: the build
    (`tools/tokyo/zones.py`) tries rectangles turned to the local street
    grid, keeps the blocks mostly inside, and prefers the zones that fill
    most of their rectangle; the outline is then straightened (sides along
    the streets snapped to them, small steps folded in), so the red line is
    a few clean straight sides,
  - zones keep **80 m (32 units) clear of the edge of the map data**.
  A well-spread set is kept per district (`common/map/tokyo/*.json` "zones").
  The server picks one from the match seed (`TokyoMap.random_section`) and
  sends it as `"map": ["asakusa", 12]`; it is saved with the match. Outside
  the zone nothing can be reached (street, roof or interior). Around it the
  rest of the district is drawn as **plain grey boxes** on ground that
  **darkens in a gradient** away from the zone (per pixel, from the zone
  polygon), and a **red line and low red curtain** follow its edge. Where
  the map data ends the city fades into **fog** along a wavy front: no
  made-up blocks, no hard edge.
- **City geometry** (`common/map/city_box.gd`, `city_geometry.gd`): every
  solid thing is an oriented box (real streets run at every angle):
  *buildings* (enterable: ground floor + roof, 1–7 floors), *sealed solids*
  (skyscrapers over ~20 storeys, temples, viaduct and expressway piers, gate
  posts: block walking and sight, nobody stands on them), and *elevated
  decks* (JR / metro viaducts, the Shuto Expressway, gate roofs: block sight
  between their heights only, you walk underneath). Rivers, canals and
  fenced at-grade railways (`blocked_mask.gd`) can't be walked on but are
  seen across; bridges and level crossings cross them, and Grasshopper can
  jump a narrow canal. Tapping a spot nobody can reach says why ("That's
  the Sumida River…", "Railway tracks are fenced off…", "That's outside the
  battle zone…", `CityGeometry.why_not`). The same boxes are drawn, traced for sight, and used
  for physics, and tests check they agree.
- **Heights** are PLATEAU's measured heights, compressed so streets stay
  visible from the camera: under 7.5 m → 1 floor, 12 → 2, 18 → 3, 25 → 4,
  34 → 5, 45 → 6, 60 m → 7 floors (all enterable); taller buildings are
  sealed towers drawn up to 22 units high. Footprints that overhang a
  carriageway are trimmed, so roads stay open.
- **Checked against the real map**: each district's build records how well
  it matches (`"quality"` in its JSON): PLATEAU covers 89–99% of the GSI base
  map's buildings, and the game's boxes reproduce 90%+ of the PLATEAU
  footprints at 98%+ precision; `tokyo_test` enforces these.
- **Map data pipeline** (`tools/tokyo/`, see its README): `fetch_osm.py`
  downloads each district from the Overpass API, `build_districts.py`
  simplifies it (oriented boxes, triangulated water / parks / land,
  roads and rail as polylines, decks + piers, street furniture placement)
  into the JSON the game loads. Add a district by adding it to
  `districts.py` and re-running both. **Map data © OpenStreetMap
  contributors (ODbL)**: the credit is shown in every battle.
- The old 32×32 hex map sheet (`map_data.gd`, from
  `Project Docs/Map refrence with building.png`) is kept for test arenas and
  so matches saved before Tokyo can finish. The Welcome screen's **Test**
  button (bottom left) starts an offline match vs AI on a random half of
  the sheet (`MapData.random_section`, new each match)
  (`MatchSession.test_stage`, cleared by the Hangar) for development.
- Spawns: random open street spots in the section's largest connected
  street area; nobody, friend or foe, starts within about 7 m of anyone else
  (`MatchRunner.SPAWN_MIN_DISTANCE`), each facing its most open street.
  Derived from the hidden match seed, so the server can rebuild a match but
  players can't predict enemy positions.

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

### Sign-in & Profiles — `ui/welcome/`, `ui/profile/`
- **First screen** (`ui/welcome/welcome.tscn`, the main scene): sign in with
  email + password, create an account, or **Continue as Guest**. Signed-in
  players go straight to the Hangar. **Test** (bottom left) opens the
  development test stage on the original map. Guests can play everything: offline
  needs no account, and online play makes a guest account kept on that
  device only. Creating an account while a guest account is saved moves its
  trophies and history to the new account.
- Server: `POST /account/signup`, `/account/login`, `/account/logout`,
  `/account/profile`, `/account/password_reset`. **Auth0** (`TT_AUTH0_*`,
  `server/auth0_client.gd`) holds the passwords and sends verification and
  password-reset emails; the server checks credentials with Auth0 and links
  each account to its Auth0 user. Without Auth0 (development), passwords are
  stored as PBKDF2-HMAC-SHA256 hashes (`server/password_hash.gd`), computed
  on a worker thread so a login never stalls the match clocks. Setup:
  `deploy/README.md` ("Auth0"). Each signed-in device gets its own session
  secret; emails are never shown to other players. Wrong passwords count
  toward the failed-login lockout.
- **Profile** (Hangar → Profile): current rank (trophies + arena), max rank
  (best trophies + arena), ladder position, skill rating (now / peak), win
  rate with W/L/D, current and best win streak, **favorite move** (most used
  trigger or action, with the top 5), and the last 50 matches (result,
  opponent, mode, how it ended, turns, units standing, trophy change). Every
  finished match with an account in a seat counts: ranked, and friendly rooms
  created or joined while you have an account. Auto-filled turns don't count
  toward move stats.
- Launch plan, App Store checklist, and scaling path:
  `docs/multiplayer/LAUNCH_PLAN.md`.
- **Surrender** button in battle (two taps to confirm) in every mode.

### Persistence — `server/db/`
- `GameStore` interface; the server keeps live state in memory and writes
  only changed records behind itself. Pick a backend with `TT_STORE`:
  `json` (one file, default for dev), `dir` (one file per record),
  `mongo` (**MongoDB**, the default for new deployments), `postgrest`
  (Postgres through PostgREST; schema in `deploy/db/`). Network stores batch,
  coalesce, and retry writes through outages.
- **MongoDB** (`server/db/mongo_store.gd` + `deploy/mongo-gateway/`): Godot has
  no MongoDB driver, so a small Node service with the official driver (the
  "gateway", internal only, token-protected) does the database work. Each
  record kind is a collection (`accounts`, `matches`, `tickets`, `meta`) and
  each record a plain document keyed by its id, so you can query it directly,
  e.g. `db.accounts.find({ email: "…" })`. Accounts have a unique email index.
  `import-dir.js` / `export-dir.js` move data between the file store and
  MongoDB (migration and backups).
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
- `city_board.gd` — free picking (street or roof; sealed towers refuse a
  move), planning overlays (routes, range circles, target markers, Spider
  wires), and the city: Tokyo (`tokyo_city.gd`) or the old hex sheet
  (`city_buildings.gd`).
- `tokyo_city.gd` + `tokyo_building.gdshader` — the low-poly city: every
  box of the district in one MultiMesh, with facades per building type
  (houses, balcony-banded apartments, office ribbon glass, lit shopfronts,
  glass towers), varied roofs and rooftop clutter; physics solids and roof
  pick bodies for the play area; the district beyond as scenery.
- **Cutaway**: walls and roofs between the camera and the selected
  character are cut away in a small dithered circle, so it and the street
  around it stay visible among tall buildings.
- `tokyo_ground.gd` + `tokyo_water.gdshader` — land (block interiors darker
  than the sidewalks that line every street), parks, roads with curbs, lane
  markings and zebra crossings (Shibuya's diagonal scramble too), rivers sunk
  between railed embankment walls with moving faceted water, bridges, fenced
  railway tracks. Yakatabune and water buses bob on the bigger rivers.
- `tokyo_props.gd` + `low_poly.gd` — street furniture (trees, with autumn
  ginkgo, lamps, utility poles and wires, vending machines, neon blade signs
  and screens, traffic signals, torii) and landmarks (Tokyo Tower,
  Kaminarimon with its lantern, the Kabukicho gate, pagodas and temple
  roofs, Skytree on Asakusa's skyline, Tokyo Tower as a full lattice over
  its Foot Town). Open-air parking lots are asphalt with parked cars. Flat-shaded vertex-colored meshes
  sharing two materials.
- `place_banner.gd` — the "SHIBUYA · Scramble Crossing" title card at the
  start of a match and the map-data credit.
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
#   TT_STORE=mongo TT_MONGO_GATEWAY_URL=http://127.0.0.1:8095 TT_MONGO_GATEWAY_TOKEN=dev-token
```

Settings and secrets go in **`deploy/.env`** (copy `deploy/.env.example`):
the server reads it at startup when run as `server.tscn`, and so does the
Mongo gateway. See `deploy/README.md` ("Where settings go") for MongoDB and
Auth0. MongoDB locally without installing it: `cd deploy/mongo-gateway &&
npm ci && npm run dev` (a throwaway in-memory MongoDB plus the gateway on `:8095`).

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
godot --headless --path . res://test/tokyo_test.tscn   # Tokyo map: data, sections, boxes, water, render = rules
godot --headless --path . res://test/smoke_test.tscn   # local multi-turn flow
godot --headless --path . res://test/net_test.tscn     # backend create/join/submit/resolve
godot --headless --path . res://test/online_test.tscn  # full online client flow
godot --headless --path . res://test/live_test.tscn    # live ladder, clock, AFK, trophies, surrender
godot --headless --path . res://test/store_test.tscn   # persistence: restart, Postgres/Mongo (fakes), outage
godot --headless --path . res://test/account_test.tscn # sign-in, sessions, guest upgrade, profiles, history
godot --headless --path . res://test/auth0_test.tscn   # Auth0 sign-in (fake Auth0), deploy/.env loading
cd deploy/mongo-gateway && npm test                    # the Mongo gateway against a real mongod
godot --headless --path . res://test/security_test.tscn  # abuse / cheating regressions (rules + server)
godot --headless --path . res://test/stress_test.tscn    # random plans over many turns: client and server agree
```

CI (`.github/workflows/tests.yml`) runs all suites, the gateway tests, the store
test against a real gateway + MongoDB, and builds both images.

Each prints `PASS`/`FAIL` and exits non-zero on failure.

**Visual check** (opens a window, saves a PNG of the battle scene):

```bash
godot --path . res://test/screenshot.tscn -- out.png [ortho_size] [pitch_deg] [turns]
```

**Tokyo map views** (any district or section, the game's lighting):

```bash
godot --path . res://test/tokyo_shot.tscn -- out.png shibuya [ortho] [pitch] [yaw] [dx] [dz]
godot --path . res://test/tokyo_shot.tscn -- out.png 1234      # random section of seed 1234
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
