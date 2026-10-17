# deploy/vps: the game host on a server

The game host next to an Asterism console (its `deploy/vps`), serving
tables in the console's rooms and, with a certificate of its own,
permanent tables for the registered boards and browsers. **The steps are in
[docs/install.md](../../docs/install.md).**

| File | |
|---|---|
| `docker-compose.yml` | the host (project `asterism-games`) on the published image `ghcr.io/ruby-asterism/asterism-games:<version>`: the console's `rooms` volume (read-only) and `router` network by name, its own `state` volume |
| `docker-compose.build.yml` | to build the image here instead of pulling it |
| `Dockerfile` | the image (the CI builds it for each tag `v<version>`; riichi_engine at the revision `Gemfile.lock` pins) |
| `env.example` | the settings, copied to `.env` (never committed) |
| `credentials/` | the host's own `.tar` from the console for the permanent tables (never committed; docs/install.md section 7) |
| `update.sh` | pull a version's image and restart in one command (`--build` builds it here); `--when-idle` restarts only when nobody sits at a table |

The console's `deploy/vps/docker-compose.games.yml` (console 0.2.2) gives
the console the host's status and puts the host's volume into its daily
backup.
