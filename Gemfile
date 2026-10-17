# frozen_string_literal: true

source "https://rubygems.org"

# asterism: the released gem, pinned. riichi_engine: the fork with the
# fixes (its fmrb branch; README "riichi_engine").
gem "asterism", "0.7.1"
gem "riichi_engine", git: "https://github.com/kishima/riichi_engine.git", branch: "fmrb"
gem "msgpack", "~> 1.7"
# The Claude AI players (README "AI players"); loaded only when
# ANTHROPIC_API_KEY is set.
gem "anthropic", "~> 1.80"

group :test do
  gem "minitest", "~> 5.0"
  gem "rake", "~> 13.0"
end
