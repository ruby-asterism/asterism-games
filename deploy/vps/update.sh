#!/bin/sh
# Updates (or rolls back) the game host on a server in one command, the
# way the console's deploy/vps/update.sh does: by version, the published
# image ghcr.io/ruby-asterism/asterism-games:<version>. Plain sh, git and
# docker compose: nothing else on the host.
#
#   ./update.sh 0.12.0                 # the version (its tag v0.12.0 and its image)
#   ./update.sh --when-idle 0.12.0     # restart only once nobody sits at a table
#   ./update.sh --build 0.12.0         # build the image here from the tag instead of pulling it
#   ./update.sh --dry-run 0.12.0       # print the steps, change nothing
#
# In order:
#   1. checks: the .env, the checkout has no local changes, the tag
#      v<version> (fetched when missing), docker compose answers, the
#      console's volume and network are there (ASTERISM_PROJECT)
#   2. git checkout of the tag (detached: the compose file and the settings
#      of that version), and the image <GAMES_IMAGE>:<version> pulled (or,
#      with --build, built from the tag with docker-compose.build.yml)
#      while the old host keeps running
#   3. (--when-idle) waits until the running host says nobody sits at any
#      table (bin/asterism-games status --idle), at most --wait-max minutes;
#      when the time runs out nothing is restarted and the checkout is put back
#   4. a copy of the saved tables, in the state volume (before-update/)
#   5. GAMES_VERSION=<version> in .env, docker compose up -d (the tables go
#      on from their saved state: a game in progress is at the same turn,
#      its players' screens come back to it)
#   6. checks that the host runs on the new image and answers its status
#   7. prints how to go back (this script with the old version)
# When something fails before the restart, the checkout is put back as it
# was and the running host is not touched.
#
# Options:
#   -C DIR          the deploy/vps directory (default: this script's directory)
#   --env-file F    the .env (default: DIR/.env)
#   --sudo          run docker (and git / sed when needed) with sudo
#   --build         build the image here (docker-compose.build.yml) instead of pulling it
#   --when-idle     restart only when nobody sits at a table (see 3)
#   --wait-max MIN  minutes --when-idle waits at most (default 360)
#   --dry-run       print what it would do
#
# Paths must not contain spaces. Docs: docs/install.md, "Updating".

usage() {
  sed -n '2,/^# Paths must/p' "$SELF" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf '\nupdate.sh: %s\n' "$*" >&2; exit 1; }

act() {
  say "+ $*"
  [ "$DRY" = 1 ] || "$@" || die "failed: $*"
}

compose() {
  # shellcheck disable=SC2086
  $SUDO docker compose --env-file "$ENV_FILE" -f "$DIR/docker-compose.yml" "$@"
}

act_compose() {
  say "+ ${SUDO:+$SUDO }docker compose $*"
  [ "$DRY" = 1 ] || compose "$@" || die "failed: docker compose $*"
}

env_value() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed "s/^[\"']//; s/[\"']\$//"
}

set_env() {
  if grep -q "^$1=" "$ENV_FILE"; then
    act $ESUDO sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    say "+ echo $1=$2 >> $ENV_FILE"
    [ "$DRY" = 1 ] || printf '%s=%s\n' "$1" "$2" | $ESUDO tee -a "$ENV_FILE" >/dev/null || die "could not write $ENV_FILE"
  fi
}

undo() {
  [ "$ARMED" = 1 ] || return 0
  ARMED=0
  printf '\nupdate.sh: stopped; putting the checkout back (%s); the running host was not restarted\n' "$OLD_REF" >&2
  $GIT -C "$TOP" -c advice.detachedHead=false checkout -q "$OLD_REF" || say "  could not check out $OLD_REF again: do it by hand" >&2
}

main() {
  ARMED=0
  DIR=""
  ENV_FILE=""
  SUDO=""
  DRY=0
  IDLE=0
  BUILD=0
  WAIT_MAX=360
  VERSION=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) DIR=$2; shift 2 ;;
      --env-file) ENV_FILE=$2; shift 2 ;;
      --sudo) SUDO=sudo; shift ;;
      --build) BUILD=1; shift ;;
      --when-idle) IDLE=1; shift ;;
      --wait-max) WAIT_MAX=$2; shift 2 ;;
      --dry-run|-n) DRY=1; shift ;;
      -h|--help) usage 0 ;;
      -*) say "update.sh: unknown option $1" >&2; usage 2 ;;
      *) [ -z "$VERSION" ] || die "one version only ($VERSION, $1)"; VERSION=$1; shift ;;
    esac
  done
  [ -n "$VERSION" ] || usage 2
  VERSION=${VERSION#v}
  printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' || die "not a version: $VERSION (e.g. 0.12.0)"
  printf '%s\n' "$WAIT_MAX" | grep -Eq '^[0-9]+$' || die "--wait-max takes minutes"

  [ -n "$DIR" ] || DIR=$(cd "$(dirname "$SELF")" && pwd)
  DIR=$(cd "$DIR" && pwd) || die "no directory $DIR"
  [ -f "$DIR/docker-compose.yml" ] || die "$DIR is not deploy/vps of asterism-games; give it with -C"
  cd "$DIR" || die "cannot enter $DIR"
  [ -n "$ENV_FILE" ] || ENV_FILE="$DIR/.env"
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE (cp env.example .env; docs/install.md)"
  ESUDO=""
  [ -w "$ENV_FILE" ] || ESUDO=$SUDO

  step "Checks"
  TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || die "$DIR is not in a git checkout of asterism-games"
  GIT=git
  [ -w "$TOP/.git" ] || GIT="$SUDO git"
  $GIT -C "$TOP" diff --quiet HEAD -- || die "the checkout $TOP has local changes (git status); commit or drop them first"
  OLD_REF=$($GIT -C "$TOP" symbolic-ref -q --short HEAD || $GIT -C "$TOP" rev-parse HEAD)
  TAG="v$VERSION"
  if ! $GIT -C "$TOP" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    depth=""
    [ "$($GIT -C "$TOP" rev-parse --is-shallow-repository)" = true ] && depth="--depth 1"
    # shellcheck disable=SC2086
    act $GIT -C "$TOP" fetch -q $depth origin "refs/tags/$TAG:refs/tags/$TAG" ||
      die "no tag $TAG (git fetch failed; is $VERSION released?)"
  fi
  $SUDO docker compose version >/dev/null 2>&1 || die "docker compose does not answer (try --sudo)"
  PROJECT=$(env_value ASTERISM_PROJECT)
  [ -n "$PROJECT" ] || PROJECT=asterism
  $SUDO docker volume inspect "${PROJECT}_rooms" >/dev/null 2>&1 ||
    die "no volume ${PROJECT}_rooms: is the console's stack (project $PROJECT) set up? (ASTERISM_PROJECT in .env)"
  $SUDO docker network inspect "${PROJECT}_router" >/dev/null 2>&1 ||
    die "no network ${PROJECT}_router: start the console's stack first"
  IMAGE=$(env_value GAMES_IMAGE)
  [ -n "$IMAGE" ] || IMAGE=ghcr.io/ruby-asterism/asterism-games
  FROM=$(env_value GAMES_VERSION)
  RUNNING=0
  [ -n "$(compose ps -q games 2>/dev/null)" ] && RUNNING=1
  if [ "$BUILD" = 1 ]; then how="built here from $TAG"; else how="pulled"; fi
  say "  $DIR (checkout $TOP at $OLD_REF), the console's project $PROJECT"
  say "  game host ${FROM:-(none)} -> $VERSION ($IMAGE:$VERSION, $how)"
  [ "$IDLE" = 0 ] || say "  restart: when nobody sits at a table (at most $WAIT_MAX minutes)"
  [ "$DRY" = 0 ] || say "  dry run: nothing below is run"

  ARMED=1
  trap undo EXIT
  step "The files and the image of $VERSION"
  act $GIT -C "$TOP" -c advice.detachedHead=false checkout -q "$TAG"
  if [ "$BUILD" = 1 ]; then
    say "+ ${SUDO:+$SUDO }env GAMES_VERSION=$VERSION docker compose -f docker-compose.yml -f docker-compose.build.yml build games"
    if [ "$DRY" = 0 ]; then
      $SUDO env GAMES_VERSION="$VERSION" docker compose --env-file "$ENV_FILE" -f "$DIR/docker-compose.yml" \
        -f "$DIR/docker-compose.build.yml" build games ||
        die "the image did not build (the host was not restarted)"
    fi
  else
    say "+ ${SUDO:+$SUDO }env GAMES_VERSION=$VERSION docker compose pull games"
    if [ "$DRY" = 0 ]; then
      $SUDO env GAMES_VERSION="$VERSION" docker compose --env-file "$ENV_FILE" -f "$DIR/docker-compose.yml" pull games ||
        die "could not pull $IMAGE:$VERSION (is $VERSION published? --build builds it here; the host was not restarted)"
    fi
  fi

  if [ "$IDLE" = 1 ] && [ "$RUNNING" = 1 ]; then
    step "Waiting until nobody sits at a table"
    if [ "$DRY" = 1 ]; then
      say "(would ask the running host every 30 s: bin/asterism-games status --idle)"
    else
      waited=0
      until compose exec -T games bundle exec bin/asterism-games status --idle; do
        [ $? -eq 2 ] && say "  (the host does not answer its status: going on)" && break
        [ "$waited" -ge $((WAIT_MAX * 60)) ] && die "still busy after $WAIT_MAX minutes: nothing restarted (run again later)"
        sleep 30
        waited=$((waited + 30))
      done
    fi
  fi

  if [ "$RUNNING" = 1 ]; then
    step "A copy of the saved tables (in the state volume, before-update/)"
    act_compose exec -T games sh -c 'rm -rf /state/before-update && mkdir -p /state/before-update && cp -a /state/rooms /state/permanent /state/before-update/ 2>/dev/null; date -u > /state/before-update/taken_at; true'
  fi

  ARMED=0
  step "Restart"
  set_env GAMES_VERSION "$VERSION"
  act_compose up -d games

  step "Check"
  if [ "$DRY" = 1 ]; then
    say "(would wait until the host runs on $IMAGE:$VERSION and answers its status)"
  else
    tries=0
    until compose exec -T games bundle exec bin/asterism-games status; do
      tries=$((tries + 1))
      [ "$tries" -ge 30 ] && die "the host does not answer after 60 s (docker compose logs games)"
      sleep 2
    done
    img=$($SUDO docker inspect -f '{{.Config.Image}}' "$(compose ps -q games)")
    [ "$img" = "$IMAGE:$VERSION" ] || die "the host runs $img, not $IMAGE:$VERSION"
  fi
  trap - EXIT

  step "Done: game host $VERSION"
  if [ -n "$FROM" ] && [ "$FROM" != "$VERSION" ]; then
    if printf '%s\n' "$FROM" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+'; then
      say "To go back: sh $DIR/update.sh -C $DIR $FROM (the image $IMAGE:$FROM is kept)"
    else
      say "Before: $FROM (an image built from a checkout; to go back, a version: sh $DIR/update.sh -C $DIR <version>)"
    fi
  fi
  say "The saved tables before this update: /state/before-update/ in the state volume"
  say "Old images stay for going back; list them: ${SUDO:+$SUDO }docker image ls $IMAGE"
}

SELF=$0
# The whole script is read before it runs (main), so the checkout of
# another version may replace this file while it runs.
main "$@"; exit $?
