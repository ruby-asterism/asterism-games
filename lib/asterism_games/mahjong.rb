# frozen_string_literal: true

# The mahjong game (README "The mahjong table") on the framework
# (asterism_games): the table (rules, seats, views, time) and its exposed
# object. Requiring this registers the game "mahjong". riichi_engine (the
# fork, README "riichi_engine") is needed here, never by the framework.
require_relative "../asterism_games"
require_relative "mahjong/table"
require_relative "mahjong/remote"

AsterismGames::Mahjong::Table.remote(AsterismGames::Mahjong::Remote)
