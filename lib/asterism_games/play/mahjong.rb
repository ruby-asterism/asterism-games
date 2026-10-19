# frozen_string_literal: true

require "asterism"
require_relative "mahjong_text"
require_relative "mahjong_screen"

module AsterismGames
  module Play
    # A mahjong table in a terminal (README "Playing in a terminal"):
    # `asterism-games play mahjong`. CRuby and the asterism gem only; it
    # calls the table as the table app does (join, view, act, sit, cpu,
    # start, rule, leave) and draws the view as text whenever it changes.
    # The table's host leaving the network (Asterism's on_leave) is said on
    # the screen and the client waits; the host back (on_join) and it asks
    # again (a host that forgot the member: it joins again).
    class Mahjong
      include MahjongText

      HELP = <<~TEXT
        Mahjong commands (one per line):
          a .. n         discard that tile of the hand (the drawn tile is the last letter)
          6s, 0p, 東     discard that tile (0: the red five; 1z..7z for the honours too)
          riichi [e|6s]  riichi, discarding that tile (alone: one choice, or the choices)
          tsumo, ron     win
          pon, chi, kan  call (several ways: a number or the tiles, "chi 2", "chi 3m4m")
          pass           do not call
          kyuushu        nine kinds (an abortive draw)
          ok             the result's OK (an empty line too); at the end, the owner: back to the lobby
          sit [1-4], stand, cpu [1-4] (empty seats to CPUs; the owner), nocpu 1-4,
          ai 1-4 KIND (an AI player, when the lobby offers one), tonpuu, hanchan,
          rule ITEM VALUE (README "Local rules"), start (the owner)
          auto           let the client play for you (wins, passes, discards the drawn tile,
                         OKs the results); again to stop
          tables, view, help, quit
        Without --table it takes the mahjong table it finds (several: it lists them and asks
        on a terminal, else the first).
      TEXT

      HOST_APP = "games"
      ASSIST = 1 # the riichi help (README "Assist")
      VIEW_EVERY_S = 2.0
      HOST_GONE_EVERY_S = 30.0

      REASONS = {
        "token" => "卓の人ではない", "not seated" => "席に着いていない", "stale" => "画面が古い: 読み直し中",
        "not offered" => "今はできない", "not playing" => "対局中ではない", "not waiting" => "待ち合わせ中ではない",
        "taken" => "その席は埋まっている", "no seat" => "その席は無い", "humans" => "人の席がもう無い",
        "not owner" => "卓の主だけができる", "seats" => "4 席がそろっていない", "no human" => "人が 1 人もいない",
        "no change" => "変わらない", "full" => "卓が満員", "spectators" => "観戦の人数が上限",
        "value" => "選べない値", "no rule" => "その項目は無い", "no ai" => "その AI は今は出せない",
        "identity" => "この部屋での名乗りが合わない"
      }.freeze

      # The whole run: connect, find the table, play until quit (or over).
      def self.run(opts, input: $stdin, out: $stdout)
        client = nil
        joined = Queue.new
        on_join = lambda do |n|
          joined << n
          client&.node_joined(n)
        end
        Play.connect(opts, on_join: on_join, on_leave: ->(n) { client&.node_left(n) }, label: "play mahjong") do |net|
          path = opts[:table] || pick_table(net, joined, input, out)
          abort "play mahjong: no mahjong table found (--table <host>/games/<table>)" unless path
          client = new(net, path, opts[:name] || net.node_id, style: opts[:tiles], out: out)
          client.start
          trap("INT") { exit }
          begin
            Play.read_loop(client, opts, input: input)
          ensure
            client.stop
          end
        end
      end

      # The tables: one, or on a terminal a list to choose from (Enter: the
      # first).
      def self.pick_table(net, joined, input, out)
        found = Play.find_tables(net, "mahjong", joined)
        return found.first if found.size <= 1 || !input.tty?
        out.puts "卓 (番号で入る、Enter で 1):"
        found.each_with_index do |p, i|
          out.puts "  #{i + 1}: #{p}  #{table_line(net, p)}"
        end
        out.print "> "
        n = input.gets.to_s.strip.to_i
        found[(n.positive? ? n : 1) - 1] || found.first
      end

      # One line about a table: its state and who sits (the public view).
      def self.table_line(net, path)
        v = net[path, timeout: 3.0].table
        return "" unless v.is_a?(Hash)
        names = (v["nm"] || []).map { |n| n.to_s.empty? ? "空き" : n }
        "#{MahjongScreen::STATES[v['st']] || v['st']}  #{names.join(' / ')}  (#{(v['mb'] || []).size} 人)"
      rescue Asterism::Error
        "(答えが無い)"
      end

      attr_reader :view

      def initialize(net, path, name, style: "emoji", out: $stdout)
        @net = net
        @path = path
        @name = name
        @out = out
        @table = net[path, timeout: 3.0]
        @screen = MahjongScreen.new(style: style, cursor: out.tty?, path: path)
        @lock = Mutex.new
        @view = nil
        @drawn = nil
        @token = nil
        @note = ""
        @pending = nil
        @auto = false
        @wake = Queue.new
        @played = false
        @host = path.split("/").first
        @host_gone = false
      end

      # Asterism's on_leave / on_join (the receiving thread: nothing here
      # waits; the ticker asks the view).
      def node_left(node)
        return unless node == @host
        @host_gone = true
        @wake << :gone
        say("ホストとのつながりが切れた (戻るのを待っています)")
      end

      def node_joined(node)
        return unless node == @host && @host_gone
        @host_gone = false
        say("ホストが戻った")
        @wake << true
      end

      # A game was played and is over now (--until-over).
      def finished? = @played && @view.is_a?(Hash) && @view["st"] == "over"

      def start
        r = @table.join(@name)
        unless r.is_a?(Hash) && r["token"]
          why = r.is_a?(Hash) ? r["error"] : r.inspect
          abort "play mahjong: #{@path}: join refused: #{REASONS[why] || why}"
        end
        @token = r["token"]
        host, app, tname = @path.split("/")
        # The state the host puts after every change: a newer one wakes the
        # ticker (no call waits on the receiving thread).
        @net.session.subscribe("asterism/#{host}/#{app}/#{tname}/state") do |sample|
          v = Asterism::Codec.unpack(sample.payload)
          @wake << true if v.is_a?(Hash) && (!@view.is_a?(Hash) || v["v"] != @view["v"])
        end
        refresh
        # And a view every VIEW_EVERY_S anyway: the host sees that this
        # member is still here.
        @ticker = Thread.new do
          loop do
            woke = @wake.pop(timeout: @host_gone ? HOST_GONE_EVERY_S : VIEW_EVERY_S)
            @wake.clear
            next if woke == :gone
            refresh
          rescue Asterism::Error => e
            say("ホストが答えない (#{e.class})")
          end
        end
      end

      def stop
        @ticker&.kill
        @table.leave(@token) if @token
      rescue Asterism::Error
        nil
      end

      # Asks the member's view and draws it when it changed.
      def refresh
        v = @table.view(@token, ASSIST)
        if v.is_a?(Hash) && v["error"] == "token"
          # The host forgot this member (a new state): join again.
          r = @table.join(@name)
          @token = r["token"] if r.is_a?(Hash) && r["token"]
          v = @table.view(@token, ASSIST)
        end
        @lock.synchronize do
          old = @view
          @view = v
          @played = true if v.is_a?(Hash) && %w[play result].include?(v["st"])
          # A choice belongs to the state it was offered in.
          @pending = nil if @pending && (!v.is_a?(Hash) || !old.is_a?(Hash) || v["sv"] != old["sv"])
          draw if signature(v) != @drawn
        end
        play_auto
      end

      # What a redraw depends on: the view without the times that only
      # count down (the screen is drawn again when something happens, not
      # every second, so a line being typed is not wiped).
      def signature(v)
        return v unless v.is_a?(Hash)
        s = v.dup
        s["dl"] = v["dl"] && v["dl"][0]
        s["ok"] = v["ok"] && v["ok"][0, 2]
        s["in"] = v.key?("in")
        s
      end

      def say(text)
        @lock.synchronize do
          @note = text
          draw
        end
      end

      # One command line; false to quit.
      def command(line)
        text = line.to_s.strip
        v = @view.is_a?(Hash) ? @view : nil
        # An empty line: the result's OK when it is offered.
        if text.empty?
          return true unless v && MahjongText.options(v).any? { |t, _| t == NEXT } && v["st"] == "result"
          text = "ok"
        end
        r = MahjongText.parse(text, v, @pending)
        @pending = nil
        answer = case r[0]
                 when :act then act(r[1], r[2])
                 when :choose
                   @pending = [r[1], r[2]]
                   nil
                 when :cmd
                   return false if %w[quit exit q leave].include?(r[1])
                   client_command(r[1], r[2])
                 when :error then r[1]
                 end
        say(answer ? "#{text}: #{answer}" : "")
        refresh
        true
      rescue Asterism::Error => e
        say("#{text}: #{e.class}: #{e.message}")
        true
      end

      def act(type, tiles)
        v = @view or return "画面がまだ無い"
        reason(@table.act(@token, v["sv"].to_i, type, tiles.pack("C*").b))
      end

      def reason(r)
        return "ok" if r == "ok" || r == true
        REASONS[r.to_s] || r.to_s
      end

      def seat_arg(args, default = -1)
        return default if args.empty?
        n = args[0].to_i
        n.between?(1, 4) ? n - 1 : default
      end

      def client_command(word, args)
        case word
        when "help", "?" then HELP.lines.map(&:strip).reject(&:empty?).first(9).join(" / ")
        when "sit" then reason(@table.sit(@token, seat_arg(args)))
        when "stand" then reason(@table.stand(@token))
        when "cpu" then reason(@table.cpu(@token, seat_arg(args), true))
        when "nocpu" then args.empty? ? "nocpu 1-4" : reason(@table.cpu(@token, seat_arg(args), false))
        when "ai" then args.size < 2 ? "ai 1-4 KIND" : reason(@table.cpu(@token, seat_arg(args), args[1]))
        when "start" then reason(@table.start(@token))
        when "tonpuu" then reason(@table.rule(@token, 0, 1))
        when "hanchan" then reason(@table.rule(@token, 0, 0))
        when "rule"
          args.size < 2 ? "rule ITEM VALUE" : reason(@table.rule(@token, args[0].to_i, args[1].to_i))
        when "auto" then (@auto = !@auto) ? "入 (もう一度で切)" : "切"
        when "view" then "ok"
        when "tables" then Play.find_tables(@net, "mahjong", Queue.new, wait: 0).join("  ")
        else "? (help)"
        end
      end

      # auto: the wins, the OKs, a pass on calls, else the drawn tile (or
      # the last tile that may be discarded).
      def play_auto
        return unless @auto
        v = @view
        return unless v.is_a?(Hash) && v["me"].to_i >= 0
        opts = MahjongText.options(v)
        return if opts.empty?
        pick = opts.find { |t, _| [TSUMO, RON].include?(t) } ||
               (v["st"] == "result" && opts.find { |t, _| t == NEXT }) ||
               opts.find { |t, _| t == SKIP }
        unless pick
          dahai = opts.select { |t, _| t == DAHAI }
          dt = v["dt"].to_i
          pick = dahai.find { |_, ts| ts == [dt] } || dahai.last
        end
        return unless pick
        r = act(pick[0], pick[1])
        say("auto #{MahjongScreen::CALL_NAMES[pick[0]] || (pick[0] == NEXT ? 'ok' : mpsz(pick[1][0]))}: #{r}")
        @wake << true
      end

      # ------------------------------------------------------------ the screen

      def draw
        v = @view
        return unless v.is_a?(Hash)
        @drawn = signature(v)
        lines = @screen.lines(v, note: @note, pending: @pending)
        if @out.tty?
          @out.print("\e[H\e[2J")
          @out.puts(lines)
          @out.print("> ")
        else
          # A pipe or a file: one screen after another, each ending in "> ".
          @out.puts(lines)
          @out.puts("> ")
        end
        @out.flush
      end
    end
  end
end
