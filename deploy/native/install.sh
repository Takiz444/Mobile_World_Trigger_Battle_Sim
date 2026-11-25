#!/usr/bin/env bash
# Docker-free install for small VMs (e.g. Oracle's Always Free E2.1.Micro,
# ~1 GB RAM), where Docker + Postgres don't fit. Runs the same pieces as
# deploy/docker-compose.yml, minus Postgres:
#
#   caddy.service        HTTPS (automatic certificate), Web client, proxy
#   trion-server.service headless Godot game server, file store (TT_STORE=dir)
#   /etc/cron.d/trion-backup   daily tarball of the store
#
# Input is a bundle made by deploy/native/make_bundle.sh:
#   bundle/app/   the repository (git archive)
#   bundle/web/   the exported Web client (release build, gzipped assets)
#
# On the VM, from the unpacked bundle directory:
#   sudo bash app/deploy/native/install.sh              # <public-ip>.sslip.io
#   sudo bash app/deploy/native/install.sh play.example.com
#
# MongoDB (a hosted cluster such as a free Atlas M0; a MongoDB server doesn't
# fit in this VM's memory): pass its connection string once,
#   sudo TT_MONGO_URI='mongodb+srv://user:pass@cluster.example.mongodb.net/' bash app/deploy/native/install.sh
# This installs Node and the Mongo gateway (trion-mongo-gateway.service, on
# 127.0.0.1 only) and switches the game to TT_STORE=mongo. When it switches
# from the file store, the existing store is imported into MongoDB first, so
# accounts and matches carry over. The file store stays on disk untouched.
#
# Auth0 sign-in: pass TT_AUTH0_DOMAIN, TT_AUTH0_CLIENT_ID and
# TT_AUTH0_CLIENT_SECRET the same way (once; they are saved in
# /etc/trion/trion.env), or add them to that file and re-run.
#
# Re-running upgrades the app/web files and restarts; secrets and data stay.
# Works on Oracle Linux 8/9 (dnf, firewalld, SELinux) and Ubuntu (apt).
set -euo pipefail

BUNDLE="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC_APP="$BUNDLE/app"
SRC_WEB="$BUNDLE/web"
DOMAIN_ARG="${1:-}"

GODOT_VERSION=4.7.2
CADDY_VERSION=2.8.4
NODE_VERSION=22.23.4
PREFIX=/opt/trion
DATA=/var/lib/trion
ENV_FILE=/etc/trion/trion.env

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -f "$SRC_APP/project.godot" ] && [ -f "$SRC_WEB/index.wasm" ] || { echo "bundle incomplete: need app/ and web/" >&2; exit 1; }

case "$(uname -m)" in
	x86_64)
		GODOT_ARCH=x86_64; CADDY_ARCH=amd64
		GODOT_SHA512=9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65
		CADDY_SHA512=b8bec15d14fb033562af9f207850027bcbaa1f891edc9efe00d38bf39e1bf9944f8b6b8eba041ddd4c171cd70c905174c704d705be2f23bc678fe1eaf37a2485
		NODE_ARCH=x64
		NODE_SHA256=b8492284c76a54baf58d61668dd0e41ee0fc98adabf9503d30f05d08f55b4406 ;;
	aarch64)
		GODOT_ARCH=arm64; CADDY_ARCH=arm64
		GODOT_SHA512=dd59918da086bd49bde2f5450b5e567ff8650cbde9abbd7b8f4ca1197ff8c609baa38834666d032deafb47099078d7822279e2a0e06e5665745468f26533e7e2
		CADDY_SHA512=5466234be3e988071cef937aedbdd94c15b6f75cf7307397e67c2641219ac9bfe2c2bb3b31fc05bc68d3b6398bbe50abfa16ccf3b127318ccac31115ad26507c
		NODE_ARCH=arm64
		NODE_SHA256=f7a1e486dbc8b286847815b477d4fb5e9fb963ed4489c3e1588853d685f589f9 ;;
	*) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

# 1. Swap: the Godot import step needs more than a Micro VM's RAM ----------
total_swap_mb=$(free -m | awk '/^Swap:/ { print $2 }')
if [ "$total_swap_mb" -lt 1500 ] && [ ! -f /swapfile-trion ]; then
	say "Adding a 2 GB swap file"
	dd if=/dev/zero of=/swapfile-trion bs=1M count=2048 status=none
	chmod 600 /swapfile-trion
	mkswap /swapfile-trion >/dev/null
	swapon /swapfile-trion
	echo "/swapfile-trion none swap sw 0 0" >> /etc/fstab
fi
# Prefer RAM: heavy swapping on a 1/8-CPU VM stalls everything, SSH included.
echo "vm.swappiness = 10" > /etc/sysctl.d/90-trion.conf
sysctl -q -p /etc/sysctl.d/90-trion.conf || true

# 2. Packages ---------------------------------------------------------------
say "Installing packages"
if command -v dnf >/dev/null 2>&1; then
	# dnf loading every repo's metadata gets OOM-killed on a 1 GB VM: skip it
	# when nothing is missing, and otherwise use only the two base repos.
	missing=$(rpm -q curl unzip tar gzip fontconfig cronie openssl | awk '/is not installed/ { print $2 }')
	if [ -n "$missing" ]; then
		dnf install -y -q --setopt=install_weak_deps=False --disablerepo='*' \
			--enablerepo='ol*_baseos_latest' --enablerepo='ol*_appstream' $missing >/dev/null
	fi
	systemctl enable --now crond >/dev/null 2>&1 || true
	# The hourly package-cache refresh (dnf-makecache) needs ~330 MB: on a
	# 1 GB VM it swapped the machine to a standstill for ~40 minutes until
	# the kernel killed it (2026-11-22). Turn it and PackageKit off; update
	# by hand with `sudo dnf --disablerepo='*' --enablerepo='ol*_baseos_latest'
	# --enablerepo='ol*_appstream' upgrade` when the game is quiet.
	systemctl disable --now dnf-makecache.timer >/dev/null 2>&1 || true
	systemctl mask --now packagekit.service >/dev/null 2>&1 || true
else
	apt-get update -qq && apt-get install -y -qq curl unzip tar gzip libfontconfig1 cron >/dev/null
fi

# 3. Godot and Caddy binaries (pinned SHA-512) ------------------------------
install_godot() {
	say "Installing Godot $GODOT_VERSION ($GODOT_ARCH)"
	local tmp; tmp=$(mktemp -d)
	curl -fsSL -o "$tmp/godot.zip" \
		"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.${GODOT_ARCH}.zip"
	echo "$GODOT_SHA512  $tmp/godot.zip" | sha512sum -c - >/dev/null
	unzip -q "$tmp/godot.zip" -d "$tmp"
	install -m 755 "$tmp/Godot_v${GODOT_VERSION}-stable_linux.${GODOT_ARCH}" /usr/local/bin/godot
	rm -rf "$tmp"
}
install_caddy() {
	say "Installing Caddy $CADDY_VERSION ($CADDY_ARCH)"
	local tmp; tmp=$(mktemp -d)
	curl -fsSL -o "$tmp/caddy.tgz" \
		"https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${CADDY_ARCH}.tar.gz"
	echo "$CADDY_SHA512  $tmp/caddy.tgz" | sha512sum -c - >/dev/null
	tar -xzf "$tmp/caddy.tgz" -C "$tmp" caddy
	install -m 755 "$tmp/caddy" /usr/local/bin/caddy
	rm -rf "$tmp"
}
/usr/local/bin/godot --version 2>/dev/null | grep -q "^${GODOT_VERSION}.stable" || install_godot
/usr/local/bin/caddy version 2>/dev/null | grep -q "^v${CADDY_VERSION}" || install_caddy
command -v restorecon >/dev/null 2>&1 && restorecon /usr/local/bin/godot /usr/local/bin/caddy

# 4. Users, files ------------------------------------------------------------
id trion >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --create-home --shell /sbin/nologin trion
id caddy >/dev/null 2>&1 || useradd --system --home-dir /var/lib/caddy --create-home --shell /sbin/nologin caddy
mkdir -p "$DATA/store" "$PREFIX" /etc/trion
chown -R trion:trion "$DATA"
chmod 700 "$DATA"

say "Installing app and Web client"
rm -rf "$PREFIX/app.new" "$PREFIX/web.new"
cp -a "$SRC_APP" "$PREFIX/app.new"
cp -a "$SRC_WEB" "$PREFIX/web.new"
# Keep the previous import cache so re-imports are incremental.
[ -d "$PREFIX/app/.godot" ] && cp -a "$PREFIX/app/.godot" "$PREFIX/app.new/.godot"
chown -R trion:trion "$PREFIX/app.new"
chown -R root:root "$PREFIX/web.new"
chmod -R a+rX "$PREFIX/web.new"

say "Importing the project (slow on a small VM)"
runuser -u trion -- env HOME="$DATA" /usr/local/bin/godot --headless --editor --quit --path "$PREFIX/app.new" >/dev/null 2>&1 || true
test -f "$PREFIX/app.new/.godot/global_script_class_cache.cfg" || { echo "Godot import failed" >&2; exit 1; }

# 5. Settings / secrets (first run only) -------------------------------------
if [ ! -f "$ENV_FILE" ]; then
	domain="$DOMAIN_ARG"
	if [ -z "$domain" ]; then
		ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
		domain="${ip//./-}.sslip.io"
	fi
	say "Writing $ENV_FILE (domain $domain, new admin key)"
	umask 077
	cat > "$ENV_FILE" <<EOF
# Generated by deploy/native/install.sh on $(date -u +%Y-%m-%d). Keep private.
TT_DOMAIN=$domain
TT_ADMIN_KEY=$(openssl rand -hex 32)
TT_TURN_TIMEOUT_SEC=43200
TT_STORE=dir
TT_DATA_DIR=$DATA/store
TT_PORT=8080
TT_LIVE_PORT=8081
TT_TRUST_PROXY=1
TT_PUBLIC_LIVE_URL=wss://$domain/live
EOF
	umask 022
elif [ -n "$DOMAIN_ARG" ]; then
	sed -i "s/^TT_DOMAIN=.*/TT_DOMAIN=$DOMAIN_ARG/; s|^TT_PUBLIC_LIVE_URL=.*|TT_PUBLIC_LIVE_URL=wss://$DOMAIN_ARG/live|" "$ENV_FILE"
fi
# Small VM: keep finished matches in memory for an hour (they stay in the store).
grep -q '^TT_MATCH_RETENTION_SEC=' "$ENV_FILE" || echo "TT_MATCH_RETENTION_SEC=3600" >> "$ENV_FILE"

# MongoDB: a connection string given now switches the store to mongo.
set_env() {   # set_env KEY VALUE: replace or append KEY=VALUE in $ENV_FILE
	local tmp; tmp=$(mktemp)
	grep -v "^$1=" "$ENV_FILE" > "$tmp" || true
	printf '%s=%s\n' "$1" "$2" >> "$tmp"
	cat "$tmp" > "$ENV_FILE" && rm -f "$tmp"
}
get_env() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }
PREV_STORE=$(get_env TT_STORE)
if [ -n "${TT_MONGO_URI:-}" ]; then
	set_env TT_MONGO_URI "$TT_MONGO_URI"
	set_env TT_STORE mongo
fi
for key in TT_AUTH0_DOMAIN TT_AUTH0_CLIENT_ID TT_AUTH0_CLIENT_SECRET TT_AUTH0_CONNECTION; do
	[ -n "${!key:-}" ] && set_env "$key" "${!key}"
done
USE_MONGO=0
SWITCHED_TO_MONGO=0
if [ "$(get_env TT_STORE)" = "mongo" ]; then
	[ -n "$(get_env TT_MONGO_URI)" ] || { echo "TT_STORE=mongo needs TT_MONGO_URI (a hosted MongoDB connection string)" >&2; exit 1; }
	USE_MONGO=1
	[ "$PREV_STORE" != "mongo" ] && SWITCHED_TO_MONGO=1
	[ -n "$(get_env TT_MONGO_GATEWAY_TOKEN)" ] || set_env TT_MONGO_GATEWAY_TOKEN "$(openssl rand -hex 32)"
	[ -n "$(get_env TT_MONGO_DB)" ] || set_env TT_MONGO_DB trion
	set_env TT_MONGO_GATEWAY_URL http://127.0.0.1:8095
fi
chmod 600 "$ENV_FILE"
DOMAIN=$(grep -E '^TT_DOMAIN=' "$ENV_FILE" | cut -d= -f2-)
cat > /etc/trion/caddy.env <<EOF
TT_DOMAIN=$DOMAIN
TT_SERVER_HOST=127.0.0.1
TT_WEB_ROOT=$PREFIX/web
EOF

# 5b. Mongo gateway (TT_STORE=mongo only) ---------------------------------------
NODE_DIR=$PREFIX/node
if [ "$USE_MONGO" = 1 ]; then
	if [ "$("$NODE_DIR/bin/node" --version 2>/dev/null)" != "v$NODE_VERSION" ]; then
		say "Installing Node $NODE_VERSION ($NODE_ARCH)"
		tmp=$(mktemp -d)
		curl -fsSL -o "$tmp/node.tgz" "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz"
		echo "$NODE_SHA256  $tmp/node.tgz" | sha256sum -c - >/dev/null
		rm -rf "$NODE_DIR" && mkdir -p "$NODE_DIR"
		tar -xzf "$tmp/node.tgz" -C "$NODE_DIR" --strip-components=1
		rm -rf "$tmp"
		command -v restorecon >/dev/null 2>&1 && restorecon -R "$NODE_DIR" >/dev/null
	fi
	say "Installing the Mongo gateway"
	runuser -u trion -- env HOME="$DATA" PATH="$NODE_DIR/bin:$PATH" \
		"$NODE_DIR/bin/npm" ci --omit=dev --no-audit --no-fund --prefix "$PREFIX/app.new/deploy/mongo-gateway" >/dev/null
	umask 077
	cat > /etc/trion/mongo-gateway.env <<EOF
MONGO_URI=$(get_env TT_MONGO_URI)
MONGO_DB=$(get_env TT_MONGO_DB)
GATEWAY_TOKEN=$(get_env TT_MONGO_GATEWAY_TOKEN)
GATEWAY_HOST=127.0.0.1
GATEWAY_PORT=8095
EOF
	umask 022
	cat > /etc/systemd/system/trion-mongo-gateway.service <<EOF
[Unit]
Description=Trion Tactics Mongo gateway (MongoDB access for the game server)
After=network-online.target
Wants=network-online.target
Before=trion-server.service

[Service]
User=trion
Group=trion
EnvironmentFile=/etc/trion/mongo-gateway.env
WorkingDirectory=$PREFIX/app/deploy/mongo-gateway
ExecStart=$NODE_DIR/bin/node server.js
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
CapabilityBoundingSet=
MemoryMax=128M
MemorySwapMax=32M
Environment=NODE_OPTIONS=--max-old-space-size=96

[Install]
WantedBy=multi-user.target
EOF
fi

# 6. systemd -------------------------------------------------------------------
cat > /etc/systemd/system/trion-server.service <<EOF
[Unit]
Description=Trion Tactics game server
After=network-online.target trion-mongo-gateway.service
Wants=network-online.target

[Service]
User=trion
Group=trion
EnvironmentFile=$ENV_FILE
Environment=HOME=$DATA
ExecStart=/usr/local/bin/godot --headless --path $PREFIX/app res://server/server.tscn
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA
CapabilityBoundingSet=
# A hard cap: if memory ever runs away, the server is killed and restarted in
# seconds (matches resume from the store) instead of swapping the VM to a halt.
MemoryMax=320M
MemorySwapMax=64M
OOMScoreAdjust=300

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy (HTTPS + Web client for Trion Tactics)
After=network-online.target trion-server.service
Wants=network-online.target

[Service]
User=caddy
Group=caddy
EnvironmentFile=/etc/trion/caddy.env
Environment=HOME=/var/lib/caddy
ExecStart=/usr/local/bin/caddy run --config $PREFIX/app/deploy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config $PREFIX/app/deploy/Caddyfile --adapter caddyfile --force
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/caddy
LimitNOFILE=65536
MemoryMax=160M
MemorySwapMax=32M

[Install]
WantedBy=multi-user.target
EOF

say "Switching to the new version"
systemctl stop trion-server caddy 2>/dev/null || true
systemctl stop trion-mongo-gateway 2>/dev/null || true
rm -rf "$PREFIX/app.old" "$PREFIX/web.old"
[ -d "$PREFIX/app" ] && mv "$PREFIX/app" "$PREFIX/app.old"
[ -d "$PREFIX/web" ] && mv "$PREFIX/web" "$PREFIX/web.old"
mv "$PREFIX/app.new" "$PREFIX/app"
mv "$PREFIX/web.new" "$PREFIX/web"
command -v restorecon >/dev/null 2>&1 && restorecon -R "$PREFIX" >/dev/null
systemctl daemon-reload
if [ "$USE_MONGO" = 1 ]; then
	if [ "$SWITCHED_TO_MONGO" = 1 ] && [ -d "$DATA/store/accounts" ]; then
		say "Importing the file store into MongoDB (switching stores)"
		# Values are read, never sourced: a connection string has & and ? in it.
		runuser -u trion -- env MONGO_URI="$(get_env TT_MONGO_URI)" MONGO_DB="$(get_env TT_MONGO_DB)" \
			"$NODE_DIR/bin/node" "$PREFIX/app/deploy/mongo-gateway/import-dir.js" "$DATA/store"
	fi
	systemctl enable --now trion-mongo-gateway >/dev/null 2>&1
	systemctl restart trion-mongo-gateway
else
	systemctl disable --now trion-mongo-gateway >/dev/null 2>&1 || true
fi
systemctl enable --now trion-server caddy >/dev/null 2>&1
systemctl restart trion-server caddy

# 7. Host firewall -----------------------------------------------------------
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
	firewall-cmd -q --permanent --add-service=http --add-service=https
	firewall-cmd -q --reload
elif iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
	for port in 80 443; do
		if ! iptables -C INPUT -p tcp -m state --state NEW --dport "$port" -j ACCEPT 2>/dev/null; then
			line=$(iptables -L INPUT --line-numbers -n | awk '/REJECT/ { print $1; exit }')
			iptables -I INPUT "$line" -p tcp -m state --state NEW --dport "$port" -j ACCEPT
		fi
	done
	command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save
fi

# 8. Daily backup ------------------------------------------------------------
mkdir -p /var/backups/trion && chmod 700 /var/backups/trion
if [ "$USE_MONGO" = 1 ]; then
	# Export MongoDB in the file store layout (restore with import-dir.js).
	cat > /usr/local/sbin/trion-backup <<EOF
#!/usr/bin/env bash
set -euo pipefail
rm -rf $DATA/export
runuser -u trion -- env MONGO_URI="\$(grep -E '^TT_MONGO_URI=' $ENV_FILE | cut -d= -f2-)" \\
	MONGO_DB="\$(grep -E '^TT_MONGO_DB=' $ENV_FILE | cut -d= -f2-)" \\
	$NODE_DIR/bin/node $PREFIX/app/deploy/mongo-gateway/export-dir.js $DATA/export >/dev/null
tar -C $DATA/export -czf /var/backups/trion/trion-\$(date -u +%Y%m%dT%H%M%SZ).tgz .
rm -rf $DATA/export
find /var/backups/trion -name 'trion-*' -mtime +14 -delete
EOF
else
	cat > /usr/local/sbin/trion-backup <<EOF
#!/usr/bin/env bash
set -euo pipefail
tar -C $DATA -czf /var/backups/trion/trion-\$(date -u +%Y%m%dT%H%M%SZ).tgz store
find /var/backups/trion -name 'trion-*' -mtime +14 -delete
EOF
fi
chmod 700 /usr/local/sbin/trion-backup
echo "17 4 * * * root /usr/local/sbin/trion-backup" > /etc/cron.d/trion-backup

# 9. Wait for HTTPS -------------------------------------------------------------
say "Waiting for https://$DOMAIN/health"
for _ in $(seq 1 60); do
	if curl -fsS --max-time 5 "https://$DOMAIN/health" >/dev/null 2>&1; then
		say "Live at https://$DOMAIN/"
		echo "  Secrets: $ENV_FILE    Logs: journalctl -u trion-server -u caddy -f"
		exit 0
	fi
	sleep 5
done
echo "Not reachable over HTTPS yet: journalctl -u caddy -n 50" >&2
exit 1
