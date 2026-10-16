# frozen_string_literal: true

require_relative "../remote"

module AsterismGames
  module Mahjong
    # The mahjong table as an Asterism object (<node>/<app>/<table>), on
    # the framework's Remote: join, mine and leave come from there, the
    # rest is the table's own. Every method takes the caller's node ID as
    # from: (Asterism fills it in; README "Who called" of asterism).
    #
    #   join(name)                  -> {"token", "seat", "owner"} or {"error" => "full"}
    #   mine                        -> the same for a node that joined, or nil
    #                                  (in a room {"error" => "identity"} for a
    #                                  caller that is neither a seat nor the
    #                                  host's, README "Who joins")
    #   sit(token, seat)            -> "ok" or why not (seat -1: any free seat)
    #   stand(token)                -> "ok" or why not
    #   cpu(token, seat, on)        -> "ok" or why not (the owner; seat -1: every empty seat)
    #   start(token)                -> "ok" or why not (the owner, four seats taken)
    #   rule(token, item, value)    -> "ok" or why not (the owner, in the lobby:
    #                                  a local rule, README "Local rules")
    #   view(token, assist)         -> the member's view (Hash) or {"error" => "token"};
    #                                  assist: the level of help its screen
    #                                  shows (README "Assist", 0-3)
    #   act(token, sv, type, tiles) -> "ok" or why not ("token", "stale",
    #                                  "not offered", "not playing", "not seated")
    #   table                       -> the public view (no hand; as a spectator sees it)
    #   leave(token)                -> true / false
    #
    # The same node gets its membership and token back from join. Every
    # call by a member counts as a sign that it is there (away_ms).
    class Remote < AsterismGames::Remote
      METHODS = exposes(join: 1, mine: 0, sit: 2, stand: 1, cpu: 3, start: 1, rule: 3, view: 2, act: 4, table: 0,
                        leave: 1)

      def sit(token, seat, from: nil)
        mark(token, from)
        @game.sit(token, seat.to_i, now)
      end

      def stand(token, from: nil)
        mark(token, from)
        @game.stand(token)
      end

      def cpu(token, seat, on, from: nil)
        mark(token, from)
        @game.cpu(token, seat.to_i, on ? true : false)
      end

      def start(token, from: nil)
        mark(token, from)
        @game.start(token, now)
      end

      def rule(token, item, value, from: nil)
        mark(token, from)
        @game.set_rule(token, item.to_i, value.to_i)
      end

      def view(token, assist, from: nil)
        mark(token, from)
        lv = assist.to_i.clamp(Table::ASSIST_LEVELS.min, Table::ASSIST_LEVELS.max)
        v = @game.member_view(token, now, lv)
        v || { "error" => "token" }
      end

      def act(token, sv, type, tiles, from: nil)
        mark(token, from)
        names = tiles.is_a?(String) ? Tiles.unpack(tiles) : Array(tiles).map(&:to_s)
        @game.act(token, sv.to_i, type.to_i, names, now)
      rescue KeyError, IndexError
        "not offered"
      end

      def table(from: nil)
        @game.spectator_view(now)
      end
    end
  end
end
