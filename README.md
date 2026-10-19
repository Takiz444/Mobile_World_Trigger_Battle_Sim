# Trion Tactics (World Trigger Battle Sim)

Cross-platform online turn-based strategy game built in **Godot 4.6**.
Simultaneous-execution 4v4 hex-grid skirmishes based on the *World Trigger*
Away Mission Test Battle Simulation Exercise.

See `Project Docs/GDDV1.pdf` for the full design document.

## Feature-Based Structure

```
/project.godot
/common/           # Shared resources, math, and data definitions
    /hex_grid/     # Hexagonal grid math (axial coords, pathfinding, mesh)
    /data/         # Core Resource/RefCounted definitions
    /combat/       # Deterministic tick engine + shared match runner
    /net/          # JSON codec, HTTP client, HTTP server
/entities/         # Units, actors (future)
/ui/
    /timeline/     # 6-tick timeline ribbon + drag-and-drop planning UI
    /event_log/    # On-screen combat log panel
    /hangar/       # pre-match deck-builder (Trigger Holder + Trion budget)
/levels/
    /board/        # 3D tabletop diorama (hex board + camera + controller)
/server/           # Headless REST backend (async multiplayer)
/test/             # Headless smoke / networking tests
/addons/           # Third-party plugins
```

Naming: `snake_case` for files/folders, `PascalCase` for node names.

## Implemented So Far

### Hex Grid Math — `common/hex_grid/hex_coord.gd`
- Axial ⇄ cube conversion, neighbors/ring/line, 3D (XZ) mapping, deterministic A*.

### Data Definitions — `common/data/`
- `trigger_card.gd`, `unit_data.gd` (8-slot Trigger Holder + Trion budget),
  `tick_action.gd`, `turn_plan.gd` (6-tick AT economy), `trigger_library.gd`
  (13-card catalog + `get_card(name)` for network serialization).

### Global State — `common/squad_store.gd` / `common/match_session.gd`
- `SquadStore` — static player squad (survives Hangar → Battle).
- `MatchSession` — static online config (mode, server URL, match id, team).

### City Map — `common/map/map_data.gd`
- 18×24 hex city modelled on `Project Docs/Map refrence with building.png`:
  building blocks (1–4 floors), streets, half/full cover, four spawns per team.
- Authored as text for the top half and rotated 180° for the bottom half, so
  both sides are identical. Shared by client and server.

### Combat Resolution — `common/combat/`
- `unit_state.gd`, `match_state.gd`, `combat_event.gd`
- `tick_engine.gd` — deterministic 6-tick pipeline (resumable per-tick).
  Simultaneous movement on (hex, floor) cells, per-slot targets (Main and Sub
  aim independently), buildings block shots (Viper curves around), and
  Bagworm as a per-turn toggle (1 AT per turn, drops when attacking).
- `visibility.gd` — fog of war (GDD 4.3): forward vision cones + all-round
  awareness, line of sight blocked by buildings/full cover, radar pings offset
  1–2 hexes for unseen enemies, Bagworm hides from radar until within 3 hexes.
- `match_runner.gd` — shared squad placement, turn resolution, winner detection,
  and the GDD 3.1 "Stand Ground + Shield" fallback plan. Used by both the local
  client and the headless server.

### Networking — `common/net/`
- `plan_codec.gd` — JSON (de)serialization for squads, plans, and results
  (cards travel by name against the shared catalog).
- `http_backend.gd` — awaitable Godot HTTP client (create/join/submit/get).
- `http_server.gd` — minimal HTTP/1.1 JSON server over `TCPServer`.

### Headless Backend — `server/server.gd`
- REST API: `GET /health`, `POST /match/create`, `POST /match/{id}/join`,
  `POST /match/{id}/submit`, `GET /match/{id}`.
- Create/join return a secret per-player `token`; submits are attributed to a
  team by token only, and must name the current `turn`.
- Validates every squad (standard stats, slot rules, Trion budget) and plan
  (only equipped cards, AT budget) before accepting it.
- Server-authoritative deterministic resolution via `MatchRunner`, with
  server-enforced fog of war: `GET /match/{id}?token=…` returns only that
  team's view (own units, enemies in sight, radar pings) and per-tick replay
  frames filtered the same way. The opponent's plans and the full state never
  leave the server. Clients catch up on missed turns from the history.
- Matches persist to disk (`TT_DATA_FILE`, default `user://matches.json`) and
  survive restarts; turn timer (default 12h, GDD 3.1) auto-fills missing plans
  with the "Stand Ground + Shield" fallback.

### Hex Mesh & Board — `common/hex_grid/hex_mesh.gd`, `levels/board/`
- Procedural hex-prism meshes, hover/selection raycasting, orbit/pan/zoom camera.
- `board_units.gd` — team-colored markers standing on the tile surface,
  tweened movement/facing, damage flash, bail-out, and radar-ping markers.
- `hex_board.gd` — map tiles, translucent stacked-floor buildings, cover props,
  and the fog overlay (tiles outside your team's sight are darkened).
- `board_camera.gd` — camera clamped to the map and framed around the UI.
- `match_controller.gd` — local (vs AI) and online (async) match orchestration,
  multi-turn lifecycle, win/loss overlay, and replay animation.

### UI — `ui/timeline/`, `ui/event_log/`, `ui/hangar/`
- Timeline: unit tabs, 6-tick Main/Sub ribbon, draggable card hand, AT meter.
- Event log: color-coded, auto-scrolling combat log.
- Hangar: Trigger Holder deck-builder with Trion budget + async multiplayer
  host/join controls.

## Run It

**Local play:** open the project in Godot and press F5 (main scene is the Hangar).

**Flow:**
1. **Hangar** — configure each unit's Trigger Holder, then **Start Match**
   (local vs AI) or **Host Online Match** / **Join** (async multiplayer).
2. **Battle** — click a tick slot → click a hex to target it → drag cards into
   slots → **Submit All** to watch the animated replay in the combat log.
3. Turns advance until one squad bails out entirely; a victory/defeat overlay
   offers Rematch or Return to Hangar.

## Run the Async Backend (Phase 3)

```bash
godot --headless --path . res://server/server.tscn
# optional env vars:
#   TT_PORT=9090               change the port (default 8080)
#   TT_TURN_TIMEOUT_SEC=60     turn timer before auto-fill (default 43200 = 12h)
#   TT_DATA_FILE=matches.json  where matches are saved (default user://matches.json)
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
```

Each prints `PASS`/`FAIL` and exits non-zero on failure.

**Visual check** (opens a window, saves a PNG of the battle scene):

```bash
godot --path . res://test/screenshot.tscn -- out.png [ortho_size] [pitch_deg] [turns]
```

After adding new `class_name` scripts, run `godot --headless --editor --quit --path .`
once so Godot registers them before running headless tests.

## Next Up

- Accounts, matchmaking, and rating (the JSON match store is per-server).
- GDD 5.3 combos (Melee Assist, Crossfire Assist) and the Wire Mobility Penchant.
- Distinct behaviour for Hound / Egret / Ibis / Lead Bullet (ranges, homing).
- Mobile touch controls (Phase 4).
