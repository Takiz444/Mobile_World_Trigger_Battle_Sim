class_name Ladder
extends RefCounted
## Competitive ladder rules for live ranked play (the "Clash Royale" layer):
## visible trophies with arena floors, season resets, the live match clock,
## and the matchmaking search window. Pure functions, shared by the server and
## the client UI so both agree on arena names and the clock.
##
## Two numbers per player:
##   trophies — visible progress. Moves +/- per live ranked match, never drops
##              below the floor of the highest arena the player has reached.
##   rating   — hidden MMR (Elo, MatchServer.elo_deltas). Used for pairing, so
##              trophy floors and season resets never distort match quality.

## Arenas by trophy threshold (ascending). Reaching an arena's threshold
## unlocks it permanently: trophies can't fall below its floor afterwards.
const ARENAS := [
	{ "name": "C-Rank Training Room", "min": 0 },
	{ "name": "B-Rank Booth", "min": 300 },
	{ "name": "Mikado City Outskirts", "min": 700 },
	{ "name": "Abandoned District", "min": 1200 },
	{ "name": "A-Rank Ranked Wars", "min": 1800 },
	{ "name": "Away Mission Selection", "min": 2600 },
	{ "name": "S-Rank", "min": 3500 },
]

## Trophies above this are halved at season end (CR-style soft reset).
const SEASON_RESET_ABOVE := 3500

const TROPHY_BASE := 30
const TROPHY_MIN := 20
const TROPHY_MAX := 40
## Trophy gap (opponent - you) worth one extra trophy.
const TROPHY_GAP_STEP := 12

# --- Live match clock --------------------------------------------------------
# A live match targets ~6-8 minutes: short simultaneous planning windows,
# replay in between, and a hard turn cap with a tiebreak (MatchRunner).

const LIVE_FIRST_TURN_SEC := 60      # extra time to read the board on turn 1
const LIVE_TURN_SEC := 40
const LIVE_REPLAY_SEC := 3           # clients animate the 3-tick replay
const LIVE_LOAD_GRACE_SEC := 15      # both clients load the battle scene
const LIVE_MAX_TURNS := 8
## A live player auto-filled this many turns in a row forfeits (AFK).
const LIVE_AFK_FORFEIT_TURNS := 2
## Seconds a disconnected live player has to come back before AFK rules apply
## (they are already covered by the turn clock; this is for the UI).
const LIVE_RECONNECT_SEC := 45

# --- Matchmaking --------------------------------------------------------------

const MM_WINDOW_START := 100     # MMR distance accepted immediately
const MM_WINDOW_GROWTH := 20     # widened per second of waiting
const MM_WINDOW_MAX := 800


## Arena index for a trophy count.
static func arena_index(trophies: int) -> int:
	var idx := 0
	for i in ARENAS.size():
		if trophies >= int(ARENAS[i]["min"]):
			idx = i
	return idx


static func arena_name(trophies: int) -> String:
	return str(ARENAS[arena_index(trophies)]["name"])


## Trophy floor once `best` trophies have been reached (the unlocked arena).
static func trophy_floor(best: int) -> int:
	return int(ARENAS[arena_index(best)]["min"])


## Trophies won by the winner (and lost by the loser) of a ranked live match.
## Beating a higher-trophy opponent pays more, a lower one less.
static func trophy_stake(winner_trophies: int, loser_trophies: int) -> int:
	var gap := loser_trophies - winner_trophies
	return clampi(TROPHY_BASE + gap / TROPHY_GAP_STEP, TROPHY_MIN, TROPHY_MAX)


## Trophy changes [team0, team1] for a finished match. `winner` is 0, 1, or
## MatchRunner.DRAW (no change). `best` is each player's personal best, for
## the arena floor.
static func trophy_deltas(trophies: Array, best: Array, winner: int) -> Array:
	if winner != 0 and winner != 1:
		return [0, 0]
	var loser := 1 - winner
	var stake := trophy_stake(int(trophies[winner]), int(trophies[loser]))
	var out := [0, 0]
	out[winner] = stake
	var floor_t := trophy_floor(int(best[loser]))
	out[loser] = -mini(stake, maxi(0, int(trophies[loser]) - floor_t))
	return out


## Trophies after a season reset.
static func season_reset(trophies: int) -> int:
	if trophies <= SEASON_RESET_ABOVE:
		return trophies
	return SEASON_RESET_ABOVE + (trophies - SEASON_RESET_ABOVE) / 2


## MMR distance a ticket accepts after waiting `wait_sec` seconds.
static func search_window(wait_sec: float) -> int:
	return mini(MM_WINDOW_MAX, MM_WINDOW_START + int(wait_sec * MM_WINDOW_GROWTH))


## Whether two waiting tickets may be paired: both must accept the distance.
static func can_pair(rating_a: int, wait_a: float, rating_b: int, wait_b: float) -> bool:
	var gap := absi(rating_a - rating_b)
	return gap <= search_window(wait_a) and gap <= search_window(wait_b)


## Planning time for `turn` of a live match.
static func live_turn_sec(turn: int) -> int:
	return LIVE_FIRST_TURN_SEC if turn <= 1 else LIVE_TURN_SEC
