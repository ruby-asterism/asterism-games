# frozen_string_literal: true

require "securerandom"
require_relative "../game"
require_relative "../ai"
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
    #
    # AI players (README "AI players", games 0.17.0): the owner may put
    # one the host offers (Jev only, AI::GAME_KINDS) in a seat as it puts a
    # CPU there; its moves are asked of the host (ai_requests) and played
    # when the answer comes (ai_answer), the CPU's when it does not come
    # in ai_turn_ms or fails.
    class Table < AsterismGames::Game
      register "othello"
      tables "othello1"
      screens "/app/game/othello/othello.app.rb"
      settings file: { "turn_seconds" => ["turn_ms", 1000], "cpu_ms" => ["cpu_ms", 1],
                       "away_seconds" => ["away_ms", 1000], "spectators" => ["spectators", 1],
                       "ai_turn_seconds" => ["ai_turn_ms", 1000] },
               env: { "OTHELLO_TURN_SECONDS" => ["turn_ms", 1000], "OTHELLO_CPU_MS" => ["cpu_ms", 1],
                      "OTHELLO_AWAY_SECONDS" => ["away_ms", 1000], "OTHELLO_SPECTATORS" => ["spectators", 1],
                      "OTHELLO_AI_TURN_SECONDS" => ["ai_turn_ms", 1000] }

      SAVE_FORMAT = 1
      SEATS = 2
      DEFAULTS = AsterismGames::Game::DEFAULTS.merge(
        "turn_ms" => 0,        # a human's time for a move (0: none); then the CPU plays it
        "cpu_ms" => 700,       # a CPU waits this long before it plays
        "ai_turn_ms" => 30_000, # an AI player's time for a move (README "AI players"); then the CPU plays it
        "spectators" => 14     # members without a seat at most (a room lets 16 pages in: 2 seats + 14)
      ).freeze

      # The rules for an AI player (the request's "instructions") and how
      # to read its "view" (look).
      DESCRIPTION = <<~TEXT
        Othello (reversi) on an 8x8 board. Columns are a-h from left to right, rows 1-8 from top to bottom; a square
        is written "d3". Black (B) moves first. A move puts a disc of your colour on an empty square so that it closes
        one or more straight lines (across, up and down, or diagonal) of the other colour's discs between it and
        another disc of yours; every closed line is turned to your colour. A move must turn at least one disc. A side
        with no legal move passes by itself; when neither side can move the game ends, and the side with more discs
        wins. Corners can never be turned back; the squares next to an empty corner often give it away.
        The view: "you" is your colour ("B" or "W"), "board" the eight rows from row 1 to row 8 (each 8 characters
        from column a to h: "." empty, "B" black, "W" white), "discs" the count of each colour, "n" the moves so far,
        "last" the last move ("--" a pass), and "moves" the legal moves, each with its number "n", its "square" and
        the discs it "turns". Answer with the number of one of the moves.
      TEXT

      attr_reader :status, :game, :seats, :stats, :ai_kinds
      attr_accessor :ai_calls_per_game

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
        @stats = Hash.new(0)
        @ai_kinds = []         # the AI players the host can offer now (the lobby view's "ak")
        @ai_calls_per_game = nil
        @ai_calls = Hash.new(0) # seat => decisions asked this game
        @ai_want = nil         # the decision asked of the AI seat to move: {seat:, key:, kind:, at:, sent:}
        @ai_got = nil          # [key, move number or nil] come back
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

      # The owner puts a CPU in an empty seat (on) or takes it out (off,
      # an AI player too); seat -1: every empty seat (on) or every CPU and
      # AI player (off). on may name an AI player the host offers ("jev":
      # the lobby view's "ak", README "AI players"): that one goes in
      # instead of a CPU. On one seat that holds a CPU or an AI player of
      # another kind, on turns it into the one asked for (a CPU into Jev,
      # Jev back into a CPU with true); a refused AI ("no ai") leaves it as
      # it was. Seat -1 with on never changes a seat that is taken.
      def cpu(token, seat, on)
        node = node_of(token) or return "token"
        return "not waiting" if playing?
        return "not owner" unless @owner == node
        ai = on.is_a?(String) && !%w[true 1 false].include?(on) ? on : nil
        return "no ai" if ai && !@ai_kinds.include?(ai)
        on = false if on == "false"
        seat = seat.to_i
        targets = seat.negative? ? (0...SEATS).to_a : [seat]
        return "no seat" unless targets.all? { |i| (0...SEATS).cover?(i) }
        n = 0
        targets.each do |i|
          s = @seats[i]
          if on && (s.nil? || (!seat.negative? && s["kind"] == "cpu" && s["ai"] != ai))
            @seats[i] = cpu_seat
            @seats[i]["ai"] = ai if ai
            n += 1
          elsif !on && s && s["kind"] == "cpu"
            @seats[i] = nil
            n += 1
          end
        end
        return "no change" if n.zero?
        name_cpus
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
        @ai_calls = Hash.new(0)
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
        if @ai_want && @ai_want[:seat] == seat
          ai_turn(seat, now)
        elsif @cpu_at && now >= @cpu_at
          play_for(seat, now, "cpu")
        elsif @deadline && now >= @deadline
          play_for(seat, now, "time")
        end
      end

      # The CPU plays the move of seat (a CPU's turn, a human's or an AI
      # player's time ran out, an AI player's answer failed).
      def play_for(seat, now, why)
        sq = Cpu.choose(@game.board, seat + 1)
        case why
        when "time"
          @log&.call("othello: #{@name}: time is up for seat #{seat}, the CPU plays #{Board.code(sq)}")
        when "ai time"
          @log&.call("othello: #{@name}: AI seat #{seat} out of time: the CPU plays #{Board.code(sq)}")
        end
        @game.play(sq)
        after_move(now)
      end

      # ------------------------------------------------------------ AI players
      #
      # An AI seat (README "AI players") is a CPU seat with "ai" => its kind.
      # On its turn the table asks the host (ai_requests: the seat's look)
      # and waits for the answer (ai_answer) until ai_turn_ms; a move that
      # does not come in time, or fails, is the CPU's. A turn with one legal
      # move is not asked (it is played as the CPU plays). The host turns
      # the AI seats into CPUs when the day's money is spent, and the table
      # turns an AI seat into a CPU when that seat has asked
      # ai_calls_per_game decisions in the game (each seat its own count).

      def ai_seat?(seat)
        s = @seats[seat]
        s && s["kind"] == "cpu" && s["ai"] ? true : false
      end

      # The AI players the host can offer now (the lobby view's "ak").
      def ai_kinds=(kinds)
        kinds = Array(kinds).map(&:to_s)
        return if kinds == @ai_kinds
        @ai_kinds = kinds
        changed unless playing?
      end

      # The decision to ask, once: [{seat:, key:, kind:, until:, request:}].
      def ai_requests(now)
        w = @ai_want
        return [] if w.nil? || w[:sent]
        if @ai_calls_per_game && @ai_calls[w[:seat]] >= @ai_calls_per_game
          ai_off!("#{@ai_calls_per_game} decisions of seat #{w[:seat]} in this game", seats: [w[:seat]])
          return []
        end
        w[:sent] = true
        @ai_calls[w[:seat]] += 1
        @stats["ai_asked"] += 1
        [{ seat: w[:seat], key: w[:key], kind: w[:kind], until: w[:at],
           request: { "game" => "othello", "table" => @name, "seat" => w[:seat],
                      "instructions" => DESCRIPTION, "view" => look(w[:seat]) } }]
      end

      # An answer came: the number of one of the moves the request listed,
      # or nil (the decider failed). Played at once.
      def ai_answer(seat, key, n, now = @now)
        w = @ai_want
        return false unless w && w[:seat] == seat && w[:key] == key
        @ai_got = [key, n]
        tick(now)
        true
      end

      # The AI seats become CPUs (the day's money, or a seat's decisions of
      # the game, are used up): all of them, those of one kind, or the
      # seats named.
      def ai_off!(why, kind: nil, seats: nil)
        only = seats
        seats = (0...SEATS).select { |i| ai_seat?(i) && (kind.nil? || @seats[i]["ai"] == kind) && (only.nil? || only.include?(i)) }
        return false if seats.empty?
        seats.each { |i| @seats[i].delete("ai") }
        @stats["ai_off"] += 1
        @log&.call("othello: #{@name}: AI seats #{seats.inspect} are CPUs now (#{why})")
        name_cpus
        schedule(@now) if playing? && @ai_want && seats.include?(@ai_want[:seat])
        changed
        true
      end

      # What an AI seat sees (the request's "view", DESCRIPTION): the
      # board, its colour and the legal moves, numbered.
      def look(seat)
        color = seat + 1
        b = @game.board
        moves = @game.moves.each_with_index.map do |sq, i|
          t = b.flips(sq, color).size
          { "n" => i, "square" => Board.code(sq), "turns" => t,
            "text" => "#{Board.code(sq)} (turns #{t} disc#{'s' unless t == 1})" }
        end
        { "you" => ".BW"[color], "board" => b.rows, "discs" => { "B" => b.count(Board::BLACK), "W" => b.count(Board::WHITE) },
          "n" => @game.n, "last" => @game.last, "moves" => moves }
      end

      # The AI seat to move: its answer, the CPU when it failed or its
      # time ran out.
      def ai_turn(seat, now)
        w = @ai_want
        got = @ai_got
        if got && got[0] == w[:key]
          @ai_want = @ai_got = nil
          @deadline = nil
          n = got[1]
          moves = @game.moves
          sq = n.is_a?(Integer) && n >= 0 ? moves[n] : nil
          if sq
            @stats["ai_moves"] += 1
            @game.play(sq)
            return after_move(now)
          end
          @stats["ai_failed"] += 1
          return play_for(seat, now, "ai failed")
        end
        return if now < w[:at]
        @stats["ai_timeouts"] += 1
        @ai_want = @ai_got = nil
        @deadline = nil
        play_for(seat, now, "ai time")
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

      # The next move's clock: a CPU waits cpu_ms, a human has turn_ms (0:
      # no limit), an AI player ai_turn_ms (its move is asked; one legal
      # move is played as the CPU's).
      def schedule(now)
        @cpu_at = @deadline = nil
        @ai_want = @ai_got = nil
        return unless playing?
        seat = @game.turn - 1
        s = @seats[seat]
        if s["kind"] == "cpu" && s["ai"] && @game.moves.size > 1
          @deadline = now + @opts["ai_turn_ms"].to_i
          @ai_want = { seat: seat, key: "m#{@game.n}", kind: s["ai"], at: @deadline, sent: false }
        elsif s["kind"] == "cpu"
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
        @ai_want = @ai_got = nil
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
      #   sk  0 empty, 1 human, 2 CPU (an AI player too)
      #   aw  bits: a seated human is away
      #   ai  the seats' AI kinds ("" the others; only when there is one)
      #   ak  the AI players the owner may seat (out of a game, when the host offers some)
      #   ow  the owner's seat (-1)       mb  [name, seat, flags (1 away, 2 owner)] in the order they joined
      #   ts  the seconds for a move (0: no limit)
      #   bd  the board (64 of . B W, a1 first)   tn  the seat to move (-1)
      #   n   moves so far (passes too)   last  the last move ("--" a pass)
      #   lg  the legal squares of the side to move ("d3c4...")
      #   cnt [black, white]              dl  ms left of a human's move (turn_ms over 0) or an AI player's
      #   res {"w" => seat that won (-1 a draw), "why" => "count" / "resign", "b", "wc"}
      def public_view(now)
        v = { "v" => @ver, "t" => @name, "st" => @status,
              "nm" => @seats.map { |s| s ? s["name"].to_s : "" },
              "sk" => @seats.map { |s| s.nil? ? 0 : (s["kind"] == "human" ? 1 : 2) },
              "aw" => (0...SEATS).sum { |i| human_away?(i) ? 1 << i : 0 },
              "ow" => (@owner && seat_index(@owner)) || -1,
              "mb" => member_list,
              "ts" => @opts["turn_ms"].to_i / 1000 }
        v["ai"] = @seats.map { |s| s && s["ai"] ? s["ai"] : "" } if @seats.any? { |s| s && s["ai"] }
        v["ak"] = @ai_kinds if !playing? && !@ai_kinds.empty?
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
          "ais" => @seats.count { |s| s && s["ai"] },
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
        # An AI seat to move: its move is asked again.
        schedule(now) if playing? && ai_seat?(@game.turn - 1)
        super
      end

      # ------------------------------------------------------------ helpers

      def pass_owner
        seated = @seats.compact.select { |s| s["kind"] == "human" }
        @owner = seated.min_by { |s| s["sat"].to_i }&.fetch("node")
      end

      def cpu_seat = { "kind" => "cpu", "name" => "CPU" }

      # The CPUs are "CPU", the AI players their kind's name (numbered when
      # there are two of one).
      def name_cpus
        @seats.each { |s| s["name"] = "CPU" if s && s["kind"] == "cpu" && !s["ai"] }
        @seats.compact.select { |s| s["ai"] }.group_by { |s| s["ai"] }.each do |kind, list|
          label = AI::LABELS[kind] || kind.capitalize
          list.each_with_index { |s, i| s["name"] = list.size > 1 ? "#{label}#{i + 1}" : label }
        end
      end
    end
  end
end
