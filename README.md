# asterism-games

Game hosts for [Asterism](https://github.com/ruby-asterism/asterism): a
CRuby process that joins a Zenoh network as an Asterism node, holds the
state of the games and lets players on boards (Family mruby), browsers and
PCs play through Asterism calls. The first game is riichi mahjong (four
players; seats nobody takes are played by CPUs), built on the
[riichi_engine](https://rubygems.org/gems/riichi_engine) gem.

Status: Step 1 of the mahjong plan: one human and three CPUs at a table, on
a local network. Not published yet.

| Path | What |
|---|---|
| `bin/asterism-games` | the host |
| `lib/asterism_games/host.rb` | the connection, the loop, the puts, the game registry (`Host::GAMES`) |
| `lib/asterism_games/config.rb` | the settings (file and environment) |
| `lib/asterism_games/store.rb` | saved states, one JSON file per table |
| `lib/asterism_games/mahjong/` | the mahjong table: `table.rb` (seats, rounds, views, time), `engine.rb` (the calls into riichi_engine and the corrections around it), `remote.rb` (the exposed object), `tiles.rb` (tile numbers) |
| `config/example.yml` | settings to copy |
| `test/` | the tests (`rake test`) |

## Running

CRuby 3.2 or newer and a C compiler (asterism-zenoh compiles its extension).

```
bundle config set --local path vendor/bundle
bundle install
ASTERISM_GAMES_CONFIG=config/example.yml bundle exec bin/asterism-games
```

The host connects to the router in the settings (by default
`tcp/127.0.0.1:7447`, a zenohd on this machine) as the node `games` and the
application `games`, and exposes each table as an object:
`games/games/mahjong1`. Ctrl-C (or SIGTERM) saves and stops. Started again,
it goes on from the saved state (the same round, the same turn, the same
seats and tokens). When the router goes away, it connects again every 3 s.

The gems come from rubygems at fixed versions (`Gemfile`: asterism 0.7.1,
riichi_engine 0.1.0): the host runs what anyone can install.

## Settings

A YAML file (`--config PATH` or `ASTERISM_GAMES_CONFIG`; see
`config/example.yml`), with the environment over it:

| Key | Environment | Default | |
|---|---|---|---|
| `router` | `ASTERISM_GAMES_ROUTER` | `tcp/127.0.0.1:7447` | the Zenoh router |
| `node` | `ASTERISM_GAMES_NODE` | `games` | this host's node ID |
| `app` | `ASTERISM_GAMES_APP` | `games` | the application every game lives under |
| `credentials` | `ASTERISM_GAMES_CREDENTIALS` | none | a console's `.tar`, for a router over mutual TLS (the router and the node ID then come from it) |
| `state_dir` | `ASTERISM_GAMES_STATE_DIR` | `var/state` | where the tables are saved |
| `tables` | | one table `mahjong1` | each `{name, game: mahjong, ...}` |

A mahjong table takes (the environment applies to every table):

| Key | Environment | Default | |
|---|---|---|---|
| `turn_seconds` | `MAHJONG_TURN_SECONDS` | 20 | a player's time to discard; after it the drawn tile is discarded |
| `call_seconds` | `MAHJONG_CALL_SECONDS` | 8 | a player's time to call a discard; after it the call is passed |
| `result_seconds` | `MAHJONG_RESULT_SECONDS` | 8 | a round's result stays this long (or until a player presses next) |
| `cpu_ms` | `MAHJONG_CPU_MS` | 700 | a CPU's pause before it acts |
| `cpu_level` | `MAHJONG_CPU_LEVEL` | `normal` | `easy` / `normal` / `hard`, or `engine` for riichi_engine's own discards (see below) |
| `humans` | | 1 | seats players can take (Step 1: one) |

## The mahjong table

### Methods

| Method | Arguments | Returns |
|---|---|---|
| `sit` | name | `{"seat", "token"}`, or `{"error" => "full"}` |
| `view` | token | the seat's view (below), or `{"error" => "token"}` |
| `act` | token, sv, type, tiles | `"ok"`, or why not: `"token"`, `"stale"` (sv is not the current one), `"not offered"`, `"not playing"` |
| `table` | none | the public view (no hand) |
| `leave` | token | `true` / `false`; the seat goes back to a CPU |

- The node that calls `sit` is the caller in the call's key
  (`Asterism.current_call.from`). The same node gets its seat and token
  back, so a player that restarts its application sits again where it was.
  The game starts when the first player sits; the seat is drawn.
- The token is 32 hex digits from `SecureRandom`. Everything about a hand
  needs it: without it, or with another, `view` and `act` refuse. The
  public view never has a hand (except the winner's, shown at a win).
- `act` takes only what the seat's list (`"a"` in its view) has: the
  host asks riichi_engine for the seat's actions and matches the request
  against them. `sv` is the state version the player saw.
- After every change the host saves the table and puts the public view on
  `asterism/<node>/<app>/<table>/state` (and every 5 s anyway). A player
  that sees a newer `"v"` there asks its view again.

### Views

A Hash (MessagePack); tiles are one byte each in binary strings (bin).

| Key | |
|---|---|
| `v` / `sv` | the view's version (any change) / the state version (actions) |
| `t`, `st` | the table's name; `wait` (no player yet), `play`, `result` (a round's result), `over` |
| `nm`, `hu` | the four names; the human seats as bits |
| `r` | `[bakaze (0 east, 1 south, 2 west), kyoku, honba, riichi sticks, dealer seat, tiles left, seat to act, phase (0 draw, 1 discard, 2 calls, 3 end)]` |
| `sc`, `ri` | the scores; riichi as bits |
| `dora` | the dora indicators |
| `kw` | four rivers, one byte a tile: `0x40` the riichi tile, `0x80` called away |
| `fu` | four meld lists: per meld `[kind, from, n, n tiles]`; kind 1 chi, 2 pon, 3 closed kan, 4 open kan, 5 added kan; from 1 right, 2 across, 3 left, 0 none |
| `hc` | the four hand sizes |
| `ls`, `ev` | the last discard `[seat, tile]`; the last action `[type, seat]` |
| `dl` | `[seat, ms]`: who the host waits for and how long it still waits |
| `res` | at a round's end: `k` (`tsumo_agari`, `ron_agari`, `ryuukyoku`, `kyuushu_kyuuhai`), `d` (the four score changes), `w`, `f`, `y` (the yaku, as riichi_engine names them, in Japanese), `pt` (fu, han, points), `h` and `ag` (the winner's hand and winning tile), `tp` (tenpai seats at a draw) |
| `fin` | at the end: `[[seat, rank, score, point x 10], ...]` |
| `me`, `h`, `dt`, `a` | the seat's view only: its seat, its hand (sorted, without the drawn tile), the drawn tile (-1 none), what it may do: `[[type, tiles], ...]` |

Tile numbers: `0..8` 1m..9m, `9` 0m (red five), `10..18` 1p..9p, `19` 0p,
`20..28` 1s..9s, `29` 0s, `30..36` 1z..7z (east south west north white
green red), `37` back. The same order as the tile sheets of Family mruby's
table screen.

Action types: 1 discard (tiles: what may be discarded; send one), 2 riichi
(tiles: the discards that declare it; send one), 3 tsumo, 4 closed kan, 5
added kan, 6 pon, 7 chi (one entry per pair), 8 open kan, 9 ron, 10 pass,
11 nine kinds, 12 next (after a result; a new game after the end).

### Message size

A board and the browser build (zenoh-pico) take at most 4096 B in one
message, Zenoh's headers and the key included, and drop a larger one without
a word. The views stay far below: the largest seen in 20 CPU hanchan was
516 B (the reply with its call key); a view built by hand with full rivers,
four kans each, long names and fourteen yaku is 908 B. The tests hold every
view under 3800 B.

### Time and saving

- The host draws for the player. A player that does not discard within
  `turn_seconds` discards the drawn tile (the last tile after a call); a call
  not made within `call_seconds` is passed.
- After every change the table is written to `state_dir/<table>.json`
  (written to a temporary file and renamed). The deadline is saved as the
  time left; a host stopped with SIGTERM saves the time left at that moment,
  a host killed gives the player the time left at the last change.

## riichi_engine 0.1.0

The engine runs the rounds (wall, deal, draws, discards, calls, riichi, wins,
yaku, points) and the CPUs. Around it, this host corrects what goes wrong
for it in 0.1.0 (each is marked `engine 0.1.0:` in `engine.rb`; the tests
that check the engine's own behaviour say "if this fails, the engine was
fixed"):

1. `evaluate_win` counts the dora on the indicators instead of the tiles
   they point to (and the uradora likewise). The host evaluates with the
   dora tiles.
2. A ron on the last discard never has houtei: the phase is already
   `round_end` when the win is evaluated. The host evaluates with the phase
   of the win.
3. A seat in riichi gets no discard from `available_round_actions` (only a
   tsumo win when it has one), so its turn cannot go on. The host offers the
   drawn tile.
4. The ippatsu chance of a riichi is never cleared by the player's own next
   discard. The host clears it.
5. `Hand#remove` takes the first tile of the same kind: discarding a 5m from
   a hand with the red 0m and a 5m may take the red one (the red five leaves
   the game), and a chi or a pon may move the wrong one. The host puts the
   exact tiles first.
6. A closed or open kan records four copies of the tile named, so a red five
   in it disappears. The host records the tiles that left the hand.
7. The priority check for a call looks at the seat's own other options, so a
   seat that could ron cannot pon instead. The host leaves only the chosen
   action pending.
8. `resolve_pending_action` breaks ties by seat number, not by turn order
   from the discarder (double ron, the "head bump"). The host decides by
   turn order. Double ron itself is not supported (the rule's `double_ron`
   has no effect); the first in turn order wins.
9. `Wall.build` reads the seed with `String#to_i(36)`, which stops at the
   first character outside `0-9a-z`: `"round-001"` and `"round-002"` (the
   README's own example) give the same wall. The host's seeds are 24
   characters of `0-9a-z`.
10. The CPU's discard (normal and hard) sorts the candidates by acceptance
    ascending and takes the first, so it keeps the hand that accepts the
    fewest tiles; in a CPU-only hanchan 8 rounds of 9 ended in a draw. The
    host's CPU (`cpu_level` normal / hard) keeps the most acceptance;
    `engine` uses the engine's choice as it is.

Also seen, not corrected: the README's game type `"tonpuu"` is
`"tonpuusen"` in the code (with `"tonpuu"` the game never ends); a kan does
not shorten the live wall; tobi ends the game below 0 points, not at 0;
`RiichiEngine.loader.eager_load` fails (`riichi_engine/api.rb` defines `API`,
`version.rb` defines `VERSION`, which Zeitwerk expects as `Api` / `Version`);
`tsumo_agari` and `ron_agari` leave the points to the host (the engine's
API says so). A CPU decision takes about 50 ms of CRuby time (the
acceptance count runs the shanten calculation for every tile).

## Tests

```
bundle exec rake test                                   # MJ_GAMES=20 hanchan by default
MJ_GAMES=4 bundle exec rake test                        # quicker
ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 bundle exec rake test   # also through a router
```

- `test_mahjong_games.rb`: MJ_GAMES hanchan by four CPUs in MJ_PROCS
  processes (default 8): no exception, the points add up after every
  round, after every action no seat's view has another seat's hand and
  every view fits in a board's message; and a worst-case view.
- `test_mahjong_rules.rb`: seats and tokens, refusals (no token, a wrong
  token, an action not offered, a stale state), the timeout, saving and
  reading back mid-round (the same view, the same play after), the deadline
  across a restart, and the corrections above.
- `test_network.rb`: the same refusals through a router, with the host in a
  child process (skipped without `ASTERISM_TEST_ROUTER`).

## License

MIT (LICENSE).
