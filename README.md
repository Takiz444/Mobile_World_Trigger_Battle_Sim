# Trion Tactics (World Trigger Battle Sim)

Cross-platform online turn-based strategy game built in **Godot 4.6**.
Simultaneous-execution 4v4 hex-grid skirmishes based on the *World Trigger*
Away Mission Test Battle Simulation Exercise.

See `Project Docs/GDDV1.pdf` for the full design document.

## Feature-Based Structure

```
/project.godot
/common/           # Shared resources, math, and data definitions
    /hex_grid/     # Hexagonal grid math (axial coords, pathfinding)
    /data/         # Core Resource/RefCounted definitions
/entities/         # Units, actors (future)
/ui/
    /timeline/      # 6-tick timeline ribbon + drag-and-drop planning UI
    /hangar/        # pre-match deck-builder (Trigger Holder + Trion budget)
/levels/
    /board/        # 3D tabletop diorama (hex board + camera)
/addons/           # Third-party plugins
```

Naming: `snake_case` for files/folders, `PascalCase` for node names.

## Implemented So Far

### Hex Grid Math — `common/hex_grid/hex_coord.gd`
Static `HexCoord` utility:
- Axial ⇄ cube coordinate conversion (`Vector2i` = q, r)
- Neighbors, distance, ring, spiral, and line drawing
- Pointy-top axial ⇄ 3D world (XZ plane) mapping
- Deterministic A* pathfinding with a `Callable` walkability check

### Data Definitions — `common/data/`
- `trigger_card.gd` — `TriggerCard` (Trion equip cost, AT cost, power, card type)
- `unit_data.gd` — `UnitData` (stats + 8-slot Trigger Holder, Trion budget + slot-placement validation)
- `tick_action.gd` — `TickAction` (per-tick Main/Sub card bundle, Full Guard detection)
- `turn_plan.gd` — `TurnPlan` (6-tick timelines, AT economy, Mental Load, Full Guard, melee Penchant)
- `trigger_library.gd` — `TriggerLibrary` (13-card catalog + sample units)

### Global State — `common/squad_store.gd`
- `SquadStore` — static player squad (survives the Hangar → Battle scene change)

### Combat Resolution — `common/combat/`
- `unit_state.gd` — `UnitState` (runtime HP, hex, facing, stealth, per-tick shield state)
- `match_state.gd` — `MatchState` (two squads, cover, spider wires, seeded RNG)
- `combat_event.gd` — `CombatEvent` (resolution log entry for replay)
- `tick_engine.gd` — `TickEngine` (deterministic 6-tick pipeline: State → Movement/Traps → Defense → Attack → Resolution, with per-tick `resolve_tick()` for replay)

### Hex Mesh — `common/hex_grid/hex_mesh.gd`
- `HexMesh` — procedural pointy-top hex-prism `ArrayMesh` + convex collision shape

### Board Diorama — `levels/board/`
- `hex_board.gd` — `HexBoard` (procedural hex tiles, mouse hover/selection raycasting, hex ⇄ world helpers)
- `board_camera.gd` — `BoardCamera` (orthographic orbit/pan/zoom, isometric default)
- `board_units.gd` — `BoardUnits` (team-colored unit markers + facing nose + HP labels)
- `match_controller.gd` — `MatchController` (places 4v4 squads, board-click targeting, enemy AI, Submit → resolve → per-tick replay)
- `main.gd` + `main.tscn` — prototype root scene (environment, lights, board, camera, UI, match)

### Timeline UI — `ui/timeline/`
- `timeline_ui.gd` — `TimelineUI` (unit tabs, 6-tick ribbon, card hand, AT meter, Submit All)
- `timeline_slot.gd` — `TimelineSlot` (Main/Sub drop target + drag source, right-click to clear)
- `action_card.gd` — `ActionCard` (draggable hand card)

### Hangar — `ui/hangar/`
- `hangar_ui.gd` — `HangarUI` (unit tabs, 4 Main + 4 Sub slots, Trion budget bar, card palette, Start Match)
- `hangar_slot.gd` — `HangarSlot` (loadout slot: drop/move/clear)
- `loadout_card.gd` — `LoadoutCard` (draggable catalog card showing Trion cost)

**Run it:** open the project in Godot and press F5 (main scene is the Hangar).

**Flow:**
1. **Hangar** — configure each unit's Trigger Holder (drag cards into slots, watch the Trion budget), then press **Start Match**.
2. **Battle** — click a tick slot → click a hex to target it → drag action cards into slots → **Submit All** to watch the 6-tick replay.

## Next Up

- Smoother replay: tween unit movement, on-screen event log panel
- Multi-turn match lifecycle + opponent AI improvements
- Backend / async multiplayer (GDD Phase 3)
