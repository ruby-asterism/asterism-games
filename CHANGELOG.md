# Changelog

Versions before 0.11.1 are noted in the README where each feature is
described ("games 0.10.0" and the like).

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
