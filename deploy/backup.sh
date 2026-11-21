#!/usr/bin/env bash
# Backs up the game store to $TT_BACKUP_DIR (default /var/backups/trion) and
# deletes backups older than $TT_BACKUP_DAYS (default 14). Run as root;
# bootstrap.sh installs it as a daily cron job.
#
# Restore (Postgres):
#   docker compose ... exec -T db pg_restore -U trion_admin -d trion --clean < trion-<stamp>.dump
#
# These copies live on the same VM: also copy them off the machine now and
# then (e.g. scp, or Oracle Object Storage, which has a free tier).
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="${TT_BACKUP_DIR:-/var/backups/trion}"
KEEP_DAYS="${TT_BACKUP_DAYS:-14}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STORE="$(grep -E '^TT_STORE=' deploy/.env | cut -d= -f2-)"
DC=(docker compose -f deploy/docker-compose.yml --env-file deploy/.env --profile postgres)

mkdir -p "$DEST"
chmod 700 "$DEST"
if [ "$STORE" = "postgrest" ]; then
	out="$DEST/trion-$STAMP.dump"
	"${DC[@]}" exec -T db pg_dump -U trion_admin -d trion --format=custom > "$out"
else
	out="$DEST/trion-$STAMP.tgz"
	"${DC[@]}" exec -T server tar -C /data -czf - . > "$out"
fi
test -s "$out"
find "$DEST" -name 'trion-*' -type f -mtime +"$KEEP_DAYS" -delete
echo "$(date -u +%FT%TZ) backup ok: $out ($(stat -c %s "$out") bytes)"
