# Changelog

Versions before 0.11.1 are noted in the README where each feature is
described ("games 0.10.0" and the like).

## 0.19.1

- The commentary tells where to get VOICEVOX when it finds no engine:
  the terminal says it is a free app installed and started apart from the
  gem (with its home page), the page's bar says the same in Japanese, and
  `commentate --help` and the README's "The voice" say it up front.

## 0.19.0

- **Commentary** (README "Commentary"): `asterism-games commentate
  mahjong` watches a table from its spectate key (0.18.0) and shows it in
  the browser: a small web server on `127.0.0.1` (HTTP and Server-Sent
  Events by hand on `socket`, no new gem; port 7470 or the next free one),
  a page that draws the table in a canvas with the hand-drawn tile sheets
  of Family mruby's mahjong app, and commentary in Japanese made by rules
  from what changed between two views (a round's start, the oorasu,
  riichi and its waits, calls, a dora or red five discarded, a new dora,
  the wall at 10, a tenpai, a win with its yaku and points, a draw, the
  lead changing hands, the end), shown as captions and read by the
  browser's voice (Web Speech API) in a queue that drops the old small
  lines first. Space pauses, M silences, H hides the hands; `--public`
  keeps the hands from the page altogether; `--json` gives the lines on
  standard output; `--table`, `--namespace` (a room's tables), `--port`,
  `--no-open`. It only reads (never joins or calls a table) and goes on
  when the host leaves and comes back.
- **The voice** (README "Commentary", "The voice"): the commentary speaks
  with VOICEVOX on this machine (`--voicevox URL`, `VOICEVOX_URL`, default
  `http://127.0.0.1:50021`), by default as ずんだもん (`--speaker`,
  `--style`; the numbers looked up by name in `/speakers`). The fixed
  phrases (riichi, the calls, ron and tsumo, the rounds, 満貫 to 役満, ...)
  are WAV files made by the user's own engine from the gem's list
  (`commentate/mahjong_voice.yml`) into
  `$XDG_CACHE_HOME/asterism-games/voices/<speaker>-<style>/`, named by the
  phrasing's digest (`asterism-games commentate voices --make`, and the
  missing ones at the start; `voices --list` lists the characters). The
  rest of each line is synthesised as it comes and served from the
  command's web server, kept in a bounded cache. The page says it all in
  one queue (the fixed phrase, then the line; captions as the voice
  starts; the old small lines dropped first) and shows the credit
  `VOICEVOX:ずんだもん`. ずんだもん's lines are in her tone (〜なのだ),
  kept as a tone of the phrasings (`MahjongPhrases::TONES`). Without an
  engine the browser's voice reads as before. The engine gets the speech
  only (サンマン, 30フ 2ハン), with the words it misreads written out
  (流局, 起家, 跳満: `MahjongPhrases::SPEECH_READ`). No sound is in the gem;
  `net/http` only, no new gem.
- **The AI's one-liners** (README "Commentary", "The AI's one-liners"):
  at a riichi, a win, a draw, the lead changing hands, the oorasu, the end
  and after a quiet minute, Claude (`claude-haiku-5-5` by default,
  `--ai-model`) adds a short line after the fixed commentary, in the
  voice's tone, marked AI on the page. At most one call every 20 s (8 s
  for a scene bigger than the last one asked about: a win after a riichi),
  one at a time, only while a page is open. A quiet minute is about one
  topic the command picks (the lead, a dama tenpai with the hands shown,
  the dora, the wall, the last discard). Thinking off, effort low,
  `max_tokens` 200; a cut answer is dropped with its stop reason in the
  log. The fixed part of the ask (the role,
  the rules in short, the tone, the length, whether the hands may be
  told) is cached; the table now and the lines that just came follow.
  With `--public` or a page's H the AI gets no hand. An answer whose round
  or phase is over, or that comes after 15 s, is dropped; on the page an
  AI's line comes after the fixed ones and goes first when the voice
  falls behind. The money is counted from the tokens (cache writes and
  reads too) in `$XDG_STATE_HOME/asterism-games/commentary_ai_usage.json`
  (`AI::Budget`), shown in the bar, and capped at `--ai-daily-usd`
  (default 3 USD a day). `ANTHROPIC_API_KEY`; the anthropic gem stays
  outside the gem's dependencies (loaded only with a key);
  `ASTERISM_GAMES_AI_FAKE=1` tries it without one. `--ai off` turns it off.
- The gem holds the page (HTML, JS, CSS) and the two tile sheets
  `tiles_hand.bmp` and `tiles_river.bmp`, copied byte for byte from
  fmruby-core; in the gem they are MIT (`TILES_LICENSE.txt`). The gem's
  test checks they are there and unchanged.

## 0.18.0

- **Spectate** (README "Spectate"): the host puts a table's spectate view
  on `asterism/<node>/spectate/<table>/state` (a room's table as
  `room<slot>-<table>`), a key outside the players' role
  (`asterism/*/games/**`) and outside every room, for a console's
  spectators and viewers and for the asterism gem's command line and MCP
  bridge. The framework's `Game#spectate_view` (nil by default: nothing
  is put) and `Game#spectate_delay_ms`; the host takes the view when it
  puts the state, keeps it for the delay and puts each one in order, and
  puts the last one again every 5 s. A room's host puts its tables' views
  on a second connection of its own (the host's own certificate, no
  namespace), never into the room; with a slot's certificate (a console
  before 0.3.0) nothing. The application `spectate` is on the network (a
  liveliness token) while the host puts.
- The mahjong table's spectate view: the table in words as `look` gives
  it, with every seat's hand and drawn tile (the hands a spectator member
  sees); never the wall, the ura dora, an indicator not turned yet, a node
  or a token. Held for the table's spectator delay (none by default).
  Othello and the drawing board put nothing.
- The console's role `games-host` needs two more lines for it (Read and
  write `asterism/${node}/spectate`, `asterism/${node}/spectate/**`); the
  console's docs/rooms.md has them and the `spectator` role. Without them
  the router drops the puts and nothing else changes.
- The host's last log line counts the spectate puts and their largest
  size apart from the players' messages.

## 0.17.1

- `bin/othello-tty` is gone: `asterism-games play othello` is the same
  client, and the gem installs `asterism-games` only.
- The first version published on rubygems.org: `gem install
  asterism-games` gives `asterism-games play` with the asterism gem and
  nothing else. The host and the tables are 0.17.0's.

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
- **Keys on a terminal** (README "Keys"): when the input is a terminal,
  both clients read one key at a time, the table apps' keys. Mahjong:
  Left / Right choose a tile (`^^` under it), Enter or Space discards it,
  `R` riichi, `T` tsumo or ron, `P` pon, `C` `V` `B` the chi offered,
  `K` `L` `J` the kans, `N` nine kinds, Esc pass, Enter the result's OK;
  the lobby `1`-`4` sit, `S` stand, `C` CPUs, Enter start. Othello: the
  arrows move a cursor on the board (it stops at the edges), Enter plays
  there, Esc resigns after asking (`resign? [Y] yes [N] no`: `Y` resigns,
  `N` or Esc cancels); `S` sit or stand, `C` the CPU, Enter start. `Q`, Ctrl+Q or Ctrl+C
  quits, and `:` (or `/`) opens a line for any command as typed before.
  The last line names the keys that work now (`[R]リーチ [T]ツモ`). The
  terminal is in raw mode only while keys are read and is put back however
  the client ends. A pipe, a file and `--commands` work as before.
- The gem holds the mahjong client (`lib/asterism_games/play/`), not the
  table: it needs neither riichi_engine nor the framework.
- **Jev at the othello table** (README "AI players", "The othello
  table"): the owner may seat Jev as at mahjong, `cpu(token, seat,
  "jev")`; the view has `ak` (`["jev"]` when the host has Jev's key) and
  `ai`, `@status` `ais`. Othello offers Jev only (`AI::GAME_KINDS`, the
  one place that says which game seats which kinds; mahjong keeps Claude
  and Jev). A move Jev does not answer in `ai_turn_seconds` (30 s,
  `OTHELLO_AI_TURN_SECONDS`), answers out of range or fails is the CPU's;
  the day's money and the game's decisions are counted with mahjong's,
  and when they run out Jev's seat becomes the CPU. `play othello`: `A`
  (or `ai`) puts Jev in the other seat and turns it back into the CPU;
  the board's first line says when Jev is thinking. The same key
  (`TYPESAFE_API_KEY`) as mahjong's Jev: nothing new to set.
- `asterism-games --help` (and `help`, `-h`) prints the usage; it used to
  start the host.
- Updating: `./update.sh 0.17.0` (docs/install.md); nothing in `.env`. The
  mahjong table does not change; the othello table offers Jev where
  `TYPESAFE_API_KEY` is already set, and old table apps keep playing it
  with the CPU.

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
