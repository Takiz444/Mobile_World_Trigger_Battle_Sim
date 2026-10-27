#!/bin/sh
# Creates the login role PostgREST connects as (password from the
# environment, so it never lives in the repo). Runs once on an empty volume.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
	-v pw="$PGRST_AUTHENTICATOR_PASSWORD" <<'SQL'
create role authenticator noinherit login password :'pw';
grant game_server to authenticator;
SQL
