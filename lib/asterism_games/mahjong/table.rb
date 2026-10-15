# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "tiles"
require_relative "engine"

module AsterismGames
  module Mahjong
    # One mahjong table: four seats, the game (a hanchan) and the round being
    # played. It holds the wall and the hands; players see what view(seat)
    # gives them. Time is passed in (milliseconds) so tests can drive it.
    #
    # Seats are "human" (a player who sat with sit and holds its token) or
    # "cpu" (riichi_engine's player). A human that does not decide in time is
    # played for: the drawn tile is discarded, a call is passed.
    class Table
      SAVE_FORMAT = 1
      MAX_ROUNDS = 40 # a hanchan has far fewer; a guard against a loop

      DEFAULTS = {
        "turn_ms" => 20_000,      # a human's time to discard
        "call_ms" => 8_000,       # a human's time to call a discard
        "cpu_ms" => 700,          # a CPU waits this long before it acts
        "result_ms" => 8_000,     # the result of a round stays this long
        "cpu_level" => "normal",  # easy / normal / hard
        "humans" => 1,            # human seats (Step 1: one)
        "game_type" => "hanchan"
      }.freeze

      attr_reader :name, :ver, :sv, :status, :state, :opts, :stats

      def initialize(name, opts = {}, store: nil, log: nil)
        @name = name
        @opts = DEFAULTS.merge(opts.transform_keys(&:to_s))
        @store = store
        @log = log
        @rule = Engine.rule(game_type: @opts["game_type"])
        @ai = ai_for(@opts["cpu_level"])
        @stats = Hash.new(0)
        reset_all
        load_saved(0)
      end

      # ------------------------------------------------------------ seats

      # A player takes a seat. The same node gets its own seat back (and the
      # same token); a new node gets a free human seat. Returns
      # {"seat", "token"} or {"error"}.
      def sit(node, name, now)
        node = node.to_s
        i = @seats.index { |s| s["kind"] == "human" && s["node"] == node }
        if i.nil?
          return { "error" => "full" } if @seats.count { |s| s["kind"] == "human" } >= @opts["humans"]
          i = @status == "wait" ? SecureRandom.random_number(4) : @seats.index { |s| s["kind"] == "cpu" }
          @seats[i] = { "kind" => "human", "node" => node, "token" => SecureRandom.hex(16) }
        end
        @seats[i]["name"] = clean_name(name, node)
        start_game(now) if @status == "wait"
        changed
        { "seat" => i, "token" => @seats[i]["token"] }
      end

      # The seat goes back to a CPU.
      def leave(token)
        i = seat_of(token)
        return false unless i
        @seats[i] = cpu_seat(i)
        @decl.delete(i)
        @deadline = nil if @deadline_seat == i
        changed
        true
      end

      def seat_of(token)
        return nil unless token.is_a?(String) && !token.empty?
        @seats.index { |s| s["kind"] == "human" && s["token"] == token }
      end

      def human?(seat)
        @seats[seat]["kind"] == "human"
      end

      # ------------------------------------------------------------ actions

      # A player's action: type (Engine::DAHAI ...) and tiles (names). sv is
      # the state version the player saw. Returns "ok" or why not.
      def act(token, sv, type, tiles, now)
        seat = seat_of(token)
        return "token" unless seat
        return "stale" unless sv == @sv
        if type == Engine::NEXT
          return next_now(now) ? "ok" : "not offered"
        end
        return "not playing" unless @status == "play"
        a = Engine.match(offers(seat), type, tiles)
        unless a
          @stats["refused"] += 1
          return "not offered"
        end
        a[:seat] = seat
        if @state.phase == :naki_wait
          @decl[seat] = a
          @deadline = nil if @deadline_seat == seat
          changed
        else
          @deadline = nil
          apply(a, now)
        end
        tick(now)
        "ok"
      end

      # What a seat may do now ([[type, [tile names]], ...]).
      def offers(seat)
        case @status
        when "result", "over"
          return human?(seat) ? [[Engine::NEXT, []]] : []
        when "play" then nil
        else return []
        end
        return [] if @state.phase == :naki_wait && @decl.key?(seat)
        Engine.offers(@state, seat, @rule)
      end

      # ------------------------------------------------------------ time

      # Moves the game on: draws, CPU turns, timeouts, the next round.
      def tick(now)
        200.times { break unless step(now) }
      end

      def step(now)
        case @status
        when "result"
          return false if now < @next_at
          next_round(now)
          true
        when "play" then step_play(now)
        else false
        end
      end

      def step_play(now)
        st = @state
        case st.phase
        when :tsumo
          apply({ type: :tsumo }, now)
          true
        when :dahai
          seat = st.current_seat
          if human?(seat)
            return set_deadline(seat, now + @opts["turn_ms"]) if @deadline.nil?
            return false if now < @deadline
            @stats["timeouts"] += 1
            auto_discard(seat, now)
            true
          else
            return wait_cpu(now) unless cpu_ready?(now)
            cpu_act(seat, now)
            true
          end
        when :naki_wait
          step_calls(now)
        else
          false
        end
      end

      def step_calls(now)
        st = @state
        humans_waiting = false
        st.pending_actions.keys.sort.each do |seat|
          next if @decl.key?(seat)
          if human?(seat)
            if @deadline.nil?
              set_deadline(seat, now + @opts["call_ms"])
              humans_waiting = true
            elsif now >= @deadline
              @stats["timeouts"] += 1
              @decl[seat] = { type: :skip, seat: seat }
              @deadline = nil
            else
              humans_waiting = true
            end
          else
            @decl[seat] = Engine.cpu_choice(st, seat, @rule, @ai) || { type: :skip, seat: seat }
          end
        end
        return false if humans_waiting
        human_called = @decl.keys.any? { |s| human?(s) }
        return wait_cpu(now) if !human_called && !cpu_ready?(now)
        resolve_calls(now)
        true
      end

      def resolve_calls(now)
        st = @state
        decl = @decl
        @decl = {}
        @deadline = nil
        @cpu_at = nil
        win = Engine.call_winner(decl, st.last_dahai[:seat])
        st.pending_actions.keys.sort.each do |seat|
          next if win && seat == win[0]
          apply({ type: :skip, seat: seat }, now)
        end
        apply(win[1], now) if win
      end

      def cpu_ready?(now)
        @cpu_at && now >= @cpu_at
      end

      # Starts the CPU's wait; true when it may act at once.
      def wait_cpu(now)
        return false if @cpu_at
        @cpu_at = now + @opts["cpu_ms"]
        @opts["cpu_ms"] <= 0
      end

      def set_deadline(seat, at)
        @deadline = at
        @deadline_seat = seat
        changed
        false
      end

      def cpu_act(seat, now)
        @cpu_at = nil
        a = Engine.cpu_choice(@state, seat, @rule, @ai)
        apply(a, now)
      rescue ::RiichiEngine::API::InvalidActionError => e
        # The CPU chose something the engine refuses: play it safe.
        @stats["cpu_refused"] += 1
        @log&.call("mahjong: cpu seat #{seat}: #{a.inspect} refused (#{e.message}); discarding the drawn tile")
        auto_discard(seat, now)
      end

      # A turn played for a seat: the drawn tile, or (after a call) the last
      # tile of the hand.
      def auto_discard(seat, now)
        @deadline = nil
        o = Engine.offers(@state, seat, @rule).find { |t, _| t == Engine::DAHAI }
        tiles = o ? o[1] : []
        drawn = @state.last_tsumo&.to_s
        tile = tiles.include?(drawn) ? drawn : Tiles.sort(tiles).last
        apply({ type: :dahai, seat: seat, tile: tile }, now)
      end

      # ------------------------------------------------------------ rounds

      def apply(action, now)
        r = Engine.apply(@state, action, @rule)
        @sv += 1
        @stats["actions"] += 1
        ev = r.events.last
        @event = ev ? [Engine::TYPE_OF[ev[:type].to_sym] || 0, ev[:seat] || -1] : nil
        finish_round(r.round_end_info, now) if r.round_end?
        changed
      end

      def finish_round(info, now)
        res = Engine.score(@state, info, @rule)
        res["round"] = [Engine::BAKAZE.index(@game["bakaze"]), @game["kyoku"], @game["honba"]]
        @game["scores"] = (0..3).map { |s| @state.scores[s] }
        @game["kyoutaku"] = @state.kyoutaku
        flow = Engine.next_round(@game, @state, res, @rule)
        @flow = { "end" => flow.game_end?, "bakaze" => flow.next_bakaze, "kyoku" => flow.next_kyoku,
                  "honba" => flow.next_honba, "oya" => flow.next_oya_index }
        @result = res
        @status = "result"
        @next_at = now + @opts["result_ms"]
        @deadline = nil
        @cpu_at = nil
        @decl = {}
        @stats["rounds"] += 1
        @stats["round_#{res['kind']}"] += 1
        @log&.call("mahjong: #{@name}: round over: #{res['kind']} #{res['points']} #{@game['scores'].inspect}")
      end

      # The "next" button: on a round's result or a finished game.
      def next_now(now)
        case @status
        when "result" then next_round(now)
        when "over" then start_game(now)
        else return false
        end
        tick(now)
        true
      end

      def next_round(now)
        f = @flow
        @game["rounds"] += 1
        if f["end"] || @game["rounds"] >= MAX_ROUNDS
          scores = (0..3).to_h { |s| [s, @game["scores"][s]] }
          @final = Engine::API.calculate_ranked_results(scores: scores, rule: @rule).map do |r|
            [r.seat, r.rank, r.score, (r.point * 10).round]
          end
          @status = "over"
          @stats["games"] += 1
          @log&.call("mahjong: #{@name}: game over: #{@final.inspect}")
        else
          @game.merge!("bakaze" => f["bakaze"], "kyoku" => f["kyoku"], "honba" => f["honba"], "oya" => f["oya"])
          new_round
        end
        changed
      end

      def start_game(now)
        @game = { "bakaze" => "ton", "kyoku" => 1, "honba" => 0, "kyoutaku" => 0, "oya" => 0,
                  "scores" => [25_000] * 4, "rounds" => 0 }
        @final = nil
        new_round
        changed
      end

      def new_round
        @state = Engine.setup(@game, @rule)
        @status = "play"
        @result = nil
        @flow = nil
        @decl = {}
        @deadline = nil
        @cpu_at = nil
        @event = nil
        @sv += 1
      end

      # ------------------------------------------------------------ views

      # What everybody may see: no hand but the winner's at a win.
      def public_view(now)
        v = { "v" => @ver, "sv" => @sv, "t" => @name, "st" => @status,
              "nm" => @seats.map { |s| s["name"].to_s }, "hu" => bits { |i| human?(i) } }
        if @game
          v["sc"] = @game["scores"].dup
          v["r"] = [Engine::BAKAZE.index(@game["bakaze"]), @game["kyoku"], @game["honba"], @game["kyoutaku"], @game["oya"]]
        end
        if @state && @status != "wait"
          st = @state
          v["r"] = [Engine::BAKAZE.index(st.bakaze), st.kyoku, st.honba, st.kyoutaku, st.oya_seat,
                    st.remaining_tiles, st.current_seat, %i[tsumo dahai naki_wait round_end].index(st.phase)]
          v["sc"] = (0..3).map { |s| st.scores[s] } if @status == "play"
          v["ri"] = bits { |i| st.riichi_flags[i] }
          v["dora"] = Tiles.pack(st.dora_hyouji.map(&:to_s)).b
          v["kw"] = (0..3).map { |s| kawa_bytes(st.kawas[s]) }
          v["fu"] = (0..3).map { |s| fuuro_bytes(st.fuuros[s], s) }
          v["hc"] = (0..3).map { |s| st.hands[s].count }
          v["ls"] = st.last_dahai ? [st.last_dahai[:seat], Tiles.code(st.last_dahai[:tile].to_s)] : nil
          v["ev"] = @event
          v["dl"] = @deadline ? [@deadline_seat, [@deadline - now, 0].max] : nil
        end
        v["res"] = result_view if @result && (@status == "result" || @status == "over")
        v["fin"] = @final if @final
        v
      end

      # One seat's view: the public one, its hand and what it may do.
      def view(seat, now)
        v = public_view(now)
        v["me"] = seat
        if @state && @status != "wait"
          st = @state
          hand = st.hands[seat].tiles.map(&:to_s)
          drawn = nil
          if st.phase == :dahai && st.current_seat == seat && st.last_tsumo
            drawn = st.last_tsumo.to_s
            hand.delete_at(hand.index(drawn))
          end
          v["h"] = Tiles.pack(Tiles.sort(hand)).b
          v["dt"] = drawn ? Tiles.code(drawn) : -1
        end
        v["a"] = offers(seat).map { |t, ts| [t, Tiles.pack(ts).b] }
        v
      end

      def bits
        n = 0
        4.times { |i| n |= (1 << i) if yield(i) }
        n
      end

      # A river: one byte a tile, 0x40 = the riichi tile, 0x80 = called away.
      def kawa_bytes(kawa)
        kawa.tiles.map { |k| Tiles.code(k.tile.to_s) | (k.riichi ? 0x40 : 0) | (k.called ? 0x80 : 0) }.pack("C*").b
      end

      # Melds: per meld [kind, from (1 right, 2 across, 3 left, 0 none), n,
      # n tiles]; kind 1 chi, 2 pon, 3 ankan, 4 daiminkan, 5 kakan.
      def fuuro_bytes(list, seat)
        out = []
        list.each do |f|
          kind = %i[chi pon ankan daiminkan kakan].index(f.type) + 1
          from = f.from_seat.nil? ? 0 : (f.from_seat - seat) % 4
          out << kind << from << f.tiles.size
          f.tiles.each { |t| out << Tiles.code(t.to_s) }
        end
        out.pack("C*").b
      end

      def result_view
        r = @result
        v = { "k" => r["kind"], "d" => r["delta"], "rd" => r["round"] }
        if r["winner"]
          v.merge!("w" => r["winner"], "f" => r["from"], "y" => r["yaku"], "pt" => r["points"],
                   "h" => Tiles.pack(Tiles.sort(r["hand"])).b, "ag" => Tiles.code(r["agari"]))
        end
        v["tp"] = r["tenpai"] if r["tenpai"]
        v
      end

      # ------------------------------------------------------------ saving

      def changed
        @ver += 1
        @dirty = true
      end

      def dirty?
        @dirty
      end

      def save(now)
        @dirty = false
        return unless @store
        @store.write(@name, to_saved(now))
      end

      def to_saved(now)
        { "format" => SAVE_FORMAT, "name" => @name, "ver" => @ver, "sv" => @sv, "status" => @status,
          "seats" => @seats, "game" => @game, "round" => @state&.to_json,
          "decl" => @decl.to_h { |k, a| [k.to_s, a.transform_keys(&:to_s).transform_values { |x| x.is_a?(Symbol) ? x.to_s : x }] },
          "deadline_left" => @deadline && [@deadline - now, 0].max, "deadline_seat" => @deadline_seat,
          "cpu_left" => @cpu_at && [@cpu_at - now, 0].max, "next_left" => @next_at && [@next_at - now, 0].max,
          "result" => @result, "flow" => @flow, "final" => @final, "event" => @event }
      end

      def load_saved(now)
        d = @store&.read(@name)
        return unless d && d["format"] == SAVE_FORMAT
        @ver = d["ver"].to_i + 1
        @sv = d["sv"].to_i
        @status = d["status"]
        @seats = d["seats"]
        @game = d["game"]
        @state = d["round"] ? Engine::API.deserialize_round_state(d["round"]) : nil
        @decl = (d["decl"] || {}).to_h do |k, a|
          [k.to_i, a.to_h { |kk, x| [kk.to_sym, kk == "type" ? x.to_sym : x] }]
        end
        @deadline = d["deadline_left"] && now + d["deadline_left"]
        @deadline_seat = d["deadline_seat"]
        @cpu_at = d["cpu_left"] && now + d["cpu_left"]
        @next_at = d["next_left"] && now + d["next_left"]
        @result = d["result"]
        @flow = d["flow"]
        @final = d["final"]
        @event = d["event"]
        @log&.call("mahjong: #{@name}: resumed (#{@status}, state #{@sv})")
      end

      # Times read back are relative to when they were saved; a host started
      # again calls this with its own clock.
      def resume_clock(now)
        d = @store&.read(@name)
        return unless d
        @deadline = d["deadline_left"] && now + d["deadline_left"]
        @cpu_at = d["cpu_left"] && now + d["cpu_left"]
        @next_at = d["next_left"] && now + d["next_left"]
      end

      # ------------------------------------------------------------ setup

      def reset_all
        @ver = 1
        @sv = 0
        @status = @opts["humans"].to_i.zero? ? "play" : "wait"
        @seats = (0..3).map { |i| cpu_seat(i) }
        @game = nil
        @state = nil
        @decl = {}
        @deadline = nil
        @deadline_seat = nil
        @cpu_at = nil
        @next_at = nil
        @result = nil
        @flow = nil
        @final = nil
        @event = nil
        @dirty = true
        start_game(0) if @status == "play"
      end

      def cpu_seat(i)
        { "kind" => "cpu", "name" => "CPU#{i + 1}" }
      end

      def ai_for(level)
        case level.to_s
        when "easy" then ::Mahjong::Cpu::Ai::EasyAi.new
        when "engine" then ::Mahjong::Cpu::Ai::NormalAi.new # the engine's own, as it is
        when "hard" then Engine::CpuAi.new(3)
        else Engine::CpuAi.new(2)
        end
      end

      NAME_MAX = 32

      def clean_name(name, node)
        s = name.to_s.dup.force_encoding("UTF-8")
        s = s.scrub("").delete("\u0000-\u001f").strip
        s = s.byteslice(0, NAME_MAX).scrub("") if s.bytesize > NAME_MAX
        s.empty? ? node : s
      end
    end
  end
end
