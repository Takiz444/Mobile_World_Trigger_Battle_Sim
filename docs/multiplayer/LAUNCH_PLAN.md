# Trion Tactics — Competitive Multiplayer & App Store Launch Plan

Branch: `multiplayer` (on top of `dev`). Status: draft. The live-play mechanism
is implemented and tested headless. Launch logistics are planned here, and
items marked **TODO** are not built yet.

---

## 1. What "like Clash Royale" means for this game

Clash Royale works because a match is **short (≈3 min), synchronous, ranked, and
always one tap away**. Players progress on a visible **trophy ladder** through
**arenas**, with **seasons** that soft-reset the top.

Our core loop is different: simultaneous 6-tick turns, not real-time card drops.
So we keep the turn structure and make it *fast*: both players are online, a
short planning clock runs, and the board replays between turns. One match takes
about **6–8 minutes**.

| Mode | Who | Clock | Ranked | Built |
|---|---|---|---|---|
| **Live Battle** (main mode) | matchmade | 60 s turn 1, 40 s after, 8-turn cap | trophies + hidden MMR | ✅ |
| **Async Ranked** | matchmade | 12 h per turn | hidden MMR only | ✅ (existing) |
| **Friendly Battle** | match code | live or async (host picks) | never | ✅ server, **TODO** host toggle in UI |
| **Practice** | vs AI | none | never | ✅ (existing local mode) |

### Live match timeline

```
matched ─► load (15 s grace) ─► Turn 1 plan (60 s) ─► replay (~4–6 s) ─► Turn 2 plan (40 s) ─► … ─► Turn 8
                                     │                                          │
                         both locked in early? resolve immediately   clock hits 0? auto-lock what's planned
```

* **Early lock-in:** the turn resolves as soon as both plans are in. Fast players get fast games.
* **Buzzer:** 1.5 s before the deadline, the client submits whatever is planned. A client that is gone gets the GDD 3.1 "Stand Ground + Shield" fallback from the server.
* **Ending:** a squad is fully bailed out, **or** the turn cap is reached. At the cap, the side with more units standing wins, then the side with more remaining Trion (as a share of the squad total), else it's a **draw**.
* **Surrender:** a player can forfeit at any time.
* **AFK:** a player auto-filled for **2 turns in a row** forfeits. If both players are AFK, the match is a draw.
* **Disconnects:** the client reconnects with backoff, and the server resends full state on every `hello`. While a player is away, the clock keeps running, so the AFK rule covers players who never come back. The opponent sees "opponent reconnecting…".

All numbers live in `common/net/ladder.gd` (`LIVE_*`). Tune them in playtests;
the 8-turn cap is the most important one to validate.

---

## 2. Competitive systems

Each player has **two numbers**:

* **Trophies (visible).** Win: +20..40 (30 at even trophies; more for beating a higher-trophy player). Loss: the same amount. Draw: 0. Each arena's threshold is a **floor**: once a player reaches an arena, they can't drop below it. New players can't go below 0.
* **Rating (hidden MMR, Elo K=32).** This is what matchmaking uses. Trophy floors and season resets would distort pairing, so pairing ignores trophies. Draws count as half a win.

**Arenas** (placeholder names, see §7 IP): 0 / 300 / 700 / 1200 / 1800 / 2600 / 3500.

**Seasons:** `POST /admin/season/reset` halves trophies above 3500. This is
manual for now. **TODO:** schedule it, add season rewards, and keep a "best season" history.

**Matchmaking:** a ticket first accepts opponents within ±100 MMR. The window
grows by 20 per second of waiting, up to ±800, and both tickets must accept the
gap. The matchmaker runs every second. Live and async queues are separate.

* **Low-population risk.** At launch, queues will be thin at odd hours and at the top of the ladder. Options, in order of preference:
  1. Launch in one region at a time.
  2. Show the expected wait time.
  3. Offer "practice vs AI while you wait".
  4. **Clearly labelled** bot opponents for players under ~300 trophies.

  We should not pass bots off as humans.
* **TODO:**
  * avoid rematching the same opponent back to back
  * region/latency buckets once we run more than one server
  * party/friend challenge invites

---

## 3. Architecture

```
 iOS / Android client (Godot)
   ├─ HTTPS  ──► REST API       accounts, queue, create/join, submit, GET state
   └─ WSS    ──► Live channel   hello / submit / forfeit  ⇄  state, opponent_locked,
                                turn_resolved, match_over, presence
                    │
        Caddy (TLS, routes /live → :8081, everything else → :8080)
                    │
        Headless Godot server (server/server.gd)
          ├─ MatchRunner / TickEngine  deterministic resolution (shared code with the client)
          ├─ Visibility               fog of war enforced server-side
          ├─ LiveHub                  WebSocket push (common/net/live_hub.gd)
          ├─ Ladder                   trophies, arenas, clock, search window
          └─ JSON store (/data)       atomic write-then-rename
```

**Why it's cheat-resistant by design:**
* The server is authoritative: clients only send *plans*, and the server validates every squad (stats, slots, Trion budget) and plan (equipped cards, AT budget).
* Fog of war is applied on the server. A modified client can't reveal hidden enemies, because the server never sends them. The opponent's plan is never sent, only "opponent locked in".
* Resolution is deterministic and seeded, so any match can be replayed exactly from its history for disputes and reports.

**Live protocol** (JSON text frames). The full reference is in the header of `server/server.gd`:

| Client → server | Server → client |
|---|---|
| `{type:"hello", match_id, token}` | `{type:"state", …same as GET /match}` |
| `{type:"submit", turn, plan}` | `{type:"submit_ack", status}` |
| `{type:"forfeit"}` | `{type:"opponent_locked", turn}` |
| `{type:"ping"}` | `{type:"turn_resolved", result, turn, seconds_left}` |
| | `{type:"match_over", winner, reason, trophy_change, rating_change}` |
| | `{type:"presence", connected:[bool,bool]}` |

The server sends `seconds_left` rather than an absolute time, so device clock skew doesn't matter.

### Scaling path

Today, one process holds everything in memory and rewrites one JSON file on each change. That is fine for
a closed beta (hundreds of concurrent players), but not for launch. Steps:

1. **Database.** Move accounts, the match index, and history into Postgres. Keep live match state in memory on the owning server, with a snapshot to the DB after each turn (`PlanCodec.encode_state` already exists).
2. **Split services.**
   * A stateless **account/queue API** (any language).
   * N **match workers**, each running the Godot headless resolver.
   * Redis for the queue and for pub/sub "turn resolved" events.
3. **Sticky routing.** Route each match's live socket to its worker. Hand the client `live_url` per match: the ticket already carries `live_url`.
4. **Regions.** Run workers in 2–3 regions. Turn-based play tolerates 200 ms, so this is about availability, not latency.

Rough beta cost: one 2 vCPU VPS (~$20–40/mo) plus a domain. Apple Developer Program: $99/yr.

---

## 4. What this branch adds

| Area | Files |
|---|---|
| Ladder rules (trophies, arenas, season reset, live clock, search window) | `common/net/ladder.gd` |
| Turn-cap tiebreak, `DRAW` result | `common/combat/match_runner.gd` |
| Live WebSocket server / client | `common/net/live_hub.gd`, `common/net/live_client.gd` |
| Server: live mode, deadlines, turn cap, AFK, forfeit, trophies, widening matchmaker, account deletion, season reset, atomic saves | `server/server.gd` |
| Battle screen: live clock, buzzer auto-lock, pushed replays, reconnect resync, draw/trophy result | `levels/board/match_controller.gd` |
| Hangar: **Live Battle** / **Async Ranked** buttons, trophies + arena while searching | `ui/hangar/hangar_ui.gd` |
| Tests (ladder, tiebreak, live flow, AFK, cap, surrender, deletion, buzzer) | `test/live_test.gd` |
| Deploy: Docker image, Caddy TLS, compose, CI | `deploy/`, `.github/workflows/tests.yml` |

All existing tests still pass. Older match stores still load: missing fields get defaults.

---

## 5. App Store launch checklist

**Accounts & privacy**
- [ ] **In-app account deletion** (Guideline 5.1.1(v)): the API exists (`POST /account/delete`). **TODO:** a Settings → Delete Account screen.
- [ ] **Sign in with Apple** (4.8): required if we add Google/Facebook login. Plan: a guest account first (as today), then optional linking to Apple ID / Game Center so progress survives a reinstall. Verify Apple identity tokens on the server.
- [ ] **Keychain storage:** the client keeps its account secret in `user://account.json` as plain text. Move it to the iOS Keychain (needs a small native plugin) and switch to short-lived session tokens.
- [ ] Privacy policy URL, App Privacy "nutrition labels", data retention policy.
- [ ] App Tracking Transparency prompt **only** if we add ad attribution. Avoid it at launch.

**Networking**
- [ ] **HTTPS/WSS only.** App Transport Security blocks `http://` and `ws://`. Ship the production URL as the default; the Hangar default is currently `http://127.0.0.1:8080`, and the URL field should be hidden in release builds.
- [ ] Export compliance: HTTPS only → set `ITSAppUsesNonExemptEncryption = NO`.
- [ ] Handle app backgrounding mid-match. iOS suspends the socket; LiveClient reconnects and resyncs on resume. Test this on real devices.

**Content & community**
- [ ] **Player names are user-generated content** (1.2): add a profanity filter, report/block, and a way to rename offenders.
- [ ] Age rating questionnaire (cartoon/fantasy violence → likely 9+ or 12+).
- [ ] **IP licensing (blocker, see §7).**

**Monetization (if any)**
- [ ] Digital goods must use **StoreKit In-App Purchase** (3.1.1). Validate receipts on the server (App Store Server API).
- [ ] Any randomized rewards must **disclose their odds** (3.1.1).
- [ ] Keep it **non-pay-to-win**: every squad already has the same stats and Trion budget, which is our competitive-integrity selling point. Sell cosmetics (agent skins, trigger VFX, emblems), a season pass, and emotes. Don't sell card levels.

**Build & release**
- [ ] Apple Developer Program account, bundle id, signing certificates.
- [ ] Godot iOS export needs **macOS + Xcode**. Add the iOS export preset (bundle id, team id, icons, launch screen, landscape only).
- [ ] TestFlight closed beta → external beta (up to 10k testers).
- [ ] App Review notes: how to reach a match quickly (e.g. a review-only bot queue), and a demo account if login is required.
- [ ] Push notifications (APNs) for "your turn" in async mode and "opponent found" while the app is backgrounded.

---

## 6. Rollout

1. **Internal (now → +2 weeks).** Deploy the compose stack to a VPS. The team plays live matches daily, and we tune the clock, turn cap, and trophy numbers.
2. **Closed beta (TestFlight, ~100–500 players).** Add analytics: match length, turns played, buzzer-lock rate, AFK rate, draw rate, queue wait. Add crash reporting.
3. **Soft launch (one or two small English-speaking markets).** This is the usual mobile pattern. Watch D1/D7 retention and queue health. Scale to the Postgres/worker design before global launch.
4. **Global launch + Season 1.**

Metrics that tell us the live format works:
* median match length of 6–9 min
* fewer than 5% of turns auto-filled
* draw rate under 10% (if higher, tune the cap or the tiebreak)
* median live queue wait under 20 s

---

## 7. Open decisions for the team

1. **IP / licensing (launch blocker).** *World Trigger* (Daisuke Ashihara / Shueisha) names are throughout the game: trigger names (Kogetsu, Scorpion, Bagworm…), "Border", the arena placeholders I used (C/B/A-Rank, Mikado City, Away Mission). Apple rejects apps that use third-party IP without rights (5.2.1). We either secure a license or rebrand to original names before submitting. This decision drives naming, art, and marketing, so it should come first.
2. **Live turn length and cap.** 40 s × 8 turns is a starting guess. Planning 4 units × 6 ticks is a lot on a phone. Consider fewer ticks or a "quick plan" preset in live mode.
3. **Android at the same time?** The Godot export is cheap. Google Play has its own account-deletion and data-safety requirements.
4. **Backend language for the scaled version.** Keep the Godot headless resolver for match workers (shared deterministic code). The account/queue API can be anything the team is comfortable operating.
5. **Bots in low-trophy queues.** Labelled or not at all? I recommend labelled.
