# frozen_string_literal: true

module AsterismGames
  module Mahjong
    # The table as an Asterism object (<node>/<app>/<table>). Its methods run
    # from Asterism.poll on the host's loop and never wait.
    #
    #   join(name[, secret])        -> {"token", "seat", "owner"} or {"error" => "full"}
    #   mine([secret])              -> the same for a node that joined, or nil
    #                                  (secret: the browser's in a room, README
    #                                  "Who joins"; {"error" => "identity"} when
    #                                  the node ID does not come from it)
    #   sit(token, seat)            -> "ok" or why not (seat -1: any free seat)
    #   stand(token)                -> "ok" or why not
    #   cpu(token, seat, on)        -> "ok" or why not (the owner; seat -1: every empty seat)
    #   start(token)                -> "ok" or why not (the owner, four seats taken)
    #   rule(token, item, value)    -> "ok" or why not (the owner, in the lobby:
    #                                  a local rule, README "Local rules")
    #   view(token[, assist])       -> the member's view (Hash) or {"error" => "token"};
    #                                  assist: the level of help its screen
    #                                  shows (README "Assist", 0-3; default 1)
    #   act(token, sv, type, tiles) -> "ok" or why not ("token", "stale",
    #                                  "not offered", "not playing", "not seated")
    #   table                       -> the public view (no hand; as a spectator sees it)
    #   leave(token)                -> true / false
    #
    # The caller is Asterism.current_call.from (the node ID in the call's
    # key); the same node gets its membership and token back from join. Every
    # call by a member counts as a sign that it is there (away_ms).
    class Remote
      # view takes one or two arguments (-1: the arguments are not counted).
      # join and mine take an optional secret (README "Who joins").
      METHODS = { join: -1, mine: -1, sit: 2, stand: 1, cpu: 3, start: 1, rule: 3, view: -1, act: 4, table: 0, leave: 1 }.freeze

      def initialize(table, clock)
        @table = table
        @clock = clock
      end

      def caller_node
        c = ::Asterism.current_call
        c ? c.from.to_s : ""
      end

      def join(name, secret = nil)
        @table.join(caller_node, name.to_s, @clock.call, secret)
      end

      def mine(secret = nil)
        node = caller_node
        r = @table.mine(node, secret)
        @table.touch(node, @clock.call) if r && !r["error"]
        r
      end

      def sit(token, seat)
        mark(token)
        @table.sit(token, seat.to_i, @clock.call)
      end

      def stand(token)
        mark(token)
        @table.stand(token)
      end

      def cpu(token, seat, on)
        mark(token)
        @table.cpu(token, seat.to_i, on ? true : false)
      end

      def start(token)
        mark(token)
        @table.start(token, @clock.call)
      end

      def rule(token, item, value)
        mark(token)
        @table.set_rule(token, item.to_i, value.to_i)
      end

      def view(token, assist = nil)
        mark(token)
        lv = assist.nil? ? Table::ASSIST_DEFAULT : assist.to_i.clamp(Table::ASSIST_LEVELS.min, Table::ASSIST_LEVELS.max)
        v = @table.member_view(token, @clock.call, lv)
        v || { "error" => "token" }
      end

      def act(token, sv, type, tiles)
        mark(token)
        names = tiles.is_a?(String) ? Tiles.unpack(tiles) : Array(tiles).map(&:to_s)
        @table.act(token, sv.to_i, type.to_i, names, @clock.call)
      rescue KeyError, IndexError
        "not offered"
      end

      def table
        @table.spectator_view(@clock.call)
      end

      def leave(token)
        @table.leave(token)
      end

      private

      # A call with a member's token from that member's own node.
      def mark(token)
        node = @table.node_of(token)
        @table.touch(node, @clock.call) if node && node == caller_node
      end
    end
  end
end
