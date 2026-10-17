# frozen_string_literal: true

require_relative "../remote"

module AsterismGames
  module Board
    # The drawing board as an Asterism object (<node>/<app>/<board>), on
    # the framework's Remote (join, mine, leave). Every method takes the
    # caller's node ID as from: (Asterism fills it in).
    #
    #   join(name)              -> {"token", "owner"} or {"error" => why}
    #   line(token, c, w, pts)  -> {"id" => stroke id} or why not
    #   more(token, id, pts)    -> "ok" or why not
    #   undo(token)             -> "ok" or why not ("nothing")
    #   clear(token)            -> "ok" or why not ("not owner")
    #   picture(id, at)         -> a page of the picture (Table#picture)
    #   view(token)             -> the board's view, "own" and "mine", or {"error" => "token"}
    #   table                   -> the board's view (what the state key has)
    class Remote < AsterismGames::Remote
      METHODS = exposes(join: 1, mine: 0, line: 4, more: 3, undo: 1, clear: 1, picture: 2, view: 1, table: 0,
                        leave: 1)
      object_doc "A shared drawing board (#{Table::WIDTH}x#{Table::HEIGHT}). join, then line / more to draw; " \
                 "the strokes go out on the board's strokes key."
      docs join: [%w[name], "Joins the board as name (or gets this node's membership back). Returns " \
                            "{\"token\", \"owner\"}: every later call brings the token. The first to join " \
                            "is the owner, who may clear the board."],
           line: [%w[token c w pts], "Starts a stroke: colour c 0-#{Table::COLORS - 1}, width step w " \
                                     "0-#{Table::WIDTHS - 1}, pts [x, y, ...] (1-#{Table::PART_POINTS} points, " \
                                     "x 0-#{Table::WIDTH - 1}, y 0-#{Table::HEIGHT - 1}). {\"id\" => id} or why not."],
           more: [%w[token id pts], "More points of your stroke id (your newest one): up to " \
                                    "#{Table::LINE_POINTS} points a stroke. \"ok\" or why not."],
           undo: [%w[token], "Takes back your last stroke still on the board. \"ok\" or \"nothing\"."],
           clear: [%w[token], "The owner clears the board. \"ok\" or \"not owner\"."],
           picture: [%w[id at], "A page of the picture from stroke id (0: the first) and its point at: " \
                                "{\"v\", \"n\" strokes, \"p\" => [[id, c, w, [x, y, ...], k], ...], \"nx\" => " \
                                "[id, at] of the next page or nil}. k 1: the points start with the stroke's " \
                                "point before at."],
           view: [%w[token], "The board: n strokes, np points, last the newest stroke's id, mb [name, flags " \
                             "(1 away, 2 owner)], lim [width, height, colours, widths, points a message, " \
                             "points a stroke, strokes, points], own (you are the owner), mine (your strokes)."],
           table: [[], "The board's view without own and mine (what the state key has)."]

      def line(token, c, w, pts, from: nil)
        mark(token, from)
        @game.line(token, c, w, pts)
      end

      def more(token, id, pts, from: nil)
        mark(token, from)
        @game.more(token, id, pts)
      end

      def undo(token, from: nil)
        mark(token, from)
        @game.undo(token)
      end

      def clear(token, from: nil)
        mark(token, from)
        @game.clear(token)
      end

      def picture(id, at, from: nil)
        @game.picture(id, at)
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
