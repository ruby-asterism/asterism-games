# The game host's image (asterism-games), built on the server from this
# checkout (deploy/vps/update.sh, or docker compose build): CRuby, the
# gems of Gemfile.lock and the host. Built by hand from the repository's
# root:
#   docker build -f deploy/vps/Dockerfile -t asterism-games:dev .
#
# riichi_engine is the fork's revision pinned in Gemfile.lock (a git
# source: bundler checks out exactly that commit); asterism comes from
# rubygems at the version the Gemfile pins, and asterism-zenoh compiles its
# C extension against the zenoh-c release it pins, downloaded while the
# image is built.
ARG RUBY_VERSION=3.2.6
FROM ruby:${RUBY_VERSION}-slim AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential curl git pkg-config unzip ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV BUNDLE_WITHOUT=test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

FROM ruby:${RUBY_VERSION}-slim

ARG GAMES_VERSION=dev
LABEL org.opencontainers.image.title="asterism-games" \
      org.opencontainers.image.description="Game hosts for Asterism: mahjong tables in the rooms of an Asterism console" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${GAMES_VERSION}"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV BUNDLE_WITHOUT=test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1 \
    ASTERISM_GAMES_IMAGE_VERSION=${GAMES_VERSION}

WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

# The host runs as 1000, the console's "rails": the room slots'
# certificates in the console's "rooms" volume are that user's (0600).
RUN groupadd --system --gid 1000 host && useradd --uid 1000 --gid 1000 --no-create-home host && \
    mkdir -p /state && chown host:host /state
USER 1000:1000

EXPOSE 7460
CMD ["bundle", "exec", "bin/asterism-games"]
