class_name Auth0Client
extends Node
## Email + password sign-in through Auth0 (a Database connection), called by
## the game server only: the client secret never reaches game clients. The
## game keeps its own email / password screen; the server forwards the
## credentials to Auth0 over TLS.
##
##   sign up        POST /dbconnections/signup          {client_id, email, password, connection}
##   sign in        POST /oauth/token  grant_type=http://auth0.com/oauth/grant-type/password-realm
##                  -> id_token, read for sub / email / email_verified. It
##                  comes straight from Auth0's token endpoint over TLS, so the
##                  TLS check stands in for the signature check (OIDC Core 3.1.3.7);
##                  issuer, audience and expiry are still checked.
##   reset          POST /dbconnections/change_password {client_id, email, connection}
##                  (Auth0 emails the reset link)
##   delete         DELETE /api/v2/users/<sub> with a Management API token
##                  (client_credentials; the application needs the delete:users
##                  scope on the Auth0 Management API), when a player deletes
##                  their account
##
## Auth0 also sends the verification email on sign-up, and its brute-force
## protection sees each player's own IP: the server sends it as
## "auth0-forwarded-for" (turn on "Trust Token Endpoint IP Header" in the
## application's settings, or every failed login counts against the game
## server's single IP).
##
## Auth0 setup (deploy/README.md, "Auth0"): a Regular Web Application with the
## Password grant enabled and the Username-Password-Authentication connection.

const GRANT_PASSWORD_REALM := "http://auth0.com/oauth/grant-type/password-realm"
## Per request; sign-up makes two in a row. Keep 2x this under the game
## client's AUTH_TIMEOUT_SEC (HttpBackend) and HttpServer.DEFERRED_TIMEOUT_MS.
const TIMEOUT_SEC := 10.0

## "your-tenant.us.auth0.com" (https:// is added), or a full URL (tests).
var domain := ""
var client_id := ""
var client_secret := ""
var connection := "Username-Password-Authentication"
var _mgmt_token := ""
var _mgmt_expires_at := 0.0


func configure(p_domain: String, p_client_id: String, p_secret: String, p_connection := "") -> void:
	domain = p_domain.strip_edges().rstrip("/")
	client_id = p_client_id.strip_edges()
	client_secret = p_secret.strip_edges()
	if p_connection.strip_edges() != "":
		connection = p_connection.strip_edges()


func enabled() -> bool:
	return domain != "" and client_id != "" and client_secret != ""


func base_url() -> String:
	return domain if domain.begins_with("http://") or domain.begins_with("https://") else "https://" + domain


## Creates the Auth0 user. {ok} or {ok: false, status, error} with a player-facing error.
func sign_up(email: String, password: String, player_name: String) -> Dictionary:
	var body := { "client_id": client_id, "email": email, "password": password, "connection": connection }
	if player_name != "":
		body["nickname"] = player_name
	var res := await _post("/dbconnections/signup", body)
	if res["ok"]:
		return { "ok": true }
	var b: Dictionary = res["body"] if res["body"] is Dictionary else {}
	var code := str(b.get("code", b.get("name", "")))
	match code:
		"invalid_password", "PasswordStrengthError":
			return _fail(400, "password is too weak: use at least 8 characters, mixing upper and lower case letters, numbers, and symbols")
		"password_dictionary_error", "PasswordDictionaryError":
			return _fail(400, "that password is too common; choose another")
		"password_no_user_info_error", "PasswordNoUserInfoError":
			return _fail(400, "the password can't contain your email or name")
		"invalid_signup", "user_exists", "username_exists":
			# Auth0 doesn't say which, so that emails can't be probed.
			return _fail(409, "an account with this email already exists; sign in instead")
	return _upstream_error("sign-up", res)


## Checks email + password. {ok, sub, email, email_verified, name} or
## {ok: false, status, error}. `client_ip` feeds Auth0's brute-force protection.
func sign_in(email: String, password: String, client_ip: String) -> Dictionary:
	var headers: Array = []
	if client_ip != "":
		headers.append("auth0-forwarded-for: %s" % client_ip)
	var res := await _post("/oauth/token", {
		"grant_type": GRANT_PASSWORD_REALM, "realm": connection,
		"client_id": client_id, "client_secret": client_secret,
		"username": email, "password": password, "scope": "openid email profile",
	}, headers)
	if not res["ok"]:
		var b: Dictionary = res["body"] if res["body"] is Dictionary else {}
		match str(b.get("error", "")):
			"invalid_grant":
				return _fail(403, "wrong email or password")
			"too_many_attempts":
				return _fail(429, "too many failed attempts; check your email to unblock the account, or try again later")
			"unauthorized":
				return _fail(403, "this account is blocked")
		return _upstream_error("sign-in", res)
	var claims := _id_token_claims(str(res["body"].get("id_token", "")) if res["body"] is Dictionary else "")
	if claims.is_empty():
		return _fail(502, "sign-in service returned an unusable answer")
	return {
		"ok": true,
		"sub": str(claims["sub"]),
		"email": str(claims.get("email", email)).to_lower(),
		"email_verified": bool(claims.get("email_verified", false)),
		"name": str(claims.get("nickname", claims.get("name", ""))),
	}


## Asks Auth0 to email a password-reset link. Always looks the same to the
## caller, whether or not the email has an account.
func request_password_reset(email: String) -> Dictionary:
	var res := await _post("/dbconnections/change_password",
		{ "client_id": client_id, "email": email, "connection": connection })
	return { "ok": true } if res["ok"] else _upstream_error("password reset", res)


## Deletes the Auth0 user (account deletion). Best effort: failures are
## logged for the operator; the game account is already gone.
func delete_user(sub: String) -> void:
	if not enabled() or sub == "":
		return
	var token := await _management_token()
	if token == "":
		push_warning("Auth0 user %s was not deleted: no Management API token (grant the application delete:users)" % sub)
		return
	var res := await _request(HTTPClient.METHOD_DELETE, "/api/v2/users/%s" % sub.uri_encode(), null,
		["Authorization: Bearer %s" % token])
	if not res["ok"] and int(res["status"]) != 404:
		push_warning("Auth0 user %s was not deleted: %s" % [sub, res["error"]])


func _management_token() -> String:
	var now := Time.get_unix_time_from_system()
	if _mgmt_token != "" and now < _mgmt_expires_at - 60.0:
		return _mgmt_token
	var res := await _post("/oauth/token", { "grant_type": "client_credentials", "client_id": client_id,
		"client_secret": client_secret, "audience": base_url() + "/api/v2/" })
	if not res["ok"] or not (res["body"] is Dictionary):
		push_warning("Auth0 Management API token failed: %s" % res["error"])
		return ""
	_mgmt_token = str(res["body"].get("access_token", ""))
	_mgmt_expires_at = now + float(res["body"].get("expires_in", 3600))
	return _mgmt_token


## The id_token's payload if it is for this application and still valid, else {}.
func _id_token_claims(id_token: String) -> Dictionary:
	var parts := id_token.split(".")
	if parts.size() != 3:
		return {}
	var payload := parts[1].replace("-", "+").replace("_", "/")
	while payload.length() % 4 != 0:
		payload += "="
	var claims: Variant = JSON.parse_string(Marshalls.base64_to_raw(payload).get_string_from_utf8())
	if not (claims is Dictionary) or str(claims.get("sub", "")) == "":
		return {}
	var aud: Variant = claims.get("aud")
	var aud_ok: bool = (aud is String and aud == client_id) or (aud is Array and (aud as Array).has(client_id))
	var iss_ok := str(claims.get("iss", "")).rstrip("/") == base_url()
	var exp_ok := float(claims.get("exp", 0.0)) > Time.get_unix_time_from_system()
	if not (aud_ok and iss_ok and exp_ok):
		push_warning("Auth0 id_token rejected (aud %s, iss %s, exp %s)" % [aud_ok, iss_ok, exp_ok])
		return {}
	return claims


func _fail(status: int, error: String) -> Dictionary:
	return { "ok": false, "status": status, "error": error }


func _upstream_error(what: String, res: Dictionary) -> Dictionary:
	# Configuration problems (wrong secret, grant not enabled) end up here:
	# log the details for the operator, tell the player only that it failed.
	push_warning("Auth0 %s failed: %s" % [what, res["error"]])
	if int(res["status"]) == 429:
		return _fail(429, "too many requests; try again in a minute")
	return _fail(503 if int(res["status"]) == 0 or int(res["status"]) >= 500 else 502,
		"the sign-in service is unavailable; try again later")


func _post(path: String, body: Dictionary, extra_headers: Array = []) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, path, body, extra_headers)


func _request(method: int, path: String, body: Variant, extra_headers: Array = []) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT_SEC
	add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	for h in extra_headers:
		headers.append(h)
	var err := req.request(base_url() + path, headers, method, JSON.stringify(body) if body != null else "")
	if err != OK:
		req.queue_free()
		return { "ok": false, "status": 0, "body": null, "error": "request failed (%d)" % err }
	var resp: Array = await req.request_completed
	req.queue_free()
	if resp[0] != HTTPRequest.RESULT_SUCCESS:
		return { "ok": false, "status": 0, "body": null, "error": "transport error %d" % resp[0] }
	var code: int = resp[1]
	var text: String = (resp[3] as PackedByteArray).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text) if text.strip_edges().begins_with("{") else null
	if code < 200 or code >= 300:
		return { "ok": false, "status": code, "body": parsed, "error": "HTTP %d %s" % [code, text.left(300)] }
	return { "ok": true, "status": code, "body": parsed, "error": "" }
