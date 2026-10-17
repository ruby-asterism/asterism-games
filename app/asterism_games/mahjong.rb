# frozen_string_literal: true

# The mahjong game (README "The mahjong table") on the framework
# (asterism_games): the table (rules, seats, views, time) and its exposed
# object. Requiring this registers the game "mahjong". riichi_engine (the
# fork, README "riichi_engine") is needed here, never by the framework.
#
# It is an application on the gem, not a part of it: app/ (this checkout
# and the image) is outside the gem's files, and its files require the
# framework by its name (require "asterism_games"), as a game of anyone's
# own would. bin/asterism-games puts app/ on the load path when it is there.
require "asterism_games"
require_relative "mahjong/table"
require_relative "mahjong/remote"

AsterismGames::Mahjong::Table.remote(AsterismGames::Mahjong::Remote)
