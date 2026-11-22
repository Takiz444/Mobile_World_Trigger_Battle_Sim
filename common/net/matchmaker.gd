class_name Matchmaker
extends RefCounted
## Ranked matchmaking rules: skill ratings and who gets paired with whom.
## Pure functions (no server state), shared by the server and the tests.
##
## Skill rating: Glicko-2 (Glickman, "Example of the Glicko-2 system", 2012).
## Each player has
##   rating      — skill estimate (shown scale; START_RATING for a new player),
##   rd          — rating deviation: how unsure we are (high for new or
##                 returning players, so their rating moves fast),
##   volatility  — how erratic their results are.
## Every ranked match is one rating period. RD grows back over inactivity.
##
## Pairing: each pair of waiting tickets gets a predicted win probability for
## the favourite, using both players' uncertainty (two unknown players are
## a fair match, whatever their ratings say). A pair is acceptable when that
## probability is within what both tickets accept; that limit relaxes the
## longer they wait, and after ANY_OPPONENT_AFTER_SEC anyone will do (small
## player pools must never wait forever). Among all acceptable pairs, the
## best ones are chosen first (fairest, then longest-waiting), not merely the
## oldest ticket's nearest rating.

# --- Glicko-2 -------------------------------------------------------------------

const START_RATING := 1000.0
const START_RD := 350.0
const MIN_RD := 40.0
const MAX_RD := 350.0
const START_VOLATILITY := 0.06
## Constrains volatility changes (Glickman suggests 0.3-1.2).
const TAU := 0.5
## Glicko-2 scale factor (rating points per internal unit).
const SCALE := 173.7178
## RD regained per day without ranked play (Glicko-1 "c"): an established
## player (RD 50) is fully uncertain again after about 100 idle days.
const RD_DECAY_PER_DAY := 34.6

# --- Pairing ------------------------------------------------------------------

## The favourite's predicted win chance a fresh ticket accepts (about a
## 100-point gap between two established players).
const FAIRNESS_START := 0.64
## Added per second of waiting.
const FAIRNESS_GROWTH := 0.006
const FAIRNESS_MAX := 0.92
## After this long in the queue a ticket accepts any opponent.
const ANY_OPPONENT_AFTER_SEC := 45.0
## Don't pair two players who just played each other until one of them has
## waited this long (prevents one pair farming each other in a busy queue,
## without blocking rematches when they're the only two searching).
const REMATCH_AVOID_SEC := 8.0


## A fresh player's rating fields.
static func new_rating() -> Dictionary:
	return { "rating": START_RATING, "rd": START_RD, "volatility": START_VOLATILITY, "rated_at": 0.0 }


## RD after `idle_days` without a rated match.
static func decayed_rd(rd: float, idle_days: float) -> float:
	if idle_days <= 0.0:
		return clampf(rd, MIN_RD, MAX_RD)
	return clampf(sqrt(rd * rd + RD_DECAY_PER_DAY * RD_DECAY_PER_DAY * idle_days), MIN_RD, MAX_RD)


static func _g(phi: float) -> float:
	return 1.0 / sqrt(1.0 + 3.0 * phi * phi / (PI * PI))


## Probability that a player rated (r, rd) beats one rated (r_opp, rd_opp),
## counting both players' uncertainty.
static func win_probability(r: float, rd: float, r_opp: float, rd_opp: float) -> float:
	var phi := sqrt(rd * rd + rd_opp * rd_opp) / SCALE
	return 1.0 / (1.0 + exp(-_g(phi) * (r - r_opp) / SCALE))


## One Glicko-2 rating period against a single opponent. `score` is 1 (win),
## 0.5 (draw) or 0 (loss). Returns {rating, rd, volatility}.
static func rate(player: Dictionary, opponent: Dictionary, score: float) -> Dictionary:
	return rate_period(player, [[opponent, score]])


## One Glicko-2 rating period: `results` is [[opponent, score], ...].
static func rate_period(player: Dictionary, results: Array) -> Dictionary:
	var mu := (float(player["rating"]) - START_RATING) / SCALE
	var phi := float(player["rd"]) / SCALE
	var sigma := float(player["volatility"])
	if results.is_empty():
		return { "rating": float(player["rating"]), "rd": minf(MAX_RD, sqrt(phi * phi + sigma * sigma) * SCALE), "volatility": sigma }

	var inv_v := 0.0
	var sum := 0.0
	for res in results:
		var mu_j := (float(res[0]["rating"]) - START_RATING) / SCALE
		var g_j := _g(float(res[0]["rd"]) / SCALE)
		var e_j := 1.0 / (1.0 + exp(-g_j * (mu - mu_j)))
		inv_v += g_j * g_j * e_j * (1.0 - e_j)
		sum += g_j * (float(res[1]) - e_j)
	var v := 1.0 / inv_v
	var delta := v * sum

	# New volatility (Illinois algorithm, step 5 of the paper).
	var a := log(sigma * sigma)
	var f := func(x: float) -> float:
		var ex := exp(x)
		var d2 := phi * phi + v + ex
		return ex * (delta * delta - phi * phi - v - ex) / (2.0 * d2 * d2) - (x - a) / (TAU * TAU)
	var big_a := a
	var big_b: float
	if delta * delta > phi * phi + v:
		big_b = log(delta * delta - phi * phi - v)
	else:
		var k := 1
		while f.call(a - k * TAU) < 0.0:
			k += 1
		big_b = a - k * TAU
	var f_a: float = f.call(big_a)
	var f_b: float = f.call(big_b)
	for _i in 100:
		if absf(big_b - big_a) <= 0.000001:
			break
		var c := big_a + (big_a - big_b) * f_a / (f_b - f_a)
		var f_c: float = f.call(c)
		if f_c * f_b <= 0.0:
			big_a = big_b
			f_a = f_b
		else:
			f_a /= 2.0
		big_b = c
		f_b = f_c
	var sigma_new := exp(big_a / 2.0)

	var phi_star := sqrt(phi * phi + sigma_new * sigma_new)
	var phi_new := 1.0 / sqrt(1.0 / (phi_star * phi_star) + 1.0 / v)
	var mu_new := mu + phi_new * phi_new * sum
	return {
		"rating": mu_new * SCALE + START_RATING,
		"rd": phi_new * SCALE,
		"volatility": sigma_new,
	}


# --- Pairing ------------------------------------------------------------------

## The highest favourite win chance a ticket accepts after `wait_sec`.
static func fairness_limit(wait_sec: float) -> float:
	if wait_sec >= ANY_OPPONENT_AFTER_SEC:
		return 1.0
	return minf(FAIRNESS_MAX, FAIRNESS_START + wait_sec * FAIRNESS_GROWTH)


## Match quality of two tickets, 0..1 (1 = a coin flip).
static func quality(a: Dictionary, b: Dictionary) -> float:
	var p := win_probability(float(a["rating"]), float(a["rd"]), float(b["rating"]), float(b["rd"]))
	return 1.0 - 2.0 * absf(p - 0.5)


## Whether tickets `a` and `b` (dicts with player_id, mode, rating, rd, wait,
## last_opponent) may be paired now.
static func can_pair(a: Dictionary, b: Dictionary) -> bool:
	if a["player_id"] == b["player_id"] or a["mode"] != b["mode"]:
		return false
	var rematch := str(a.get("last_opponent", "")) == str(b["player_id"]) \
		or str(b.get("last_opponent", "")) == str(a["player_id"])
	if rematch and maxf(float(a["wait"]), float(b["wait"])) < REMATCH_AVOID_SEC:
		return false
	var favourite := 0.5 + (1.0 - quality(a, b)) / 2.0
	return favourite <= fairness_limit(float(a["wait"])) and favourite <= fairness_limit(float(b["wait"]))


## Chooses pairs among waiting `tickets` (see can_pair for the fields; each
## also needs a unique "ticket"). Returns [[ticket_a, ticket_b], ...], where
## ticket_a waited longer. Best pairs first: highest quality, plus a bonus
## for time already waited so nobody is starved by better-fitting newcomers.
static func pair(tickets: Array) -> Array:
	var candidates: Array = []
	for i in tickets.size():
		for j in range(i + 1, tickets.size()):
			var a: Dictionary = tickets[i]
			var b: Dictionary = tickets[j]
			if can_pair(a, b):
				var score := quality(a, b) + 0.01 * (float(a["wait"]) + float(b["wait"]))
				candidates.append({ "a": a, "b": b, "score": score })
	candidates.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["score"]) > float(y["score"]))
	var used := {}
	var out: Array = []
	for c in candidates:
		var a: Dictionary = c["a"]
		var b: Dictionary = c["b"]
		if used.has(a["ticket"]) or used.has(b["ticket"]):
			continue
		used[a["ticket"]] = true
		used[b["ticket"]] = true
		out.append([a, b] if float(a["wait"]) >= float(b["wait"]) else [b, a])
	return out
