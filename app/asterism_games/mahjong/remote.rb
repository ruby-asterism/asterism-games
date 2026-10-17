# frozen_string_literal: true

require "asterism_games/remote"

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
    #   cpu(token, seat, on)        -> "ok" or why not (the owner; seat -1: every empty seat;
    #                                  on: an AI player's name puts it in, README "AI players")
    #   start(token)                -> "ok" or why not (the owner, four seats taken)
    #   rule(token, item, value)    -> "ok" or why not (the owner, in the lobby:
    #                                  a local rule, README "Local rules")
    #   view(token, assist)         -> the member's view (Hash) or {"error" => "token"};
    #                                  assist: the level of help its screen
    #                                  shows (README "Assist", 0-3)
    #   act(token, sv, type, tiles) -> "ok" or why not ("token", "stale",
    #                                  "not offered", "not playing", "not seated")
    #   table                       -> the public view (no hand; as a spectator sees it)
    #   describe                    -> how to play from a program (a text; README
    #                                  "Playing from a program")
    #   look(token)                 -> the seat's view in words, with its moves numbered
    #   choose(token, sv, n)        -> plays move n of look ("ok" or why not)
    #   points(token)               -> what the hand would score
    #   leave(token)                -> true / false
    #
    # The same node gets its membership and token back from join. Every
    # call by a member counts as a sign that it is there (away_ms).
    class Remote < AsterismGames::Remote
      METHODS = exposes(join: 1, mine: 0, sit: 2, stand: 1, cpu: 3, start: 1, rule: 3, view: 2, act: 4, table: 0,
                        describe: 0, look: 1, choose: 3, points: 1, leave: 1)
      object_doc "A riichi mahjong table (four seats). From a program: call describe first, then join, sit, " \
                 "and look / choose in a loop."
      docs sit: [%w[token seat], "Takes seat 0-3 (-1: any free one), in the lobby. \"ok\" or why not."],
           stand: [%w[token], "Gives the seat up, in the lobby. \"ok\" or why not."],
           cpu: [%w[token seat on], "The owner (the first to sit): on true puts a CPU in the empty seat (seat -1: " \
                                    "every empty seat), false takes a CPU or AI player out; a name the lobby offers " \
                                    "(look's \"ai_players\": \"claude\", \"jev\") puts that AI player in."],
           start: [%w[token], "The owner starts the game once the four seats are taken. \"ok\" or why not."],
           rule: [%w[token item value], "The owner sets a local rule in the lobby: item 0 the game (0 hanchan, " \
                                        "1 east only), see describe. \"ok\" or why not."],
           view: [%w[token assist], "The member's view in the table screens' short keys and tile bytes " \
                                    "(assist 0-3: the help shown). Programs read look instead."],
           act: [%w[token sv type tiles], "Plays an action in the screens' numbers. Programs use choose instead."],
           table: [[], "The public view (no hand), as a spectator sees it, in the screens' short keys."],
           describe: [[], "How to play from a program and what look returns (a text). Read it first."],
           look: [%w[token], "The table as this member's seat sees it, in words: hand, rivers, melds, scores, " \
                             "dora indicators, and \"moves\" (numbered) when it is the seat's decision. See describe."],
           choose: [%w[token sv n], "Plays the move numbered n of look's \"moves\", with the \"sv\" of that look. " \
                                    "\"ok\", or why not (\"stale\": look again)."],
           points: [%w[token], "What the seat's hand would score: the win offered now, or each wait of a tenpai hand " \
                               "by ron and tsumo (no ura dora, furiten not checked)."]

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
        @game.cpu(token, seat.to_i, on.is_a?(String) ? on : (on ? true : false))
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

      # README "Playing from a program".
      def describe(from: nil)
        Table::DESCRIPTION
      end

      def look(token, from: nil)
        mark(token, from)
        node = @game.node_of(token)
        return { "error" => "token" } unless node
        v = @game.look_public(@game.seat_index(node) || -1, now)
        v["ai_players"] = @game.ai_kinds if @game.status == "wait" && !@game.ai_kinds.empty?
        v
      end

      def choose(token, sv, n, from: nil)
        mark(token, from)
        @game.choose(token, sv, n, now)
      end

      def points(token, from: nil)
        mark(token, from)
        @game.points_of(@game.seat_of(token))
      end
    end
  end
end
