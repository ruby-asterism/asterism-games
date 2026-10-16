# frozen_string_literal: true

# The othello game (README "The othello table") on the framework
# (asterism_games): the rules and the CPU (othello/board), the table and
# its exposed object. Requiring this registers the game "othello". It
# needs nothing but the framework.
require_relative "../asterism_games"
require_relative "othello/board"
require_relative "othello/table"
require_relative "othello/remote"

AsterismGames::Othello::Table.remote(AsterismGames::Othello::Remote)
