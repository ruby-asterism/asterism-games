# asterism-games

Game hosts for [Asterism](https://github.com/ruby-asterism/asterism): a
CRuby process that joins a Zenoh network as an Asterism node, holds the
state of the games and lets players on boards (Family mruby), browsers and
PCs play through Asterism calls. The first game is riichi mahjong (four
players; seats nobody takes are played by CPUs), built on the
[riichi_engine](https://github.com/HenrikStephensen/riichi_engine) gem (a
fork with fixes, see "riichi_engine" below).

Status: Step 2 of the mahjong plan: up to four players at a table (a lobby
to sit and start, calls by several players decided together, players that
drop out played for after a short wait until they are back), two tables at once, on a local
network. Not published yet.

| Path | What |
|---|---|
| `bin/asterism-games` | the host |
| `bin/mahjong-bots` | players without screens, for trying a table (one process each) |
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
`games/games/mahjong1` and `games/games/mahjong2` (the default settings). Ctrl-C (or SIGTERM) saves and stops. Started again,
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
| `tables` | | two tables `mahjong1`, `mahjong2` | each `{name, game: mahjong, ...}` |

A mahjong table takes (the environment applies to every table):

| Key | Environment | Default | |
|---|---|---|---|
| `turn_seconds` | `MAHJONG_TURN_SECONDS` | 20 | a player's time to discard; after it the drawn tile is discarded |
| `call_seconds` | `MAHJONG_CALL_SECONDS` | 8 | the time to call a discard, the same for every player who may; after it the call is passed |
| `result_seconds` | `MAHJONG_RESULT_SECONDS` | 8 | a round's result stays this long (or until a player presses next) |
| `over_seconds` | `MAHJONG_OVER_SECONDS` | 60 | the end of a game stays this long (or until the owner presses next), then the table is back in its lobby |
| `away_seconds` | `MAHJONG_AWAY_SECONDS` | 10 | a member that has not called the table this long is shown as away |
| `away_wait_seconds` | `MAHJONG_AWAY_WAIT_SECONDS` | 2 | an away member's time to discard or to call, instead of `turn_seconds` / `call_seconds` |
| `cpu_ms` | `MAHJONG_CPU_MS` | 700 | a CPU's pause before it acts |
| `cpu_level` | `MAHJONG_CPU_LEVEL` | `normal` | `easy` / `normal` / `hard` (riichi_engine's CPU levels) |
| `humans` | | 4 | seats members may take (0: four CPUs that play at once, for tests) |
| `rule` | | (below) | riichi_engine rule keys over the host's defaults ("Rules") |

## The mahjong table

### Methods

| Method | Arguments | Returns |
|---|---|---|
| `join` | name | `{"token", "seat" (-1: none), "owner"}`, or `{"error" => "full"}` (16 members) |
| `mine` | none | the same for a node that joined, or nil (nothing is created) |
| `sit` | token, seat | `"ok"` or why not (`"taken"`, `"not waiting"`, ...); seat -1: the first free one. In the lobby only; a seated member moves |
| `stand` | token | `"ok"` or why not (lobby only) |
| `cpu` | token, seat, on | the owner: a CPU into an empty seat (on) or out of it; seat -1 with on fills every empty seat |
| `start` | token | the owner, once the four seats are taken and one is a member: the seats are drawn (who deals first) and the game starts |
| `view` | token[, assist] | the member's view (below), or `{"error" => "token"}`; assist: the help its screen shows (Assist, 0-3; without it 1) |
| `act` | token, sv, type, tiles | `"ok"`, or why not: `"token"`, `"not seated"`, `"stale"` (sv is not the current one), `"not offered"`, `"not playing"` |
| `table` | none | the public view (no hand) |
| `leave` | token | `true` / `false`; in the lobby the seat empties, during a game it goes to a CPU |

- People join a table and wait in its lobby (`"st" => "wait"`): a member
  sits in a seat or watches. The first member who sat is the owner (when the
  owner stands or leaves, the member seated longest takes over). The owner
  fills empty seats with CPUs and starts. At the end of a game the owner's
  next (or `over_seconds`) brings the table back to the lobby with the same
  seats, for another game.
- The node that calls is the caller in the call's key
  (`Asterism.current_call.from`). The same node gets its membership and
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

- Shanten: seven pairs and kokushi are riichi_engine's own counts (its CPU's
  `Cpu::Analysis::Shanten`); the regular form is the host's
  (`Engine.shanten`). The engine's count takes the hand as all there is, so
  it is wrong once there are melds (three sets and a single tile next to a
  meld is tenpai, the engine says 2-shanten), and it takes about 50 ms a
  turn for the acceptance. The host counts each suit apart (once per suit
  pattern) with the melds as sets already made; for a closed hand it gives
  the engine's number (the tests compare 3000 random hands), with melds
  tenpai is what the wait judge says.
- Time (CRuby, one seat's help at one state, one process): over 4 CPU
  hanchan with seats at levels 1, 2 and 3, median 0.9 ms, 95 % 4.5 ms, at
  most 30 ms (the first ones, before the suit patterns are known; `rake
  test` prints the `assist:` line).

### Calls on a discard

When several seats may call a discard (ron, pon, chi, open kan), every one
of them answers once: a CPU at once, a player by `act` (a call or pass), or a
pass when `call_seconds` (counted from the discard, the same deadline for
everybody) run out. An answer is final (the seat's list is empty after it).
Once all have answered, riichi_engine's priority decides: ron over pon and
open kan over chi; several rons by the rule (double ron; three rons are a
draw, sanchahou), equal calls in turn order from the discarder. The players
see the choices exactly as the engine lists them.

### Players that drop out

A member that has not called the table for `away_seconds` (its screen asks
its view every 3 s) is away: the public view marks its seat (`"aw"`) and the
member list. While it is away its seat is played for after a short wait:
`away_wait_seconds` from the start of its turn or of the calls (the drawn
tile is discarded, a call is passed), instead of `turn_seconds` and
`call_seconds`, so the others are not held up a whole turn every time. The
other players keep their own times (in the calls, the away seat passes
early and the rest go on waiting). A wait that started before the member
went away ends as soon as it is seen away, if its short wait is over by
then. Once it calls again it has the full times again; its screen asks its
view and goes on. A seat is never handed to a CPU because its player is
away; a member that leaves (`leave`) during a game is.

### Views

A Hash (MessagePack); tiles are one byte each in binary strings (bin).

| Key | |
|---|---|
| `v` / `sv` | the view's version (any change) / the state version (actions) |
| `t`, `st` | the table's name; `wait` (the lobby), `play`, `result` (a round's result), `over` |
| `nm`, `hu` | the four names (`""` for an empty seat); the human seats as bits |
| `sk` | the four seats: 0 empty, 1 a member, 2 a CPU |
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
| `dl` | `[seats as bits, ms]`: whom the host waits for (one seat's turn, or every seat that may still call) and how long it still waits |
| `res` | at a round's end: `k` (`tsumo_agari`, `ron_agari`, `ryuukyoku`, `kyuushu_kyuuhai`, `sanchahou`), `d` (the four score changes), `f` (who dealt in), `wn` (one entry per winner, in turn order from the discarder: `w` seat, `y` the yaku as riichi_engine names them, in Japanese, `pt` fu, han and points, `h` and `ag` the hand and the winning tile), `tp` (tenpai seats at a draw), `rs` (the seats of the three rons at a sanchahou) |
| `fin` | at the end: `[[seat, rank, score, point x 10], ...]` |
| `me`, `h`, `dt`, `a` | the member's view only: its seat (-1: watching), its hand (sorted, without the drawn tile), the drawn tile (-1 none), what it may do: `[[type, tiles], ...]` |
| `wt` | the member's view only, the help (Assist, levels 1-3): one binary string, per discard the tile, the number of waits n and n pairs `[wait, left]` (the waits as riichi_engine's wait judge gives them; left: 4 less what the seat can see of the tile: its own hand, the rivers, every meld, the dora indicators) |
| `uk` | the member's view only, level 3 when no discard leaves the hand tenpai: one binary string, per discard the tile, the shanten after it, the number n of tiles that bring it down and n pairs `[tile, left]` (left as in `wt`; a tile the seat sees all four of is left out) |

Tile numbers: `0..8` 1m..9m, `9` 0m (red five), `10..18` 1p..9p, `19` 0p,
`20..28` 1s..9s, `29` 0s, `30..36` 1z..7z (east south west north white
green red), `37` back. The same order as the tile sheets of Family mruby's
table screen.

Action types: 1 discard (tiles: what may be discarded; send one), 2 riichi
(tiles: the discards that declare it; send one), 3 tsumo, 4 closed kan, 5
added kan, 6 pon, 7 chi (one entry per pair), 8 open kan, 9 ron, 10 pass,
11 nine kinds, 12 next (after a result; after the end of a game, the owner's
next goes back to the lobby). 13 is only an event (`ev`): three rons, a draw.

### Message size

A board and the browser build (zenoh-pico) take at most 4096 B in one
message, Zenoh's headers and the key included, and drop a larger one without
a word. The views stay far below: the largest seen in 20 CPU hanchan was
about 570 B (the reply with its call key); a view built by hand with full
rivers, four kans each, sixteen members with long names and three winners
with fourteen yaku each is about 1.9 KB. The riichi help adds at most
14 x (2 + 13 x 2) = 392 B (fourteen discards with thirteen waits each, more
than a hand can have; a nine-sided chuuren gives 80 B); a view built by hand
with it, full rivers, the other seats' kans and the long names is about
1.5 KB. The acceptance (`uk`, level 3) adds at most 14 x (3 + 34 x 2) =
994 B (every kind after every discard, more than a hand can have; random
hands give at most about 250 B, 20 CPU hanchan at most 762 B with a view of
1,043 B); the same view built by hand with it is about 2.1 KB. `wt` and `uk` never come together. The tests hold every view
under 3800 B.

### Time and saving

- The host draws for the player. A player that does not discard within
  `turn_seconds` discards the drawn tile (the last tile after a call); a call
  not made within `call_seconds` is passed.
- One host process holds every table of its settings (two by default); each
  is saved to its own file and goes on by itself.
- After every change the table is written to `state_dir/<table>.json`
  (written to a temporary file and renamed), with the members, the seats and
  the owner (a restarted host keeps the lobby too). The deadline is saved as the
  time left; a host stopped with SIGTERM saves the time left at that moment,
  a host killed gives the player the time left at the last change.

## Rules

The host's defaults follow Mahjong Soul's default rules (its four-player
ranked games and the defaults of a friends' room) wherever riichi_engine can
choose; the engine's own defaults stay as they are and the host passes its
values (`Engine::RULE_DEFAULTS`). A table's `rule` setting goes over them.
Where the engine cannot choose, the table says so: those rules are left for
later. "Not sure" marks what could not be confirmed.

| Rule | Mahjong Soul's default | riichi_engine | Choosable | The host's default |
|---|---|---|---|---|
| Open tanyao (kuitan) | yes | `kuitan` (true) | yes | true |
| Atozuke | yes | `atozuke` (true) | key only (not used by the engine) | (true) |
| Red fives | one each of 5m 5p 5s | `aka_dora` (1/1/1) | yes | 1/1/1 |
| Ippatsu, ura dora, kan dora, kan ura | yes | always | no | yes |
| When a kan dora shows | at once for a closed kan, after the discard for an open or added kan (not sure) | at once for every kan | no | at once (later) |
| Double ron | yes | `double_ron` (true) | yes (fork `fix/multiple-ron`) | true |
| Three rons | all three win (no sanchahou) | `triple_ron_draw` (true) | yes (fork `fix/multiple-ron`) | **false: all three win** (as Mahjong Soul) |
| Honba and sticks at a double ron | to the first winner from the discarder | the host's scoring | (host) | to the first winner |
| Dealer at a double ron | keeps the seat if one of the winners | `GameFlow` (winners) | (engine) | as the engine |
| Abortive draws | nine kinds, four winds, four kans, four riichi; the dealer keeps the seat | nine kinds only (the others are documented, not implemented) | no | nine kinds (the others later) |
| Double yakuman hands (suuankou tanki, kokushi 13-wait, junsei chuuren, daisuushii) | count double | `double_yakuman` (false; not used) | no | single (later) |
| Several yakuman in one hand | added up | `multiple_yakuman` (false) | yes (fork `feat/multiple-yakuman`) | true |
| Kazoe yakuman (13 han) | yes | `kazoe_yakuman` (true) | yes | true |
| Kiriage mangan | no | `kiriage_mangan` (false) | yes | false |
| Nagashi mangan | yes | none | no | none (later) |
| Pao (liability) | daisangen, daisuushii (not sure about others) | none | no | none (later) |
| Tobi | yes; 0 points goes on, below 0 ends | `tobi` (true, below 0) | yes | true |
| West round (south round in a tonpuu game) | when nobody has 30,000 after the last round; sudden death, ends after west 4 | `nishi_iri` (false), `nishi_iri_threshold` (30,000); the engine goes on past west 4 | yes (the host ends the game after west 4) | true, 30,000 |
| Agari-yame, tenpai-yame | both, for the last dealer in the lead (not sure: above 30,000 only) | agari-yame always (dealer in the lead, above 0); no tenpai-yame | no | the engine's agari-yame |
| Starting points, first place target | 25,000, 30,000 | `initial_score` (25,000), `oka_origin` (30,000) | yes | 25,000, 30,000 |
| Uma and oka | friends' room: 5-15 (+15/+5/-5/-15) and the oka to the top (not sure; ranked games use rank points instead) | `uma` (20/10/-10/-20) | yes | 15/5/-5/-15 |
| Thinking time | 5 s a turn plus a 20 s bank (friends' room) | none (the host's timers) | (host) | 20 s a turn, 8 s a call (`turn_seconds`, `call_seconds`; no bank) |

## riichi_engine

The engine runs the rounds (wall, deal, draws, discards, calls, riichi, wins,
yaku, points) and the CPUs. The host uses a fork of 0.1.0 with its errors
fixed: the `fmrb` branch of a clone of
[riichi_engine](https://github.com/HenrikStephensen/riichi_engine) next to
this repository (`../riichi_engine`; `Gemfile` takes it as a local git
source, so the lockfile pins a revision). Each fix is a branch of its own
(`fix/*`, `feat/*`), written to be sent upstream; `fmrb` merges them (version
`0.1.1.fmrb2`, not published). The host has no corrections of its own around
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

The fork compares its win evaluation with the Python package `mahjong`
(PyPI) on 30 000 random winning hands and one or more hands per yaku
(`spec/compat/`): the yaku, han, fu and payments agree except where a rule
differs (two yakuman in one hand score as one yakuman in riichi_engine, as
two in the Python package; with `multiple_yakuman` they agree).

Exhaustive draws in CPU-only hanchan: with 0.1.0, 341 of 452 rounds (75 %)
with the engine's own CPU, 127 of 496 (26 %) with the host's corrected CPU;
with the fork's own CPU, 85 of 488 (17 %) at normal and 97 of 496 (20 %) at
hard over 40 hanchan each, and 72 of 282 (26 %) in the 20 normal hanchan of
one `rake test`.

Still as in 0.1.0: a kan does not shorten the live wall; tobi ends the game
below 0 points, not at 0; the west round never ends without a player above
the threshold (the host ends the game after west 4);
`tsumo_agari` and `ron_agari` leave the points to the host (the engine's API
says so). A CPU decision takes about 50 ms of CRuby time (the acceptance count
runs the shanten calculation for every tile).

## Tests

```
bundle exec rake test                                   # MJ_GAMES=20 CPU hanchan, MJ_HUMAN_GAMES=1 four-player hanchan
MJ_GAMES=4 bundle exec rake test                        # quicker
ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 bundle exec rake test   # also through a router
```

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
- `test_network.rb`: the same refusals through a router, with the host in a
  child process (skipped without `ASTERISM_TEST_ROUTER`).

`bin/mahjong-bots` fills a table with players over the network (to try a
second table, or the host under load): `bundle exec bin/mahjong-bots
--table games/games/mahjong2`.

## License

MIT (LICENSE).
