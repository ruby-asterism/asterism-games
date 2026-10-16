# frozen_string_literal: true

# The framework (README "Writing a game"): the host, the rooms'
# supervisor, the settings, the store and the bases of a game (Game,
# Remote). No game is in here; a game is required next to it
# (asterism_games/mahjong) and registers itself.
require_relative "asterism_games/version"
require_relative "asterism_games/game"
require_relative "asterism_games/remote"
require_relative "asterism_games/store"
require_relative "asterism_games/config"
require_relative "asterism_games/host"
require_relative "asterism_games/rooms"
