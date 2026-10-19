# frozen_string_literal: true

source "https://rubygems.org"

# asterism: the released gem, pinned. riichi_engine: the fork with the
# fixes (its fmrb branch; README "riichi_engine").
gem "asterism", "0.8.0"
gem "riichi_engine", git: "https://github.com/kishima/riichi_engine.git", branch: "fmrb"
gem "msgpack", "~> 1.7"
# The Claude AI players (README "AI players"); loaded only when
# ANTHROPIC_API_KEY is set.
gem "anthropic", "~> 1.80"
# The games' records in one SQLite database (README "Game records"). Not a
# dependency of the gem: without it the records stay in JSON files.
gem "sqlite3", "~> 2.1"

group :test do
  gem "minitest", "~> 5.0"
  gem "rake", "~> 13.0"
end
