# Deploying Trion Tactics

One VM runs everything: Caddy (HTTPS, and the Web client at `https://<domain>/`),
the game server, and Postgres + PostgREST. Total cost: $0.

| Piece | Choice | Why |
|---|---|---|
| Server VM | **Oracle Cloud Always Free**, Ampere A1 (ARM), Ubuntu 24.04 | Free forever, not a trial: up to 4 CPUs / 24 GB RAM, 200 GB disk, 10 TB/month traffic. It never sleeps, which matters because live matches are held in memory. |
| Domain + HTTPS | `<public-ip>.sslip.io` + Let's Encrypt via Caddy | Free, with no DNS setup. You can switch to your own domain at any time. |
| Database | Postgres 16 in the same compose stack | Free, already set up in `db/`, backed up daily by `backup.sh`. |
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
- Season reset: `sudo bash -c 'source /etc/trion/trion.env; curl -fsS -X POST -H "Authorization: Bearer $TT_ADMIN_KEY" http://127.0.0.1:8080/admin/season/reset'`

When an A1 VM (more RAM) is available, use the Docker path above. To move data
from the file store to Postgres, the records would need to be imported; nothing
does that yet.

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

- Logs: `sudo docker compose -f deploy/docker-compose.yml --env-file deploy/.env --profile postgres logs -f`
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
