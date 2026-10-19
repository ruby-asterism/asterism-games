# Changelog

Versions before 0.11.1 are noted in the README where each feature is
described ("games 0.10.0" and the like).

## 0.17.0

- **`asterism-games play <game>`** (README "Playing in a terminal"): the
  tables from a terminal, CRuby and the asterism gem only. `play othello`
  is what `bin/othello-tty` was (the script stays and runs it, with the
  same options). `play mahjong` is new: the table list, the lobby (sit,
  stand, CPUs, tonpuu or hanchan, start), the rounds with the tiles in
  kanji as the table app draws them (the hand in two rows, 一..九 or
  full-width １..９ over 萬 筒 索; 一萬 ４筒 ３索 東 in the rivers), or
  `--tiles emoji` (🀇🀈🀉; the fonts decide how they look, 🀄 is often a
  colour emoji) or `--tiles mpsz` (1m 4p 3s and 東 ... 中), the result
  with its yaku and points and the OKs it waits for, the end of the game,
  and watching. Discard by the letter under a tile or by the tile (`6s`,
  `0p`); `riichi`, `tsumo`, `ron`, `pon`, `chi`, `kan`, `pass`, `ok`, with
  a choice when there are several ways; the last line says what can be
  done now, and on a terminal the time left counts down in place once a
  second (only that line is rewritten, the cursor saved and put back, so
  a line being typed is untouched). `--commands "sit,cpu,start"` waits
  for the moment the table can take each command (the lobby, the owner's
  role, the four seats). Tiles and letters keep their columns however wide a terminal
  or a font makes an emoji (each put at its column with the cursor). Both
  take `--router`, `--credentials`, `--namespace`, `--table`, `--name`,
  and with neither of the first two `ASTERISM_ROUTER` /
  `ASTERISM_CREDENTIALS`, as the asterism command line; both wait for a
  host that left the network and go on when it is back.
- The gem holds the mahjong client (`lib/asterism_games/play/`), not the
  table: it needs neither riichi_engine nor the framework.
- `asterism-games --help` (and `help`, `-h`) prints the usage; it used to
  start the host.
- Updating: `./update.sh 0.17.0` (docs/install.md); nothing in `.env`. The
  host and the tables do not change.

## 0.16.3

- **asterism 0.8.0** (the Gemfile's pin, from 0.7.1): the host now takes
  from the gem what it did by hand before: the tables' counts on
  `@status` (`net.status`; README "Status"), the players' table apps
  coming and going (`net.on_app_join` / `on_app_leave`; README "Who is
  there"), and the methods' argument names and texts in the meta
  (`asterism objects`, `asterism mcp`). Nothing the players or the
  tables see changes; the wire protocol is 1 as before. The gem's
  dependency stays `~> 0.7, >= 0.7.1`: with an asterism 0.7.1 the host
  still does these by hand.
- Updating: `./update.sh 0.16.3` (docs/install.md); nothing in `.env`.

## 0.16.2

- **The owner away hands the role on** (README "Players that drop out"):
  when a mahjong table's owner has been away for `owner_handover_seconds`
  (`MAHJONG_OWNER_HANDOVER_SECONDS`, 60; 0: never), in the lobby or in a
  game, the role goes to a member who is there: the seated one who sat
  first, else the one who joined first. The old owner coming back does
  not take it back. One log line.
- **A table left alone ends its game** (README "Players that drop out"):
  during a game, when no seated human is there any more (a member who
  left counts no more at once, an away one for `abandon_seconds`,
  `MAHJONG_ABANDON_SECONDS`, 180; 0: never), the game is abandoned: back
  to the lobby, the CPUs kept, the away humans off their seats, nothing
  recorded (no record, nothing in the stats). One log line. Tables of CPUs
  only (`humans: 0`) are not touched.
- `seat_reuse_seconds` stays 1800 (README "Who joins"): with the console
  0.3.9 a page opened again in the same browser comes back as the same
  seat, and the time still has to match the door's `WS_DOOR_SEAT_IDLE`,
  after which a seat may go to another page.
- Updating: `./update.sh 0.16.2` (docs/install.md); nothing in `.env`
  (the two settings have their defaults). Works with any console; with
  0.3.9 a closed tab opened again is the same person.

## 0.16.1

- The mahjong table's view carries the game host's version, `hv`
  (README, the view's keys), so the table apps can show which host they
  are playing on (the list of tables and the lobby). Nothing else
  changes; `.env` and the records stay as they are.

## 0.16.0

- **The rooms of one invite link see each other's game records** (README
  "Game records"; with a console 0.3.8): the host reads a room's
  `"group"` from `rooms.json` (the console's invite link it was made
  from; not secret) and gives it to the room's host, which keeps it with
  each game the room plays. A room's `records` and `record` give out its
  own games and those of the rooms of the same group (the same table
  name). Rooms without a group (made by an admin, or a console before
  0.3.8), the permanent tables and the LAN tables are as before. The
  stats and `@status`'s `last` stay the room's own; the newest kept are
  counted as before.
- The records' database gains the column `grp` (added in place on the
  first start; the format stays 1, so 0.15.0 put back reads it as
  before). The games of before keep none and stay their own room's.
- Updating: `./update.sh 0.16.0` (docs/install.md, "From 0.15 to
  0.16.0"); nothing in `.env`. Either the console or the host may be
  updated first.

## 0.15.0

- **A daily limit per AI kind** (README "AI players"):
  `ASTERISM_GAMES_AI_DAILY_USD_CLAUDE` and `ASTERISM_GAMES_AI_DAILY_USD_JEV`
  give a kind a limit of its own. A kind with one stops when its own money
  of the day reaches it: no table offers it any more and its seats are
  played by the CPU, while the other kinds go on. A kind without one
  follows `ASTERISM_GAMES_AI_DAILY_USD` as before (the day's total of
  every kind). Without any of them the host behaves as 0.14.0. A value
  that is not a number of dollars (0 or more) is ignored with a line in
  the log; the start's log line says each kind's limit, and the stop is
  said once per kind (`today's limit for claude ($10.0) is reached`). A
  new day lets the kind play again.
- `@status`'s `ai_today` keeps `calls`, `usd` and `limit_usd` and, when a
  kind has a limit of its own, adds `kinds` (each kind's `usd`,
  `limit_usd`, `own`, `over`; README "Status"). The rooms' status
  (`bin/asterism-games status`) adds `kind_limit_usd` and prints a kind's
  money against its own limit. `ai_usage.json` keeps its form.
- **Mahjong: the start of a round and the result** (README "Result"),
  at a table with humans:
  - After the deal the host waits `deal_pause_seconds` (2,
    `MAHJONG_DEAL_PAUSE_SECONDS`) while the screens show the round's name
    ("東1局 0本場"): no clock runs (the dealer's first move has its full
    time after it), no CPU or AI player plays, `act` is `"not offered"`.
    New view key `in` (the ms left).
  - A round's result waits until every human seated and there (not away)
    has pressed OK, the action next (12): a screen of before gives its
    OK with its "next" as it did. Whoever does not press, the result
    moves on `result_auto_seconds` (10, `MAHJONG_RESULT_AUTO_SECONDS`)
    after the end of its count. The count is the screens' rule too: per
    winner one second for each yaku line and one for the points, the
    winners of a double or triple ron one after the other, one second for
    a round without a win. New view key `ok`: `[the seats that gave their
    OK, the seats still waited for, the ms until it moves on]` (bits,
    bits, ms; not in a spectator's delayed view).
  - **`result_seconds` (`MAHJONG_RESULT_SECONDS`) no longer holds a table
    with humans**: the fixed 8 s are now only those of a table without
    humans (CPUs and AI players), which stays as it was (no pause, no
    OKs). The end of a game (`over`) is as before.
  - A table saved with a result by 0.14.0 moves on by its saved time.
- Updating: `./update.sh 0.15.0` and the two lines in `.env`
  (docs/install.md, "From 0.14 to 0.15.0"); the times of the round's start
  and result have optional lines of their own.
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
