# Deploying Trion Tactics

One VM runs everything: Caddy (HTTPS, and the Web client at `https://<domain>/`),
the game server, and MongoDB (through the small Mongo gateway). Total cost: $0.

| Piece | Choice | Why |
|---|---|---|
| Server VM | **Oracle Cloud Always Free**, Ampere A1 (ARM), Ubuntu 24.04 | Free forever, not a trial: up to 4 CPUs / 24 GB RAM, 200 GB disk, 10 TB/month traffic. It never sleeps, which matters because live matches are held in memory. |
| Domain + HTTPS | `<public-ip>.sslip.io` + Let's Encrypt via Caddy | Free, with no DNS setup. You can switch to your own domain at any time. |
| Database | MongoDB 7 in the same compose stack (or a free Atlas M0 cluster) | Free; accounts, profiles and match history are plain documents you can query. Backed up daily by `backup.sh`. Postgres (`--profile postgres`) and the file store still work. |
| Web client | Served by the same Caddy | Same origin as the API, so it needs no CORS and no extra service. |

Free hosts that don't fit: Render and Koyeb free tiers sleep when idle and lose
in-memory matches; Fly.io no longer has a free tier; Supabase free projects
pause after a week without activity.

## First deploy (about 20 minutes)

1. **Create the account** at <https://signup.oraclecloud.com>. It needs a card
   for identity checks; Always Free resources are never charged. Pick a home
   region close to your players; you can't change it later.
2. **Create the VM**: Compute → Instances → Create.
   - Image: **Canonical Ubuntu 24.04**. Shape: **VM.Standard.A1.Flex**, 2 OCPU / 12 GB is plenty.
   - Networking: keep "Assign a public IPv4 address" on.
   - SSH keys: upload your public key, or download the generated one.
   - If you get "Out of capacity", try another availability domain, or retry later.
3. **Open ports 80 and 443** in the cloud firewall: Instance → Subnet →
   Default Security List → Add Ingress Rules: source `0.0.0.0/0`, TCP,
   destination ports `80,443`.
4. **SSH in and run the bootstrap:**
   ```sh
   ssh ubuntu@<public-ip>
   git clone https://github.com/Takiz444/Mobile_World_Trigger_Battle_Sim.git trion
   cd trion && git checkout multiplayer
   ./deploy/bootstrap.sh
   ```
   If the repo is private, create a read-only deploy key or a fine-grained
   token for the clone. The first build takes about 5–10 minutes. The script
   ends by printing the game URL, e.g. `https://144-24-1-2.sslip.io/`.
5. **Save `deploy/.env`** (on the VM) in a password manager. It holds the
   admin key and database passwords, which were generated on the VM.
6. **Set `PRODUCTION_URL`** in `common/net/server_config.gd` to the printed
   `https://…` address. Only native (iOS/Steam) builds need this; the Web
   client always uses the address it was loaded from.

Optional: on Oracle, idle Always Free VMs can be reclaimed after 7 days of
very low use. Upgrading the account to Pay-As-You-Go prevents that, and
Always Free resources stay free.

## Small VM (1 GB, no Docker): the current production setup

Production currently runs on an **Always Free VM.Standard.E2.1.Micro** (Oracle
Linux 9, about 500 MB of usable RAM). Docker and Postgres don't fit there, so
`deploy/native/install.sh` runs the same pieces as systemd services instead:
Caddy, plus the Godot server with the file store (`TT_STORE=dir`, in
`/var/lib/trion/store`, tarred daily to `/var/backups/trion`).

- Live at: <https://150-136-143-127.sslip.io/>
- Secrets: `/etc/trion/trion.env` on the VM (admin key, generated there).
- Deploy or update, from this machine (Git Bash):
  ```sh
  GODOT=/path/to/godot deploy/native/make_bundle.sh      # -> build/trion-bundle.tgz
  scp -i <key> build/trion-bundle.tgz opc@150.136.143.127:
  ssh -i <key> opc@150.136.143.127 'rm -rf bundle && mkdir bundle && tar -xzf trion-bundle.tgz -C bundle && sudo bash bundle/app/deploy/native/install.sh'
  ```
  The bundle is built from committed code (`git archive HEAD`), so commit first.
- Logs: `sudo journalctl -u trion-server -u caddy -f`
- Off-VM backups: the Windows scheduled task "Trion backup pull" runs
  `deploy/native/pull_backups.ps1` daily, copying the VM's backups to
  `Documents\Trion-Backups` (newest 60 kept). It only runs when that PC is on.
- SSH: key-only, no root (`/etc/ssh/sshd_config.d/01-trion-hardening.conf`).
- Season reset: `sudo bash -c 'source /etc/trion/trion.env; curl -fsS -X POST -H "Authorization: Bearer $TT_ADMIN_KEY" http://127.0.0.1:8080/admin/season/reset'`

When an A1 VM (more RAM) is available, use the Docker path above. The file
store moves into MongoDB with `deploy/mongo-gateway/import-dir.js` (see
[MongoDB](#mongodb)); nothing imports it into Postgres yet.

## Where settings go

All secrets and settings (MongoDB connection string, Auth0 keys, admin key)
live in one env file, never in the repository:

| How you run it | File | How to create it |
|---|---|---|
| Your PC (local development) | `deploy/.env` | `cp deploy/.env.example deploy/.env`, then fill it in. The game server (`server.tscn`) and the Mongo gateway (`npm start` / `npm run dev`) both read it at startup. |
| Docker (`bootstrap.sh`) | `deploy/.env` on the VM | Written by `bootstrap.sh` on first run with random secrets; add `TT_MONGO_URI` / `TT_AUTH0_*` and re-run it. |
| Oracle micro VM (`install.sh`) | `/etc/trion/trion.env` on the VM | Written by `install.sh`; pass `TT_MONGO_URI=…` / `TT_AUTH0_…=…` to it once (see below). |

`deploy/.env` is git-ignored. `deploy/.env.example` documents every key.

Local run with MongoDB, step by step:

1. `cp deploy/.env.example deploy/.env` and set:
   ```sh
   TT_STORE=mongo
   TT_MONGO_URI=mongodb+srv://USER:PASSWORD@cluster0.xxxxx.mongodb.net/?retryWrites=true&w=majority
   TT_MONGO_GATEWAY_TOKEN=<any long random string>
   TT_MONGO_GATEWAY_URL=http://127.0.0.1:8095
   ```
   (No MongoDB yet? Skip `TT_MONGO_URI` and use `npm run dev` in step 2:
   a throwaway in-memory database.)
2. Terminal 1: `cd deploy/mongo-gateway && npm ci && npm start`.
   It prints `Read settings from …/deploy/.env` and
   `Trion Mongo gateway on 127.0.0.1:8095, database trion`.
3. Terminal 2: `godot --headless --path . res://server/server.tscn`.
   The startup line must say `store mongo via http://127.0.0.1:8095`. If the
   gateway isn't reachable, the server refuses to start (it never runs
   without its database).

## Auth0

With `TT_AUTH0_*` set, sign-up, sign-in, verification emails and password
reset go through Auth0; the game never stores passwords. The game keeps its
own email / password screen: the server checks the credentials with Auth0
(password-realm grant), so the client secret never leaves the server.
Without Auth0 the server keeps PBKDF2 password hashes itself (fine for
development; no reset emails).

1. Create a free tenant at <https://auth0.com/signup>.
2. **Applications → Create Application → Regular Web Application**, e.g. "Trion server".
   - Settings → Advanced → **Grant Types**: tick **Password** (and Client Credentials).
   - Settings → Advanced → **OAuth**: turn on **Trust Token Endpoint IP Header**,
     so Auth0's brute-force protection sees each player's IP (the server
     sends it as `auth0-forwarded-for`) instead of blocking the server's IP.
   - Connections: enable **Username-Password-Authentication** (only).
3. **APIs → Auth0 Management API → Machine To Machine Applications**:
   authorize "Trion server" with the **delete:users** scope, so deleting a
   game account deletes the Auth0 user too (App Store rule).
4. Copy Domain, Client ID and Client Secret into the env file:
   ```sh
   TT_AUTH0_DOMAIN=your-tenant.us.auth0.com
   TT_AUTH0_CLIENT_ID=…
   TT_AUTH0_CLIENT_SECRET=…
   ```
   Micro VM: `sudo TT_AUTH0_DOMAIN=… TT_AUTH0_CLIENT_ID=… TT_AUTH0_CLIENT_SECRET='…' bash bundle/app/deploy/native/install.sh`.
5. Restart; the server's startup line says `sign-in Auth0 (https://your-tenant…)`.

Optional: Authentication → Database → Password Policy sets the password
rules (the game shows Auth0's error), and Branding → Email Templates shapes
the verification and reset emails. Auth0's free plan covers this game's
needs. Accounts that signed up before Auth0 was turned on move over: the
player uses Create Account with the same email, verifies it from Auth0's
email, then signs in (linking needs the verified email, so nobody can claim
someone else's account).

## MongoDB

The game server reaches MongoDB through `deploy/mongo-gateway` (Node + the
official driver; Godot has no MongoDB driver). The gateway only listens
inside the stack (Docker) or on 127.0.0.1 (native) and requires
`TT_MONGO_GATEWAY_TOKEN`.

- **Docker, MongoDB in the stack** (new `bootstrap.sh` installs): `TT_STORE=mongo`,
  `--profile mongo`. Secrets are generated into `deploy/.env`.
- **Docker, hosted MongoDB**: set `TT_MONGO_URI` in `deploy/.env`;
  `bootstrap.sh` then uses `--profile atlas` (gateway only, no local database).
- Existing installs keep their store: `bootstrap.sh` never rewrites an
  existing `deploy/.env`.

### Moving the micro VM (file store) to MongoDB Atlas

MongoDB itself doesn't fit in the E2.1.Micro's memory, so use a free Atlas
cluster; the VM runs only the gateway (about 60 MB).

1. At <https://www.mongodb.com/cloud/atlas/register> create a free **M0**
   cluster in a region near the VM.
2. **Database Access**: add a user with a generated password and the
   "Read and write to any database" role.
3. **Network Access**: add the VM's public IP (`150.136.143.127/32`).
4. **Connect → Drivers**: copy the `mongodb+srv://…` connection string and put
   the password in it.
5. Build and upload the bundle as usual, then install with the connection
   string (single quotes; it contains `&` and `?`):
   ```sh
   sudo TT_MONGO_URI='mongodb+srv://USER:PASS@cluster0.xxxxx.mongodb.net/?retryWrites=true&w=majority'      bash bundle/app/deploy/native/install.sh
   ```
   It installs Node, starts `trion-mongo-gateway`, and **imports the current
   file store into MongoDB before the server switches**, so accounts and
   matches carry over. The file store in `/var/lib/trion/store` stays as it
   was (the way back: set `TT_STORE=dir` in `/etc/trion/trion.env` and
   restart `trion-server`). Later updates need no `TT_MONGO_URI`; it's saved
   in `/etc/trion/trion.env`.
6. Check: `sudo journalctl -u trion-mongo-gateway -u trion-server -n 50`.

Atlas M0 has no automatic backups, so the daily job exports MongoDB to
`/var/backups/trion/trion-<stamp>.tgz` in the file store layout. Restore with
`MONGO_URI=… node deploy/mongo-gateway/import-dir.js <unpacked dir>`.

Looking at the data (mongosh, Compass, or the Atlas UI): collections
`accounts`, `matches`, `tickets`, `meta` in database `trion`, e.g.
`db.accounts.find({ email: "someone@example.com" }, { history: 1, stats: 1 })`.
Password hashes and session secrets are stored there too, so keep database
access as tight as the server's secrets.

## Updating

```sh
cd trion && git pull && ./deploy/bootstrap.sh
```

This rebuilds the server and the Web client and restarts them. Existing secrets
and data are kept. Live matches in progress are lost on restart; async matches
resume.

## Using your own domain later

Point an `A` record at the VM's IP, then run `./deploy/bootstrap.sh play.example.com`.
Update `PRODUCTION_URL` to match.

## Operations

- Logs: `sudo docker compose -f deploy/docker-compose.yml --env-file deploy/.env --profile mongo logs -f`
  (use the profile your store needs: `mongo`, `atlas`, or `postgres`)
- Backups: daily at 04:17 UTC to `/var/backups/trion` (kept 14 days). Run one now
  with `sudo ./deploy/backup.sh`. Also copy them off the VM now and then.
- Season reset (admin API, reachable only from the VM itself):
  ```sh
  sudo docker compose -f deploy/docker-compose.yml --env-file deploy/.env exec server sh -c \
    'curl -fsS -X POST -H "Authorization: Bearer $TT_ADMIN_KEY" http://127.0.0.1:8080/admin/season/reset'
  ```
- Name blocklist: edit `common/net/blocked_names.txt` and redeploy.

## Troubleshooting

- **Bootstrap times out waiting for HTTPS:** check `logs caddy`. Usually the
  Security List (step 3) is missing ports 80/443.
- **Certificate rate limit on sslip.io:** use your own domain, or a free
  DuckDNS name (<https://www.duckdns.org>), and pass it to `bootstrap.sh`.
