class_name PasswordHash
extends RefCounted
## Password storage for email accounts: PBKDF2-HMAC-SHA256 (RFC 8018) with a
## random 16-byte salt, stored as
##   pbkdf2_sha256$<iterations>$<salt hex>$<hash hex>
## Godot has no bcrypt / argon2, but Crypto.hmac_digest is native, so PBKDF2
## costs about 3 µs per iteration on a desktop CPU. The iteration count is
## stored with each hash, so it can be raised later (old hashes still verify).
##
## derive() is slow on purpose: the server runs it on WorkerThreadPool and
## never on the main loop that runs the match clocks.

const PREFIX := "pbkdf2_sha256"
const DEFAULT_ITERATIONS := 60000
const MIN_ITERATIONS := 1000
const SALT_BYTES := 16
const MIN_LENGTH := 8
const MAX_LENGTH := 128


## The derived 32-byte key. Thread-safe (own Crypto instance).
static func derive(password: String, salt: PackedByteArray, iterations: int) -> PackedByteArray:
	var crypto := Crypto.new()
	var key := password.to_utf8_buffer()
	# One output block: U1 = HMAC(P, S || INT(1)), Ui = HMAC(P, Ui-1), T = XOR of all.
	var block := salt.duplicate()
	block.append_array(PackedByteArray([0, 0, 0, 1]))
	var u := crypto.hmac_digest(HashingContext.HASH_SHA256, key, block)
	var acc := [u.decode_u64(0), u.decode_u64(8), u.decode_u64(16), u.decode_u64(24)]
	for i in iterations - 1:
		u = crypto.hmac_digest(HashingContext.HASH_SHA256, key, u)
		acc[0] ^= u.decode_u64(0)
		acc[1] ^= u.decode_u64(8)
		acc[2] ^= u.decode_u64(16)
		acc[3] ^= u.decode_u64(24)
	var out := PackedByteArray()
	out.resize(32)
	for i in 4:
		out.encode_u64(i * 8, acc[i])
	return out


static func new_salt() -> PackedByteArray:
	return Crypto.new().generate_random_bytes(SALT_BYTES)


static func encode(iterations: int, salt: PackedByteArray, key: PackedByteArray) -> String:
	return "%s$%d$%s$%s" % [PREFIX, iterations, salt.hex_encode(), key.hex_encode()]


## {iterations, salt, key} of a stored hash, or {} if it is not one.
static func parse(stored: String) -> Dictionary:
	var parts := stored.split("$")
	if parts.size() != 4 or parts[0] != PREFIX or not parts[1].is_valid_int():
		return {}
	var iterations := int(parts[1])
	var salt := parts[2].hex_decode()
	var key := parts[3].hex_decode()
	if iterations < MIN_ITERATIONS or salt.size() != SALT_BYTES or key.size() != 32:
		return {}
	return { "iterations": iterations, "salt": salt, "key": key }


## "" if `password` is acceptable, else why not.
static func check_strength(password: String) -> String:
	if password.length() < MIN_LENGTH:
		return "password must be at least %d characters" % MIN_LENGTH
	if password.length() > MAX_LENGTH:
		return "password must be at most %d characters" % MAX_LENGTH
	return ""
