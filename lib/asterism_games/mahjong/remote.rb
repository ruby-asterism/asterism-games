# frozen_string_literal: true

module AsterismGames
  module Mahjong
    # The table as an Asterism object (<node>/<app>/<table>). Its methods run
    # from Asterism.poll on the host's loop and never wait.
    #
    #   sit(name)                  -> {"seat", "token"} or {"error" => "full"}
    #   view(token)                -> the seat's view (Hash) or {"error" => "token"}
    #   act(token, sv, type, tiles) -> "ok" or why not ("token", "stale",
    #                                  "not offered", "not playing")
    #   table                      -> the public view (no hand)
    #   leave(token)               -> true / false
    #
    # The caller of sit is Asterism.current_call.from (the node ID in the
    # call's key); the same node gets its seat and token back. Everything
    # about a hand needs the token sit returned.
    class Remote
      METHODS = { sit: 1, view: 1, act: 4, table: 0, leave: 1 }.freeze

      def initialize(table, clock)
        @table = table
        @clock = clock
      end

      def sit(name)
        c = ::Asterism.current_call
        @table.sit(c ? c.from.to_s : "", name.to_s, @clock.call)
      end

      def view(token)
        seat = @table.seat_of(token)
        return { "error" => "token" } unless seat
        @table.view(seat, @clock.call)
      end

      def act(token, sv, type, tiles)
        names = tiles.is_a?(String) ? Tiles.unpack(tiles) : Array(tiles).map(&:to_s)
        @table.act(token, sv.to_i, type.to_i, names, @clock.call)
      rescue KeyError, IndexError
        "not offered"
      end

      def table
        @table.public_view(@clock.call)
      end

      def leave(token)
        @table.leave(token)
      end
    end
  end
end
