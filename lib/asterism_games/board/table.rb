# frozen_string_literal: true

require_relative "../game"

module AsterismGames
  module Board
    # One drawing board (README "The drawing board"): a picture in board
    # coordinates (WIDTH x HEIGHT) made of strokes, each a colour (one of
    # COLORS), a width (one of WIDTHS steps) and a run of points. Nobody
    # wins; every member draws. The first member to join is the owner (the
    # next one in the order of joining when it goes), who alone may clear
    # the board; each member may take back its own last stroke.
    #
    # Handing it out: every change goes out on the board's strokes key
    # (asterism/<node>/<app>/<board>/strokes, Game#tell) as one message:
    #
    #   {"o" => "a", "id", "c", "w", "p" => [x, y, ...], "k", "v"}
    #       points of stroke id: k 0 starts the stroke, k 1 goes on with it
    #       (p then starts with the stroke's last point so far, so every
    #       message draws as a line of its own); at most PART_POINTS points
    #   {"o" => "u", "id", "v"}   stroke id taken back
    #   {"o" => "c", "v"}         the board cleared
    #
    # v is the board's version when it was told. A screen draws these as
    # they come; a recording of the key (the console's) played back puts
    # the same messages again, and a screen draws them the same way (its
    # picture may then differ from the saved one until it reads the
    # picture again, picture). The same messages, so the same size limit:
    # a message stays under the 4096 bytes a board receives (Zenoh's header
    # included): PART_POINTS points of 3-byte coordinates are 1.5 KB.
    #
    # Limits: a stroke has at most LINE_POINTS points (a screen starts a
    # new stroke past it); the board keeps at most MAX_STROKES strokes and
    # MAX_POINTS points, and drops the oldest strokes past either (nothing
    # is told: a screen that keeps the same limits drops them too, and
    # they leave its picture when it is drawn again).
    class Table < AsterismGames::Game
      register "board"
      tables "board1"
      screens "/app/game/board/board.app.rb"
      settings file: { "away_seconds" => ["away_ms", 1000] },
               env: { "BOARD_AWAY_SECONDS" => ["away_ms", 1000] }

      SAVE_FORMAT = 1
      # Strokes come several times a second while somebody draws: the
      # saved picture is written at most once a second (and when the host stops).
      SAVE_HOLD_MS = 1000
      WIDTH = 640
      HEIGHT = 360
      COLORS = 16
      WIDTHS = 4
      PART_POINTS = 256
      LINE_POINTS = 1024
      MAX_STROKES = 1000
      MAX_POINTS = 40_000
      # A page of picture: at most this many points.
      PAGE_POINTS = 400
      KEY = "strokes"

      attr_reader :strokes, :points, :owner

      def initialize(name, opts = {}, store: nil, log: nil)
        super
        @strokes = [] # [{"id", "node", "c", "w", "p" => [x, y, ...]}], oldest first
        @points = 0
        @next_id = 1
        @owner = nil
        @dropped = 0
        load_saved(0)
      end

      # ------------------------------------------------------------ members

      def member_reply(node)
        { "token" => @members[node]["token"], "owner" => @owner == node }
      end

      def join(node, name, now)
        r = super
        if r["token"] && @owner.nil?
          @owner = node.to_s
          r["owner"] = true
        end
        r
      end

      def forget(node)
        super
        pass_owner if @owner == node
      end

      def pass_owner
        @owner = @members.min_by { |_n, m| m["at"].to_i }&.first
      end

      # ------------------------------------------------------------ drawing

      # A new stroke: colour c (0...COLORS), width w (0...WIDTHS), points
      # [x, y, ...] (1..PART_POINTS points). Returns {"id" => id} or why not.
      def line(token, c, w, pts)
        node = node_of(token) or return "token"
        c = int(c)
        w = int(w)
        return "colour" unless c && c >= 0 && c < COLORS
        return "width" unless w && w >= 0 && w < WIDTHS
        pts = clean_points(pts) or return "points"
        s = { "id" => @next_id, "node" => node, "c" => c, "w" => w, "p" => pts }
        @next_id += 1
        @strokes << s
        @points += pts.size / 2
        changed
        tell(KEY, { "o" => "a", "id" => s["id"], "c" => c, "w" => w, "p" => pts.dup, "k" => 0, "v" => @ver })
        trim
        { "id" => s["id"] }
      end

      # More points of the caller's stroke id (its newest stroke, still on
      # the board, under LINE_POINTS points with these). "ok" or why not.
      def more(token, id, pts)
        node = node_of(token) or return "token"
        s = @strokes.reverse_each.find { |x| x["node"] == node }
        return "not yours" unless s && s["id"] == int(id)
        pts = clean_points(pts) or return "points"
        return "long" if s["p"].size / 2 + pts.size / 2 > LINE_POINTS
        last = s["p"][-2, 2]
        s["p"].concat(pts)
        @points += pts.size / 2
        changed
        tell(KEY, { "o" => "a", "id" => s["id"], "c" => s["c"], "w" => s["w"], "p" => last + pts, "k" => 1, "v" => @ver })
        trim
        "ok"
      end

      # Takes back the caller's last stroke still on the board. "ok" or why not.
      def undo(token)
        node = node_of(token) or return "token"
        i = @strokes.rindex { |x| x["node"] == node } or return "nothing"
        s = @strokes.delete_at(i)
        @points -= s["p"].size / 2
        changed
        tell(KEY, { "o" => "u", "id" => s["id"], "v" => @ver })
        "ok"
      end

      # The owner clears the board. "ok" or why not.
      def clear(token)
        node = node_of(token) or return "token"
        return "not owner" unless @owner == node
        @strokes = []
        @points = 0
        changed
        tell(KEY, { "o" => "c", "v" => @ver })
        @log&.call("board: #{@name}: cleared")
        "ok"
      end

      # A page of the picture from stroke id (the first one at or after it)
      # and its point at: {"v", "n", "p" => [[id, c, w, [x, y, ...], k], ...],
      # "nx" => [id, at] for the next page, or nil}. k 1: the points start
      # with the stroke's point before at (the page goes on with a stroke
      # the last page began). At most PAGE_POINTS points a page.
      def picture(id, at)
        id = int(id) || 0
        at = int(at) || 0
        at = 0 if at.negative?
        out = []
        left = PAGE_POINTS
        i = @strokes.index { |s| s["id"] >= id } || @strokes.size
        at = 0 if i < @strokes.size && @strokes[i]["id"] != id
        nx = nil
        while i < @strokes.size
          s = @strokes[i]
          n = s["p"].size / 2
          if left <= 0
            nx = [s["id"], at]
            break
          end
          take = [n - at, left].min
          from = at.positive? ? at - 1 : 0
          out << [s["id"], s["c"], s["w"], s["p"][from * 2, (at + take - from) * 2], at.positive? ? 1 : 0]
          left -= take
          if at + take < n
            nx = [s["id"], at + take]
            break
          end
          at = 0
          i += 1
        end
        { "v" => @ver, "n" => @strokes.size, "p" => out, "nx" => nx }
      end

      # Past MAX_STROKES or MAX_POINTS: the oldest strokes go (the newest stays).
      def trim
        while @strokes.size > 1 && (@strokes.size > MAX_STROKES || @points > MAX_POINTS)
          s = @strokes.shift
          @points -= s["p"].size / 2
          @dropped += 1
        end
      end

      def tick(now)
        super
        expire_members(now)
      end

      # ------------------------------------------------------------ views

      # Everybody's view (members, spectators, the state key):
      #   st  "draw"                       n   strokes   np  points
      #   last  the newest stroke's id (0: none)
      #   mb  [name, flags (1 away, 2 owner)] in the order they joined
      #   lim [WIDTH, HEIGHT, COLORS, WIDTHS, PART_POINTS, LINE_POINTS, MAX_STROKES, MAX_POINTS]
      def public_view(now)
        { "v" => @ver, "t" => @name, "st" => "draw", "n" => @strokes.size, "np" => @points,
          "last" => @strokes.empty? ? 0 : @strokes[-1]["id"], "mb" => member_list,
          "lim" => [WIDTH, HEIGHT, COLORS, WIDTHS, PART_POINTS, LINE_POINTS, MAX_STROKES, MAX_POINTS] }
      end

      # A member's view: the public one, whether it is the owner and how
      # many of the strokes are its own.
      def member_view(token, now)
        node = node_of(token) or return nil
        public_view(now).merge("own" => @owner == node, "mine" => @strokes.count { |s| s["node"] == node })
      end

      def member_list
        @members.sort_by { |_n, m| m["at"].to_i }.map do |node, m|
          [m["name"].to_s, (member_away?(node) ? 1 : 0) | (@owner == node ? 2 : 0)]
        end
      end

      def summary(now)
        away = @members.keys.count { |n| member_away?(n) }
        { "st" => "draw", "members" => @members.size, "humans" => @members.size - away, "cpus" => 0,
          "away" => away, "strokes" => @strokes.size, "points" => @points }
      end

      # ------------------------------------------------------------ saving

      def to_saved(now)
        super.merge("owner" => @owner, "next_id" => @next_id,
                    "strokes" => @strokes.map { |s| s.values_at("id", "node", "c", "w", "p") })
      end

      def restore(data, now)
        super
        @owner = data["owner"]
        @next_id = data["next_id"].to_i
        @strokes = Array(data["strokes"]).filter_map do |id, node, c, w, p|
          next unless id.is_a?(Integer) && p.is_a?(Array) && p.size >= 2 && p.size.even?
          { "id" => id, "node" => node.to_s, "c" => c.to_i, "w" => w.to_i, "p" => p }
        end
        @points = @strokes.sum { |s| s["p"].size / 2 }
        @next_id = [@next_id, (@strokes.map { |s| s["id"] }.max || 0) + 1].max
        @owner = nil unless @owner && @members.key?(@owner)
        pass_owner unless @owner
        @log&.call("board: #{@name}: resumed (#{@strokes.size} strokes, #{@points} points, #{@members.size} members)")
      end

      # ------------------------------------------------------------ helpers

      def int(x)
        x.is_a?(Integer) ? x : nil
      end

      # [x, y, ...] of integers on the board, 1..PART_POINTS points; nil when not.
      def clean_points(pts)
        return nil unless pts.is_a?(Array) && pts.size >= 2 && pts.size.even? && pts.size <= PART_POINTS * 2
        i = 0
        while i < pts.size
          x = pts[i]
          y = pts[i + 1]
          return nil unless x.is_a?(Integer) && y.is_a?(Integer) && x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT
          i += 2
        end
        pts.dup
      end
    end
  end
end
