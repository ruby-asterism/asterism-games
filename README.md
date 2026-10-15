# asterism-games

Game hosts for [Asterism](https://github.com/ruby-asterism/asterism): a
CRuby process that joins a Zenoh network as an Asterism node, holds the
state of the games and lets players on boards (Family mruby), browsers and
PCs play through Asterism calls. The first game is riichi mahjong (four
players; seats nobody takes are played by CPUs), built on the
[riichi_engine](https://github.com/HenrikStephensen/riichi_engine) gem (a
fork with fixes, see "riichi_engine" below).

Status: Step 1 of the mahjong plan: one human and three CPUs at a table, on
a local network. Not published yet.

| Path | What |
|---|---|
| `bin/asterism-games` | the host |
| `lib/asterism_games/host.rb` | the connection, the loop, the puts, the game registry (`Host::GAMES`) |
| `lib/asterism_games/config.rb` | the settings (file and environment) |
| `lib/asterism_games/store.rb` | saved states, one JSON file per table |
| `lib/asterism_games/mahjong/` | the mahjong table: `table.rb` (seats, rounds, views, time), `engine.rb` (the calls into riichi_engine), `remote.rb` (the exposed object), `tiles.rb` (tile numbers) |
| `config/example.yml` | settings to copy |
| `test/` | the tests (`rake test`) |

## Running

CRuby 3.2 or newer and a C compiler (asterism-zenoh compiles its extension),
and the riichi_engine fork cloned next to this repository as
`../riichi_engine` with its `fmrb` branch (see "riichi_engine").

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

asterism comes from rubygems at a fixed version (0.7.1); riichi_engine from
the `fmrb` branch of a clone at `../riichi_engine` (see "riichi_engine"
below).

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
| `cpu_level` | `MAHJONG_CPU_LEVEL` | `normal` | `easy` / `normal` / `hard` (riichi_engine's CPU levels) |
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

## riichi_engine

The engine runs the rounds (wall, deal, draws, discards, calls, riichi, wins,
yaku, points) and the CPUs. The host uses a fork of 0.1.0 with its errors
fixed: the `fmrb` branch of a clone of
[riichi_engine](https://github.com/HenrikStephensen/riichi_engine) next to
this repository (`../riichi_engine`; `Gemfile` takes it as a local git
source, so the lockfile pins a revision). Each fix is a branch of its own
(`fix/*`), written to be sent upstream; `fmrb` merges them (version
`0.1.1.fmrb1`, not published). The host has no corrections of its own around
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

The fork compares its win evaluation with the Python package `mahjong`
(PyPI) on 30 000 random winning hands and one or more hands per yaku
(`spec/compat/`): the yaku, han, fu and payments agree except where a rule
differs (two yakuman in one hand score as one yakuman in riichi_engine, as
two in the Python package).

Exhaustive draws in CPU-only hanchan: with 0.1.0, 341 of 452 rounds (75 %)
with the engine's own CPU, 127 of 496 (26 %) with the host's corrected CPU;
with the fork's own CPU, 85 of 488 (17 %) at normal and 97 of 496 (20 %) at
hard over 40 hanchan each, and 72 of 282 (26 %) in the 20 normal hanchan of
one `rake test`.

Still as in 0.1.0: a kan does not shorten the live wall; tobi ends the game
below 0 points, not at 0; several yakuman in one hand score as one;
`tsumo_agari` and `ron_agari` leave the points to the host (the engine's API
says so). A CPU decision takes about 50 ms of CRuby time (the acceptance count
runs the shanten calculation for every tile).

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
  across a restart, and the engine fixes the host relies on (dora, houtei,
  red fives, a riichi seat's discard, pon over ron, head bump, seeds).
- `test_network.rb`: the same refusals through a router, with the host in a
  child process (skipped without `ASTERISM_TEST_ROUTER`).

## License

MIT (LICENSE).
