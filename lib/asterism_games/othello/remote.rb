# frozen_string_literal: true

require_relative "../remote"

module AsterismGames
  module Othello
    # The othello table as an Asterism object (<node>/<app>/<table>), on
    # the framework's Remote (join, mine, leave). Every method takes the
    # caller's node ID as from: (Asterism fills it in).
    #
    #   join(name)              -> {"token", "seat", "owner"} or {"error" => why}
    #   mine                    -> the same for a node that joined, or nil
    #   sit(token, seat)        -> "ok" or why not (seat -1: the free seat)
    #   stand(token)            -> "ok" or why not
    #   cpu(token, seat, on)    -> "ok" or why not (the owner; seat -1: every seat;
    #                              on: true, false or an AI player of the view's "ak")
    #   start(token)            -> "ok" or why not (the owner, both seats taken)
    #   move(token, n, square)  -> "ok" or why not ("token", "stale", "illegal",
    #                              "not your turn", "not playing", "not seated");
    #                              n: the view's "n", square: "d3"
    #   resign(token)           -> "ok" or why not
    #   view(token)             -> the table's view and "me" (the member's seat), or {"error" => "token"}
    #   table                   -> the table's view (what the state key has)
    #   leave(token)            -> true / false
    class Remote < AsterismGames::Remote
      METHODS = exposes(join: 1, mine: 0, sit: 2, stand: 1, cpu: 3, start: 1, move: 3, resign: 1, view: 1, table: 0,
                        leave: 1)
      object_doc "An othello table (two seats). join, sit, then view / move in a loop."
      docs sit: [%w[token seat], "Takes seat 0 or 1 (-1: the free one), in the lobby. \"ok\" or why not."],
           stand: [%w[token], "Gives the seat up, in the lobby."],
           cpu: [%w[token seat on], "The owner (the first to sit): on true puts a CPU in the empty seat (-1: every " \
                                    "empty seat), false takes it out; on \"jev\" (one of the view's ak) puts that AI " \
                                    "player there, or turns the seat's CPU into it (true turns it back)."],
           start: [%w[token], "The owner starts the game once both seats are taken (the colours are drawn)."],
           move: [%w[token n square], "Plays square (\"d3\": column a-h, row 1-8) as the seat to move. n is the " \
                                      "view's \"n\" (moves so far), so a move meant for an older board is refused " \
                                      "(\"stale\"). \"ok\" or why not."],
           resign: [%w[token], "Resigns the game."],
           view: [%w[token], "The table: st (wait, play, over), nm names, sk seats (0 empty, 1 member, 2 CPU), " \
                             "bd the board (64 of . B W, a1 b1 .. h8), tn the seat to move (-1), n moves so far, " \
                             "lg the legal squares of the side to move (\"d3c4\"), cnt [black, white], " \
                             "res the result, me your seat, ai the seats' AI players (\"jev\"), ak the AI players the owner may seat. Seat 0 is black (B), seat 1 white (W): the seats are drawn at the start."],
           table: [[], "The table's view without me (what the state key has)."]

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

      def move(token, n, square, from: nil)
        mark(token, from)
        @game.move(token, n, square.to_s, now)
      end

      def resign(token, from: nil)
        mark(token, from)
        @game.resign(token, now)
      end

      def view(token, from: nil)
        mark(token, from)
        @game.member_view(token, now) || { "error" => "token" }
      end

      def table(from: nil)
        @game.public_view(now)
      end
    end
  end
end
