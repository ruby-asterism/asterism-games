# The game host on a server

The game host (`bin/asterism-games`) next to an Asterism console on a
server (a VPS), serving a mahjong table in each room that opens the table's
screen (README "Rooms") and, if you want, permanent tables for the boards
and browsers registered with the console (README "Permanent tables",
section 7). The console's installation comes first: its
`docs/install.md`, with rooms set up (its section 12, "Rooms") and its
`deploy/vps` running as the compose project `asterism`.

Names and addresses below are placeholders: `router.example.org`,
`play.example.org`, `192.0.2.10` for the server.

## 1. What runs

```
 browsers (a room's link)                        the console's stack (project "asterism")
   --wss://router.example.org:7443/room-->  nginx --> door --TLS as room-<slot>-s<seat>--> zenohd tls/7448
                                                                                     ^
 asterism-games (project "asterism-games")                                           |
   supervisor  reads /rooms/rooms.json (which rooms are open, what they open, seats) |
   + one host process per room that opens the table --TLS as games (its own .tar), namespace room/<slot>
                                                      (a console before 0.3.0: as room-<slot>)
   + one host process for the permanent tables -------TLS as games (its own .tar), no namespace
   GET /status on 7460 <-- the console (the rooms' page)
   /state (its volume): rooms/<slot>/, permanent/ the saved tables,      <-- the console's daily backup (read-only)
                        records.sqlite3 the games' records (+ records-backup.sqlite3, its copy)
   /credentials (deploy/vps/credentials/, read-only): games.tar

 boards (P4-Nano, Tab5) --tls/router.example.org:7448, their own certificates--> zenohd
 browsers with a pass  --wss://router.example.org:7443--> nginx --> zenohd ws/
```

- The game host is a compose project of its own (`deploy/vps/docker-compose.yml`,
  project `asterism-games`). It uses the console's volume `asterism_rooms`
  (read-only: `rooms.json` and the slots' certificates) and the console's
  network `asterism_router` by name; it publishes no port on the server.
- Nothing changes for nginx, the firewall or DNS: the host is a client of
  zenohd inside the server, like the door.
- Memory: about 45 MB for the supervisor and 45-50 MB for each room with a
  table (2 rooms with 4 players each: 136-140 MB in all), and as much for
  the permanent tables' process (51 MB RSS, 24 MB of it its own, with two tables in play). The container's limit is
  `GAMES_MEM_LIMIT` (384 MB), and `GAMES_ROOM_MAX` (3) rooms have tables at
  once.

## 2. What you need

- The console 0.2.2 or later running (`docker compose ps` in its
  `deploy/vps` shows zenohd, door, console, bridge, signer, backup), with
  room slots made and applied. With the console 0.3.0 (seats), the host
  needs its own certificate for the rooms too: section 7's `games.tar`
  (the same row), section 8 "From 0.4.0 to 0.5.0".
- About 400 MB of free memory and 300 MB of disk for the image.
- git and Docker with compose v2.24 or later, as for the console.

## 3. Get the files

Next to the console's checkout (the examples use `/srv/asterism`):

```
cd /srv/asterism
git clone <the asterism-games repository> asterism-games
cd asterism-games/deploy/vps
cp env.example .env && chmod 600 .env
```

`.env` (env.example says what each line is): `ASTERISM_PROJECT=asterism`
(the console's project), `GAMES_ROOM_MAX`, `GAMES_MEM_LIMIT`, and the
tables' times (`MAHJONG_TURN_SECONDS` and the rest, README "Settings").
The rules are the host's defaults (README "Rules").

## 4. Pull and start

The image is published for each version on the GitHub Container Registry
(`ghcr.io/ruby-asterism/asterism-games:<version>`, also `:<major>.<minor>`
and `:latest`; amd64 and arm64), built by the repository's CI from the tag
`v<version>`. It holds the whole host: the framework, the games (mahjong
with the riichi_engine fork at the revision `Gemfile.lock` pins, othello,
the drawing board) and `config/rooms.yml`.

```
./update.sh 0.12.0        # checks out v0.12.0, pulls its image and starts it
```

`update.sh` checks the checkout and the console's volume and network,
checks out the version's tag (the compose file and the settings of that
version), pulls the image, writes `GAMES_VERSION` in `.env`, starts the
container and waits until it answers its status. By hand, the same is
`git checkout v0.12.0`, `GAMES_VERSION=0.12.0` in `.env`, then
`docker compose pull && docker compose up -d`.

### Building the image yourself

Instead of pulling, build it here from the checkout
(`docker-compose.build.yml`, the same Dockerfile the CI builds):

```
docker compose -f docker-compose.yml -f docker-compose.build.yml build
docker compose up -d
```

Give it a name of your own in `.env` first (`GAMES_IMAGE=asterism-games-local`),
so a later pull does not replace it. `./update.sh --build 0.12.0` does the
same from the version's tag.

```
docker compose ps                                          # games: running (healthy)
docker compose exec games bundle exec bin/asterism-games status
docker compose logs --tail 20 games                        # "games: rooms from /rooms/rooms.json ..."
```

## 5. The console's side

In the console's `deploy/vps`:

1. `.env`: the apps a room may open, the tables' screens among them (the
   othello table's since games 0.7.0, the drawing board's since 0.11.0):

   ```
   ASTERISM_ROOM_APPS=Othello=/app/test/othello.app.rb,Mahjong=/app/game/mahjong/mahjong.app.rb,Othello (table)=/app/game/othello/othello.app.rb,Board=/app/game/board/board.app.rb
   ```

2. Add `docker-compose.games.yml` to the compose files. It gives the
   console the host's status (`ASTERISM_GAMES_STATUS_URL`, the rooms' page
   shows each room's tables) and mounts the host's saved tables into the
   backup service (`ASTERISM_BACKUP_EXTRA`). Either in `.env`:

   ```
   COMPOSE_FILE=docker-compose.yml:docker-compose.games.yml
   ```

   or with `-f` on every command (and `update.sh -f docker-compose.yml -f
   docker-compose.games.yml`). The file needs the volume
   `asterism-games_state`, which section 4 made.

3. `docker compose up -d` (the console and the backup service are made
   again with the new settings).

## 6. Check

1. Admin > Rooms says "The game host (asterism-games 0.3.0, up since ...)".
2. Make a room with "Opens: Mahjong". Within a second the host's log says
   `room 01: room <id> opens /app/game/mahjong/mahjong.app.rb: host pid ...`
   and `room 01: games: games/games up (mahjong1) via tls/zenohd:7448 in room/01`
   (with a console 0.3.0 the line before ends "(its own certificate
   games.tar, 16 seats; mahjong1)"). A room with "Opens: Othello (table)"
   gets `othello1` instead (0.7.0: a room gets the tables of the game its
   link opens), and one with "Opens: Board" the drawing board `board1`.
   The rooms' list shows `mahjong1: in its lobby, 0 seated ...`.
3. Open the room's link: the table screen lists `games/games/mahjong1`.
   Sit, fill the empty seats with CPUs (the owner's C) and start.
4. The graph (Rooms on) shows the room's frame with the node `games` and its
   object `mahjong1`, next to the pages in the room.
5. Close the room: the host's log says the host stopped and the room's
   tables were removed.

## 7. Permanent tables (optional)

Tables outside the rooms, for the boards that connect to the console's
router with their own certificates and for the browsers with a pass
(README "Permanent tables"). The host joins the router with a certificate
of its own, a row of the console's registry.

1. **In the console** (Admin > Relay; the templates and what they keep
   closed: the console's docs/rooms.md, "A game host's permanent tables";
   console 0.2.3 shows the tables on the rooms' page):
   - Roles > New role `games-host`: Read and write `asterism/${node}`,
     `asterism/${node}/games/**`, `asterism/${node}/@profile`,
     `asterism/${node}/*/@status` (the tables' counts, README "Status"),
     `asterism/${node}/spectate`, `asterism/${node}/spectate/**` (the
     tables watched from outside, README "Spectate"); Read
     `asterism/*/game` (the players' table apps: the host sees them leave
     at once, README "Who is there"); Watch `asterism/**`; not for browsers.
   - Roles > New role `games`: Read `asterism/*/games/**`; Ask
     `asterism/*/games/*/call/${node}` and `asterism/*/games/*/meta`;
     browsers have this role; Opens in a browser page
     `/app/game/mahjong/mahjong.app.rb`.
   - The boards' rows (e.g. `fmruby-aaaaaa`): Edit, tick `games` next to
     `match`.
   - Register: kind `client`, name `games`, role `games-host`. Open it,
     "Issue a certificate", "Save all (.tar)": `games.tar`.
   - Apply (the banner "Review and apply").
2. **On the server**, put the file next to this checkout's compose file
   (the container's user is 1000):

   ```
   cd /srv/asterism/asterism-games/deploy/vps
   install -m 600 -o 1000 -g 1000 ~/games.tar credentials/games.tar     # sudo if you are not uid 1000
   echo 'ASTERISM_GAMES_PERMANENT_CREDENTIALS=/credentials/games.tar' >> .env
   docker compose up -d                                                  # the host starts again with it
   ```

   Copy the file to the server as you would a private key (scp, then
   remove the copy in your downloads). `credentials/` is never committed
   (its `.gitignore`).
3. **Check**:

   ```
   docker compose logs --tail 20 games      # "permanent: host pid ..." and
                                            # "permanent: games: games/games up (mahjong1, mahjong2) via tls/zenohd:7448"
   docker compose exec games bundle exec bin/asterism-games status
                                            # "permanent tables (games): up, mahjong1 wait (0 seated ...)"
   ```

   The console's rooms page says "Permanent tables of the node games ...:
   up", the graph shows `games` with `mahjong1` and `mahjong2` on the
   registered side, and a board's table screen (or "Open the browser
   build" with the mahjong table) lists `games/mahjong1` and
   `games/mahjong2`.

A host that says `permanent: no readable /credentials/games.tar` waits for
the file (the rooms go on). Issuing a new certificate for the row: put the
new `.tar` in place and `docker compose restart games`. To stop the
permanent tables, take the line out of `.env` and `docker compose up -d`;
their saved tables stay in `/state/permanent/`.

### AI players (optional)

A table's owner can seat Claude and Jev next to the CPUs (README "AI
players") when the host has their keys. They are read from `.env` (the
host gets every line as its environment) and go nowhere else. Jev's key
comes from TypeSafe's console (console.typesafe.ai): sign in, open Keys
and create one; it is shown once, so put it straight into `.env`.

1. In `deploy/vps`, check that `.env` is `-rw-------` (`chmod 600 .env`).
2. Add the keys you have (an editor on the server, not a command line that
   your shell's history keeps):

   ```
   ANTHROPIC_API_KEY=...              # Claude (console.anthropic.com, an API key)
   TYPESAFE_API_KEY=...               # Jev (console.typesafe.ai, Keys: create an API key)
   ASTERISM_GAMES_AI_DAILY_USD=3.0    # the most they may cost a day
   ```

   Or a limit for each kind (0.15.0; a kind stops alone when its own money
   of the day reaches it, README "AI players"):

   ```
   ASTERISM_GAMES_AI_DAILY_USD_CLAUDE=10
   ASTERISM_GAMES_AI_DAILY_USD_JEV=2
   ```

3. `docker compose up -d games`. The log says
   `games: AI players: claude, jev (at most $3.0 a day, 400 decisions a seat in a game)`
   (with the kinds' limits: `at most $10.0 a day for claude, $2.0 for jev`);
   the table apps' lobby shows `+Claude` / `+Jev` to the owner.

`./update.sh` keeps `.env`. What they cost is in the volume
(`/state/ai_usage.json`, per day) and in `bin/asterism-games status`
(`docker compose exec games bin/asterism-games status`). To stop them,
take the keys out of `.env` and `docker compose up -d games`: the seated AI
players' moves go to the CPU from the next decision. A key that leaked:
revoke it at its service first, then replace the line.

## 8. Updating

From `deploy/vps`:

```
./update.sh --when-idle 0.12.0    # pull first, restart when nobody sits at a table
./update.sh 0.12.1                # a version (its tag v0.12.1 and its image)
./update.sh --build 0.12.1        # build the image here from the tag instead of pulling it
./update.sh --dry-run 0.12.1      # print the steps
```

The image is pulled (or built) while the old host runs. With `--when-idle` the script
waits (at most `--wait-max` minutes, 360) until the running host says
nobody sits at any table, then copies the saved tables to
`/state/before-update/` in the volume and restarts. Without it the restart
is at once: the tables are saved on every change, so a game in progress goes
on from the same turn after a few seconds, and the players' screens come
back to it by themselves. To go back, run it with the old version (it
prints it); the old image stays (`docker image ls ghcr.io/ruby-asterism/asterism-games`).

### From 0.20.0 to 0.20.1 (a message of play)

Nothing to do on a server: only `asterism-games play`'s message changes.

### From 0.19.1 to 0.20.0 (watch games)

`./update.sh 0.20.0` (or `--when-idle 0.20.0`). Nothing in `.env`. The
mahjong tables gain watch games (README "Watch games"): a new method
`watch` on the table object, which the players' roles already reach (the
calls go on the table's call key, as every other method). The AI players
of a watch game spend the same daily money as any game
(`ASTERISM_GAMES_AI_DAILY_USD` and the per-kind limits); lower them first
if watch games should not use more of it. `ASTERISM_GAMES_AI_CALLS_PER_GAME`
(400) now counts each AI seat's decisions of a game, not the game's: a
game with four AI seats may ask up to 1600 (README "AI players"). The table apps of Family mruby
show the button only with a 0.20.0 host; older screens work as before
against it.

### From 0.19.0 to 0.19.1 (where to get VOICEVOX)

Nothing to do on a server: only the commentary's messages change.

### From 0.18.0 to 0.19.0 (the commentary in the browser)

Nothing to do on a server: the host and the tables are the same as
0.18.0's. The version adds `asterism-games commentate mahjong` (README
"Commentary"), which a watcher runs on their own PC with a `viewer` or
`spectator` certificate; it reads the spectate keys 0.18.0 puts.

### From 0.17.1 to 0.18.0 (the tables watched from outside)

`./update.sh 0.18.0` (or `--when-idle 0.18.0`). Nothing in `.env`. The
host puts the mahjong tables' spectate view (README "Spectate") on
`asterism/<node>/spectate/<table>/state`. For the router to let it
through, add two lines to the role `games-host` in the console (Admin >
Members > Roles, "Read and write"): `asterism/${node}/spectate` and
`asterism/${node}/spectate/**`, then Apply. Who may read it is a role of
its own (`spectator`, or the `viewer` role): the console's docs/rooms.md,
"Watching the tables from outside". Until the role has the lines the
router drops the puts; the tables, the rooms and the players' screens are
as before either way. A room's host opens one more connection to the
router for it (the same certificate).

### From 0.17.0 to 0.17.1 (the gem without othello-tty)

Nothing to do on a server: the host and the tables are the same as
0.17.0's. `bin/othello-tty` is gone (`asterism-games play othello` is
it), and 0.17.1 is the first version on rubygems.org
(`gem install asterism-games`).

### From 0.16.3 to 0.17.0 (asterism-games play, Jev at the othello table)

`./update.sh 0.17.0` (or `--when-idle 0.17.0`). Nothing in `.env`. The
version adds the terminal clients (`asterism-games play othello`, `play
mahjong`; README "Playing in a terminal"), which players run on their own
machines, and Jev at the othello table with the key the mahjong tables
already use (README "AI players").

### From 0.16.2 to 0.16.3 (asterism 0.8.0)

`./update.sh 0.16.3` (or `--when-idle 0.16.3`). Nothing in `.env`. The
image has asterism 0.8.0, which the host uses for its `@status`, for
who is there and for the methods' texts in the meta; nothing the players
see changes.

### From 0.16.1 to 0.16.2 (the owner away, a table left alone)

`./update.sh 0.16.2` (or `--when-idle 0.16.2`). Nothing in `.env`. A
mahjong table's owner away for a minute hands the role to a member who
is there, and a game whose seated humans have all been away for three
minutes (or have left) goes back to the lobby without a record (README
"Players that drop out"). Other times, in `.env`:
`MAHJONG_OWNER_HANDOVER_SECONDS` and `MAHJONG_ABANDON_SECONDS` (0 turns
either off). With the console 0.3.9 a page of a room opened again in the
same browser comes back as the same seat; the order of the updates does
not matter.

### From 0.16.0 to 0.16.1 (the table shows the host's version)

`./update.sh 0.16.1` (or `--when-idle 0.16.1`). Nothing in `.env`. The
mahjong table's view carries the host's version (`hv`), which the table
apps show on the list of tables and the lobby.

### From 0.15 to 0.16.0 (the rooms of an invite link see each other's records)

0.16.0 lets the rooms made through one invite link of the console list and
replay each other's mahjong game records (README "Game records"). It needs
the console 0.3.8, which writes each such room's group to `rooms.json`;
with an older console nothing changes.

1. `./update.sh 0.16.0` (or `--when-idle 0.16.0`). Nothing in `.env`.
2. On its first start the host adds the column `grp` to the records'
   database (`/state/records.sqlite3`); it takes no time and the format
   stays 1. The games already kept have no group and stay their own
   room's.
3. The console may be updated before or after. A room that is open while
   the console is updated gets its group at its host's next start (a
   restart of the games host, e.g. this update after the console's).

Going back to 0.15.0 (`./update.sh 0.15.0`) keeps the database as it is:
0.15.0 ignores the column and gives each room its own games again.

### From 0.14 to 0.15.0 (a daily limit per AI kind)

0.15.0 lets each kind of AI player have a daily limit of its own (README
"AI players"). Without the new lines nothing changes.

1. Add the limits to `.env` (an editor on the server), for example:
   ```
   ASTERISM_GAMES_AI_DAILY_USD_CLAUDE=10
   ASTERISM_GAMES_AI_DAILY_USD_JEV=2
   ```
   `ASTERISM_GAMES_AI_DAILY_USD` may stay: it is the limit of a kind
   without a line of its own (the day's total of every kind).
2. `./update.sh 0.15.0` (or `--when-idle 0.15.0`). The host reads `.env`
   when it starts, so the update's restart takes the new lines in.
3. The log says
   `games: AI players: claude, jev (at most $10.0 a day for claude, $2.0 for jev, 400 decisions a game)`.
   A value it cannot read is said there too (`... is not a number of
   dollars (0 or more); ignored ...`), and that kind follows
   `ASTERISM_GAMES_AI_DAILY_USD`.

Going back to 0.14.0 ignores the two lines (the total's limit applies to
all again); `ai_usage.json` keeps the same form.

0.15.0 also changes how a round starts and ends at a table with humans
(README "Result"): the round's name shows for 2 s after the deal, and a
result waits until every player there has pressed OK (the screens'
"next"), or moves on by itself 10 s after its count. Nothing to do on
the server; the screens of before (a board's flash, the browser build)
play as they did, their "next" being their OK. Two optional lines in
`.env` change the times (seconds; `MAHJONG_RESULT_SECONDS` now holds
only the tables without humans):
```
MAHJONG_RESULT_AUTO_SECONDS=10
MAHJONG_DEAL_PAUSE_SECONDS=2
```

### From 0.13 to 0.14.0 (the records in SQLite)

0.14.0 keeps the games' records in one SQLite database,
`/state/records.sqlite3` (README "Game records"), with the 1000 newest
games of each table instead of 20, and a room's games kept after the room
closes (for the stats, README "Stats").

- **The records are taken in on the first start.** Each table that has a
  `<table>.records.json` of 0.13.0 (the permanent tables', and the rooms'
  still open) puts its games into the database and renames the file to
  `<table>.records.json.imported`. The log says it once per table
  (`mahjong1: 3 records taken into records.sqlite3 ...`). It takes well
  under a second; nothing is to be done.
- **Going back to 0.13.0** after it: the old host does not read the
  database and finds no `<table>.records.json`, so its tables start with
  no records (the games stay in the database for 0.14.0). To give 0.13.0
  its 20 back, rename the `.imported` files before you start it.
- **The volume grows**: about 17 KB a tonpuu game and 23 KB a hanchan, so
  up to 17-23 MB a table at 1000 games, and the same again for
  `records-backup.sqlite3`, the copy the backups take (section 9). Fewer
  games: `MAHJONG_RECORDS_KEPT` in `.env`.
- The image has the sqlite3 gem; nothing else is needed on the server.

### From 0.11 to 0.12.0 (the published image)

Until 0.11.1 `update.sh` took a ref (a branch, a tag or a commit) and built
the image `asterism-games:<ref>-<commit>` on the server. From 0.12.0 it
takes a version and pulls the published image.

1. In `.env`, set `GAMES_IMAGE=ghcr.io/ruby-asterism/asterism-games` (or
   remove the line: that is the default). Keep `asterism-games` only if
   you build it yourself (then `--build`, "Building the image yourself").
   The `GAMES_REF` line is no longer read.
2. The old `update.sh` cannot pull: take the new one from the tag for this
   once, then update with it:
   ```
   git -C .. fetch -q origin refs/tags/v0.12.0:refs/tags/v0.12.0
   git -C .. show v0.12.0:deploy/vps/update.sh > /tmp/games-update.sh
   sh /tmp/games-update.sh -C "$(pwd)" 0.12.0
   ```
3. The images built before (`asterism-games:main-<commit>`) stay; remove
   them once 0.12.0 runs (`docker image ls asterism-games`).

### From 0.4.0 to 0.5.0 (the console's seats)

0.5.0 joins the rooms with the host's own certificate when the console
lists the host in `rooms.json` (`"hosts"`, the console 0.3.0's
`ASTERISM_ROOM_HOSTS`), and takes a seat's caller as it comes (README "Who
joins"). With a console before 0.3.0 it works as 0.4.0.

1. Update the game host **before** the console: `./update.sh v0.5.0` (or
   `main`). A host 0.4.0 under a console 0.3.0 can no longer write its
   tables in the rooms (the slot's certificate has a deny on the host's
   names).
2. The certificate: `credentials/games.tar` of section 7 (the permanent
   tables' row `games`), named by `ASTERISM_GAMES_PERMANENT_CREDENTIALS`;
   the rooms use it too. Only rooms and no permanent tables: put the file
   there all the same and name it with `ASTERISM_GAMES_ROOM_CREDENTIALS`
   instead (the row needs the role `games-host` only for the permanent
   tables). The row's name must be the host's node in the rooms
   (`rooms.node`, `games`) and in the console's `ASTERISM_ROOM_HOSTS`.
3. Update the console (its docs/install.md, "From 0.2.3 to 0.3.0"). Within
   a second of the console's new `rooms.json` each room's host starts again
   ("the room's seats or hosts changed in rooms.json", then
   "... (its own certificate games.tar, 16 seats; mahjong1)"). Since 0.7.0
   only the seats and the host's names join a room's table (the pages from
   before the seats are refused; `ASTERISM_GAMES_ROOM_SECRET_IDS` is gone).

## 9. Backups and restoring

With `docker-compose.games.yml`, the console's daily backup takes the
host's volume in: the same `.tar.gz` has `extra/games/rooms/<slot>/...`
and `extra/games/permanent/...` (the manifest lists the files). A restore
of the console (`bin/asterism restore`) leaves them alone. To put the
tables back by hand (`rooms` or `permanent` below):

```
cd /srv/asterism/asterism-games/deploy/vps
docker compose stop games
docker run --rm -v asterism_backups:/backups:ro -v asterism-games_state:/state debian:stable-slim \
  sh -c 'cd /tmp && tar xzf /backups/<backup>.tar.gz extra/games && cp -a extra/games/rooms /state/ && chown -R 1000:1000 /state/rooms'
docker compose start games
```

Only rooms still open (the same room on the same slot) take their tables
back; the host removes the others. The permanent tables always do.

**The games' records** (0.14.0): the backup has the database as the host
was writing it (`extra/games/records.sqlite3`, with its `-wal` and `-shm`)
and the consistent copy the host makes after every game,
`extra/games/records-backup.sqlite3`. Restore the copy: put it in the
volume without a database, and the host makes the database from it when it
starts (the log says `records: /state/records.sqlite3 made from
records-backup.sqlite3`):

```
docker compose stop games
docker run --rm -v asterism_backups:/backups:ro -v asterism-games_state:/state debian:stable-slim \
  sh -c 'cd /tmp && tar xzf /backups/<backup>.tar.gz extra/games/records-backup.sqlite3 && \
         rm -f /state/records.sqlite3 /state/records.sqlite3-wal /state/records.sqlite3-shm && \
         cp extra/games/records-backup.sqlite3 /state/ && chown 1000:1000 /state/records-backup.sqlite3'
docker compose start games
```

The games played after the backup are lost with this (the copy is the
day's). Never copy `records.sqlite3` itself out of a backup: it may be
caught in the middle of a write. The
certificate (`credentials/games.tar`) is not in the backup: it is a
private key; issue a new one for the row if it is lost.

## 10. Starting with the server, logs, memory

- `restart: unless-stopped`: Docker starts the host at boot, after the
  console's stack has made its network. A systemd unit is not needed; if
  the console's stack runs under one (its install.md section 19), the same
  example with `WorkingDirectory=/srv/asterism/asterism-games/deploy/vps`
  and `ExecStop=/usr/bin/docker compose stop` works here.
- Stop the game host before `docker compose down` of the console's stack:
  the console's network cannot be removed while the host is on it.
- Logs: `docker compose logs -f games` (json-file, 5 files of 10 MB). One line
  per room opened or closed, per game started, per round, per away seat.
- Memory: `docker stats asterism-games-games-1`. A host process stopped by
  the limit is started again by the supervisor; its table goes on from the
  last change.

## 11. Removing

```
docker compose down            # in asterism-games/deploy/vps
docker volume rm asterism-games_state   # the saved tables (after the console no longer mounts it:
                                         # take docker-compose.games.yml out and docker compose up -d there)
```
