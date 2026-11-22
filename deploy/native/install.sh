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
# Re-running upgrades the app/web files and restarts; secrets and data stay.
# Works on Oracle Linux 8/9 (dnf, firewalld, SELinux) and Ubuntu (apt).
set -euo pipefail

BUNDLE="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC_APP="$BUNDLE/app"
SRC_WEB="$BUNDLE/web"
DOMAIN_ARG="${1:-}"

GODOT_VERSION=4.7.2
CADDY_VERSION=2.8.4
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
		CADDY_SHA512=b8bec15d14fb033562af9f207850027bcbaa1f891edc9efe00d38bf39e1bf9944f8b6b8eba041ddd4c171cd70c905174c704d705be2f23bc678fe1eaf37a2485 ;;
	aarch64)
		GODOT_ARCH=arm64; CADDY_ARCH=arm64
		GODOT_SHA512=dd59918da086bd49bde2f5450b5e567ff8650cbde9abbd7b8f4ca1197ff8c609baa38834666d032deafb47099078d7822279e2a0e06e5665745468f26533e7e2
		CADDY_SHA512=5466234be3e988071cef937aedbdd94c15b6f75cf7307397e67c2641219ac9bfe2c2bb3b31fc05bc68d3b6398bbe50abfa16ccf3b127318ccac31115ad26507c ;;
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

# 2. Packages ---------------------------------------------------------------
say "Installing packages"
if command -v dnf >/dev/null 2>&1; then
	dnf install -y -q curl unzip tar gzip fontconfig cronie >/dev/null
	systemctl enable --now crond >/dev/null 2>&1 || true
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
chmod 600 "$ENV_FILE"
DOMAIN=$(grep -E '^TT_DOMAIN=' "$ENV_FILE" | cut -d= -f2-)
cat > /etc/trion/caddy.env <<EOF
TT_DOMAIN=$DOMAIN
TT_SERVER_HOST=127.0.0.1
TT_WEB_ROOT=$PREFIX/web
EOF

# 6. systemd -------------------------------------------------------------------
cat > /etc/systemd/system/trion-server.service <<EOF
[Unit]
Description=Trion Tactics game server
After=network-online.target
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
MemoryHigh=450M

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

[Install]
WantedBy=multi-user.target
EOF

say "Switching to the new version"
systemctl stop trion-server caddy 2>/dev/null || true
rm -rf "$PREFIX/app.old" "$PREFIX/web.old"
[ -d "$PREFIX/app" ] && mv "$PREFIX/app" "$PREFIX/app.old"
[ -d "$PREFIX/web" ] && mv "$PREFIX/web" "$PREFIX/web.old"
mv "$PREFIX/app.new" "$PREFIX/app"
mv "$PREFIX/web.new" "$PREFIX/web"
command -v restorecon >/dev/null 2>&1 && restorecon -R "$PREFIX" >/dev/null
systemctl daemon-reload
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
cat > /etc/cron.d/trion-backup <<EOF
17 4 * * * root tar -C $DATA -czf /var/backups/trion/trion-\$(date -u +\%Y\%m\%dT\%H\%M\%SZ).tgz store && find /var/backups/trion -name 'trion-*' -mtime +14 -delete
EOF

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
