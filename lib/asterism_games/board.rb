# frozen_string_literal: true

# The shared drawing board (README "The drawing board") on the framework
# (asterism_games): one picture that every member draws on, handed out
# as strokes. Requiring this registers the game "board". It needs nothing
# but the framework.
require_relative "../asterism_games"
require_relative "board/table"
require_relative "board/remote"

AsterismGames::Board::Table.remote(AsterismGames::Board::Remote)
