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
   --wss://router.example.org:7443/room-->  nginx --> door --TLS as room-<slot>--> zenohd tls/7448
                                                                                     ^
 asterism-games (project "asterism-games")                                           |
   supervisor  reads /rooms/rooms.json (which rooms are open, what they open)        |
   + one host process per room that opens the table --TLS as room-<slot>, namespace room/<slot>
   + one host process for the permanent tables -------TLS as games (its own .tar), no namespace
   GET /status on 7460 <-- the console (the rooms' page)
   /state (its volume): rooms/<slot>/, permanent/ the saved tables <-- the console's daily backup (read-only)
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
  room slots made and applied.
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

## 4. Build and start

```
./update.sh main          # builds the image asterism-games:main-<commit> and starts it
```

`update.sh` checks the checkout and the console's volume and network,
builds the image (bundler takes the riichi_engine fork at the revision
`Gemfile.lock` pins), writes `GAMES_VERSION` and `GAMES_REF` in `.env`,
starts the container and waits until it answers its status. By hand, the
same is `docker compose build && docker compose up -d`.

```
docker compose ps                                          # games: running (healthy)
docker compose exec games bundle exec bin/asterism-games status
docker compose logs --tail 20 games                        # "games: rooms from /rooms/rooms.json ..."
```

## 5. The console's side

In the console's `deploy/vps`:

1. `.env`: the apps a room may open, mahjong among them (env.example of
   0.2.2):

   ```
   ASTERISM_ROOM_APPS=Othello=/app/test/othello.app.rb,Mahjong=/app/game/mahjong/mahjong.app.rb
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
   and `room 01: games: games/games up (mahjong1) via credentials in room/01`.
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
     `asterism/${node}/games/**`, `asterism/${node}/@profile`; Watch
     `asterism/**`; not for browsers.
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

## 8. Updating

From `deploy/vps`:

```
./update.sh --when-idle main      # build first, restart when nobody sits at a table
./update.sh v0.3.1                # a tag
./update.sh --dry-run main        # print the steps
```

The image is built while the old host runs. With `--when-idle` the script
waits (at most `--wait-max` minutes, 360) until the running host says
nobody sits at any table, then copies the saved tables to
`/state/before-update/` in the volume and restarts. Without it the restart
is at once: the tables are saved on every change, so a game in progress goes
on from the same turn after a few seconds, and the players' screens come
back to it by themselves. To go back, run it with the old ref (it prints
it); the old image stays (`docker image ls asterism-games`).

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
back; the host removes the others. The permanent tables always do. The
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
