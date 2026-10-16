# frozen_string_literal: true

require "securerandom"
require_relative "../game"
require_relative "board"

module AsterismGames
  module Othello
    # One othello table (README "The othello table"): two seats and the
    # spectators. People join (a member with a token) and wait in the lobby
    # ("wait"); the first member who sits is the owner, who may put a CPU in
    # the empty seat and starts the game once both seats are taken. The
    # colours are drawn at the start: seat 0 is black and moves first. A
    # side with no legal move passes by itself; when neither side can move
    # the discs are counted. After the game ("over") the board and the
    # result stay until someone sits, stands or the owner starts again.
    #
    # Nothing is hidden in othello: every member sees the same view (the
    # public one), and the host puts it on the state key.
    #
    # Time (turn_ms, the setting turn_seconds): 0 is no limit. Over 0, a
    # human whose time for a move runs out has that move played by the CPU.
    class Table < AsterismGames::Game
      register "othello"
      tables "othello1"
      screens "/app/game/othello/othello.app.rb"
      settings file: { "turn_seconds" => ["turn_ms", 1000], "cpu_ms" => ["cpu_ms", 1],
                       "away_seconds" => ["away_ms", 1000], "spectators" => ["spectators", 1] },
               env: { "OTHELLO_TURN_SECONDS" => ["turn_ms", 1000], "OTHELLO_CPU_MS" => ["cpu_ms", 1],
                      "OTHELLO_AWAY_SECONDS" => ["away_ms", 1000], "OTHELLO_SPECTATORS" => ["spectators", 1] }

      SAVE_FORMAT = 1
      SEATS = 2
      DEFAULTS = AsterismGames::Game::DEFAULTS.merge(
        "turn_ms" => 0,        # a human's time for a move (0: none); then the CPU plays it
        "cpu_ms" => 700,       # a CPU waits this long before it plays
        "spectators" => 14     # members without a seat at most (a room lets 16 pages in: 2 seats + 14)
      ).freeze

      attr_reader :status, :game, :seats

      def initialize(name, opts = {}, store: nil, log: nil)
        super
        @status = "wait"
        @seats = [nil] * SEATS
        @owner = nil
        @sit_count = 0
        @game = nil
        @result = nil
        @deadline = nil
        @cpu_at = nil
        load_saved(0)
      end

      # ------------------------------------------------------------ members and seats

      def member_reply(node)
        { "token" => @members[node]["token"], "seat" => seat_index(node) || -1, "owner" => @owner == node }
      end

      def join_refusal(node)
        super || (spectators_full? ? "spectators" : nil)
      end

      def renamed(node, name)
        i = seat_index(node)
        @seats[i]["name"] = name if i
      end

      # In the lobby a member's seat empties; during a game the CPU takes it.
      def forget(node)
        i = seat_index(node)
        @seats[i] = playing? ? cpu_seat : nil if i
        super
        pass_owner if @owner == node
        schedule(@now) if playing?
      end

      def keep_member?(node) = !seat_index(node).nil?

      def spectators_full?
        watching = @members.keys.count { |n| seat_index(n).nil? }
        free = playing? ? 0 : @seats.count(&:nil?)
        watching >= @opts["spectators"].to_i + free
      end

      def seat_index(node)
        @seats.index { |s| s && s["kind"] == "human" && s["node"] == node }
      end

      def playing? = @status == "play"

      # The member sits (seat -1: the free one, else the CPU's). Returns "ok" or why not.
      def sit(token, seat, now)
        node = node_of(token) or return "token"
        return "not waiting" if playing?
        seat = seat.to_i
        if seat.negative?
          return "ok" if seat_index(node)
          seat = @seats.index(nil) || @seats.index { |s| s["kind"] == "cpu" }
          return "taken" unless seat
        end
        return "no seat" unless (0...SEATS).cover?(seat)
        cur = seat_index(node)
        return "ok" if cur == seat
        return "taken" if @seats[seat] && @seats[seat]["kind"] == "human"
        m = @members[node]
        sat = cur ? @seats[cur]["sat"] : (@sit_count += 1)
        @seats[cur] = nil if cur
        @seats[seat] = { "kind" => "human", "node" => node, "token" => m["token"], "name" => m["name"], "sat" => sat }
        @owner ||= node
        m["seen"] = now
        back_to_lobby
        "ok"
      end

      def stand(token)
        node = node_of(token) or return "token"
        return "not waiting" if playing?
        i = seat_index(node) or return "not seated"
        @seats[i] = nil
        pass_owner if @owner == node
        back_to_lobby
        "ok"
      end

      # The owner puts a CPU in an empty seat (on) or takes it out; seat -1:
      # every empty seat (on) or every CPU (off).
      def cpu(token, seat, on)
        node = node_of(token) or return "token"
        return "not waiting" if playing?
        return "not owner" unless @owner == node
        seat = seat.to_i
        targets = seat.negative? ? (0...SEATS).to_a : [seat]
        return "no seat" unless targets.all? { |i| (0...SEATS).cover?(i) }
        n = 0
        targets.each do |i|
          if on && @seats[i].nil?
            @seats[i] = cpu_seat
            n += 1
          elsif !on && @seats[i] && @seats[i]["kind"] == "cpu"
            @seats[i] = nil
            n += 1
          end
        end
        return "no change" if n.zero?
        back_to_lobby
        "ok"
      end

      # ------------------------------------------------------------ the game

      # The owner starts: both seats taken, at least one human. The colours
      # are drawn.
      def start(token, now)
        node = node_of(token) or return "token"
        return "not waiting" if playing?
        return "not owner" unless @owner == node
        return "seats" unless @seats.all?
        return "no human" if @seats.none? { |s| s["kind"] == "human" }
        @seats = @seats.shuffle(random: Random.new(SecureRandom.random_number(2**32)))
        @game = Othello::Match.new
        @result = nil
        @status = "play"
        @log&.call("othello: #{@name}: game started (#{@seats.map { |s| s['name'] }.join(' (black), ')} (white))")
        schedule(now)
        changed
        "ok"
      end

      # The member plays square (e.g. "d3") as move number n (the moves so
      # far, passes included: a move sent for an older board is "stale").
      def move(token, n, square, now)
        node = node_of(token) or return "token"
        return "not playing" unless playing?
        i = seat_index(node) or return "not seated"
        return "not your turn" unless i == @game.turn - 1
        return "stale" unless n.to_i == @game.n
        sq = Board.square(square)
        return "illegal" unless sq && sq >= 0 && @game.play(sq)
        after_move(now)
        "ok"
      end

      # The member gives up its game.
      def resign(token, now)
        node = node_of(token) or return "token"
        return "not playing" unless playing?
        i = seat_index(node) or return "not seated"
        finish(1 - i, "resign")
        "ok"
      end

      def tick(now)
        super
        expire_members(now)
        return unless playing?
        seat = @game.turn - 1
        if @cpu_at && now >= @cpu_at
          play_for(seat, now, "cpu")
        elsif @deadline && now >= @deadline
          play_for(seat, now, "time")
        end
      end

      # The CPU plays the move of seat (a CPU's turn, or a human's time ran out).
      def play_for(seat, now, why)
        sq = Cpu.choose(@game.board, seat + 1)
        @log&.call("othello: #{@name}: time is up for seat #{seat}, the CPU plays #{Board.code(sq)}") if why == "time"
        @game.play(sq)
        after_move(now)
      end

      def after_move(now)
        if @game.over?
          w = @game.winner
          finish(w.zero? ? -1 : w - 1, "count")
        else
          schedule(now)
          changed
        end
      end

      # The next move's clock: a CPU waits cpu_ms, a human has turn_ms (0: no limit).
      def schedule(now)
        @cpu_at = @deadline = nil
        return unless playing?
        s = @seats[@game.turn - 1]
        if s["kind"] == "cpu"
          @cpu_at = now + @opts["cpu_ms"].to_i
        elsif @opts["turn_ms"].to_i.positive?
          @deadline = now + @opts["turn_ms"].to_i
        end
      end

      # winner: the seat that won (-1: a draw); why: "count" or "resign".
      def finish(winner, why)
        @result = { "w" => winner, "why" => why, "b" => @game.board.count(Board::BLACK),
                    "wc" => @game.board.count(Board::WHITE) }
        @status = "over"
        @cpu_at = @deadline = nil
        @log&.call("othello: #{@name}: game over (#{why}, #{@result['b']}-#{@result['wc']}, " \
                   "#{winner.negative? ? 'a draw' : "seat #{winner} wins"})")
        changed
      end

      def back_to_lobby
        @status = "wait"
        @game = nil
        @result = nil
        changed
      end

      # ------------------------------------------------------------ views

      # Everybody's view (members, spectators, the state key):
      #   st  "wait" / "play" / "over"   nm  the seats' names (seat 0 black)
      #   sk  0 empty, 1 human, 2 CPU     aw  bits: a seated human is away
      #   ow  the owner's seat (-1)       mb  [name, seat, flags (1 away, 2 owner)] in the order they joined
      #   ts  the seconds for a move (0: no limit)
      #   bd  the board (64 of . B W, a1 first)   tn  the seat to move (-1)
      #   n   moves so far (passes too)   last  the last move ("--" a pass)
      #   lg  the legal squares of the side to move ("d3c4...")
      #   cnt [black, white]              dl  ms left of a human's move (turn_ms over 0)
      #   res {"w" => seat that won (-1 a draw), "why" => "count" / "resign", "b", "wc"}
      def public_view(now)
        v = { "v" => @ver, "t" => @name, "st" => @status,
              "nm" => @seats.map { |s| s ? s["name"].to_s : "" },
              "sk" => @seats.map { |s| s.nil? ? 0 : (s["kind"] == "human" ? 1 : 2) },
              "aw" => (0...SEATS).sum { |i| human_away?(i) ? 1 << i : 0 },
              "ow" => (@owner && seat_index(@owner)) || -1,
              "mb" => member_list,
              "ts" => @opts["turn_ms"].to_i / 1000 }
        if @game
          v["bd"] = @game.board.to_s
          v["tn"] = playing? ? @game.turn - 1 : -1
          v["n"] = @game.n
          v["last"] = @game.last
          v["lg"] = @game.moves.map { |sq| Board.code(sq) }.join
          v["cnt"] = [@game.board.count(Board::BLACK), @game.board.count(Board::WHITE)]
        end
        v["dl"] = [@deadline - now, 0].max if @deadline
        v["res"] = @result if @result
        v
      end

      # A member's view: the public one and its own seat ("me", -1: none).
      def member_view(token, now)
        node = node_of(token) or return nil
        public_view(now).merge("me" => seat_index(node) || -1)
      end

      def member_list
        @members.sort_by { |_n, m| m["at"].to_i }.map do |node, m|
          [m["name"].to_s, seat_index(node) || -1, (member_away?(node) ? 1 : 0) | (@owner == node ? 2 : 0)]
        end
      end

      def human_away?(i)
        s = @seats[i]
        s && s["kind"] == "human" && member_away?(s["node"])
      end

      def summary(now)
        humans = @seats.count { |s| s && s["kind"] == "human" }
        { "st" => @status, "members" => @members.size, "humans" => humans,
          "cpus" => @seats.count { |s| s && s["kind"] == "cpu" },
          "away" => (0...SEATS).count { |i| human_away?(i) }, "n" => @game&.n }
      end

      # ------------------------------------------------------------ saving

      def to_saved(now)
        super.merge("counts" => [@join_count, @sit_count], "status" => @status, "seats" => @seats, "owner" => @owner,
                    "hist" => @game&.hist, "result" => @result,
                    "deadline_left" => @deadline && [@deadline - now, 0].max,
                    "cpu_left" => @cpu_at && [@cpu_at - now, 0].max)
      end

      def restore(data, now)
        super
        @join_count, @sit_count = Array(data["counts"]).map(&:to_i)
        @sit_count ||= 0
        @status = data["status"].to_s
        @seats = Array(data["seats"]).first(SEATS)
        @seats << nil while @seats.size < SEATS
        @owner = data["owner"]
        @game = data["hist"] && Othello::Match.replay(data["hist"])
        @status = "wait" if @game.nil? && @status != "wait"
        @result = data["result"]
        @log&.call("othello: #{@name}: resumed (#{@status}, #{@game ? @game.n : 0} moves, #{@members.size} members)")
      end

      def resume_clock(now, data = saved)
        return unless data
        @deadline = data["deadline_left"] && now + data["deadline_left"]
        @cpu_at = data["cpu_left"] && now + data["cpu_left"]
        super
      end

      # ------------------------------------------------------------ helpers

      def pass_owner
        seated = @seats.compact.select { |s| s["kind"] == "human" }
        @owner = seated.min_by { |s| s["sat"].to_i }&.fetch("node")
      end

      def cpu_seat = { "kind" => "cpu", "name" => "CPU" }
    end
  end
end
