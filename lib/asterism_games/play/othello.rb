# frozen_string_literal: true

require "asterism"

module AsterismGames
  module Play
    # An othello table in a terminal (README "The othello table"):
    # `asterism-games play othello` (and bin/othello-tty, which calls it).
    # It joins the table, shows the board as text at every change (the
    # state the host puts) and reads commands: watch, or sit and type the
    # squares ("d3"). When the table's host leaves the network (Asterism's
    # on_leave) it says the connection is lost and stops asking; when the
    # host is back (on_join) it asks again at once (and every 30 s
    # meanwhile, should the word not come).
    class OthelloTty
      HELP = <<~TEXT
        On a terminal it reads keys: the arrows move the cursor on the board, Enter (or
        Space) plays there, Esc resigns (after "resign? [Y/N]"); in the lobby S sit or stand, C the CPU, Enter start; Q or
        Ctrl+C quits; : (or /) opens a line for a command.
        Othello commands (one per line, or after :): d3 (play there), sit [0|1], stand, cpu (fill the
        empty seat; the owner), start (the owner), resign, auto (let the client play your
        moves: the first legal square; again to stop), view, help, quit.
        Without --table it takes the first othello table it finds (looking again whenever
        a node joins the network, for 10 s).
      TEXT

      # The whole run: connect, find the table, play until quit (or over).
      def self.run(opts, input: $stdin, out: $stdout)
        tty = nil
        joined = Queue.new
        on_join = lambda do |n|
          joined << n
          tty&.node_joined(n)
        end
        Play.connect(opts, on_join: on_join, on_leave: ->(n) { tty&.node_left(n) }, label: "play othello") do |net|
          path = opts[:table] || Play.find_tables(net, "othello", joined).first
          abort "play othello: no othello table found (--table <host>/games/<table>)" unless path
          kout = Play.key_out(input, out)
          tty = new(net, path, opts[:name] || net.node_id, out: kout, keys: Play.keys?(input))
          tty.start
          trap("INT") { exit }
          begin
            Play.read_loop(tty, opts, input: input, out: kout)
          ensure
            tty.stop
          end
        end
      end

      HOST_APP = "games"
      VIEW_EVERY_S = 2.0
      # While the host is gone: a view now and then, should on_join not come.
      HOST_GONE_EVERY_S = 30.0

      def initialize(net, path, name, out: $stdout, keys: false)
        @net = net
        # Keys (README "Keys"): the cursor on the board ([x, y], nil until
        # a game shows), a line being typed after ":".
        @keys = keys
        @cursor = nil
        # Esc during this member's game: "resign? [Y/N]" (as the othello app).
        @confirm = false
        @typing = false
        @path = path
        @name = name
        @out = out
        @table = net[path, timeout: 3.0]
        @lock = Mutex.new
        @view = nil
        @token = nil
        @note = ""
        @auto = false
        @wake = Queue.new
        @played = false
        @host = path.split("/").first
        @host_gone = false
      end

      # Asterism's on_leave / on_join (on the receiving thread: nothing here
      # waits; the ticker asks the view).
      def node_left(node)
        return unless node == @host
        @host_gone = true
        @wake << :gone # the ticker waits again, now the long way
        say("the connection is lost: the host left the network (waiting for it)")
      end

      def node_joined(node)
        return unless node == @host && @host_gone
        @host_gone = false
        say("the host is back")
        @wake << true
      end

      # A game was played and is over now (--until-over).
      def finished? = @played && @view && @view["st"] == "over"

      def start
        r = @table.join(@name)
        # "identity": in a room, only the seats and the host's names join.
        abort "othello-tty: #{@path}: join refused: #{r.is_a?(Hash) ? r['error'] : r.inspect}" unless r.is_a?(Hash) && r["token"]
        @token = r["token"]
        host, app, tname = @path.split("/")
        # The state the host puts after every change (and every 5 s): a newer
        # one wakes the thread that asks the view (no call waits on the
        # receiving thread).
        @net.session.subscribe("asterism/#{host}/#{app}/#{tname}/state") do |sample|
          v = Asterism::Codec.unpack(sample.payload)
          @wake << true if v.is_a?(Hash) && (@view.nil? || v["v"] != @view["v"])
        end
        refresh
        # And a view every VIEW_EVERY_S anyway: the host sees that this member
        # is still here (where it cannot see the nodes come and go).
        @ticker = Thread.new do
          loop do
            woke = @wake.pop(timeout: @host_gone ? HOST_GONE_EVERY_S : VIEW_EVERY_S)
            @wake.clear
            next if woke == :gone
            refresh
          rescue Asterism::Error => e
            say("no answer from the table (#{e.class})")
          end
        end
      end

      def stop
        @ticker&.kill
        @table.leave(@token) if @token
      rescue Asterism::Error
        nil
      end

      # Asks the member's view and draws it.
      def refresh
        v = @table.view(@token)
        if v.is_a?(Hash) && v["error"] == "token"
          # The host forgot this member (a new state): join again.
          r = @table.join(@name)
          @token = r["token"] if r.is_a?(Hash) && r["token"]
          v = @table.view(@token)
        end
        @lock.synchronize do
          @view = v
          @played = true if v.is_a?(Hash) && v["st"] == "play"
          @cursor = self.class.place_cursor(v, @cursor)
          @confirm = false unless self.class.own_game?(v)
          draw
        end
        play_auto
      end

      def say(text)
        @lock.synchronize do
          @note = text
          draw
        end
      end

      # One command line; false to quit.
      def command(line)
        words = line.to_s.strip.downcase.split
        return true if words.empty?
        r = case words[0]
            when "quit", "exit", "q" then return false
            when "help", "?" then "d3 | sit [0|1] | stand | cpu | start | resign | auto | view | quit"
            when "sit" then @table.sit(@token, (words[1] || -1).to_i)
            when "stand" then @table.stand(@token)
            when "cpu" then @table.cpu(@token, -1, true)
            when "start" then @table.start(@token)
            when "resign" then @table.resign(@token)
            when "auto" then (@auto = !@auto) ? "auto: on" : "auto: off"
            when "view" then "ok"
            when /\A[a-h][1-8]\z/ then move(words[0])
            else "? (help)"
            end
        say("#{line.strip}: #{r}")
        refresh
        true
      rescue Asterism::Error => e
        say("#{line.strip}: #{e.class}: #{e.message}")
        true
      end

      # ------------------------------------------------------------ keys

      KEY_STEPS = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0] }.freeze

      # The cursor for a view: none outside a game or without a seat; at a
      # legal square of this member's (the first) when it has none yet.
      def self.place_cursor(v, cursor)
        return nil unless v.is_a?(Hash) && v["st"] == "play" && v["me"].to_i >= 0
        return cursor if cursor
        sq = v["tn"] == v["me"] ? v["lg"].to_s[0, 2] : ""
        sq.size == 2 ? square_xy(sq) : nil
      end

      def self.square_xy(sq) = ["abcdefgh".index(sq[0]), sq[1].to_i - 1]

      def self.square(xy) = "#{'abcdefgh'[xy[0]]}#{xy[1] + 1}"

      # The cursor moved by an arrow, stopping at the board's edge (from
      # the middle when there is none yet).
      def self.step(cursor, key)
        x, y = cursor || [3, 3]
        dx, dy = KEY_STEPS.fetch(key)
        [(x + dx).clamp(0, 7), (y + dy).clamp(0, 7)]
      end

      # A game this member plays (seated, going on): Esc offers to resign.
      def self.own_game?(v) = v.is_a?(Hash) && v["st"] == "play" && v["me"].to_i >= 0

      # One key as a command. Returns [:cursor, [x, y]], [:cmd, line] (a
      # square, sit, stand, cpu, start, resign), [:confirm, on] (the
      # question "resign?" shown or put away), [:note, text], [:line],
      # [:quit] or [:none]. confirm: the question is up (Y resigns, N or Esc
      # cancels, other keys wait).
      def self.key_command(key, view, cursor, confirm: false)
        k = key.is_a?(String) ? key.downcase : key
        return [:quit] if [:ctrl_c, :ctrl_q, "q"].include?(k)
        if confirm && own_game?(view)
          return [:cmd, "resign"] if k == "y"
          return [:confirm, false] if k == "n" || k == :esc
          return [:none]
        end
        return [:line] if [":", "/"].include?(k)
        return [:none] unless view.is_a?(Hash) && !view["error"]
        me = view["me"].to_i
        if view["st"] == "play"
          return [:none] if me.negative?
          return [:confirm, true] if k == :esc
          return [:cursor, step(cursor, k)] if KEY_STEPS.key?(k)
          return [:none] unless %i[enter space].include?(k)
          return [:note, "not your move"] unless view["tn"] == me
          return [:note, "move the cursor to a square first"] unless cursor
          sq = square(cursor)
          return view["lg"].to_s.scan(/../).include?(sq) ? [:cmd, sq] : [:note, "#{sq}: not a legal square"]
        end
        case k
        when "s" then [:cmd, me >= 0 ? "stand" : "sit"]
        when "c" then view["ow"] == me && me >= 0 ? [:cmd, "cpu"] : [:note, "the owner puts the CPU in"]
        when :enter then view["ow"] == me && me >= 0 ? [:cmd, "start"] : [:none]
        else [:none]
        end
      end

      # One key (Play.key_loop); false to quit, :line for a line to type.
      def key(k)
        r = self.class.key_command(k, @view, @cursor, confirm: @confirm)
        case r[0]
        when :quit then return false
        when :line then return :line
        when :confirm
          @lock.synchronize do
            @confirm = r[1]
            draw
          end
        when :cmd
          @confirm = false
          return command(r[1])
        when :cursor
          @lock.synchronize do
            @cursor = r[1]
            draw
          end
        when :note then say(r[1])
        end
        true
      end

      # A line is being typed after ":" (a prompt at the bottom).
      def typing(on)
        @lock.synchronize do
          @typing = on
          draw
        end
      end

      def move(square)
        v = @view or return "no view yet"
        @table.move(@token, v["n"].to_i, square)
      end

      # auto: plays the first legal square when it is this member's turn.
      def play_auto
        return unless @auto
        v = @view
        return unless v && v["st"] == "play" && v["tn"] == v["me"] && v["lg"].to_s.size >= 2
        sq = v["lg"][0, 2]
        r = @table.move(@token, v["n"].to_i, sq)
        say("auto #{sq}: #{r}")
        @wake << true
      end

      # ------------------------------------------------------------ the screen

      def draw
        v = @view
        return unless v.is_a?(Hash)
        return @out.puts("table: #{v['error']}") if v["error"]
        me = v["me"].to_i
        names = v["nm"] || ["", ""]
        lines = []
        lines << "#{@path}  #{status_text(v)}"
        bd = v["bd"]
        hints = me >= 0 && v["tn"] == me ? v["lg"].to_s.scan(/../) : []
        cur = keys_on? && v["st"] == "play" ? @cursor : nil
        lines << "    a b c d e f g h"
        8.times do |y|
          row = (0...8).map do |x|
            c = bd ? bd[y * 8 + x] : "."
            code = "#{'abcdefgh'[x]}#{y + 1}"
            c == "B" ? "X" : (c == "W" ? "O" : (hints.include?(code) ? "*" : "."))
          end
          lines << "  #{y + 1}#{self.class.board_row(row, cur && cur[1] == y ? cur[0] : nil)}"
        end
        cnt = v["cnt"] || [0, 0]
        2.times do |i|
          who = names[i].to_s.empty? ? "(empty)" : names[i]
          tags = []
          tags << "you" if i == me
          tags << "CPU" if v["sk"].to_a[i] == 2
          tags << "owner" if v["ow"] == i
          tags << "away" if v["aw"].to_i[i] == 1
          turn = v["tn"] == i ? " <" : ""
          colour = v["st"] == "wait" ? "seat#{i + 1}" : (i.zero? ? "black" : "white")
          lines << format("  %s %-5s %-24s %2d%s", i.zero? ? "X" : "O", colour,
                          "#{who}#{" (#{tags.join(', ')})" unless tags.empty?}", cnt[i], turn)
        end
        watchers = (v["mb"] || []).select { |m| m[1] == -1 }.map(&:first)
        lines << "  watching: #{watchers.join(', ')}" unless watchers.empty?
        lines << "  #{@note}" unless @note.empty?
        lines << "  #{keys_on? ? key_prompt(v, me) : prompt(v, me)}"
        @out.print("\e[H\e[2J") if @out.tty?
        @out.puts(lines)
        @out.print("> ") if @keys && @typing
        @out.flush
      end

      def keys_on? = @keys && !@typing

      # A row of the board: each cell after a space, the cursor's cell
      # between [ ] (in the spaces around it, so the columns stay).
      def self.board_row(cells, cx)
        out = +""
        cells.each_with_index do |c, x|
          out << (x == cx ? "[" : (cx && x == cx + 1 ? "]" : " "))
          out << c
        end
        out << (cx == 7 ? "]" : "")
        out
      end

      # The last line with keys: each key in [ ] before what it does.
      def key_prompt(v, me)
        common = "[:] type a command  [Q] quit"
        if v["st"] == "play"
          return "watching  #{common}" if me.negative?
          return "resign? [Y] yes [N] no" if @confirm
          return "your move: [arrows] move [Enter] play (* marks the squares) [Esc] resign  #{common}" if v["tn"] == me
          return "waiting for the other player  [arrows] move [Esc] resign  #{common}"
        end
        words = [me >= 0 ? "[S] stand" : "[S] sit"]
        if me >= 0 && v["ow"] == me
          sk = v["sk"] || [0, 0]
          words << "[C] CPU" if sk.any?(&:zero?)
          words << "[Enter] start" unless sk.any?(&:zero?)
        end
        "#{words.join(' ')}  #{common}"
      end

      def status_text(v)
        case v["st"]
        when "wait" then "lobby (sit, cpu, start)"
        when "play"
          t = v["dl"] ? format(", %d s left", (v["dl"].to_i + 999) / 1000) : ""
          "move #{v['n'].to_i + 1}, last #{v['last'] || '-'}#{t}"
        when "over"
          r = v["res"] || {}
          w = r["w"].to_i
          who = w.negative? ? "a draw" : "#{(v['nm'] || [])[w]} (#{w.zero? ? 'black' : 'white'}) wins"
          "over: #{who}, #{r['b']}-#{r['wc']}#{' by resignation' if r['why'] == 'resign'}"
        else v["st"].to_s
        end
      end

      def prompt(v, me)
        return "watching (sit to play; help)" if me.negative? && v["st"] != "play"
        return "watching" if me.negative?
        return "your move: a square (* marks them), or resign" if v["st"] == "play" && v["tn"] == me
        return "waiting for the other player" if v["st"] == "play"
        return "seated (start: the owner plays again; stand: leave the seat)" if v["st"] == "over"
        "seated (the colours are drawn at the start)"
      end
    end
  end
end
