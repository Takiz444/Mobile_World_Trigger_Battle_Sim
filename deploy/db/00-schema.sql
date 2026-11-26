-- Trion Tactics game store (PostgrestStore). Runs once when the Postgres
-- container initializes an empty data volume.
--
-- Each record is a JSONB document keyed by id, the same records the server
-- keeps in memory (GameStore). A few fields are lifted into generated
-- columns for indexing and queries (leaderboards, history, analytics); the
-- server itself only does key-value reads and writes.

create schema if not exists api;

create or replace function api.touch_updated_at() returns trigger
language plpgsql as $$
begin
	new.updated_at := now();
	return new;
end $$;

create table api.accounts (
	id          text primary key,
	doc         jsonb not null,
	name        text generated always as (doc->>'name') stored,
	trophies    int  generated always as ((doc->>'trophies')::int) stored,
	rating      int  generated always as ((doc->>'rating')::int) stored,
	updated_at  timestamptz not null default now()
);
create index accounts_trophies on api.accounts (trophies desc, rating desc);

create table api.tickets (
	id          text primary key,
	doc         jsonb not null,
	status      text generated always as (doc->>'status') stored,
	updated_at  timestamptz not null default now()
);

create table api.matches (
	id          text primary key,
	doc         jsonb not null,
	mode        text generated always as (doc->>'mode') stored,
	ranked      boolean generated always as ((doc->>'ranked')::boolean) stored,
	winner      int  generated always as ((doc->>'winner')::int) stored,
	ended_at    double precision generated always as ((doc->>'ended_at')::double precision) stored,
	player0     text generated always as (doc->'players'->>0) stored,
	player1     text generated always as (doc->'players'->>1) stored,
	updated_at  timestamptz not null default now()
);
-- Startup loads unfinished + recently finished matches.
create index matches_open on api.matches (winner, ended_at);
-- Match history per player.
create index matches_player0 on api.matches (player0, ended_at desc);
create index matches_player1 on api.matches (player1, ended_at desc);

create table api.meta (
	id          text primary key,
	doc         jsonb not null,
	updated_at  timestamptz not null default now()
);

create trigger accounts_touch before update on api.accounts for each row execute function api.touch_updated_at();
create trigger tickets_touch  before update on api.tickets  for each row execute function api.touch_updated_at();
create trigger matches_touch  before update on api.matches  for each row execute function api.touch_updated_at();
create trigger meta_touch     before update on api.meta     for each row execute function api.touch_updated_at();

-- The role PostgREST runs requests as. Only the game server can reach
-- PostgREST (internal network), so this role has full read/write on the
-- store. To harden: give PostgREST a JWT secret, make game_server a JWT
-- role, set TT_DB_TOKEN, and drop the anonymous role.
create role game_server nologin;
grant usage on schema api to game_server;
grant select, insert, update, delete on all tables in schema api to game_server;
