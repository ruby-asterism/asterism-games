# deploy/vps: the game host on a server

The game host next to an Asterism console (its `deploy/vps`), serving
tables in the console's rooms. **The steps are in
[docs/install.md](../../docs/install.md).**

| File | |
|---|---|
| `docker-compose.yml` | the host (project `asterism-games`): the console's `rooms` volume (read-only) and `router` network by name, its own `state` volume |
| `Dockerfile` | the image, built here from the checkout (riichi_engine at the revision `Gemfile.lock` pins) |
| `env.example` | the settings, copied to `.env` (never committed) |
| `update.sh` | build and restart in one command; `--when-idle` restarts only when nobody sits at a table |

The console's `deploy/vps/docker-compose.games.yml` (console 0.2.2) gives
the console the host's status and puts the host's volume into its daily
backup.
