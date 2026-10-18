# Changelog

Versions before 0.11.1 are noted in the README where each feature is
described ("games 0.10.0" and the like).

## Unreleased

- **`deploy/vps/update.sh` no longer stops at "local changes" because of
  `credentials/`.** The directory belongs to the container's user (mode
  700, docs/install.md), so git run as the server's user could not stat
  the `.gitignore` it tracks there and called it changed. The check of the
  checkout now leaves `credentials/` out (its contents are the host's own).
  Servers that marked the file with `git update-index --assume-unchanged`
  to get past it need nothing more.

## 0.14.0

- **The games' records in SQLite** (README "Game records"): every game a
  mahjong table plays to its end goes into one database in the state
  volume, `state_dir/records.sqlite3` (setting `records_db`), written once
  at the game's end by whichever host process played it (the rooms', the
  permanent tables', a LAN host; WAL, a 10 s wait for the lock). The 1000
  newest games of each table are kept (`records_kept`,
  `MAHJONG_RECORDS_KEPT`; the rooms' tables of one name together). A
  game in progress is still in the table's saved state (JSON).
- A room's games stay when the room closes. Only the room's own host gives
  them out (`records`, `record`, the table apps' recent games) while it is
  open; the other rooms, the permanent and the LAN tables never list them.
- **Taken in once**: a table's `<table>.records.json` of 0.13.0 goes into
  the database on the first start of 0.14.0 and is renamed
  `<table>.records.json.imported` (docs/install.md, "From 0.13 to 0.14.0").
- A game's `id` is its row in the database (it grows across the tables).
- **Backups**: after every game the host writes a consistent copy,
  `records-backup.sqlite3` (`VACUUM INTO`, renamed over the last one), for
  the console's daily backup to take; a host that finds the copy without
  the database starts from it, which is how a restore puts it back
  (docs/install.md, "Backups and restoring"). The console needs no change.
- **New method `stats(days, game, scope, from)`** (README "Stats"): per
  person (by the name at the table) and per kind (CPU, Claude, Jev):
  games, ranks, average rank, 1st rate, wins, deal-ins and riichi with
  their rates of the rounds, average score, the sum of the rank points; by
  period and kind of game, over every table and room (`"all"`, the
  default) or this table's games; names and numbers, never a record; in
  pages, with its text in the meta (`asterism call`, `asterism mcp`).
- The records keep each AI seat's kind (`"ais"`: `"claude"`, `"jev"`) for
  the stats; a record of 0.13.0 is read by its AI player's name.
- The sqlite3 gem is in the Gemfile (the image) and **not a dependency of
  the gem**: without it (the gem alone, or `records_db: json`) the records
  stay in the JSON files of 0.13.0 (the 20 newest, a room's go with it),
  and `stats` counts those. `rake test:gem` runs that way.

## 0.13.0

- **Mahjong game records** (README "Game records"): every game a table
  plays to its end is kept, the 20 newest of each table, in the table's
  place in the store (`<table>.records.json`; a room's go with the room).
  A record holds the deals, the dora indicators, every draw and discard,
  the calls, riichi, the wins and draws and the points, in `look`'s tile
  names. A game in progress is part of the table's saved state, so a host
  started again goes on with its record.
- New methods `records(from)` (the games, newest first, in pages) and
  `record(id, round, part)` (a game's head, a round, a part of a long
  round), with their names and texts in the meta: the table apps, the
  command line (`asterism call`) and an AI assistant (`asterism mcp`) read
  the same. Every answer fits one message of a board.
- `@status`: each mahjong table's most recent result (`last`: its id,
  when, the four as `[name, rank, score]` in rank order). The rooms'
  status file stays counts only.
- The views have `cl`, the last declaration (`[type, state version,
  seat, ...]`: riichi, the calls, the wins, nine kinds), which the table
  apps show at the seat that made it.
- Mahjong (the unreleased 0.12.1): `cpu(token, seat, on)` on one seat that holds a CPU or an AI
  player of another kind turns it into the one asked for in the same call
  (a CPU into `"claude"`, `"claude"` into `"jev"`, `true` an AI player
  back into a CPU). A refused AI player (`"no ai"`: no key, or the day's
  limit) leaves the seat as it was. Seat -1 still fills empty seats only.
  The table apps' lobby has a button per seat that goes round empty, CPU,
  Claude, Jev with it.

## 0.12.0

- **The gem `asterism-games`** (`asterism-games.gemspec`, `require
  "asterism_games"`): the framework, othello and the drawing board,
  `bin/asterism-games` and `bin/othello-tty`. It depends on asterism
  (`~> 0.7`, 0.7.1 or later) only. Not in it: mahjong, `bin/mahjong-bots`,
  `deploy/`, `config/`, the tests (README "The gem and the image").
- Mahjong moved from `lib/asterism_games/mahjong` to
  `app/asterism_games/mahjong`: an application on the gem, kept out of it
  (it needs the riichi_engine fork from git). `require
  "asterism_games/mahjong"` is unchanged with `app/` on the load path;
  `bin/asterism-games` and `bin/mahjong-bots` put it there when it exists.
- `bin/asterism-games --require FILE` loads a game of your own after the
  others.
- `rake test:gem`: the tests of what the gem holds, with `lib/` alone on
  the load path (mahjong never loaded).
- **The image is published**: pushing a tag `v<version>` builds
  `deploy/vps/Dockerfile` (amd64, arm64) and pushes
  `ghcr.io/ruby-asterism/asterism-games:<version>` (also `:<major>.<minor>`
  and `:latest`; `.github/workflows/image.yml`).
- `deploy/vps`: the compose file uses the published image by default
  (`GAMES_IMAGE=ghcr.io/ruby-asterism/asterism-games`); building it on the
  server is `docker-compose.build.yml`. `update.sh` takes a version
  (`./update.sh 0.12.0`: the tag `v0.12.0` and its image, pulled; `--build`
  builds it there) instead of a ref, and no longer writes `GAMES_REF`. Its
  copy of the saved tables before a restart takes the permanent tables too.
  Updating from 0.11: docs/install.md "From 0.11 to 0.12.0" (set
  `GAMES_IMAGE`, and take the new `update.sh` from the tag once).

## 0.11.1

- Jev (the `jev` AI player) is asked through TypeSafe's own API
  (`POST https://api.typesafe.ai/v1/systemone`) instead of Cloudflare
  Workers AI. Its key is `TYPESAFE_API_KEY` (console.typesafe.ai, Keys);
  `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` are no longer read.
  Move the key in `.env` when updating, or Jev is not offered.
- `ASTERISM_GAMES_JEV_MODEL` defaults to `jev-latest` (was `typesafe/jev`,
  a Workers AI name). A versioned id such as `jev-1.13.0` keeps one model.
- The tokens counted are the answer's `usage` (`input_tokens`,
  `output_tokens`); the default price stays $0.042 per million input
  tokens, output free (TypeSafe's published price, checked 2026-10-18).
