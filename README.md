# asterism-games

A showcase of [Asterism](https://github.com/ruby-asterism/asterism): how
to write the server side of an application in Ruby on an Asterism
network. A game host is a CRuby process that joins a Zenoh network as an
Asterism node, exposes each table as an Asterism object, holds the state
of the games and lets players on boards (Family mruby), browsers and PCs
play through Asterism calls.

It is two parts, in this one repository, handed out two ways ("The gem
and the image"): the framework with the two sample games is the gem
`asterism-games`, and the whole host with mahjong is a docker image.

- **The framework** (`lib/asterism_games.rb`, `lib/asterism_games/*.rb`):
  everything a game host needs whatever the game is. The connection
  (Asterism's block API, the tables exposed with `caller: :from`), the
  host's loop, the puts of each table's state, saving and resuming, the
  members and their tokens, who may join in a room, the rooms' supervisor
  (one host process per room of an Asterism console), the permanent tables
  next to the rooms, the status (`GET /status`) and the settings. A game
  subclasses `AsterismGames::Game` and `AsterismGames::Remote` and writes
  only its rules and the methods it exposes ("Writing a game"). The
  framework requires no game.
- **The games**: riichi mahjong (`app/asterism_games/mahjong/`: four
  players, seats nobody takes are played by CPUs), built on the
  [riichi_engine](https://github.com/HenrikStephensen/riichi_engine) gem (a
  fork with fixes, see "riichi_engine" below), which only that game needs,
  so it is an application on the gem (`app/`) and not in it;
  othello (`lib/asterism_games/othello/`: two seats and the spectators,
  the smallest game on the framework, "The othello table"); and a shared
  drawing board (`lib/asterism_games/board/`: no winner, one picture every
  member draws on, handed out as strokes that a console can record and
  play back, "The drawing board"). The table screens are Family mruby apps
  (fmruby-core's `flash/app/game/mahjong/`, `flash/app/game/othello/` and
  `flash/app/game/board/`), on the boards and in the browser build;
  `asterism-games play othello` and `asterism-games play mahjong` are the
  tables in a terminal, with CRuby and the asterism gem only ("Playing in a
  terminal").

```
 bin/asterism-games  ──requires──>  asterism_games/mahjong (app/, when there)  ──>  riichi_engine
        │            ──requires──>  asterism_games/othello
        │            ──requires──>  asterism_games/board
        │            ──requires──>  your game (--require FILE)
        │                                   │ (Table < Game, Remote < Remote)
        └──requires──>  asterism_games  <───┘
                        (Host, Rooms, Config, Store, Game, Remote)  ──>  asterism

 the gem asterism-games:  lib/ (framework, othello, board, the terminal clients), bin/asterism-games, bin/othello-tty
 the image:               all of the above, app/ (mahjong), config/, the Gemfile's gems
```

Status: up to four players at a table (a lobby to sit and start, calls by
several players decided together, players that drop out played for after a
short wait until they are back), two tables at once on a local network, or
a table in each room of an Asterism console on a server ("Rooms") and
permanent tables next to them for the boards and browsers registered with
the console ("Permanent tables"; the server's setup: docs/install.md).

| Path | What |
|---|---|
| `asterism-games.gemspec` | the gem: what it holds and needs ("The gem and the image") |
| `bin/asterism-games` | the host (loads the framework and the games); `status`; `play <game>`, a table in this terminal ("Playing in a terminal"); `help` |
| `bin/mahjong-bots` | players without screens, for trying a mahjong table (one process each; not in the gem) |
| `bin/othello-tty` | `asterism-games play othello`, under its old name |
| `lib/asterism_games/play.rb`, `lib/asterism_games/play/` | the terminal clients ("Playing in a terminal"): the options, `othello.rb`, `mahjong.rb` with `mahjong_text.rb` (tiles as text, widths, reading the input) and `mahjong_screen.rb` (the screen); they need neither the framework nor riichi_engine |
| `lib/asterism_games.rb` | the framework, without any game |
| `lib/asterism_games/game.rb` | the base of a game: the registry, the members and tokens, who joins in a room, the views, the time, saving ("Writing a game") |
| `lib/asterism_games/remote.rb` | the base of the exposed object: the methods and their numbers of arguments, the caller (`from:`), `join` / `mine` / `leave` |
| `lib/asterism_games/host.rb` | the connection (Asterism's `Net`), the loop, the puts, the status file |
| `lib/asterism_games/rooms.rb` | the rooms' supervisor: one host process per room that opens a table ("Rooms"), and one for the permanent tables ("Permanent tables"); `GET /status` |
| `lib/asterism_games/config.rb` | the settings (file and environment; each game's table keys come from the game) |
| `lib/asterism_games/store.rb` | saved states, one JSON file per table |
| `app/asterism_games/mahjong.rb` | the mahjong game, outside the gem: requiring it registers `mahjong` |
| `app/asterism_games/mahjong/` | `table.rb` (seats, rounds, views, time, the table's settings), `engine.rb` (the calls into riichi_engine), `remote.rb` (the exposed object), `tiles.rb` (tile numbers) |
| `lib/asterism_games/othello.rb` | the othello game: requiring it registers `othello` |
| `lib/asterism_games/othello/` | `board.rb` (the rules, a game as a history, the CPU), `table.rb` (seats, the owner, time, views, saving), `remote.rb` (the exposed object) |
| `lib/asterism_games/board.rb` | the drawing board: requiring it registers `board` |
| `lib/asterism_games/board/` | `table.rb` (the strokes, the owner, the limits, the picture in pages, saving), `remote.rb` (the exposed object) |
| `config/example.yml` | settings to copy |
| `config/rooms.yml` | the settings of the server's image (rooms) |
| `deploy/vps/` | the server's image, compose files, `update.sh` (docs/install.md) |
| `.github/workflows/image.yml` | builds the image for each tag `v<version>` and publishes it on ghcr.io |
| `docs/install.md` | putting the host on a server next to an Asterism console |
| `test/` | the tests (`rake test`, `rake test:gem`); `test/framework/` a small game on the framework alone |

## The gem and the image

**The gem** `asterism-games` (`require "asterism_games"`) is for writing a
game host of your own: the framework, the two sample games that need
nothing else (othello, the drawing board), `bin/asterism-games` (with
`play`, the terminal clients of othello and mahjong: a mahjong table needs
riichi_engine, its client does not) and `bin/othello-tty`. It depends on
the asterism gem only (0.7.1 or later in
0.x; what came after 0.7.1, such as `@status` and `on_app_join`, is used
when there). Not in it: mahjong (`app/`, it needs the riichi_engine fork
from git), `bin/mahjong-bots`, `deploy/`, `config/` and the tests. The AI
players' code is in it, and is offered only with a key; Claude needs the
anthropic gem as well, which is not a dependency (`gem install anthropic`,
"AI players").

```
gem install asterism-games              # CRuby 3.2 or newer and a C compiler (asterism-zenoh)
```

A host of the sample games on a plain zenohd (`games.yml`):

```yaml
router: tcp/127.0.0.1:7447
node: games
state_dir: var/state
tables:
  - name: othello1
    game: othello
  - name: board1
    game: board
```

```
asterism-games --config games.yml       # games/games/othello1, games/games/board1
asterism-games play othello --commands "sit,cpu,start"  # in another terminal: play against the CPU
```

Without a settings file the host serves the first game's tables: with the
gem alone that is othello (`othello1`). A game of your own ("Writing a
game") is a file that requires `asterism_games` and registers its table;
the host loads it with `--require`, and the settings name its tables:

```
asterism-games --config my.yml --require ./counter.rb
```

**The image** `ghcr.io/ruby-asterism/asterism-games:<version>` is the
whole host as the server runs it: the gem's files, mahjong (`app/`), the
settings of the rooms (`config/rooms.yml`) and the gems of `Gemfile.lock`
(riichi_engine at a pinned revision, anthropic). The CI
(`.github/workflows/image.yml`) builds it for each tag `v<version>` (the
number of `VERSION`) for amd64 and arm64. `docker pull
ghcr.io/ruby-asterism/asterism-games:0.12.0`; next to a console:
docs/install.md (`deploy/vps`, which pulls it, or builds it with
`docker-compose.build.yml`).

## Running

From this checkout (everything, mahjong too). CRuby 3.2 or newer and a C
compiler (asterism-zenoh compiles its extension). Bundler fetches the
riichi_engine fork from GitHub (see "riichi_engine"). The `Gemfile` is for
this checkout and the image (mahjong, the AI players); the gem's own needs
are in the gemspec.

```
bundle config set --local path vendor/bundle
bundle install
ASTERISM_GAMES_CONFIG=config/example.yml bundle exec bin/asterism-games
```

The host connects to the router in the settings (by default
`tcp/127.0.0.1:7447`, a zenohd on this machine) as the node `games` and the
application `games`, and exposes each table as an object:
`games/games/mahjong1` and `games/games/mahjong2` (the default settings;
`config/example.yml` adds `games/games/othello1`). Ctrl-C (or SIGTERM) saves and stops. Started again,
it goes on from the saved state (the same round, the same turn, the same
seats and tokens). When the router goes away, it connects again every 3 s.

asterism comes from rubygems at a fixed version (0.8.0); riichi_engine from
the `fmrb` branch of the fork on GitHub (see "riichi_engine" below).

## Settings

A YAML file (`--config PATH` or `ASTERISM_GAMES_CONFIG`; see
`config/example.yml`), with the environment over it:

| Key | Environment | Default | |
|---|---|---|---|
| `router` | `ASTERISM_GAMES_ROUTER` | `tcp/127.0.0.1:7447` | the Zenoh router |
| `node` | `ASTERISM_GAMES_NODE` | `games` | this host's node ID |
| `app` | `ASTERISM_GAMES_APP` | `games` | the application every game lives under |
| `credentials` | `ASTERISM_GAMES_CREDENTIALS` | none | a console's `.tar`, for a router over mutual TLS (the router comes from it, and the node ID too unless `node` is given) |
| `state_dir` | `ASTERISM_GAMES_STATE_DIR` | `var/state` | where the tables are saved |
| `records_db` | `ASTERISM_GAMES_RECORDS_DB` | `state_dir/records.sqlite3` | the games' records ("Game records"): the SQLite database, or `json` for the JSON files of before 0.14.0 (also what a host without the sqlite3 gem uses) |
| `tables` | | the first game's tables (`mahjong1`, `mahjong2`; with the gem alone `othello1`) | each `{name, game, ...}`; `game` defaults to the first game registered (`mahjong`; with the gem alone `othello`) |

The other keys of a table are its game's (`settings` in the game's class,
"Writing a game"). A mahjong table takes (the environment applies to every
mahjong table):

| Key | Environment | Default | |
|---|---|---|---|
| `turn_seconds` | `MAHJONG_TURN_SECONDS` | 5 | a player's time for a move (a discard, riichi, a kan, a win); a move that takes longer goes on into the bank ("Time") |
| `bank_seconds` | `MAHJONG_BANK_SECONDS` | 20 | each player's bank, full again every round; when the move's time and the bank are used up, the drawn tile is discarded (0: no bank, `turn_seconds` a move and no more) |
| `call_seconds` | `MAHJONG_CALL_SECONDS` | 8 | the time to call a discard, the same for every player who may; after it the call is passed |
| `result_seconds` | `MAHJONG_RESULT_SECONDS` | 8 | a table without humans (CPUs and AI players only): a round's result stays this long. A table with humans waits for their OKs instead ("Result", games 0.15.0) |
| `result_auto_seconds` | `MAHJONG_RESULT_AUTO_SECONDS` | 10 | a table with humans: a round's result moves on by itself this long after its count, whoever has not pressed OK ("Result") |
| `deal_pause_seconds` | `MAHJONG_DEAL_PAUSE_SECONDS` | 2 | a table with humans: after the deal the round's name shows this long; no clock runs and no CPU or AI player plays ("Result"; 0: none) |
| `over_seconds` | `MAHJONG_OVER_SECONDS` | 60 | the end of a game stays this long (or until the owner presses next), then the table is back in its lobby |
| `away_seconds` | `MAHJONG_AWAY_SECONDS` | 10 | a member whose node leaves the network is away at once; one that has not called the table this long is away too (where the host does not see the nodes come and go: "Who is there") |
| `away_wait_seconds` | `MAHJONG_AWAY_WAIT_SECONDS` | 2 | an away member's time to discard or to call, instead of `turn_seconds` and the bank / `call_seconds` |
| `cpu_ms` | `MAHJONG_CPU_MS` | 700 | a CPU's pause before it acts |
| `cpu_level` | `MAHJONG_CPU_LEVEL` | `normal` | `easy` / `normal` / `hard` (riichi_engine's CPU levels) |
| `ai_turn_seconds` | `MAHJONG_AI_TURN_SECONDS` | 30 | an AI player's time for a move; then the CPU plays it ("AI players") |
| `ai_call_seconds` | `MAHJONG_AI_CALL_SECONDS` | 15 | an AI player's time to answer a discard it may call |
| `humans` | | 4 | seats members may take (0: four CPUs that play at once, for tests) |
| `spectators` | `MAHJONG_SPECTATORS` | 12 | members without a seat at most ("Spectators") |
| `spectator_delay_minutes` | `MAHJONG_SPECTATOR_DELAY_MINUTES` | 0 | spectators see the game (and the four hands) this much later ("Spectators"); `spectator_delay_seconds` / `MAHJONG_SPECTATOR_DELAY_SECONDS` as before, in seconds |
| `rule` | | (below) | riichi_engine rule keys over the host's defaults ("Rules"); the owner's local rules go over them ("Local rules") |
| `records_kept` | `MAHJONG_RECORDS_KEPT` | 1000 (SQLite), 20 (JSON) | the newest games kept of a table ("Game records") |
| `owner_handover_seconds` | `MAHJONG_OWNER_HANDOVER_SECONDS` | 60 | the owner away this long: the role goes to a member who is there ("Players that drop out"; 0: never) |
| `abandon_seconds` | `MAHJONG_ABANDON_SECONDS` | 180 | a game whose seated humans have all been away this long (or have left) is abandoned: back to the lobby, not recorded ("Players that drop out"; 0: never) |

An othello table's keys: "The othello table".

## Rooms

An Asterism console (0.2.2 and later) makes rooms: a key space of its own
(`room/<slot>/**`) that people join from a browser with the room's link
(the console's docs/rooms.md). With a `rooms` section (or
`ASTERISM_GAMES_ROOMS_DIR`) the host serves tables in rooms instead of the
`tables` above.

- **Which rooms, which tables.** The console writes the open rooms to
  `rooms.json` in its "rooms" volume, with the app each room's link opens.
  A room that opens one of `rooms.apps` (by default every game's table
  screen, `Game.screens`: `/app/game/mahjong/mahjong.app.rb`,
  `/app/game/othello/othello.app.rb`, `/app/game/board/board.app.rb`) gets
  the tables of `rooms.tables` whose game has that screen: a room opening
  the mahjong screen gets the mahjong tables, one opening the othello
  screen the othello tables, one opening the board's screen the board. Without
  `rooms.tables` each game's first table is there (`mahjong1`, `othello1`),
  so each room gets one table of its game. Other rooms (another app, or a
  game with no table in `rooms.tables`) get nothing. The admin chooses the
  app when making the room (Admin > Rooms, "Opens": Mahjong; the console's
  `ASTERISM_ROOM_APPS` lists what may be chosen), so a table needs no step
  beyond the one a room needs anyway. The people in the room open the link
  and see the table in the screen's list, as on a home network
  (`games/games/mahjong1`).
- **One process per room.** The asterism gem keeps one connection a
  process, so the supervisor forks a host process (Host) per room. It joins
  the router in the room's namespace (`room/<slot>`): its keys are the
  room's, and nothing of it reaches other rooms or the registered side (the
  router's ACL). **Which certificate** (0.5.0): when `rooms.json` lists the
  host's node in `"hosts"` (a console 0.3.0, its `ASTERISM_ROOM_HOSTS`),
  the router keeps the rooms' `asterism/games...` for the host's own
  certificate, and the process joins with it: `rooms.credentials`, else the
  permanent tables' `.tar` (`permanent.credentials`; the same row `games`
  of the console's registry), at `rooms.router` or the permanent tables'
  router. With a console before 0.3.0 it joins with the slot's certificate
  (`certs/room-<slot>.tar`, in the same volume, read-only), as before. A
  console that lists the host while the host has no certificate set: the
  log says so and the rooms get no table that works. At most `rooms.max` rooms have tables (3); a room
  beyond that gets none (the status says so). A host process that stops is
  started again after 1, 2, 4 ... 30 s.
- **A slot used again.** The tables of a room are saved under
  `state_dir/rooms/<slot>/` with the room's ID (`room.json`). When the room
  is closed or has ended (the file lists it as revoked, or its end has
  passed), or the slot holds another room, the host process stops and the
  directory is removed: the next room on the slot starts from an empty
  lobby, with no seats or tokens of the last one. A file that cannot be read
  changes nothing (it is not taken as every room closed).
- **Restarts.** Stopped (SIGTERM) and started again, the supervisor finds
  the open rooms and each host reads its saved tables: a game goes on from
  the same turn. When the router restarts, each host connects again within
  3 s.
- **Status.** `rooms.status_listen` (`0.0.0.0:7460` in the image) answers
  `GET /status`: the rooms with tables, each table's state and counts
  (seated, CPUs, at the table, away; no names, nodes or tokens), whether the
  host can read `rooms.json`, the rooms without a table, `busy` (someone
  sits at a table and is there: away seats do not count) and the RSS. The console's rooms page shows it
  (`ASTERISM_GAMES_STATUS_URL`); `bin/asterism-games status [--idle]` prints
  it (`--idle` exits 0 when nobody sits at a table: update.sh's
  `--when-idle`). In the console's graph each room's frame shows the host's
  node (`games`) and its tables, like any node in a room.

### Who joins

A seat at a table goes with the node ID of the member that took it: a
member's `join` and `mine` give back its token, and with it its hand. So
the table must know that a call's caller (`from:`, which Asterism fills
in from the last chunk of the call's key: the tables are exposed with
`caller: :from`) is who it says.

**With seats** (a console 0.3.0: `rooms.json` says how many seats the
room's slot has, `"seats"`, and the seats' node prefix): the console's door
gives each page in a room a seat and connects it with the seat's
certificate, and the router lets a seat call only under its own node ID,
`<prefix><slot><seat>` (`wasm-0103`), and lets only the host's certificate
call under the host's names (`games...`, the host and its bots). The room's
host takes those callers as they come, with no secret, as a board's
certificate is taken on the permanent tables. The supervisor hands the
room's host the seats' node IDs (`wasm-0101` .. `wasm-0116`) and the host's
name; a room whose seats or hosts change in `rooms.json` (the console was
updated during the room) gets its host started again. A seat may go to
another page after nobody was on it for a while (the door's
`WS_DOOR_SEAT_IDLE`, 30 minutes): a seat's node ID that has not called the
table for `rooms.seat_reuse_seconds` (1800) is a new page, and the old
member leaves (its seat is played by a CPU in a game) before the new one
joins. A page opened again in the same browser comes back with its secret
and gets the same seat (the console 0.3.9: the door cuts what is left of
the old connection), so it is the same member, at its seat, with its hand:
the same person within `seat_reuse_seconds`. That time stays at the door's
30 minutes (games 0.16.2 looked at it again): the door gives a seat to
another page only after as long without a connection, and a longer time
here would hand the old member's seat and hand to that new page.

Nobody else joins a room's table: a `join` or `mine` from another caller
answers `{"error" => "identity"}` (the screen says to open the room's link
again). The pages of the browser build from before the seats (a node ID
worked out from a secret) are not taken any more (games 0.7.0).

Outside the rooms nothing is checked (a home network; the permanent
tables, where a board's certificate is its node ID).

- **Bots in a room.** `bin/mahjong-bots --credentials games.tar --namespace
  room/01` (the host's own certificate): the bots are `games-bot<pid>-<i>`,
  names the router keeps for that certificate, so the table takes them as
  they are.
- **What the router now keeps closed** (console 0.3.0): a member cannot
  declare a queryable, put a state or a liveliness token, or reply on the
  host's keys (`room/<slot>/asterism/games...`), so it cannot pose as the
  table and collect what other pages send; nor can a page from before the
  seats (the slot's certificate has a deny on the host's and the seats'
  names).

| Key (`rooms:`) | Environment | Default | |
|---|---|---|---|
| `dir` | `ASTERISM_GAMES_ROOMS_DIR` | none (no rooms) | the console's rooms volume: `rooms.json`, `certs/` |
| `apps` | `ASTERISM_GAMES_ROOM_APPS` (comma separated) | the games' screens (`/app/game/mahjong/mahjong.app.rb`, `/app/game/othello/othello.app.rb`, `/app/game/board/board.app.rb`) | a room whose link opens one of these gets the tables of the game with that screen |
| `max` | `ASTERISM_GAMES_ROOM_MAX` | 3 | rooms with tables at once |
| `node` | `ASTERISM_GAMES_ROOM_NODE` | `games` | the host's node ID in a room |
| `router` | `ASTERISM_GAMES_ROOM_ROUTER` | the certificate's (`tls/zenohd:7448`) | the router |
| `status_listen` | `ASTERISM_GAMES_STATUS_LISTEN` | none | host:port of `GET /status` |
| `tables` | | each game's first table (`mahjong1`, `othello1`) | as `tables` above; a room gets those of the game its link opens; the `MAHJONG_*` and `OTHELLO_*` environment applies |
| `credentials` | `ASTERISM_GAMES_ROOM_CREDENTIALS` | `permanent.credentials` | the host's own `.tar` for the rooms (used when `rooms.json` lists the host in `"hosts"`) |
| `seat_reuse_seconds` | `ASTERISM_GAMES_ROOM_SEAT_REUSE_SECONDS` | 1800 | a seat's node ID silent this long at a table is a new page |

Memory (CRuby 3.2, the image, measured): the supervisor about 43 MB RSS,
each room's host about 45-50 MB more (the forked process shares the loaded
code with the supervisor at first).

## Permanent tables

Next to the rooms, the supervisor can keep tables of its own on the
registered side of the console's router: the boards that connect with
their own certificates (P4-Nano, Tab5: `/home/asterism/config.toml` and
their `.tar`) and the browsers with a pass see them in the table screen's
list (`games/games/mahjong1`, `games/games/mahjong2`), as on a home network.

- **The host's certificate.** The console registers the host as a row of
  its own (kind `client`, name `games`, the role `games-host`) and issues
  its certificate; the `.tar` ("Save all (.tar)") goes to the host
  (`permanent.credentials`). The router's ACL knows the host by that name,
  so the node ID is the certificate's name unless `permanent.node` says
  otherwise. The players' rows get the role `games`. The roles' templates
  and what they keep closed: the console's docs/rooms.md, "A game host's
  permanent tables".
- **One more process.** The supervisor forks one more host process
  (Host) for the tables of `permanent.tables` (`mahjong1` and `mahjong2`),
  joins the router with that certificate, outside every room (no
  namespace), and puts the host's profile with the name `permanent tables`
  (games 0.7.1; `asterism-games` before). A room's host joins with the same
  certificate, so both have the node ID `games`: the console's graph shows
  this one as `permanent tables (games)` and a room's as `games (room 05)`
  (console 0.3.3). It is started
  again like a room's host (1, 2, 4 ... 30 s). Without the certificate file
  (or not readable) the supervisor waits for it and says so once in the
  log; the rooms go on.
- **Saving.** The tables are saved under `state_dir/permanent/` after every
  change and taken back at every start; the rooms' clean-up never touches
  them. A game goes on from the same turn after a restart of the host.
- **Status.** `GET /status` has `permanent` (the host's node, `state`: `up`,
  `starting`, `restarting` or `no certificate`, each table's counts; null
  when not set up); `busy` counts its seats too, and the RSS its process.
  The console (0.2.3) shows it on the rooms' page under the game host's
  line; the graph shows the node `games` and its tables on the registered
  side.
- **Hands.** A seat's view needs the seat's token, which `join` gives to
  the node that joined. A board's node ID is its certificate's name and the
  router lets only that certificate call under it, so another member cannot
  get a board's token. The browsers are one subject at the router (any
  browser may call under any `wasm-*` node ID, the console's docs/g1_5.md),
  so a browser's seat is as safe as the other pass holders are trusted.

| Key (`permanent:`) | Environment | Default | |
|---|---|---|---|
| `credentials` | `ASTERISM_GAMES_PERMANENT_CREDENTIALS` | none (no permanent tables) | the host's `.tar` from the console |
| `router` | `ASTERISM_GAMES_PERMANENT_ROUTER` | the certificate's (`tls/zenohd:7448` in the image) | the router |
| `node` | `ASTERISM_GAMES_PERMANENT_NODE` | the certificate's name | the host's node ID |
| `tables` | `ASTERISM_GAMES_PERMANENT_TABLES` (names, comma separated; a name finds its game, or `name:game`) | `mahjong1`, `mahjong2` (the image's `config/rooms.yml`: and `othello1`) | as `tables` above; the `MAHJONG_*` and `OTHELLO_*` environment applies |

The section is read only with `rooms` (the supervisor). Without rooms, the
host itself does the same with `credentials` and `tables`.

Memory (the image, measured with a room's table and both permanent tables
in play): the permanent tables' process 51 MB RSS (24 MB PSS: the rest is
shared with the supervisor), the container 66 MiB in all with the
supervisor and one room. With `rooms.max` (3) rooms as well, about 250 MB
RSS (about 120 MB PSS).

## Who is there

A member is away when it is gone: its seat shows it (`"aw"`, the member
list's flag), a mahjong seat is played for after a short wait, the status
counts it. The host learns it from Asterism, not from the calls (games
0.8.0), and by the player's table app (games 0.10.0): a table app runs as
the application **`game`** of its node (the boards' and the browsers'
table apps, `bin/othello-tty`, `bin/mahjong-bots` do), and the host
follows the liveliness token `asterism/<node>/game`. The Net's
`on_app_leave` tells it that the table app left the network (a closed
browser tab, a board's app that closed, a process killed, a line that
dropped) even when the node stays with other applications (a board that
runs another Asterism app next to the table), and `on_app_join` that it
is there again. With asterism 0.7.1 (no `on_app_*`) the host watches the
tokens `asterism/*/game` itself on the session. The host passes both to
every table (`Game#node_left` / `node_joined`):

- a member whose node leaves is away at once, and back at once when its
  node joins again (before it calls anything);
- a member whose node the host has seen join is there for as long as the
  node is, calling or not (a screen on the list of tables, a terminal
  watching);
- a member whose node the host has never seen (see below), or that does
  not run as the application `game` (an `asterism mcp` client started
  without `--app game`, a script with an app name of its own), is away when
  it has not called the table for `away_seconds`, as before 0.8.0: the
  screens still ask their view every few seconds for that.

Members gone for long are forgotten six times `away_seconds` after their
last call or after their node left, whichever is later (seated members are
kept); in a room a seat's node ID gone for `seat_reuse_seconds` is a new
page when it comes back ("Who joins"). Presence is not saved: a host that
starts again counts its members as just seen, and the nodes there join on
its first polls. When the host's own connection drops, every node leaves
and joins again once it is back (a second or so, "When the connection is
lost" of asterism).

Whether the host sees the others come and go is the router's business:

| Where | The host sees the players' nodes | So |
|---|---|---|
| a home network (a plain zenohd, no access control) | yes | away at once (measured 10-20 ms after the node left; 6-14 ms after the table app closed while its node kept another application, games 0.10.0) |
| a room (console 0.3.0, seats) | yes: a room's host reads the whole room, the seats' liveliness tokens included | away at once (measured 6-7 ms) |
| the permanent tables (console roles `games-host` and `games`) | yes, when the role `games-host` has `Read asterism/*/game` (the console's docs/rooms.md): the router sends the host the players' table apps' liveliness tokens | away at once (measured 13 ms on the console's rehearsal) |

A role `games-host` made before that line (with only `Watch asterism/**`)
gets just the tokens on its own keys: the host then falls back to the time
without a call (away after `away_seconds`, measured 13.6 s with the default
10 s). Add the line to the role (Admin > Relay > Roles, Edit) and Apply;
nothing in the host changes with it.

The screens follow the host the same way: the tables' apps (fmruby-core
`flash/app/game/`) and `bin/othello-tty` take a host's tables off their
list when its node leaves and look for them again when a node joins
(Asterism's `each` reads the liveliness they already follow: no message is
sent); at a table, a host that leaves shows the connection lost, the
screen stops asking its view (one every 30 s, should the word not come)
and asks again as soon as the host is back.

## Status

The host tells its tables' counts on the network (games 0.9.0), as
`asterism/<node>/<app>/@status` (asterism's `docs/protocol.md` 8: an
application's status, a map it puts when it changes and gives to whoever
asks). One entry per table, with the counts of `GET /status` (no node IDs
or tokens), and for a mahjong table the result of its most recent game
(games 0.13.0, "Game records"):

```
asterism/games/games/@status
{"mahjong1" => {"st" => "play", "members" => 4, "humans" => 1, "cpus" => 3, "ais" => 1, "away" => 0,
                "last" => {"id" => 12, "at" => "2026-10-18 21:05", "game" => "tonpuu",
                           "result" => [["kishima", 1, 38200], ["CPU2", 2, 27100], ["Claude", 3, 21900], ["CPU1", 4, 12800]]}},
 "othello1" => {"st" => "wait", "members" => 0, "humans" => 0, "cpus" => 0, "away" => 0},
 "ai_today" => {"calls" => 84, "usd" => 0.02, "limit_usd" => 3.0}}
```

`last` is the four in rank order as `[name, rank, score]`, by the names
the table shows its members anyway (a table app shows them to whoever
joins); it is there once a game has ended. The rooms' status file
(`GET /status` of the rooms' host) stays counts only.

`ais` counts the AI players' seats (they are counted in `cpus` too), and
`ai_today` is the AI players' totals of the day (README "AI players"),
only on a host that can seat them. When some kind has a daily limit of its
own (games 0.15.0) `ai_today` also has `kinds`, one entry for each kind
the host offers: its money of the day (`usd`), the limit it stops at
(`limit_usd`: its own, or the total's), whether that limit is its own
(`own`) and whether it has stopped for today (`over`):

```
"ai_today" => {"calls" => 84, "usd" => 0.02, "limit_usd" => 3.0,
               "kinds" => {"claude" => {"usd" => 0.0198, "limit_usd" => 10.0, "own" => true, "over" => false},
                           "jev" => {"usd" => 0.0002, "limit_usd" => 2.0, "own" => true, "over" => false}}}
```

- **When.** After a table changes (a join, a seat taken or left, a move)
  and once a second (an away seat changes the counts with time alone); a
  put goes out only when the counts differ from the last one. A host puts
  it as soon as it is connected.
- **Who reads it.** `asterism watch` and `asterism tree` (the asterism
  gem's command line), its MCP bridge (`asterism_status`), the console's
  details of the host's node (console 0.3.4), or anyone with
  `Asterism.status_of("games", "games")`.
- **Where.** On a home network and on the permanent tables. The role
  `games-host` needs `asterism/${node}/*/@status` in "Read and write" (the
  console's docs/rooms.md): a `**` does not match the chunk `@status`. A
  room's host tells none (the rooms' rules let it write only its own
  place, which `@status` is not part of, and the console only watches who
  is in a room).
- **The asterism gem.** With an asterism that has `Asterism.status`
  (0.8.0, the version this repository is pinned to) the host uses it
  (`net.status`); with an asterism 0.7.1 (the gem's lowest) it does the
  same by hand on the connection's session (`Host::TablesStatus`: a
  queryable on the key and a put when the counts change).
- **Size.** Five tables take about 300 bytes (the largest put is in the
  log's `largest message` with the others).

## Writing a game

A game is two classes on the framework: the table (`AsterismGames::Game`:
the rules, the views, the saved form) and the object the host exposes for
each table (`AsterismGames::Remote`: the methods players call). Everything
else is the framework's: the connection, the members and their tokens, who
may join in a room, the host's loop, the puts, saving and resuming, the
rooms, the permanent tables, the status and the settings. A complete small
game is `test/framework/tally.rb`, and a real one the othello table
(`lib/asterism_games/othello/`, about 600 lines with its rules and CPU);
the shape of one:

```ruby
require "asterism_games"

module Counter
  class Remote < AsterismGames::Remote
    exposes press: 2, view: 1             # name => number of arguments (join, mine, leave are there)

    def press(token, n, from:)            # from: the caller's node ID (caller: :from)
      mark(token, from)                    # a call from the member's own node: it is there
      @game.press(token, n.to_i, now)
    end

    def view(token, from:)
      mark(token, from)
      @game.member_view(token, now) || { "error" => "token" }
    end
  end

  class Table < AsterismGames::Game
    register "counter"                     # tables: [{name: counter1, game: counter}]
    remote Remote
    tables "counter1"                      # the tables when the settings name none
    screens "/app/game/counter/counter.app.rb"   # a room whose link opens this gets them
    settings file: { "goal" => ["goal", 1] }, env: { "COUNTER_GOAL" => ["goal", 1] }
    DEFAULTS = AsterismGames::Game::DEFAULTS.merge("goal" => 10).freeze

    def initialize(...)
      super
      @n = 0
      load_saved(0)                        # restore and resume_clock when a saved state is there
    end

    def press(token, n, now)
      return "token" unless node_of(token)
      @n += n
      changed                              # saved and put by the host
      "ok"
    end

    def tick(now) = super.tap { expire_members(now) }   # time: called on the host's loop
    def public_view(now) = { "v" => @ver, "t" => @name, "n" => @n }   # put on .../<table>/state
    def member_view(token, now) = node_of(token) && public_view(now)
    def to_saved(now) = super.merge("n" => @n)
    def restore(data, now) = super.then { @n = data["n"].to_i }
  end
end
```

`bin/asterism-games` requires the framework and the games it serves
(`asterism_games/mahjong` from `app/` when it is there, then
`asterism_games/othello` and `asterism_games/board`), then the files given
with `--require FILE` (a game of your own, with the gem or this checkout);
the settings name a game per table. The mahjong of `app/` is written the
same way: it requires the framework by its name, as your game would.

What the framework gives a game:

| | |
|---|---|
| `Remote.exposes` | the exposed methods and their numbers of arguments (-1: any), checked by Asterism before a call; the host exposes them with `caller: :from`, so every method takes `from:` (Asterism fills it in from the call's key and refuses a call that brings it). `join(name)`, `mine`, `leave(token)` are the base's |
| `Game#join` / `mine` / `leave` | a member per node with a token (`SecureRandom`, 32 hex digits); the same node gets its token back. In a room the caller is checked ("Who joins"). A game adds its own through `member_reply`, `join_refusal`, `renamed`, `forget` (free what the member held) and `keep_member?` |
| `node_of(token)`, `touch`, `member_away?`, `node_left` / `node_joined`, `expire_members` | the token's member; who is there ("Who is there": the host calls `node_left` / `node_joined` from Asterism's `on_leave` / `on_join`, a member's call is `touch`, and `away_ms` without one is away too); members gone for long (six times `away_ms` from their last call or from when their node left) |
| `tick(now)` | the host calls it on its loop (every 10 ms) and the game moves on by the time given: deadlines, CPU turns. Never waits |
| `public_view` / `spectator_view` / `state_view` / a member's view | what everybody, a spectator, the state key and one member see. What only one member may see (a hand) goes in the answer of that member's call, never on the state key (anyone in the key space may subscribe to it) |
| `changed`, `dirty?`, `unsaved?` | a change to save and put; a change only one member's view shows (`@unsaved = true`) is saved, not put |
| `to_saved` / `restore` / `resume_clock`, `SAVE_FORMAT` | the saved form (one JSON file per table, `state_dir/<table>.json`, written to a temporary file and renamed); a state of another format is not read. Times are saved as the time left and resumed with the host's clock |
| `tell(sub, value)`, `SAVE_HOLD_MS` | more than the state: the host puts `value` on `asterism/<node>/<app>/<table>/<sub>` on its next step, in the order told, before the state (the board's strokes). A game that changes many times a second writes its saved state at most once per `SAVE_HOLD_MS` (the host writes what is held when it stops) |
| `summary(now)` | the counts the status shows (`st`, `members`, `humans`, `cpus`, `away`, and the game's own): no names, no nodes, no tokens. `busy` (`bin/asterism-games status --idle`) is `humans - away` |
| `settings`, `tables`, `screens`, `DEFAULTS` | the table keys of the settings file and the environment, the tables a host serves by default, the table apps that get the tables in a room, the table's options |

The host (`Host`) is written with Asterism's block API:
`Asterism.connect(...) do |net| ... end` exposes the tables, sets the
profile (`name: asterism-games` for a host of its own, `permanent tables`
for the permanent tables' host, no name in a room) and starts the Net's
receiving thread, which answers the calls. The games move on in the
host's own loop (`step`: `tick`, saving, the puts, every 10 ms), which
holds `Asterism::LOCK` while it runs: the receiving thread holds the same
lock for each of its ticks, so a game never sees a call and a step at
once, and a game needs no lock of its own. When the connection is lost
(the receiving thread ends; `net.lost_reason` says why) the host saves and
connects again after 3 s; while a client of a router only reconnects
(`reconnecting?`) the tables stay and the puts wait.

## The mahjong table

### Methods

| Method | Arguments | Returns |
|---|---|---|
| `join` | name | `{"token", "seat" (-1: none), "owner"}`, or `{"error" => "full"}` (16 members) or `{"error" => "spectators"}` ("Spectators"); a join again from the same node keeps the membership and takes the name given (a screen whose player changes its name; at the seat too, during a game as well); at most 32 bytes, no control characters, empty: the node ID |
| `mine` | none | the same for a node that joined, or nil (nothing is created) |
| `sit` | token, seat | `"ok"` or why not (`"taken"`, `"not waiting"`, ...); seat -1: the first free one. In the lobby only; a seated member moves |
| `stand` | token | `"ok"` or why not (lobby only) |
| `cpu` | token, seat, on | the owner: a CPU into an empty seat (on) or out of it (a CPU or an AI player); seat -1 with on fills every empty seat; on as a name the lobby offers (`"claude"`, `"jev"`) puts that AI player in ("AI players"), `"no ai"` when it is not offered; on one seat that holds a CPU or an AI player of another kind, on turns it into the one asked for (games 0.12.1) |
| `start` | token | the owner, once the four seats are taken and one is a member: the seats are drawn (who deals first) and the game starts |
| `rule` | token, item, value | the owner, in the lobby: a local rule ("Local rules"); `"ok"` or why not (`"not owner"`, `"not waiting"`, `"no rule"`, `"value"`, `"no change"`) |
| `view` | token, assist | the member's view (below), or `{"error" => "token"}`; assist: the help its screen shows (Assist, 0-3) |
| `act` | token, sv, type, tiles | `"ok"`, or why not: `"token"`, `"not seated"`, `"stale"` (sv is not the current one), `"not offered"`, `"not playing"` |
| `table` | none | the public view (no hand), as a spectator sees it |
| `leave` | token | `true` / `false`; in the lobby the seat empties, during a game it goes to a CPU |
| `describe`, `look`, `choose`, `points` | | for programs ("Playing from a program") |
| `records`, `record` | from / id, round, part | the games played to the end and their records ("Game records") |
| `stats` | days, game, scope, from (all optional) | the players' stats ("Stats") |

- People join a table and wait in its lobby (`"st" => "wait"`): a member
  sits in a seat or watches. The first member who sat is the owner (when the
  owner stands or leaves, the member seated longest takes over). The owner
  fills empty seats with CPUs and starts. At the end of a game the owner's
  next (or `over_seconds`) brings the table back to the lobby with the same
  seats, for another game.
- The node that calls is the caller in the call's key (`from:`, filled
  in by Asterism; a call that brings `from:` itself is refused). The
  arguments are as before: a table app that knows nothing of `from:`
  calls as it did. The same node gets its membership and
  token back from `join` (and `mine`), so a player that restarts its
  application finds its table again.
- The token is 32 hex digits from `SecureRandom`. Everything about a hand
  needs it: without it, or with another, `view` and `act` refuse. A member
  without a seat (a spectator) gets the public view. The public view never
  has a hand (except the winners', shown at a win).
- `act` takes only what the seat's list (`"a"` in its view) has: the
  host asks riichi_engine for the seat's actions and matches the request
  against them. `sv` is the state version the player saw.
- After every change the host saves the table and puts the public view on
  `asterism/<node>/<app>/<table>/state` (and every 5 s anyway). A player
  that sees a newer `"v"` there asks its view again; a screen also asks every
  3 s, which tells the host it is still there.

### Assist

The help the table screen shows its player, chosen by the player and sent
with each `view` (a screen's setting, not the table's: every seat may ask
for another level). Worked out once per state version, seat and level, only
from what that seat can see, and only for a seat that asks.

| Level | Help |
|---|---|
| 0 | none |
| 1 (default) | when the seat may declare riichi: `wt` for each discard that declares it |
| 2 | at the seat's discard: `wt` for each discard that leaves the hand tenpai, with or without riichi (an open hand, a hand that stays dama). Whether a wait has a yaku is not judged |
| 3 | as 2; when no discard leaves the hand tenpai, `uk` for every discard |

- Shanten: riichi_engine's own count (`Cpu::Analysis::Shanten.calculate(t34,
  melds:)`, the fork's `fix/shanten-melds`; `Engine.shanten` calls it). It
  takes the melds as sets already made, counts seven pairs and kokushi for
  a closed hand only, and works out each suit once per suit pattern. The
  host had its own count of the regular form until 0.1.1.fmrb3 (0.1.0's
  took the hand as all there is, wrong once there are melds, and took about
  50 ms a turn for the acceptance); the engine's gives the same help (on
  6,623 states of CPU hanchan, the level 3 help was the same byte for byte)
  and is about 10 % quicker. The tests compare it with the engine's count
  for closed hands (3000 random hands) and, with melds, tenpai with the
  wait judge.
- Time (CRuby, one seat's help at one state, one process): over 8 CPU
  hanchan with seats at levels 1, 2 and 3, median 1.3 ms, 95 % 4.8 ms, at
  most about 60 ms (the first ones, before the suit patterns are known, or
  a garbage collection; `rake test` prints the `assist:` line).

### Local rules

The owner chooses the table's rules in the lobby, before the start; every
member sees them there (the view's `ru`), and the game is played by the
rules it started with (`rule` answers `"not waiting"` once it has started).
They are saved with the table and stay for the next game at the table. The
host's rules ("Rules": `Engine::RULE_DEFAULTS` and the table's `rule`
setting) are where they start, and choosing a host's value again drops the
choice. A new room (a slot used again) starts from the host's rules.

`ru` has one number per item for items 0-10, `rx` for items 11-14 and `ry`
for items 15-16, in this order (the table screen puts the three together;
the numbers of the items never change, and a screen shows them in an order
of its own); `rule(token, item, value)` takes one of the values listed (or
the host's own value for the item). Item 10 is the time ("Time"): its value is
a code, the seconds for a move plus 1000 times the seconds of the bank
(5+20 is 20005, a fixed 20 s is 20). `ru` gives its seconds for a move
only, `tb` its bank (the screen adds them up again), and in the lobby `tc` the codes to choose from, in order (the
host's own value among them):

| Item | | riichi_engine key | Values |
|---|---|---|---|
| 0 | the game | `game_type` | 0 hanchan, 1 tonpuu |
| 1 | open tanyao | `kuitan` | 0 / 1 |
| 2 | red fives | `aka_dora` | 0 none, 3 one each of 5m 5p 5s, 4 two of 5p |
| 3 | double ron | `double_ron` | 0 (the head bump) / 1 |
| 4 | three rons a draw | `triple_ron_draw` | 0 (all three win) / 1 (sanchahou) |
| 5 | several yakuman added up | `multiple_yakuman` | 0 / 1 |
| 6 | kazoe yakuman | `kazoe_yakuman` | 0 / 1 |
| 7 | kiriage mangan | `kiriage_mangan` | 0 / 1 |
| 8 | tobi | `tobi` | 0 / 1 |
| 9 | the extra round ("延長"): west for a hanchan, south for a tonpuu game | `nishi_iri`, `nan_iri` together | 0 / 1 (the value is the key of the game chosen; a table app that calls the item the west round sets both) |
| 10 | the time for a move and the bank ("持ち時間") | (the host's `turn_seconds`, `bank_seconds`) | `tc`: 5+20 (20005), 5+0 (5), a fixed 30 s (30), 60 s (60) and 600 s (600), and the host's own |
| 11 | the abortive draws besides nine kinds (four winds, four kans, four riichi) | `suufon_renda`, `suukaikan`, `suucha_riichi` together | 0 / 1 (1 only when all three are on; a host setting with some of them shows 0, and 0 chosen again goes back to it) |
| 12 | nagashi mangan | `nagashi_mangan` | 0 / 1 |
| 13 | double yakuman (suuankou tanki, kokushi 13-wait, junsei chuuren) | `double_yakuman` | 0 / 1 |
| 14 | tenpai-yame | `tenpai_yame` | 0 / 1 |
| 15 | the CPUs' level | (the host's `cpu_level`) | 0 easy, 1 normal, 2 hard: the CPUs of the table's next game play at it |
| 16 | the spectators' delay | (the host's `spectator_delay_minutes`) | seconds: 0 (none), 60, 180, 300, and the host's own; in the lobby `dc` lists them in order ("Spectators") |

Left out: `atozuke` (riichi_engine has the key but does not use it), the
starting points, the first place target and the uma (they change the final
points, not the play: the table's `rule` setting still sets them),
`renpuu_jantou_fu` (the fu of a pair of the double wind; it is not sure
what Mahjong Soul does), `pao` (which yakuman; a list, not a switch),
`minkan_dora_after_discard` (when the kan dora of an open kan shows) and
`agari_yame` (the screen's column has room for fifteen rows at 640x360).

### Spectators

A member without a seat watches: its view is the public one with the four
hands besides (`sh`, `sd`: each seat's hand and drawn tile, as a seat's
own `h` and `dt`), and no offers, no help and no sign of who may call. The
put on `.../state` and `table` have no hand (except the winners', shown at
a win), so the seated players, who read the put too, never see another
hand.

- **How many.** At most `spectators` members without a seat (12: a room
  of an Asterism console lets 16 pages in, four of them at the seats; the
  host itself connects to the router directly). In the lobby a member that
  could still sit counts in addition, so people can come in and sit. A
  member beyond that gets `{"error" => "spectators"}`; a member gets its
  place back as before.
- **The delay.** With a delay (`spectator_delay_minutes`, or chosen by the
  owner in the lobby: "Local rules", item 16), the spectators' view, the
  put and `table` show the game as it was that long ago: the host keeps the
  game's part of the public view (`st sv r sc ri dora kw fu hc ls ev res
  fin fr`) and the four hands at every change for that long, and the
  people's part (`nm hu sk aw ow mb ru rx ry`) and `v` are now's (so a
  screen asks again when the delayed picture moves on). There is no
  deadline (`dl`) in a delayed view. The seated players' own views are never
  delayed. Counted in time, not in actions: a round's result then stays as
  long for the spectators as for the players, and an action every 0.7 s (a
  CPU) or every 20 s (a person) does not change how far behind the
  spectators are. A host started again starts the delay over (the past is
  not saved).
- **The default is no delay.** The spectators see the hands as they are:
  good for watching a game, and for an audience in the same room. A seated
  player who joins the same table from a second screen sees the others'
  hands too; where that matters, choose a delay (a minute or more: the
  hands it shows are then of a past turn).

### Calls on a discard

When several seats may call a discard (ron, pon, chi, open kan), every one
of them answers once: a CPU at once, a player by `act` (a call or pass), or a
pass when `call_seconds` (counted from the discard, the same deadline for
everybody) run out. An answer is final (the seat's list is empty after it).
Once all have answered, riichi_engine's priority decides: ron over pon and
open kan over chi; several rons by the rule (by default every ron wins,
two or three; `triple_ron_draw` makes three a draw, sanchahou), equal calls in turn order from the discarder. The players
see the choices exactly as the engine lists them.

Nobody learns who else may call, or who has answered:

- A seat sees its own choices only (`a`). Its `dl` has its own bit while it
  still has to answer; every other seat's `dl` has the bits of the three
  others whoever they are (the screen says "the others are answering"),
  with the same time left. The public view (the put, `table`, the
  spectators) has no `dl` while the calls are open.
- An answer changes only the answering seat's view: its `v` is the table's
  plus one until the calls are decided (its buttons go), the table's own
  version does not move and nothing is put (the table is saved). The
  change that follows the calls moves the version by two, past what that
  seat saw.
- When everybody passed, the last event (`ev`) is a pass by seat -1.
- What still shows: that the host waits (the phase `r[7]` is the calls,
  for a human the time of the window), not for whom.

### Time

Mahjong Soul's "5+20" by default: a move (a discard, riichi, a kan, a win,
nine kinds) has `turn_seconds` (5), and each player has a bank of
`bank_seconds` (20). What a move takes beyond its 5 s comes off the bank;
when the 5 s and the bank are both used up, the move is played for (the
drawn tile is discarded). The bank is full again at the start of every
round. A bank of 0 is
a fixed time a move (`turn_seconds` and no more). The calls on a discard
keep `call_seconds` and do not touch the bank. An away player keeps its
short wait ("Players that drop out"; it takes nothing off the bank while
`away_wait_seconds` is shorter than `turn_seconds`). The owner chooses the
time in the lobby ("Local rules", item 10). The banks are saved with the
table; a table saved before the bank starts its game with full banks (and
a fixed time the owner had chosen stays fixed).

The player sees the time on its own move: `dl` is `[seats, ms left, the
bank's ms]` when the move has a bank, the bank being the last part of the
ms left (the move's own time is what comes before it).

### Result

(games 0.15.0) A table with a human at it:

- **The start of a round.** After the deal the host waits
  `deal_pause_seconds` (2) while every screen shows the round's name in
  big letters ("東1局 0本場"). Nobody's time runs (the dealer's first move
  has its full time from the end of the pause), no CPU or AI player plays,
  and `act` answers `"not offered"`. The view says it with `in`.
- **The result waits for every human's OK.** A round's result (a win or
  a draw) moves on to the next round once every human seated and there
  (not away, "Players that drop out") has pressed OK: the action next
  (12), so a screen made before 0.15.0 gives its OK with its next as it
  did. A seat that has given it has nothing more in `a` (a second next is
  `"ok"` and changes nothing). An away human is not waited for; with
  nobody there the time decides.
- **Or by itself after the count.** Whoever does not press, the result
  moves on `result_auto_seconds` (10) after the end of its count. The
  count is the time a screen takes to show the result one step a second,
  the same rule on both sides: **per winner, one step for each line of
  its yaku (`y`) and one for its points; with two or three winners their
  steps one after the other (the sum); a round without a win (a draw, an
  abortive draw, three rons) one step.** A step is 1 s. The host counts
  from the moment of the result; a screen that shows all at once (a
  player who skips the steps) does not change the host's time. The view
  says whom the result waits for and how long with `ok`.
- The end of a game (`over`) is as before: the owner's next (or
  `over_seconds`) takes the table back to the lobby.

A table without humans (`humans` 0, or every human replaced by a CPU)
has neither: its result stays `result_seconds` (8) and its rounds start
at once, as before 0.15.0. A table saved with a result before 0.15.0
moves on by its saved time.

### Players that drop out

A member whose node leaves the network is away at once ("Who is there"),
and so is one that has not called the table for `away_seconds` (its screen
asks its view every 3 s), the way to tell where the host does not see the
nodes come and go: the public view marks its seat (`"aw"`) and the member
list. While it is away its seat is played for after a short wait:
`away_wait_seconds` from the start of its turn or of the calls (the drawn
tile is discarded, a call is passed), instead of `turn_seconds` and
`call_seconds`, so the others are not held up a whole turn every time. The
other players keep their own times (in the calls, the away seat passes
early and the rest go on waiting). A wait that started before the member
went away ends as soon as it is seen away, if its short wait is over by
then. Once its node is back or it calls again it has the full times again;
its screen asks its view and goes on. A seat is never handed to a CPU because its player is
away; a member that leaves (`leave`) during a game is.

**The owner away** (games 0.16.2): when the owner has been away for
`owner_handover_seconds` (60), in the lobby or during a game, the role
goes to a member who is there: the seated one who sat first, else the
one who joined first. With nobody there it stays where it is, and passes
as soon as someone is. The old owner coming back does not take it back.
The log says `the owner <node> was away for 60 s: <node> is the owner
now`. In a room a page opened again in the same browser comes back as the
same seat (the console 0.3.9's door, "Who joins"), and so as the owner if
the role has not passed yet.

**A table left alone** (games 0.16.2): during a game (`play`, `result`),
when none of the seated humans counts any more, the game is abandoned. A
seated human counts while it is there and for `abandon_seconds` (180)
after it went away; a member that left the table (`leave`) counts no
more at once (its seat is a CPU's already). The table goes back to the
lobby as at the end of a game: the CPUs and AI players keep their seats,
the away humans are taken off theirs (they stay members, watching, and
may sit again), the owner's role passes as when an owner stands, and
nothing of the unfinished game is kept: no record, nothing in the stats.
The log says `game abandoned: no human there for 180 s (seats [0, 2]
emptied; not recorded)`. One human back within the time keeps the game
going for everyone (the other away seats are played for as before). A
table of CPUs only (`humans: 0`, the permanent spectator tables) is never
abandoned.

### Views

A Hash (MessagePack); tiles are one byte each in binary strings (bin).

| Key | |
|---|---|
| `v` / `sv` | the view's version (any change; in a seat's own view one more after its answer to open calls, "Calls on a discard") / the state version (actions) |
| `t`, `st` | the table's name; `wait` (the lobby), `play`, `result` (a round's result), `over` |
| `hv` | the game host's version (games 0.16.1), shown by the table apps on the list and the lobby |
| `nm`, `hu` | the four names (`""` for an empty seat); the human seats as bits |
| `sk` | the four seats: 0 empty, 1 a member, 2 a CPU (an AI player too) |
| `ai`, `ak` | when an AI player sits: each seat's kind (`"claude"`, `"jev"`, `""` for the others); in the lobby, the AI players the owner may seat ("AI players") |
| `aw` | the seats whose member is away, as bits |
| `ow` | the owner's seat (-1: nobody seated) |
| `mb` | the members in the order they joined: `[name, seat (-1 none), flags (1 away, 2 owner)]` |
| `r` | `[bakaze (0 east, 1 south, 2 west), kyoku, honba, riichi sticks, dealer seat, tiles left, seat to act, phase (0 draw, 1 discard, 2 calls, 3 end)]` |
| `sc`, `ri` | the scores; riichi as bits |
| `dora` | the dora indicators |
| `kw` | four rivers, one byte a tile: `0x40` the riichi tile, `0x80` called away |
| `fu` | four meld lists: per meld `[kind, from, n, n tiles]`; kind 1 chi, 2 pon, 3 closed kan, 4 open kan, 5 added kan; from 1 right, 2 across, 3 left, 0 none. The tiles are in the order a table shows them: the called tile is first when it came from the left, second from across, last from the right (an added kan: the last of the first three, the added tile fourth) |
| `hc` | the four hand sizes |
| `ls`, `ev` | the last discard `[seat, tile]`; the last action `[type, seat]` |
| `cl` | the last declaration, `[type, the state version it came with, seat, ...]` (games 0.13.0): riichi (2), tsumo (3), a kan (4, 5, 8), pon (6), chi (7), ron (9; every winner of a double ron), nine kinds (11), three rons (13; the three seats). A screen shows it for a moment at the seat that made it; a new state version is a new declaration (`ev` is gone by the next draw, a riichi's or a kan's at once). In the public view too (everybody hears a declaration), as old as the rest for the spectators |
| `dl` | `[seats as bits, ms]`: whom the host waits for and how long it still waits: the seat whose turn it is; in the calls on a discard, in a seat's own view only, its own bit while it has to answer, else the three others' ("Calls on a discard"); on a player's own move with a bank, a third number, the bank's ms in it ("Time") |
| `res` | at a round's end: `k` (`tsumo_agari`, `ron_agari`, `ryuukyoku`, and the abortive draws `kyuushu_kyuuhai`, `sanchahou`, `suufon_renda`, `suukaikan`, `suucha_riichi`), `rd` (the round: `[bakaze, kyoku, honba]`), `d` (the four score changes), `f` (who dealt in), `wn` (one entry per winner, in turn order from the discarder: `w` seat, `y` the yaku as riichi_engine names them, in Japanese, `yh` the han of each (-1: a yakuman, -2: a double yakuman), `pt` fu, han and points, `h` and `ag` the hand and the winning tile, `pa` pao: `[[the seat that pays, the yakuman], ...]`), `tp` (tenpai seats at a draw), `ng` (the seats with nagashi mangan at a draw; paid in place of the no-ten payments), `rs` (the seats of the three rons at a sanchahou) |
| `ru`, `rx`, `ry` | the local rules ("Local rules"), one number per item: items 0-10, 11-14 and 15-16 (item 10 the seconds for a move) |
| `tb`, `tc`, `dc` | item 10's bank, seconds; in the lobby, item 10's choices as codes and item 16's choices in seconds ("Local rules") |
| `in` | while the round's name shows after the deal ("Result"): the ms left (games 0.15.0) |
| `ok` | on a result of a table with humans ("Result"): `[the seats that gave their OK as bits, the seats it still waits for as bits (seated, there, no OK yet), the ms until it moves on by itself]`; a screen shows "OK を待っています (n/m)" with n the first's bits and m both together (games 0.15.0) |
| `fin` | at the end: `[[seat, rank, score, point x 10], ...]` |
| `fr` | at the end, why the game ended: `normal_end` (the last round played, the fourth round of the extra round too), `tobi`, `all_last_oya_agari` (agari-yame), `all_last_oya_tenpai` (tenpai-yame), `sudden_death` (somebody reached 30,000 in the extra round), `west` (after west 4, the host's, only without `sudden_death`), `rounds` (the host's guard against a loop); none for a game saved before it was added |
| `me`, `h`, `dt`, `a` | the member's view only: its seat (-1: watching), its hand (sorted, without the drawn tile), the drawn tile (-1 none), what it may do: `[[type, tiles], ...]` |
| `wt` | the member's view only, the help (Assist, levels 1-3): one binary string, per discard the tile, the number of waits n and n pairs `[wait, left]` (the waits as riichi_engine's wait judge gives them; left: 4 less what the seat can see of the tile: its own hand, the rivers, every meld, the dora indicators) |
| `sh`, `sd` | a spectator's own view only: the four hands (sorted, without the drawn tile) and the four drawn tiles (-1 none) ("Spectators") |
| `uk` | the member's view only, level 3 when no discard leaves the hand tenpai: one binary string, per discard the tile, the shanten after it, the number n of tiles that bring it down and n pairs `[tile, left]` (left as in `wt`; a tile the seat sees all four of is left out) |

Tile numbers: `0..8` 1m..9m, `9` 0m (red five), `10..18` 1p..9p, `19` 0p,
`20..28` 1s..9s, `29` 0s, `30..36` 1z..7z (east south west north white
green red), `37` back. The same order as the tile sheets of Family mruby's
table screen.

Action types: 1 discard (tiles: what may be discarded; send one), 2 riichi
(tiles: the discards that declare it; send one), 3 tsumo, 4 closed kan, 5
added kan, 6 pon, 7 chi (one entry per pair), 8 open kan, 9 ron, 10 pass,
11 nine kinds, 12 next (after a result, the seat's OK, "Result"; after the
end of a game, the owner's next goes back to the lobby). 13 is only an event (`ev`): three rons, a draw.

### Message size

A board and the browser build (zenoh-pico) take at most 4096 B in one
message, Zenoh's headers and the key included, and drop a larger one without
a word. The views stay far below: the largest seen in 20 CPU hanchan was
about 570 B (the reply with its call key); a view built by hand with full
rivers, four kans each, sixteen members with long names and three winners
with fourteen yaku each (and pao, and the reason the game ended) is about 2.1 KB. The riichi help adds at most
14 x (2 + 13 x 2) = 392 B (fourteen discards with thirteen waits each, more
than a hand can have; a nine-sided chuuren gives 80 B); a view built by hand
with it, full rivers, the other seats' kans and the long names is about
1.5 KB. The acceptance (`uk`, level 3) adds at most 14 x (3 + 34 x 2) =
994 B (every kind after every discard, more than a hand can have; random
hands give at most about 250 B, 20 CPU hanchan at most 762 B with a view of
1,043 B); the same view built by hand with it is about 2.1 KB. `wt` and `uk` never come together. A spectator's view of the
largest result adds the four hands (59 B): about 2.2 KB. The tests hold every view
under 3800 B.

### Time and saving

- The host draws for the player. A player that does not move within
  `turn_seconds` and what is left of its bank ("Time") discards the drawn
  tile (the last tile after a call); a call not made within `call_seconds`
  is passed.
- One host process holds every table of its settings (two by default); each
  is saved to its own file and goes on by itself.
- After every change the table is written to `state_dir/<table>.json`
  (written to a temporary file and renamed), with the members, the seats and
  the owner (a restarted host keeps the lobby too). The deadline is saved as the
  time left; a host stopped with SIGTERM saves the time left at that moment,
  a host killed gives the player the time left at the last change.

## Rules

The host's defaults follow Mahjong Soul's default rules (its four-player
ranked games) wherever riichi_engine can choose; the engine's own defaults stay as they are and the host passes its
values (`Engine::RULE_DEFAULTS`). A table's `rule` setting goes over them,
and the owner's choices in the lobby go over that ("Local rules": the game,
open tanyao, red fives, double ron, three rons, several yakuman, kazoe
yakuman, kiriage mangan, tobi, the extra round, the time and the bank, the
abortive draws, nagashi mangan, double yakuman, tenpai-yame).
Where the engine cannot choose, the table says so: those rules are left for
later. "Not sure" marks what could not be confirmed.

| Rule | Mahjong Soul's default | riichi_engine | Choosable | The host's default |
|---|---|---|---|---|
| Open tanyao (kuitan) | yes | `kuitan` (true) | yes | true |
| Atozuke | yes | `atozuke` (true) | key only (not used by the engine) | (true) |
| Red fives | one each of 5m 5p 5s | `aka_dora` (1/1/1) | yes | 1/1/1 |
| Ippatsu, ura dora, kan dora, kan ura | yes | always | no | yes |
| When a kan dora shows | at once for a closed kan, after the discard for an open or added kan | `minkan_dora_after_discard` (false: at once for every kan) | key only | true |
| Double ron | yes | `double_ron` (true) | yes (fork `fix/multiple-ron`) | true |
| Three rons | all three win (no sanchahou) | `triple_ron_draw` (true) | yes (fork `fix/multiple-ron`) | **false: all three win** (as Mahjong Soul) |
| Honba and sticks at a double ron | to the first winner from the discarder | the host's scoring | (host) | to the first winner |
| Dealer at a double ron | keeps the seat if one of the winners | `GameFlow` (winners) | (engine) | as the engine |
| Abortive draws | nine kinds, four winds, four kans, four riichi; the dealer keeps the seat | nine kinds always; `suufon_renda`, `suukaikan`, `suucha_riichi` (false) | yes (one item for the three) | all |
| Double yakuman hands (suuankou tanki, kokushi 13-wait, junsei chuuren, daisuushii) | count double | `double_yakuman` (false) | yes | true (daisuushii is a double yakuman in riichi_engine without the key) |
| Several yakuman in one hand | added up | `multiple_yakuman` (false) | yes (fork `feat/multiple-yakuman`) | true |
| Kazoe yakuman (13 han) | yes | `kazoe_yakuman` (true) | yes | true |
| Kiriage mangan | no | `kiriage_mangan` (false) | yes | false |
| Nagashi mangan | yes; in place of the no-ten payments | `nagashi_mangan` (false) | yes | true |
| Pao (liability) | daisangen, daisuushii (not suukantsu) | `pao` (a list of yakuman, []; `suukantsu` too) | key only | daisangen, daisuushii |
| Tobi | yes; 0 points goes on, below 0 ends | `tobi` (true, below 0) | yes | true |
| The extra round: west for a hanchan, south for a tonpuu game | when nobody has 30,000 after the last round | `nishi_iri` (false), `nan_iri` (false), `nishi_iri_threshold` (30,000) | yes (one item for both) | true, true, 30,000 |
| Sudden death in the extra round | it ends when somebody has 30,000 (a ron with several winners where the dealer keeps the deal goes on, before agari-yame too); one round at most | `sudden_death` (false: the round goes on until the deal passes with somebody at 30,000, west 4 back to west 1) | key only | true (without it the host ends the game after west 4) |
| Agari-yame, tenpai-yame | both, for the last dealer in the lead with 30,000 or more | `agari_yame` (true), `tenpai_yame` (false); the dealer in the lead, above 0 (30,000 when there is an extra round) | tenpai-yame yes, agari-yame key only | both true |
| Starting points, return, first place target | 25,000, 25,000 (no oka), 30,000 | `initial_score` (25,000), `oka_origin` (30,000), `nishi_iri_threshold` (30,000) | key only | 25,000, 25,000, 30,000 |
| Uma | 5-15 (+15/+5/-5/-15), rank uma only | `uma` (20/10/-10/-20) | key only | 15/5/-5/-15 |
| Riichi sticks left at the end | to the top | none (`calculate_ranked_results` takes the points as given) | (host) | to the top |
| Equal points at the end | the seat nearer the first dealer ranks higher | by seat number | (engine) | as the engine (the first dealer is always seat 0) |
| A pair of the double wind | 4 fu | `renpuu_jantou_fu` (2) | key only | 4 |
| Kuikae (swap-calling) | banned (the called tile and, after a chi, the other end) | `kuikae` (true: allowed) | key only | false (banned; a chi that leaves nothing to discard is not offered) |
| A closed kan after riichi | only of the drawn tile, when the waits stay the same | `riichi_ankan` (false) | key only | true |
| Robbing a closed kan | for kokushi musou only | `kokushi_ankan_chankan` (false) | key only | true |
| Honba at a pao ron | paid by the seat liable | `pao_honba` (`"discarder"`) | key only | `"liable"` |
| The winning tile of a tenhou | the one that scores most | `tenhou_best_tile` (false: the tile drawn) | key only | true |
| Kan ura dora | yes | always (`fix/kan-uradora`) | no | yes |
| Thinking time | 5+20: 5 s a move plus a 20 s bank | none (the host's timers) | yes (item 10) | 5 s a move, a 20 s bank every round, 8 s a call (`turn_seconds`, `bank_seconds`, `call_seconds`; "Time") |
| Riichi on a tile that is ronned | not made: the 1000 points come back, no stick (a pon or kan of the tile lets it stand) | `riichi_void_on_ron` (false: the stick stays, the winner takes it) | key only | true |
| Same-turn furiten | after passing a winning tile (robbing a kan too), until one's next draw | on a pass of a ron offered, and on a winning tile with no ron offered (no yaku on it, or furiten already; `fix/dojun-furiten-no-yaku`) | no | as the engine |
| Formal tenpai (karaten) | yes, except a single wait on a tile the hand holds four of | the wait judge leaves out only a tile the hand holds four of (a single wait on the fourth tile of a pon is tenpai; `test/karaten-tenpai`) | no | as the engine |

## Game records

Every game a mahjong table plays to its end is kept as a record (games
0.13.0): the deals, the dora indicators, every draw and discard, the calls,
riichi, the wins and draws and the points. The table apps list a table's
recent games and step through a record with the four hands face up; a
program reads the same with `records` and `record` (the CLI, an AI
assistant through `asterism mcp`).

- **Where they are kept** (games 0.14.0). With the sqlite3 gem (the image,
  and a checkout with the Gemfile) every game goes into one SQLite
  database in the state volume, `state_dir/records.sqlite3` (`records_db`),
  written once at the end of each game. The rooms' and the permanent
  tables' hosts are processes of their own and all write into the
  supervisor's database (WAL; a process that finds it locked waits up to
  10 s). The newest 1000 games of each table are kept (`records_kept`);
  the rooms' tables of one name count together (the 1000 newest of every
  room's `mahjong1`), so the database stays bounded however many rooms
  open. Without the sqlite3 gem (the gem alone, `records_db: json`) the
  records stay as before 0.14.0: the 20 newest of each table in
  `<table>.records.json` next to the table's saved state.
- **A room's games** stay in the database when the room closes (its saved
  tables go). They are given out (`records`, `record`, the recent games of
  the table apps) only by the room's own host while the room is open: no
  other room, no permanent table and no LAN table lists them. The stats
  count them ("Stats": names and numbers, never a record).
- **The rooms of one invite link** (games 0.16.0, with a console 0.3.8):
  a room made through a console's invite link has the link's group
  (`rooms.json` `"group"`, a random string that is not the link's secret).
  The room's host keeps it with each game the room plays, and its
  `records` and `record` give out the room's own games and those of every
  other room of the same group, open or closed (the same table name:
  `mahjong1`), newest first. So the next room of the same link lists and
  replays the games of the last one. A room without a group (made by an
  admin, or by a console before 0.3.8) gives out its own games only, as
  before; another group's rooms, the permanent tables and the LAN tables
  give out none of them. The stats (`"table"` is the room's own games) and
  `@status`'s `last` stay the room's own. The games played before 0.16.0
  have no group and stay their own room's. A room's group is read when
  its host starts (a room open across the console's update gets it at
  the host's next start). The newest kept are counted as before (the
  rooms' tables of one name together, whatever their group). In the
  database: the column `grp` of `games` (NULL outside such rooms), added
  in place on the first start of 0.16.0; the format stays 1, so a host of
  0.14.0 or 0.15.0 put back reads and writes the same database.
- **Taken in once.** A host of 0.14.0 that finds a table's
  `<table>.records.json` (0.13.0) next to a database takes its games in
  (the same games, in their order, with their times) and renames the file
  to `<table>.records.json.imported`; nothing reads it again (a host of
  0.13.0 put back would start with no records). A room's file is taken in
  by the room's host, with the room's ID.
- **Ids.** A game's `id` is its row in the database: it grows across every
  table, and a table's ids are not consecutive. An id is never used twice.
- **Backups.** After each game the host makes a consistent copy next to
  the database, `records-backup.sqlite3` (`VACUUM INTO` a `*.tmp` name,
  then renamed over the last copy), so a backup that copies the files of
  the state volume (the console's daily backup with
  `docker-compose.games.yml`) has a whole database whatever the host was
  writing at that moment. A host that finds the copy but no database
  starts from the copy: that is how a restore puts it back
  (docs/install.md, "Backups and restoring").
- A game in progress is never given out; its record so far is in the
  table's saved state (JSON, as before), so a host started again goes on
  with it.
- **Who reads them.** Anyone who can call the table (no token): the router's
  rules decide, as for joining.

| Method | Arguments | Returns |
|---|---|---|
| `records` | from (optional, 0) | `{"records" => [...], "total", "next"}`: the games, newest first, from the from-th, as many as fit one message; `next` is the from of the next page (none: the end). Each: `id`, `at` (the host's local time, `"2026-10-18 21:05"`), `game` (`hanchan` / `tonpuu`), `names`, `ranks`, `scores` (in seat order) |
| `record` | id | the game's head: `id`, `at`, `time` (Unix seconds), `table`, `game`, `rules` (as `look`'s), `names`, `kinds` (human / cpu / ai), `final` (`[[seat, rank, score, points x 10], ...]`), `reason` (as the view's `fr`), `rounds` (`[[wind, number, honba, kind, [four changes]], ...]`) |
| `record` | id, round | round `round` (from 0) as below, with `id`, `round`, `of` (how many rounds), `part`, `parts` |
| `record` | id, round, part | a round too big for one message comes in parts (`parts` > 1): part 0 has everything with the first moves, part k the moves from `move_from` on |

`{"error" => "no record"}` (an id not kept), `"no round"`, `"no part"`.

A round:

| Key | |
|---|---|
| `wind`, `number`, `honba`, `riichi_sticks`, `dealer` | the round (`east` .. `north`, 1-4) as it starts |
| `scores` | the four scores as it starts |
| `dora_indicators` | the indicator(s) as it starts (a kan's come as moves) |
| `hands` | the four deals, sorted |
| `moves` | in order, each an array starting with the seat (-1: the table's own) |
| `result` | `kind` (as the view's `res`), `changes` (the four), `from`, `wins` (`seat`, `yaku`, `yaku_han`, `han`, `fu`, `points`, `hand` (without the winning tile), `tile`, `pao`), `ura_indicators`, `tenpai`, `nagashi`, `ron_seats` |
| `end_scores`, `end_sticks` | the scores and the sticks on the table after it |

The moves:

| Move | |
|---|---|
| `[seat, "draw", tile]` | a draw (a kan's replacement tile too) |
| `[seat, "discard", tile]`, `[seat, "discard", tile, true]` | a discard; `true`: the tile just drawn (tsumogiri) |
| `[seat, "riichi", tile]` (`, true`) | riichi, declared with that discard |
| `[seat, "chi" / "pon" / "open_kan", tile, [tiles], from]` | a call of the discard `tile` of seat `from` with `tiles` from the hand |
| `[seat, "closed_kan", [four tiles]]`, `[seat, "added_kan", tile]` | a closed kan; a tile added to a pon |
| `[-1, "dora", tile]` | a new dora indicator (after a kan, when the rule shows it) |
| `[seat, "tsumo", tile]`, `[seat, "ron", tile, from]` | a win (one `ron` per winner of a double ron; three at a sanchahou) |
| `[seat, "nine_kinds"]` | the abortive draw with nine kinds |

Tiles are `look`'s names: `"1m".."9m"`, `"1p".."9p"`, `"1s".."9s"`,
`"0m"` / `"0p"` / `"0s"` the red fives, `"1z".."7z"` east, south, west,
north, white, green, red. A whole hanchan takes about 25 KB of JSON (16 KB
of MessagePack); a round's answer about 2 KB, the largest seen 2.2 KB
(the tests hold every answer under 3800 B and split longer rounds). In
the database a tonpuu game takes about 17 KB and a hanchan about 23 KB:
1000 games of a table 17-23 MB, and the copy for the backup as much again.

From the command line and an AI assistant:

```
asterism call --router tcp/192.0.2.2:7447 games/games/mahjong1 records
asterism call --router tcp/192.0.2.2:7447 games/games/mahjong1 record 12
asterism call --router tcp/192.0.2.2:7447 games/games/mahjong1 record 12 0

claude mcp add records -- asterism mcp --router tcp/192.0.2.2:7447 \
  --allow 'games/mahjong1.records' --allow 'games/mahjong1.record'
```

Then ask the assistant, for example: "Read the last game of mahjong1
(records, then record with its id and each round) and go through the
second player's discards: where did it deal in, and what would have been
safer?" Every move of a finished game is there, the four hands included,
so an assistant can review a game as a whole.

## Stats

`stats` counts the players' games from the records (games 0.14.0, the
SQLite form; the JSON form counts the table's own 20). The table apps show
it from their recent games ("Stats", S).

| Argument | | |
|---|---|---|
| days | 0 | 0: every game kept; N: the games of the last N days |
| game | `""` | `"hanchan"`, `"tonpuu"`, `""` both |
| scope | `"all"` | `"all"`: every game in the database (every table of every place, the rooms' too, closed ones included); `"table"`: this table's games (in a room, the room's) |
| from | 0 | the page: the `next` of the answer before |

`{"rows" => [...], "games", "total", "next", "days", "game", "scope",
"store"}`: `games` the games counted, `total` the rows, `next` when there
are more than fit one message (about 13 rows a page), `store` `sqlite` or
`json`. A row per player:

- **Who.** A person is a name (`"kind" => "human"`): the name entered at the
  table, so the same name is the same person whichever board or page it
  came from, and a new name a new person (anyone may take a name; nothing
  checks it). The CPUs are one row (`"cpu"`, `"CPU"`), each AI player one
  row (`"claude"`, `"jev"`). Persons first, by games, then the kinds.
- **The numbers.** `games`, `ranks` (`[1st, 2nd, 3rd, 4th]`), `avg_rank`,
  `top_rate` (1st / games), `rounds` (the rounds of the games played),
  `wins`, `dealins` (a ron from this seat: once a round, a double ron too),
  `riichi`, `win_rate` / `dealin_rate` / `riichi_rate` (of the rounds),
  `avg_score` (the final score), `points` (the sum of the rank points,
  `final`'s points / 10, with the uma).
- **What a room sees.** Names and numbers only, never a record: a room's
  table gives `"all"` like any other (the people of the whole host), and
  `"table"` for the room's own games. Outside the room, a room's games are
  in the counts of `"all"` and nowhere else.

```
asterism call --router tcp/192.0.2.2:7447 games/games/mahjong1 stats
asterism call --router tcp/192.0.2.2:7447 games/games/mahjong1 stats 30 tonpuu
asterism mcp --router tcp/192.0.2.2:7447 --allow 'games/mahjong1.stats'
```

The counts are made once per game at its end (the seats' rows of the
database), so a stats call reads no record: 1000 games take 20-50 ms.

## Playing in a terminal

(games 0.17.0) `asterism-games play <game>` sits at a table from a
terminal: CRuby and the asterism gem only (no curses: the screen is drawn
again as text whenever the table changes, cleared with ANSI escapes on a
terminal, one screen after another in a pipe or a file).

```
asterism-games play mahjong --router tcp/127.0.0.1:7447 --name Alice   # a home network
asterism-games play mahjong --credentials alice.tar                    # a console's permanent tables
asterism-games play mahjong --tiles emoji                              # the tiles as emoji (🀇🀈🀉)
asterism-games play mahjong --tiles mpsz                               # or as 1m 4p 3s
asterism-games play othello --commands "sit,cpu,start"                 # "The othello table"
asterism-games play --help
```

| Option | |
|---|---|
| `--router LOCATOR` | the Zenoh router |
| `--credentials FILE` | a console's `.tar` (a router over mutual TLS; the router and the node ID come from it) |
| `--namespace PREFIX` | inside a room's key space (`room/01`) |
| `--table PATH` | the table (`<host>/games/<table>`); without it the first one found (mahjong: several are listed to choose from on a terminal) |
| `--name NAME` | the name at the table (default: the node ID) |
| `--node NODE` | the node ID (default `tty-<host>-<pid>`, or the `.tar`'s name) |
| `--commands LIST` | commands run first, comma separated (`"sit,cpu,tonpuu,start"`) |
| `--until-over` | quit when a game it saw played is over |
| `--tiles kanji\|emoji\|mpsz` | mahjong: the tiles in kanji (default), as emoji or as text |

With neither `--router` nor `--credentials` it takes `ASTERISM_ROUTER` and
`ASTERISM_CREDENTIALS` from the environment, as the asterism command line
does (all or nothing: a router on the line never meets a `.tar` from the
environment); with nothing at all, a zenohd on this machine
(`tcp/127.0.0.1:7447`). When the table's host leaves the network
(Asterism's `on_leave`) the screen says the connection is lost and the
client waits; when the host is back (`on_join`) it asks again (and joins
again when the host forgot it).

### Keys

On a terminal (the input is a tty) both clients read one key at a time,
the keys of the table apps (fmruby-core's `flash/app/game/mahjong/` and
`flash/app/game/othello/`); the last line of the screen says which keys
work now, each in `[ ]` before what it does (`[R]リーチ [T]ツモ`). In a
pipe or a file (and the tests) they read lines as before, and
`--commands` runs first either way.

| Mahjong | |
|---|---|
| Left, Right | choose a tile of the hand (`^^` under it; the drawn tile is chosen whenever the hand changes) |
| Enter, Space | discard the chosen tile; the result's OK; at the end of the game, the owner: back to the lobby |
| `R` | riichi: then Left / Right and Enter discard with it (a tile that does not declare it: the first that does), Esc gives it up |
| `T` | tsumo or ron |
| `P` | pon |
| `C` `V` `B` | the first, second and third chi offered (the last line names each one's tiles: `[C]チー 3m4m [V]チー 4m6m`) |
| `K` `L` `J` | the first, second and third kan offered |
| `N` | nine kinds (an abortive draw) |
| Esc | pass (do not call) |
| `1`..`4` | the lobby: sit there (an empty seat or a CPU's) |
| `S` | the lobby: stand |
| `C` | the lobby, the owner: CPUs into the empty seats |
| Enter | the lobby, the owner: start (four seats taken) |

| Othello | |
|---|---|
| the arrows | move the cursor on the board (`[ ]` around the square; it stops at the edges; it starts on a legal square) |
| Enter, Space | play there (a square that is not legal: a short note, nothing sent) |
| Esc | during this member's own game: resign, after `resign? [Y] yes [N] no` on the last line (`Y` resigns, `N` or Esc cancels; as the othello app). `:resign` also works |
| `S` | the lobby (or after a game): sit, or stand |
| `C` | the owner: the CPU into the empty seat |
| Enter | the lobby (or after a game), the owner: start |

| Both | |
|---|---|
| `Q`, Ctrl+Q, Ctrl+C | quit |
| `:` or `/` | a line to type a command in, as in a pipe (`tonpuu`, `rule 3 1`, `chi 2`, `6s`, `resign`, `auto` ...): the terminal is back in its line mode for it, the screen shows the letters and the words again, Enter sends it (an empty line sends nothing) |

The terminal is put in raw mode while the client reads keys (`io/console`;
ESC alone is told from an arrow by waiting 50 ms for the rest of the
sequence) and the cursor is hidden; however the client ends (`Q`, Ctrl+C,
an exception, a signal) the terminal is put back as it was and the cursor
shown again. In raw mode the terminal does not turn `\n` into a new line,
so the client writes `\r\n`.

### Mahjong

The lobby (sit, stand, CPUs, the game's length, start), the rounds, the
results and the end of the game, in the table app's words (東1局, 本場,
供託, ドラ, リーチ, ポン ...). A member without a seat watches, with the
four hands ("Spectators"). The screen is drawn again when the table
changes; on a terminal the time left counts down in place once a second
(below), and a line being typed is never wiped by it.

```
東2局 0本場  供託1  残り32  ドラ ２筒
南 CPU2  25000* 南 白 中 ９索 ３筒 ９筒 ８筒 [六萬] 西
西 CPU3  25000  白 １索 九萬 ２索 北 ８筒 ３筒 ３索 ５索 ３索
   鳴き         發 發 發
北 CPU1  25000  白 １索 中 九萬 東 東 三萬 二萬 南
東 自分  24000  ３索 白 一萬 九萬 ２筒 東 ８索 發 四萬
  南 CPU2: リーチ

五 １ １ ４ ９ ９ １ ２ ２ ２ ７ ８ 西    ３
萬 筒 筒 筒 筒 筒 索 索 索 索 索 索       索
a  b  c  d  e  f  g  h  i  j  k  l  m     n
自分の番: 打つ牌 (文字か 6s)  あと 5+20秒
>
```

- The first line: the round, the honba, the riichi sticks on the table
  (供託), the tiles left and the dora indicators. Then the four seats,
  the next one first and this one (自分) last: the seat wind, the name, the
  points (`*`: riichi), the river (the riichi tile in `[ ]`; a tile called
  away is in the meld, not the river; a river longer than the line goes
  on below, so a line stays within 80 columns) and under it the melds
  (鳴き; a closed kan with its ends face down, 裏). Then the hand, the
  drawn tile apart at the end, and a letter under each tile; `赤:` names
  the letters of the red fives (on a terminal they are drawn in red too),
  `待ち:` the waits after each discard that declares riichi. The last line
  says what can be done now, with the time left (the move's and the
  bank's, "Time").
- **The tiles** (`--tiles`), three ways:
  - `kanji` (the default): as the table app draws a tile. In the hand (and
    a spectator's hands, a winning hand) two rows, the number on top and
    the suit below: 一..九 over 萬, full-width １..９ over 筒 and 索 (not
    ①②③, which many fonts draw small), an honour as its one character
    (東 南 西 北 白 發 中). In the rivers, the melds and the dora one line
    per tile: 一萬 ４筒 ３索 東. Every glyph is a CJK one, two columns
    wide in any terminal, so this is the readable choice.
  - `emoji`: Unicode's mahjong tiles (🀇🀈🀉 ...). How they look is up to
    the terminal's fonts: 🀄 (the red dragon) is often drawn as a colour
    emoji, hard to read next to the others, and some fonts draw the
    tiles small or wider than their column.
  - `mpsz`: the suits as `1m`..`9m`, `1p`.., `1s`.. (`0m` `0p` `0s` the
    red fives), the honours as 東 南 西 北 白 發 中.

```
北 CPU3   6800* 🀀 🀁 🀇 🀂 🀑 🀆 🀃 🀗 [🀔 ] 🀘 🀝 🀄🀄          (--tiles emoji)
🀇 🀊 🀌 🀎 🀞 🀠 🀑 🀓 🀖 🀗 🀘 🀃 🀅   🀛
a b c d e f g h i j k l m   n

東 CPU1  24000* 南 6s 6s 中 中 2m 8s 0p 9m [8p] 9s 2s 2s 1p 北      (--tiles mpsz)
7m 8m 6p 7p 1s 1s 3s 8s 西 北    6s
a  b  c  d  e  f  g  h  i  j     k
```

- **The columns.** The kanji and the full-width digits are two columns
  wide everywhere. The mahjong emoji are one column wide by Unicode's
  widths except 🀄, which is two (it is an emoji shown in colour by
  default), and fonts often draw them wider than the column they get.
  Every tile in the hand has a slot of two columns for an emoji, three
  for the kanji or `1m` (the tile and room after it), the letters the
  same slots. On a terminal the client puts each tile, each
  letter and the text after them at its column with the cursor (`ESC [ n
  G`), so a tile drawn wider never pushes the letters or the next tile
  along; in a pipe or a file it pads with spaces by the widths above (🀄
  fills its slot). The letters stay under their tiles either way; with
  the emoji a font that draws a tile wider than two columns overlaps the
  next one (the kanji never do).
- **The time** counts down on a terminal: about once a second the client
  works the screen out again with the time gone since the view came,
  and rewrites only the lines that changed (the last line's `あと 5+20秒`,
  a result's `OK を待っています ... あと N 秒`) where they are: ESC 7 saves
  the cursor where the player types, the line is cleared and written,
  ESC 8 puts the cursor back. The line being typed is not touched. In a
  pipe or a file nothing is rewritten.
- **`--commands`** run in order, each when the table can take it: the
  lobby commands (`sit`, `cpu`, `start`, `tonpuu` ...) wait for the lobby
  (a game may still be going on, or its end shown, when the client
  joins), the owner's for this member to be seated and the owner, `start`
  for the four seats; the screen says what each waits for (`--commands:
  cpu (卓の主を待っています)`). One the host answers "no" is not tried
  again.

Typed (in a pipe or a file each line; on a terminal after `:`):

| Typed | |
|---|---|
| `a` .. `n` | discard that tile of the hand (the drawn tile is the last letter) |
| `6s`, `0p`, `東` (or `1z`..`7z`), `４筒`, `一萬` | discard that tile (`0`: the red five; `5p` takes the red five when the hand has no other five) |
| `riichi` | riichi: alone with one choice, else the client lists the discards that declare it and the next line chooses (a letter or a tile); `riichi e` / `riichi 6s` at once |
| `tsumo`, `ron` | win |
| `pon`, `chi`, `kan` | call; with several ways the client lists them numbered and the next line chooses (`2`, or the tiles: `3m4m`, `34m`, letters); `chi 2`, `chi 3m4m` at once |
| `pass` | do not call |
| `kyuushu` | nine kinds (an abortive draw) |
| `ok` (or an empty line) | the result's OK ("Result": the screen says `OK を待っています (n/m)`); at the end of the game, the owner: back to the lobby |
| `sit [1-4]`, `stand` | take a seat (a CPU's too), leave it (the lobby) |
| `cpu [1-4]`, `nocpu 1-4`, `ai 1-4 KIND` | the owner: CPUs into the empty seats (or one), a CPU out, an AI player in when the lobby offers one ("AI players") |
| `tonpuu`, `hanchan`, `rule ITEM VALUE` | the owner: the game's length, any local rule ("Local rules") |
| `start` | the owner: start |
| `auto` | the client plays for you: wins when offered, passes calls, discards the drawn tile, OKs the results (again to stop) |
| `tables`, `view`, `help`, `quit` | |

The host's answers are shown in the table app's words (`今はできない`,
`卓の主だけができる` ...).

## Playing from a program

The mahjong table also speaks to programs (games 0.10.0): an AI assistant
through `asterism mcp`, a script, the host's own AI players. The screens'
view (short keys, tiles as bytes) stays as it is; next to it:

| Method | Arguments | Returns |
|---|---|---|
| `describe` | none | a text: how to play from a program, what `look` returns, the tiles' names (read it first) |
| `look` | token | the table as the member's seat sees it, in words: `status`, `you`, `seats` (name, kind human / cpu / ai / empty, wind, score, riichi, `river`, `riichi_index`, `called_indexes`, `melds`, `hand_count`), `round` (wind, number, honba, riichi sticks, dealer, wall left, turn, phase), `dora_indicators`, `last_discard`, `hand`, `drawn`, `moves`, `help`, `deadline_ms`, `result`, `final`, `rules`; in the lobby `ai_players` |
| `choose` | token, sv, n | plays the move numbered `n` of the `moves` of the look whose `sv` it gives: `"ok"`, `"stale"` (look again), `"no such move"`, or why not as `act` |
| `points` | token | what the hand would score: `now` (the win offered now) and `waits` (for each wait of a tenpai hand, after each discard that leaves it tenpai on the seat's turn: `ron` and `tsumo` with han, fu, points, yaku, or `no_yaku`) |

- `moves` lists what the seat may do now, numbered from 0: `{"n", "type",
  "tile"/"tiles", "text"}` with the types `discard`, `riichi` (a discard
  that declares it), `tsumo`, `ron`, `pon`, `chi`, `open_kan`,
  `closed_kan`, `added_kan`, `pass`, `nine_kinds`, `next`. Empty when the
  seat has nothing to decide: look again a moment later.
- `help` is the help of assist level 3 in words: after each discard that
  leaves the hand tenpai, its waits as `{tile => unseen}`; otherwise the
  shanten after each discard and the tiles that bring it down.
- A seat sees what its screen shows and no more: its own hand, the rivers,
  the melds, the dora indicators, the scores. `points` leaves the ura dora
  out (nobody sees them before a win) and does not check furiten.
- Every method of both tables has its arguments' names and a text in the
  meta (asterism's `docs/protocol.md` 5, with an asterism after 0.7.1):
  `asterism objects` prints them and `asterism mcp` makes them the tools'
  inputs and descriptions. With asterism 0.7.1 the meta has the numbers
  only, as before.

An AI assistant sits at a table like this:

```
claude mcp add asterism -- asterism mcp --router tcp/192.0.2.2:7447 --allow 'games/mahjong1.*' --app game
```

(`--app game`: the host then follows the assistant as it follows a table
app, "Who is there"; without it the assistant is away after
`away_seconds` without a call, and an away seat gets two seconds for a
move.) The table's time for a move (`turn_seconds`, 5 + 20 s of bank) is
short for an assistant that thinks: a table for them can take a longer
one (`MAHJONG_TURN_SECONDS`, or the owner's local rule item 10).

## AI players

A table's owner puts an AI player into an empty seat as it puts a CPU
there (games 0.10.0): `cpu(token, seat, "claude")` or `"jev"`, the names
the lobby view offers (`"ak"`; `look`'s `ai_players`). On one seat that
holds a CPU or another AI player the same call turns it into the one
asked for (games 0.12.1; `true` turns an AI player back into a CPU, and
a refused one leaves the seat as it was). The table apps give each seat
of the lobby a button that goes round empty, CPU, Claude, Jev (the kinds
offered), and show the seat by its name (`Claude`, `Jev`, numbered when there are several) with
`[AI]`; the view's `"ai"` gives each seat's kind (`""` for the others),
`"sk"` keeps 2 for them (an old screen shows a CPU named Claude).

| Kind | What answers | Model (setting) |
|---|---|---|
| `claude` | Claude through the Messages API (the `anthropic` gem): the instructions (`describe`) as the cached system prompt, the seat's `look` as JSON, a structured answer `{"n": <move>}` | `claude-sonnet-5-5` (`ASTERISM_GAMES_CLAUDE_MODEL`), effort `low` (`ASTERISM_GAMES_CLAUDE_EFFORT`) |
| `jev` | Jev through TypeSafe's own API (`POST https://api.typesafe.ai/v1/systemone`, games 0.11.1): a decision model asked one choice question, the moves as its answers (keys `"0"`, `"1"`, ... with their texts), the `look` as its state; the answer's `usage` is what is counted | `jev-latest` (`ASTERISM_GAMES_JEV_MODEL`; a versioned id such as `jev-1.13.0` keeps one model) |

- **How a decision goes.** For each decision of an AI seat the table asks
  the host (the seat's `look`, exactly what a human in that seat sees); the
  host asks the API on a thread of its own, never holding the game's lock,
  and hands the number back. A decision with one move is not asked.
- **Time.** An AI seat has its own time: `ai_turn_seconds` (30 s) for a
  move, `ai_call_seconds` (15 s) for its answer to a discard it may call
  (`MAHJONG_AI_TURN_SECONDS`, `MAHJONG_AI_CALL_SECONDS`). The humans keep
  theirs. When the answer does not come in time, or fails (an error, a
  refusal, a move it was not offered), the CPU plays that move and the AI
  goes on with the next.
- **Money.** What each decision costs is counted from the tokens the API
  reports, per day (the host's local date), in `state_dir/ai_usage.json`
  (shared by the rooms' hosts and the permanent tables; counts and money
  only). When today's total reaches `ASTERISM_GAMES_AI_DAILY_USD` (3.0) no
  table offers an AI player any more and the seated ones become CPUs; a
  game asks at most `ASTERISM_GAMES_AI_CALLS_PER_GAME` (400) decisions,
  then its AI seats become CPUs. `bin/asterism-games status` prints the
  day's decisions, tokens and money per kind; the host's `@status` has the
  totals (`ai_today`).
- **A limit per kind** (games 0.15.0). `ASTERISM_GAMES_AI_DAILY_USD_CLAUDE`
  and `ASTERISM_GAMES_AI_DAILY_USD_JEV` (the kind's name in capitals) give
  a kind a daily limit of its own. A kind with one stops when its own money
  of the day reaches it: no table offers it any more and its seats become
  CPUs, while the other kinds go on. A kind without one follows
  `ASTERISM_GAMES_AI_DAILY_USD` as before: it stops when the day's total of
  every kind reaches it. Without any of them everything is as before
  0.15.0. A value that is not a number of dollars (0 or more) is ignored,
  with a line in the log. The log says the limits at the start
  (`games: AI players: claude, jev (at most $10.0 a day for claude, $2.0
  for jev, 400 decisions a game)`) and once for each kind that stops
  (`today's limit for claude ($10.0) is reached`); a new day lets it play
  again. `ai_today` on `@status` then has `kinds` (README "Status").
- **Prices.** USD per million tokens, settings with the published prices
  as defaults: Claude Sonnet 5.5 `ASTERISM_GAMES_CLAUDE_USD_IN` 2.0, `_OUT`
  10.0, `_CACHE_WRITE` 2.5 (5-minute cache), `_CACHE_READ` 0.10 (checked
  2026-10-17); Jev `ASTERISM_GAMES_JEV_USD_IN` 0.042, `_OUT` 0 (TypeSafe
  charges input tokens only; checked 2026-10-18). Change them when the
  prices change.
- **Keys.** `ANTHROPIC_API_KEY` for Claude, `TYPESAFE_API_KEY` for Jev
  (console.typesafe.ai, Keys), from the environment (on the VPS:
  `deploy/vps/.env`, mode 600, docs/install.md). Without a kind's key the
  kind is not offered at all (no button). The keys go into no log, no
  state file, no status and no error text (an API's error is logged as its
  HTTP status or class only).
- `ASTERISM_GAMES_AI_THREADS` (4): decisions asked at once.
  `ASTERISM_GAMES_AI_FAKE=1` seats fakes under both names, for a LAN
  without keys and for tests (no API is called; `_FAKE_DELAY_MS`,
  `_FAKE_SLOW_EVERY`, `_FAKE_FAIL_EVERY` make every n-th decision late or
  failed).
- **Writing another decider.** `decide(request, timeout:)` returning
  `AI::Decision.new(n:, tokens:, ms:)` (lib/asterism_games/ai.rb); the
  request is `{"game", "table", "seat", "instructions", "view"}`.
- **Which game seats which kinds** (games 0.17.0): `AI::GAME_KINDS` in
  lib/asterism_games/ai.rb is the one place that says it. Mahjong seats
  `claude` and `jev`; othello seats `jev` only, whatever other keys the
  host has (its `"ak"` is `["jev"]` with Jev's key, else absent, and
  `cpu(token, seat, "claude")` is `"no ai"`). Othello's Jev uses the same
  key (`TYPESAFE_API_KEY`), the same decider, the same money of the day
  and the same `ASTERISM_GAMES_AI_CALLS_PER_GAME` as mahjong's; nothing is
  set for it alone. See "The othello table" for its view and its time.

## The othello table

The smallest game on the framework (`lib/asterism_games/othello/`): the
rules and the CPU (`board.rb`), the table (`table.rb`) and its object
(`remote.rb`), about 600 lines. The screens: fmruby-core's
`flash/app/game/othello/othello.app.rb` ("Othello (table)", a window; the
boards, the browser build and the sim) and `asterism-games play othello`
(CRuby, "Playing in a terminal"). The
game between two machines without a host is fmruby-core's
`flash/app/test/othello.app.rb` ("Othello (direct)").

- Two seats and the spectators. The first member who sits is the owner:
  the owner may put the CPU in the empty seat and starts once both seats
  are taken (one of them a member). The colours are drawn at the start:
  seat 0 is black and moves first.
- Standard othello on 8x8: a move must turn at least one disc, every line
  it closes is turned, a side with no legal move passes by itself (`"--"`
  in the history), and when neither side can move the discs decide (a draw
  when they are equal). A player may resign.
- After the game the board and the result stay (`"st" => "over"`) until
  someone sits or stands (back to the lobby) or the owner starts again.
- A member who leaves during a game hands its seat to the CPU.
- **Jev** (games 0.17.0, "AI players"): when the host has Jev's key the
  owner may put Jev in the empty seat, or turn the CPU there into Jev,
  with `cpu(token, seat, "jev")` (`true` turns it back into the CPU, `false`
  takes it out). Jev is asked each move with more than one legal square:
  the request's `"game"` is `"othello"`, `"instructions"` the rules and how
  to read the view, `"view"` `{"you" => "B" / "W", "board" => the eight
  rows from row 1 (columns a-h), "discs" => {"B", "W"}, "n", "last",
  "moves" => [{"n", "square", "turns", "text"}]}`; the answer is a move's
  `n`. One out of range, one that does not come in `ai_turn_seconds` (30 s)
  or a failure is played by the CPU, and the game goes on. When the day's
  money is spent, or the game has asked `ASTERISM_GAMES_AI_CALLS_PER_GAME`
  decisions, Jev's seat becomes the CPU. The table apps show Jev by its
  name with `[AI]` and say when it is thinking; `dl` counts its time down.
- Nothing in othello is hidden, so every member sees the same view: the
  table's view (the one the host puts on the state key) and `me`, the
  member's seat.

| Method | Arguments | Returns |
|---|---|---|
| `join` | name | `{"token", "seat" (-1: none), "owner"}`, or `{"error" => "full"}` / `"spectators"` |
| `mine` | none | the same for a node that joined, or nil |
| `sit` | token, seat | `"ok"` or why not; seat -1: the free seat (else the CPU's). Not during a game |
| `stand` | token | `"ok"` or why not |
| `cpu` | token, seat, on | the owner: the CPU into an empty seat (on) or out of it; seat -1: every seat. on `"jev"` (one of `ak`): Jev instead of the CPU, or the CPU there into Jev; `"no ai"` when it is not offered |
| `start` | token | the owner, both seats taken |
| `move` | token, n, square | `"ok"`, or why not (`"stale"`: n is not the view's `n`, `"illegal"`, `"not your turn"`, `"not seated"`, `"not playing"`); square as `"d3"` |
| `resign` | token | `"ok"` or why not |
| `view` | token | the table's view and `me`, or `{"error" => "token"}` |
| `table` | none | the table's view |
| `leave` | token | `true` / `false` |

The view: `st` (`wait` / `play` / `over`), `nm` the seats' names, `sk`
(0 empty, 1 member, 2 CPU), `aw` (bits: a seated member is away), `ow` the
owner's seat, `mb` the members (`[name, seat, flags]`), `ts` the seconds
for a move, `ai` the seats' AI players (`["", "jev"]`; only when there is
one; `sk` keeps 2 for them, so an old screen shows a CPU named Jev), `ak`
the AI players the owner may seat (out of a game, only when the host
offers some); with a game `bd` (64 characters of `.` `B` `W`, a1 first, row
by row), `tn` the seat to move (-1 none), `n` the moves so far (passes
too), `last`, `lg` the legal squares of the side to move (`"d3c4f5e6"`),
`cnt` the discs `[black, white]`, `dl` the ms left of a member's move (with
a time per move) or of Jev's; after it `res` (`{"w" => the seat that won, -1 a draw,
"why" => "count" / "resign", "b", "wc"}`). At most about 900 B with 16
members of 32-byte names (`rake test` prints it); a game between two
players about 330 B.

| Key | Environment | Default | |
|---|---|---|---|
| `turn_seconds` | `OTHELLO_TURN_SECONDS` | 0 | a member's time for a move (0: none); over 0, when it runs out the CPU plays that move |
| `cpu_ms` | `OTHELLO_CPU_MS` | 700 | the CPU's pause before it plays |
| `away_seconds` | `OTHELLO_AWAY_SECONDS` | 10 | as for mahjong: away at once when its node leaves, or after this long without a call ("Who is there") |
| `spectators` | `OTHELLO_SPECTATORS` | 14 | members without a seat at most (in the lobby the free seats count besides) |
| `ai_turn_seconds` | `OTHELLO_AI_TURN_SECONDS` | 30 | Jev's time for a move; then the CPU plays it |

The CPU is small: the square with the best weight (corners first, the
squares next to a corner last), then the most discs turned.

### In a terminal: `asterism-games play othello`

(`bin/othello-tty` until games 0.17.0; it is still there and runs this,
with the same options.) CRuby and the asterism gem only (no Family
mruby). The options are every client's ("Playing in a terminal"). It joins the table,
draws the board as text at every change (it takes the state the host puts
and asks its view; X black, O white, `*` the squares it may play) and on a
terminal reads keys ("Keys": the arrows move a cursor, Enter plays), else
commands: `sit`, `stand`, `cpu`, `ai [KIND]` (Jev in the other seat, when
the host offers it), `start`, a square (`d3`), `resign`, `auto` (play the
first legal square for you), `quit`. With keys the owner's `A` puts Jev in
the other seat (empty or the CPU's) and turns it back into the CPU the
next time (`[A] Jev`, `[A] back to the CPU`; not shown when the host
offers no AI player); the seat shows `Jev (AI)` and the first line
`Jev is thinking, 28 s left` on its moves. When the table's
host leaves the network (Asterism's `on_leave`) it says the connection is
lost and stops asking until the host is back (`on_join`; every 30 s
meanwhile, should the word not come). Without `--table` it looks for a
table when a node joins.

```
# a home network (a plain zenohd)
asterism-games play othello --router tcp/127.0.0.1:7447 --name Alice
# the permanent tables of a console (a row's .tar with the role games; the node is its name)
asterism-games play othello --credentials alice.tar --table games/games/othello1
# start a game against the CPU at once
asterism-games play othello --name Alice --commands "sit,cpu,start"
```

```
games/games/othello1  move 2, last d3
    a b c d e f g h
  1 . . . . . . . .
  2 . . . . . . . .
  3 . . * X * . . .
  4 . . . X X . . .
  5 . . * X O . . .
  6 . . . . . . . .
  7 . . . . . . . .
  8 . . . . . . . .
  X black CPU (CPU)                 4
  O white Alice (you, owner)        1 <
  your move: a square (* marks them), or resign
```

On a terminal, with keys:

```
  3 . .[*]X * . . .
  ...
  your move: [arrows] move [Enter] play (* marks the squares)  [:] type a command  [Q] quit
```

## The drawing board

A game without a winner (`lib/asterism_games/board/`, about 360 lines):
one picture that every member of the board draws on. It shows the other
half of the framework: a state that is handed out as it changes, rather
than a view that is read. The screen is fmruby-core's
`flash/app/game/board/board.app.rb` ("Board" / "お絵かき", a window; the
boards, the browser build and the sim).

- The picture is strokes in board coordinates (640x360): a colour (one of
  16; the screen's palette), a width step (one of 4: 1, 2, 4 and 8 board
  pixels on the screen) and points. A screen sends a stroke while it is
  drawn (`line`, then `more`), so the others see it grow.
- The first member to join is the owner (the next one in the order of
  joining when it goes), who alone may clear the board. Each member may
  take back its own last stroke still on the board (`undo`).
- The host saves the picture (`state_dir/board1.json`, at most once a
  second while somebody draws, and when it stops) and has it again when it
  starts. A room's board goes when the room closes, like a room's tables.

| Method | Arguments | Returns |
|---|---|---|
| `join` | name | `{"token", "owner"}`, or `{"error" => "full"}` |
| `line` | token, c, w, pts | a new stroke: `{"id" => id}`, or why not (`"colour"`, `"width"`, `"points"`); pts `[x, y, ...]`, 1-256 points |
| `more` | token, id, pts | more points of the caller's newest stroke: `"ok"`, or `"not yours"`, `"long"` (past 1024 points: the screen starts a new stroke), `"points"` |
| `undo` | token | `"ok"` or `"nothing"` |
| `clear` | token | `"ok"` or `"not owner"` |
| `picture` | id, at | a page of the picture from stroke `id` (0: the first) and its point `at`: `{"v", "n", "p" => [[id, c, w, pts, k], ...], "nx" => [id, at] of the next page, or nil}`; k 1: the page goes on with a stroke the page before began, and its points start with that stroke's point before `at`. At most 400 points a page (2.2 KB) |
| `view` | token | the board's view, `own` (the caller is the owner) and `mine` (its strokes) |
| `table` | none | the board's view (what the state key has) |
| `leave` | token | `true` / `false` |

The view (the state key): `st` (`draw`), `n` the strokes, `np` the
points, `last` the newest stroke's id, `mb` the members (`[name, flags]`,
1 away, 2 owner), `lim` `[640, 360, 16, 4, 256, 1024, 1000, 40000]` (the
size, colours, widths, points a message, points a stroke, strokes, points).

**The strokes key.** Every change goes out on
`asterism/<node>/<app>/<board>/strokes` (`Game#tell`) as one message, in
the order the host took them:

| Message | |
|---|---|
| `{"o" => "a", "id", "c", "w", "p" => [x, y, ...], "k", "v"}` | points of stroke `id`: `k` 0 starts it, `k` 1 goes on with it (`p` then starts with the stroke's last point so far, so each message draws as a line of its own) |
| `{"o" => "u", "id", "v"}` | stroke `id` taken back |
| `{"o" => "c", "v"}` | the board cleared |

`v` is the board's version when it was told. A screen draws the messages
as they come and keeps the strokes, to draw the place of a stroke taken
back again; it reads the whole picture (`picture`, in pages) when it joins
and after the connection or the host comes back.

**Recording and playing back** (the console's recordings, its docs
`v4.md` and `rooms.md`): record the Asterism key
`asterism/<host>/games/board1/strokes`, and a playback to the network puts
the same messages on the same key: the screens draw the board being drawn
again. A screen cannot tell a played message from a real one, so the
picture it shows may then differ from the board's own (the host does not
see the playback); the messages played carry the older versions, so a
screen says a recording is playing (`v` older than the last state it saw)
and `R` reads the board's own picture again. A console records keys on the
registered side only (the boards' own certificates and the browsers with
a pass, the permanent tables): it cannot subscribe to or put into a room.

**Limits.** A message is at most 256 points: with 3-byte coordinates and
the largest id and version, 1.6 KB with its key (`rake test` prints it),
well under the 4096 bytes a board takes. A stroke is at most 1024 points.
The board keeps at most 1000 strokes and 40000 points and drops the oldest
strokes past either (nothing is told: a screen keeps the same limits and
drops them too; they leave its screen when that place is drawn again).
Dropping rather than refusing keeps the board drawable for as long as
people draw; the point limit is what a screen can keep (4 bytes a point,
about 60 % of a window app's 1.5 MB VM at the limit). 500 strokes of 60
points are 240 KB saved and add about 3 MB to the host's RSS.

| Key | Environment | Default | |
|---|---|---|---|
| `away_seconds` | `BOARD_AWAY_SECONDS` | 10 | as for mahjong ("Who is there") |

## riichi_engine

The engine runs the rounds (wall, deal, draws, discards, calls, riichi, wins,
yaku, points) and the CPUs. The host uses a fork of 0.1.0 with its errors
fixed: the `fmrb` branch of
[kishima/riichi_engine](https://github.com/kishima/riichi_engine), a fork of
[riichi_engine](https://github.com/HenrikStephensen/riichi_engine)
(`Gemfile` takes it as a git source, so the lockfile pins a revision). Each fix is a branch of its own
(`fix/*`, `feat/*`), written to be sent upstream; `fmrb` merges them (version
`0.1.1.fmrb6`, not published). The host has no corrections of its own around
the engine any more.

What 0.1.0 got wrong, and what this host did about it before the fork:

| | In 0.1.0 | Fork branch | The host's correction (removed) |
|---|---|---|---|
| 1 | `evaluate_win` counts dora (and uradora) on the indicators | `fix/dora-indicators` | evaluated with the dora tiles |
| 2 | no houtei: the phase is already `round_end` (and a houtei-only hand is not offered the ron) | `fix/houtei` | evaluated in the phase of the win |
| 3 | a seat in riichi gets no discard, its turn cannot go on | `fix/riichi-discard` | offered the drawn tile |
| 4 | ippatsu is not cleared by the player's own next discard | `fix/ippatsu` | cleared it |
| 5 | a red five is swapped or lost in a discard, chi, pon or kan | `fix/red-five` | put the exact tiles first, recorded the kan's tiles |
| 6 | a seat that could ron cannot pon instead | `fix/call-own-options` | left only the chosen action pending |
| 7 | ties between rons by seat number (no head bump) | `fix/ron-turn-order` | decided by turn order; now `resolve_pending_action(..., from_seat:)` |
| 8 | seeds are read up to the first non-base-36 character | `fix/wall-seed` | used only base-36 seeds |
| 9 | the normal/hard CPU keeps the shape with the least acceptance | `fix/cpu-discard-ukeire` | its own CPU (`Engine::CpuAi`); now the engine's |
| 10 | `game_type` `"tonpuu"` (the documented name) never ends | `fix/tonpuu-game-type` | (not used) |
| 11 | `RiichiEngine.loader.eager_load` fails | `fix/zeitwerk-eager-load` | (not used) |
| 12 | no tanyao with a red five | `fix/tanyao-red-five` | none (found by the comparison below) |
| 13 | a triplet completed by ron on a shanpon wait has the concealed fu | `fix/shanpon-ron-fu` | none (comparison) |
| 14 | only the first wait of the winning tile is scored (pinfu, higher fu missed) | `fix/machi-interpretation` | none (comparison) |
| 15 | four identical sequences are iipeiko, not ryanpeiko | `fix/ryanpeiko-four-sequences` | none (comparison) |
| 16 | `double_ron` and `triple_ron_draw` have no effect (one ron always wins, by head bump) | `fix/multiple-ron` | none (Step 2 needs them) |
| 17 | several yakuman in one hand always score as one (a new key, `multiple_yakuman`) | `feat/multiple-yakuman` | none |
| 18 | the shanten counts the concealed tiles as the whole hand (wrong with melds), and slowly | `fix/shanten-melds` | its own count of the regular form (`Engine.shanten`); now the engine's |
| 19 | a kan does not shorten the live wall | `fix/kan-live-wall` | none |
| 20 | the CPU judges riichi on the hand before the discard (it never declares riichi) | `fix/cpu-riichi` | none |
| 21 | every discard ends the first go-around for all four (no nine kinds, double riichi or chiihou for a child) | `fix/first-turn-flags` | none |
| 22 | an unknown `game_type` never ends | `fix/unknown-game-type` | none |
| 23 | a kan's ura dora indicator is not counted (the ura indicators stay as dealt) | `fix/kan-uradora` | none |
| 24 | a seat that lets a winning tile go by with no ron offered (no yaku on it) is not furiten for the go-around | `fix/dojun-furiten-no-yaku` | none |
| 25 | the normal/hard CPU calls without a yaku in sight (it looks at the shanten alone), and a chi with several pairs is counted without taking the tiles out | `fix/cpu-yaku-calls` | none |

New keys in 0.1.1.fmrb3, each off by default (the engine plays as 0.1.0
without them; the host turns them on, "Rules"): `suufon_renda`,
`suukaikan`, `suucha_riichi` (`feat/abortive-draws`), `nagashi_mangan`
(`feat/nagashi-mangan`), `pao` (`feat/pao`), `minkan_dora_after_discard`
(`feat/kan-dora-after-discard`), `double_yakuman` used at last
(`feat/double-yakuman`), `tenpai_yame` (`feat/agari-yame`). New keys in
0.1.1.fmrb4, likewise: `kuikae` (`feat/kuikae`; on by default, the host
turns it off), `riichi_ankan` (`feat/riichi-ankan`),
`kokushi_ankan_chankan` (`feat/kokushi-ankan-chankan`), `pao_honba`
(`feat/pao-honba`), `tenhou_best_tile` (`feat/tenhou-best-tile`),
`nan_iri` and `sudden_death` (`feat/sudden-death`). New in 0.1.1.fmrb6:
`riichi_void_on_ron` (`feat/riichi-void-on-ron`; off by default, the host
turns it on).

The fork compares its win evaluation with the Python package `mahjong`
(PyPI) on 30 000 random winning hands and one or more hands per yaku
(`spec/compat/`): the yaku, han, fu and payments agree except where a rule
differs (two yakuman in one hand score as one yakuman in riichi_engine, as
two in the Python package; with `multiple_yakuman` they agree).

Exhaustive draws in CPU-only hanchan: with 0.1.0, 341 of 452 rounds (75 %)
with the engine's own CPU, 127 of 496 (26 %) with the host's corrected CPU;
with the fork's own CPU, 85 of 488 (17 %) at normal and 97 of 496 (20 %) at
hard over 40 hanchan each, and 72 of 282 (26 %) in the 20 normal hanchan of
one `rake test` (0.1.1.fmrb2). With 0.1.1.fmrb3 (its CPU now declares
riichi and calls less), over 40 hanchan each: 15 % at normal (68 of 449
rounds), 14 % at hard (57 of 419), 33 % at easy.

Still as in 0.1.0: tobi ends the game below 0 points, not at 0 (the
fork's documents now say so, `fix/tobi-doc`); without `sudden_death` the
west round never ends without a player above the threshold (the host ends
the game after west 4); `tsumo_agari` and `ron_agari` leave the points to
the host (the engine's API says so). Without `kuikae` set to false a seat
may discard the tile it just called, and without `riichi_void_on_ron` a
riichi declared on a tile that is ronned keeps its stick on the table. A
CPU decision takes about 2 ms of CRuby time at the median (about 0.4 s at
most, the first time a suit pattern with many tiles is counted).

## Tests

```
bundle exec rake test                                   # MJ_GAMES=20 CPU hanchan, MJ_HUMAN_GAMES=1 four-player hanchan
MJ_GAMES=4 bundle exec rake test                        # quicker
bundle exec rake test:gem                               # what the gem holds only: lib/ alone, mahjong never loaded, no sqlite3
gem build asterism-games.gemspec                        # the gem (its files: test/test_gem.rb checks them)
ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 bundle exec rake test   # also through a router
```

- `test_play.rb`: `asterism-games play` (in `rake test:gem` too): the
  options and `ASTERISM_ROUTER` / `ASTERISM_CREDENTIALS`, `--help` (the
  host's too: it prints and starts nothing), the tiles in kanji (the
  default), as emoji and MPSZ both ways, the widths (🀄 two columns), rows that keep their columns
  (padded by width, or each part put at its column on a terminal) with the
  letters under their tiles, reading discards (letters, `6s`, `0p`, the red
  five as `5p`), declarations and calls (choosing by number, tile or
  letter), the countdown rewritten in place on a terminal (only the time
  line, between ESC 7 and ESC 8), and the screens (a round in kanji with
  its two-row hand and a river that goes on below, emoji and MPSZ; the lobby, a result,
  the end, a call, a spectator). With `ASTERISM_TEST_ROUTER`, a host in a
  process of its own and three clients at once (kanji by default, emoji,
  MPSZ) that play a
  tonpuu game against three CPUs each to the end from scripted input
  (letters, tiles, calls, passes, OKs; `PLAY_TRANSCRIPT_DIR` keeps what
  they showed).
- `test_play_commands.rb`: `--commands "sit,cpu,start"` against a table
  in this process: they wait for the lobby when a game is going on as
  the client joins (and then sit, fill and start), the owner's wait for
  the owner, and run at once in a fresh lobby.
- `test_mahjong_games.rb`: MJ_GAMES hanchan by four CPUs in MJ_PROCS
  processes (default 8) and MJ_HUMAN_GAMES hanchan by four members playing
  through `act` (wins when offered, calls now and then, passes, timeouts,
  and now and then something not offered, refused): no exception, the points
  add up after every round, after every step no seat's view has another
  seat's hand, the help comes only as each seat's level says (level 1 only
  with a riichi offer, uk only at level 3 and never with wt), and every
  view fits in a board's message (the four seats ask for the help at
  levels 1, 2, 3 and 0); and the worst-case views (a result, a riichi turn
  with the riichi help at its largest).
- `test_mahjong_assist.rb`: the help by level (which views get `wt` and
  `uk`, the call with and without the level), the shanten against the
  engine's for closed hands and against the wait judge with melds, the
  acceptance, and the largest acceptance view.
- `test_mahjong_rules.rb`: the lobby (join, sit, stand, the owner, CPUs,
  start, a spectator, away and back, back to the lobby after a game), tokens,
  refusals (no token, a wrong token, an action not offered, a stale state),
  the timeout, saving and reading back mid-round and in the lobby, the
  deadline across a restart, calls (every player answers, one deadline for
  all, ron over pon), double ron (turn order, honba and sticks to the first,
  off: head bump), three rons (a draw; off: three winners), multiple
  yakuman on and off, the host's rule defaults, the riichi help (the waits
  after each riichi discard and what is left of them, only in the seat's
  own view), and the engine fixes the host relies on.
- `test_mahjong_local_rules.rb`: the local rules (the host's values to
  start from, the owner only, the lobby only, the values offered, each item
  reaching the engine, the time to discard, saved and kept for the next
  game; a tonpuu game chosen in the lobby ends in the east round or the
  south round after it, open
  tanyao off offers no ron on an open tanyao-only hand, the red fives in
  the wall), the spectators (over a whole game the four hands and no
  offer, help or sign of a call in a spectator's own view, no hand in the
  put, `table` or a seat's view; with a delay they see the game and the
  hands as they were that long ago while the players do not wait; none by
  default; how many), the CPUs' level and the spectators' delay chosen in
  the lobby (reaching the CPUs, saved, the delay setting in minutes) and
  the han of each yaku in a result; the items of
  0.1.1.fmrb3 (the three abortive draws as one item, over a setting with
  only some of them) and the extra round item (both keys, its value by the
  game chosen, over a setting with only one of them).
- `test_mahjong_round_ends.rb`: the rules of 0.1.1.fmrb3, fmrb4 and fmrb6
  the host turns on: every host key reaching the engine, a ron on the
  riichi tile giving the 1000 back (a pon of it letting the riichi stand), nagashi mangan paid in place
  of the no-ten payments (and not when turned off), pao recorded at the pon
  and paid (all of it at a tsumo, half with the discarder at a ron, the
  honba of a ron by the seat liable), no swap-calling after a chi (not
  offered, refused), the west round ended by sudden death (the reason in
  the view), a tonpuu game going south below 30,000 (not with the extra
  round turned off), a double
  yakuman's -2 and points (one yakuman when turned off), four winds ending
  the round by name (the dealer keeps the seat, one more honba; none when
  turned off), why a game ended in the view, the riichi sticks left at the
  end going to the top (equal points by seat), and a table saved before
  these rules read back and played on.
- `test_mahjong_time.rb`: the time ("Time"): 5+20 by default and from the
  settings, a move beyond its 5 s taking the rest off the bank, the move
  played for when the bank is used up (then 5 s a move), the bank filled
  again at every round, an away
  player's short wait leaving the bank, the calls keeping their time, the
  owner's choice (a bank, a fixed time, only the lobby's choices) reaching the
  table, the banks saved, and a table saved before the bank read back.
- `test_mahjong_result_ok.rb`: the start of a round and the result
  ("Result"): the pause after the deal (no clock, no CPU or AI move, every
  round, saved), the result waiting for every human's OK (an away one not
  counted, an old screen's next as its OK), moving on by itself after the
  count and 10 s (the count by the yaku lines, a double ron, a draw), the
  settings, and a table without humans as before.
- `test_mahjong_records.rb`: the game records ("Game records"): a game's
  record whole (every round replayed from its deal by its moves: each
  discard and call from the hand that holds it, the wins' hands, no tile
  more than four times, each seat's points from round to round by the
  result and its riichi stick, the final scores), going on across a
  restart of the host mid-round, the 20 newest kept (the numbers go on),
  without a database a closed room's records gone with it; with SQLite
  (0.14.0) the records read by the next host, the 1000 newest kept (and
  the pages walking them), the JSON records of 0.13.0 taken in once (the
  same games in the list and the same records), a closed room's games kept
  in the database while no other room, permanent or LAN table gives them
  out (the stats count them), the stats equal to what the records count
  another way (wins from the tsumo and ron moves, deal-ins from the ron
  moves, riichi, ranks, rank points; a person by name, CPU, Claude, Jev),
  the stats in pages; every answer of `records` and
  `record` under 3800 B (twenty games of long names in pages, a long round
  in parts), the remote's calls, the last result on `@status` (and not in
  the rooms' counts), and the declarations in the view (`cl`). The CPU
  hanchan of `test_mahjong_games.rb` check each game's record the same way.
- `test_mahjong_call_privacy.rb`: the calls on a discard keep their secret:
  each seat sees its own choices only, and a second seat that may call (or
  answers) changes no other seat's view, the spectator's, the put or the
  public view (two tables compared key by key); the versions after the
  calls, the passes naming nobody, and over whole four-member hanchan no
  `dl` but a candidate's own bit or the "others" bits.
- `test_mahjong_room_identity.rb`: who joins in a room: the seats and the
  host's names join, nobody else (join and mine), nothing checked outside a
  room, join and mine without a secret, a seat silent for long is a new
  page, the room's ID reaching the tables.
- `test_othello.rb`: the othello rules (the legal moves, the discs turned in
  every direction, a side that cannot move passing by itself, the end and
  the winner by the discs, a history replayed), the CPU playing only legal
  moves to the end, a game against the CPU, the seats and the owner, the
  spectators' limit, no time limit by default and the CPU playing a move
  whose time ran out, a game saved and resumed with the same tokens and the
  time left, the exposed methods and the largest view.
- `test_board.rb`: the drawing board: a stroke and more points on the
  strokes key (a part going on from the last point), what is refused, a
  stroke's point limit, taking back one's own last stroke, only the owner
  clearing and the owner passing on, the oldest strokes dropped past the
  stroke and point limits (the newest staying), the largest message and
  the largest page of the picture, the picture in pages giving every point
  once, saved and resumed (owner, ids, tokens), writes held to one a
  second, the host putting the strokes before the state and counting them
  in the status, and a host started again having the picture.
- `test_rooms.rb`: the rooms' supervisor with stand-in host processes: which
  rooms get a host (the app, closed, ended), the child's settings (the
  slot's certificate, the namespace), a new room on the slot starting from
  nothing (and a slot that moved while the supervisor was down), the same
  room keeping its tables across a restart, an unreadable file changing
  nothing, `max` and a stopped host started again, the status (counts
  only) and the settings from the environment; which tables a room gets
  (each game's screen and first table by default, a room opening the
  mahjong screen gets mahjong tables only and one opening the othello
  screen othello tables only, the given tables split by game, table names
  in the environment finding their game).
- `test_presence.rb`: who is there ("Who is there"): a member's node that
  leaves is away at once and back at once, a call or a join brings it back,
  without the network's word a member is away after `away_ms` as before,
  the time to forget counts from when the node left (a seated member
  stays), the saved form keeps no presence, a room's seat gone for
  `seat_reuse_ms` is a new page when its node comes back, an away mahjong
  seat, and the host telling every table.
- `test_mahjong_owner_handover.rb`: the owner away ("Players that drop
  out"): the role passes after `owner_handover_ms` to the seated member who
  sat first, else by join order, stays with nobody there, is not taken
  back, also during a game, 0 turns it off; a table left alone: a game whose
  humans are all away for `abandon_ms` goes back to the lobby without a
  record, a member who left stops counting at once, one human back in time
  keeps the game, a result is abandoned too, a table of CPUs plays on, 0
  turns it off.
- `test_network.rb`: the same refusals through a router, with the host in a
  child process, and the caller from Asterism (a call that brings `from:`
  is refused, the numbers of arguments are counted) (skipped without
  `ASTERISM_TEST_ROUTER`).
- `test_framework.rb`: the framework without a game: its files require
  nothing of a game, loading it loads only its own files (no riichi_engine),
  and `test/framework/test_tally.rb` runs in a process of its own with a
  small game of its own (`test/framework/tally.rb`) and nothing else: the
  exposed methods, the settings from the game, members and tokens through
  the Remote with `from:`, saving and another host going on from the saved
  state, the status file, a room and the permanent tables of that game
  (who joins, `GET /status`, the room's tables removed when it closes) and,
  with `ASTERISM_TEST_ROUTER`, the host over a router (calls, the state
  put, the profile, and another node killed: away at once, back when its
  node is there again). Also the mahjong game's registration and its exposed
  methods as before, and that nothing of mahjong is in `lib/`.
- `test_gem.rb`: the gem (`asterism-games.gemspec`): its files are `lib/`,
  the two commands and the texts, never `app/`, `deploy/`, `config/`, the
  tests or anything like a key; its version is `VERSION`'s and it depends on
  asterism only. Under `rake test:gem` (with `test_framework.rb`,
  `test_othello.rb`, `test_board.rb` and `test_record_book.rb`, `lib/`
  alone on the load path, `test/no_sqlite3/` making `require "sqlite3"`
  fail) the games are othello and the board and nothing of mahjong is
  loaded.
- `test_record_book.rb`: the records' book of the framework (`RecordBook`):
  the JSON form (the newest kept in the store, read back, the stats' rows),
  and without the sqlite3 gem a host takes the JSON form; with SQLite the
  newest kept of a table (another table apart, the seats going with their
  games, ids never reused), a room's games given out only in that room and
  kept when it closes (the rooms' table counted together), the stats by
  time and kind of game, four processes ending 100 games at once into one
  database (none lost, `integrity_check` ok, the copy whole) and a restore
  from the copy alone.

`bin/mahjong-bots` fills a table with players over the network (to try a
second table, or the host under load): `bundle exec bin/mahjong-bots
--table games/games/mahjong2`. In a room: `--credentials room-01.tar
--namespace room/01 --room <room ID> --table games/games/mahjong1`. `--rules 0=1,1=0` sets
local rules before the start (a tonpuu game without open tanyao),
`--start-ms` waits in the lobby (for spectators), `--result-ms` looks at
each result that long.

## License

MIT (LICENSE).
