# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "../game"
require_relative "tiles"
require_relative "engine"

module AsterismGames
  module Mahjong
    # One mahjong table: the people at it, four seats, the game (a hanchan)
    # and the round being played. It holds the wall and the hands; players
    # see what view(seat) gives them. Time is passed in (milliseconds) so
    # tests can drive it.
    #
    # People join the table (join: a member, with a token) and wait in the
    # lobby (status "wait"); a member sits in a seat or stays a spectator.
    # The first member who sat is the table's owner: the owner fills empty
    # seats with CPUs and starts the game once the four seats are taken. At
    # the end of a game the table goes back to the lobby with its seats.
    #
    # Seats are nil (empty, in the lobby only), "human" (a member) or "cpu"
    # (riichi_engine's player). A human who does not decide in time is played
    # for: the drawn tile is discarded, a call is passed. A human's time for
    # a move is turn_ms, and each seat has a bank of bank_ms for the round
    # (README "Time"): a move that takes longer than turn_ms takes the rest
    # from the bank, and the move is played for when both are used up (bank
    # 0: a fixed time per move). A member that has
    # not called the table for away_ms is shown as away; until it comes back
    # its seat is played for after a shorter wait (away_wait_ms instead of
    # turn_ms and call_ms, counted from the start of the wait), so the others
    # are not held up a full turn each time. Back, it has the full times again.
    class Table < Game
      register "mahjong"
      tables "mahjong1", "mahjong2"
      screens "/app/game/mahjong/mahjong.app.rb"
      # The table keys of the settings file (seconds) and of the environment
      # (for every mahjong table), and the table's own (ms) names (README
      # "Settings").
      settings file: {
                 "turn_seconds" => ["turn_ms", 1000], "bank_seconds" => ["bank_ms", 1000],
                 "call_seconds" => ["call_ms", 1000],
                 "result_seconds" => ["result_ms", 1000], "over_seconds" => ["over_ms", 1000],
                 "away_seconds" => ["away_ms", 1000], "away_wait_seconds" => ["away_wait_ms", 1000],
                 "cpu_ms" => ["cpu_ms", 1],
                 "cpu_level" => ["cpu_level", nil], "humans" => ["humans", 1],
                 "spectators" => ["spectators", 1], "spectator_delay_seconds" => ["spectator_delay_ms", 1000],
                 "spectator_delay_minutes" => ["spectator_delay_ms", 60_000],
                 "rule" => ["rule", :hash]
               },
               env: {
                 "MAHJONG_TURN_SECONDS" => ["turn_ms", 1000],
                 "MAHJONG_BANK_SECONDS" => ["bank_ms", 1000],
                 "MAHJONG_CALL_SECONDS" => ["call_ms", 1000],
                 "MAHJONG_RESULT_SECONDS" => ["result_ms", 1000],
                 "MAHJONG_OVER_SECONDS" => ["over_ms", 1000],
                 "MAHJONG_AWAY_SECONDS" => ["away_ms", 1000],
                 "MAHJONG_AWAY_WAIT_SECONDS" => ["away_wait_ms", 1000],
                 "MAHJONG_CPU_MS" => ["cpu_ms", 1],
                 "MAHJONG_CPU_LEVEL" => ["cpu_level", nil],
                 "MAHJONG_SPECTATORS" => ["spectators", 1],
                 "MAHJONG_SPECTATOR_DELAY_SECONDS" => ["spectator_delay_ms", 1000],
                 "MAHJONG_SPECTATOR_DELAY_MINUTES" => ["spectator_delay_ms", 60_000]
               }

      SAVE_FORMAT = 2
      MAX_ROUNDS = 40 # a hanchan has far fewer; a guard against a loop
      ASSIST_LEVELS = 0..3 # README "Assist"
      ASSIST_DEFAULT = 1   # the riichi help (view's default; a screen always says its level)

      DEFAULTS = Game::DEFAULTS.merge(
        "turn_ms" => 5_000,       # a human's time for a move (a discard, riichi, a kan, a win)
        "bank_ms" => 20_000,      # and the bank a move may go on into, one per seat, full again every round (0: none)
        "call_ms" => 8_000,       # every human's time to call a discard
        "cpu_ms" => 700,          # a CPU waits this long before it acts
        "result_ms" => 8_000,     # the result of a round stays this long
        "over_ms" => 60_000,      # the end of a game stays this long (then the lobby)
        "away_wait_ms" => 2_000,  # an away seat's time to discard or call
        "cpu_level" => "normal",  # easy / normal / hard
        "humans" => 4,            # seats members may take (0: CPUs only, at once)
        "spectators" => 12,       # members without a seat at most (a room lets 16 pages in: 4 seats + 12)
        "spectator_delay_ms" => 0, # what spectators see is this old (README "Spectators")
        "rule" => {}              # riichi_engine rule keys over Engine::RULE_DEFAULTS
        # and Game::DEFAULTS: away_ms (10 s), the rooms' room_id, trusted_nodes,
        # trusted_prefix and seat_reuse_ms (README "Who joins")
      ).freeze

      # The local rules the owner chooses in the lobby (README "Local
      # rules"): one value per item, in this order, and rule(token, item,
      # value) changes one. Items 0-9 and 11-14 are riichi_engine rule keys
      # (9 sets two keys together, 11 three), 10 is the host's own time for
      # a move and the bank (time_code), 15 the table's CPUs (RULE_CPU) and
      # 16 the spectators' delay in seconds.
      # The view's "ru" has items 0-10, "rx" items 11-14 and "ry" the rest
      # (the table app reads the three and puts them together).
      # The screen shows them in an order of its own (the numbers stay).
      RULE_ITEMS = [
        ["game", "game_type"],          # 0 hanchan, 1 tonpuu
        ["kuitan", "kuitan"],           # 0 / 1
        ["aka", "aka_dora"],            # red fives: 0, 3 (one each), 4 (two 5p)
        ["double_ron", "double_ron"],
        ["sanchahou", "triple_ron_draw"],
        ["multiple_yakuman", "multiple_yakuman"],
        ["kazoe", "kazoe_yakuman"],
        ["kiriage", "kiriage_mangan"],
        ["tobi", "tobi"],
        ["extra", %w[nishi_iri nan_iri]], # the extra round: west for a hanchan, south for a tonpuu game
        ["turn", nil],                  # the time for a move and the bank (time_code)
        ["abortive", %w[suufon_renda suukaikan suucha_riichi]], # the abortive draws besides nine kinds
        ["nagashi", "nagashi_mangan"],
        ["double_yakuman", "double_yakuman"],
        ["tenpai_yame", "tenpai_yame"],
        ["cpu", nil],                   # the CPUs' level: 0 easy, 1 normal, 2 hard
        ["delay", nil]                  # what spectators see is this many seconds old
      ].freeze
      RULE_RU = 11 # the items in "ru"
      RULE_RX = 15 # and up to here in "rx" (the rest go in "ry")
      RULE_CPU = %w[easy normal hard].freeze
      # Item 16's choices (seconds): none, 1, 3 and 5 minutes.
      RULE_DELAYS = [0, 60, 180, 300].freeze
      RULE_GAMES = %w[hanchan tonpuu].freeze
      RULE_AKA = { 0 => { "m" => 0, "p" => 0, "s" => 0 }, 3 => { "m" => 1, "p" => 1, "s" => 1 },
                   4 => { "m" => 1, "p" => 2, "s" => 1 } }.freeze
      # Item 10's choices, [seconds for a move, seconds of the bank] (bank 0:
      # a fixed time per move): Mahjong Soul's default 5+20 first. The
      # value of the item is time_code: the seconds for a move plus 1000
      # times the bank, so a fixed time is just its seconds. The table app
      # offers the lobby view's "tc".
      RULE_TIMES = [[5, 20], [5, 0], [30, 0], [60, 0], [600, 0]].freeze
      # The public view's keys that belong to the game (a spectator's delayed
      # view takes them from the past, the rest is now).
      GAME_KEYS = %w[st sv r sc ri dora kw fu hc ls ev dl res fin fr].freeze

      attr_reader :sv, :status, :state, :stats, :rule

      def initialize(name, opts = {}, store: nil, log: nil)
        super
        @choice = {}         # the owner's local rules: riichi_engine keys
        @time_choice = nil   # the owner's [time for a move, bank] (ms), nil: the setting's
        @cpu_choice = nil    # the owner's CPU level (RULE_CPU), nil: the setting's
        @delay_choice = nil  # the owner's spectator delay (ms), nil: the setting's
        @rule = effective_rule
        @ai = ai_for(cpu_level)
        @stats = Hash.new(0)
        reset_all
        load_saved(0)
      end

      # ------------------------------------------------------------ members
      #
      # join, mine, leave, the tokens and who joins in a room are the
      # framework's (Game); the table adds the seats to them.

      # join: {"token", "seat" (-1: none), "owner"}.
      def member_reply(node)
        { "token" => @members[node]["token"], "seat" => seat_index(node) || -1, "owner" => @owner == node }
      end

      # A table of 16 members ("full"), or no room for another spectator.
      def join_refusal(node)
        super || (spectators_full? ? "spectators" : nil)
      end

      # A seated member's new name is its seat's too.
      def renamed(node, name)
        i = seat_index(node)
        @seats[i]["name"] = name if i
      end

      # A member leaves (or is forgotten). In the lobby its seat empties;
      # during a game its seat goes to a CPU. The owner's role passes on.
      def forget(node)
        i = seat_index(node)
        if i
          if @status == "wait"
            @seats[i] = nil
          else
            @seats[i] = cpu_seat
            @decl.delete(i)
            @answered.delete(i)
          end
        end
        super
        pass_owner if @owner == node
        name_cpus
      end

      # Seated members stay however long they are away (expire_members).
      def keep_member?(node)
        !seat_index(node).nil?
      end

      # No room for another member without a seat: spectators at most
      # opts["spectators"], and in the lobby as many more as there are seats
      # a member could still take.
      def spectators_full?
        watching = @members.keys.count { |n| seat_index(n).nil? }
        room = @opts["spectators"].to_i
        if @status == "wait"
          humans = @seats.count { |x| x && x["kind"] == "human" }
          room += [@opts["humans"].to_i - humans, 0].max
        end
        watching >= room
      end

      def seat_index(node)
        @seats.index { |s| s && s["kind"] == "human" && s["node"] == node }
      end

      # The member sits (seat -1: the first free one). In the lobby only; a
      # seated member moves. Returns "ok" or why not.
      def sit(token, seat, now)
        node = node_of(token)
        return "token" unless node
        return "not waiting" unless @status == "wait"
        seat = seat.to_i
        if seat.negative?
          return "ok" if seat_index(node)
          seat = (0..3).find { |i| @seats[i].nil? } || (0..3).find { |i| @seats[i]["kind"] == "cpu" }
          return "taken" unless seat
        end
        return "no seat" unless (0..3).cover?(seat)
        cur = seat_index(node)
        return "ok" if cur == seat
        s = @seats[seat]
        return "taken" if s && s["kind"] == "human"
        return "humans" if cur.nil? && @seats.count { |x| x && x["kind"] == "human" } >= @opts["humans"]
        sat = cur ? @seats[cur]["sat"] : (@sit_count += 1)
        @seats[cur] = nil if cur
        m = @members[node]
        @seats[seat] = { "kind" => "human", "node" => node, "token" => m["token"], "name" => m["name"], "sat" => sat }
        @owner ||= node
        m["seen"] = now
        name_cpus
        changed
        "ok"
      end

      # The member stands up (lobby only). The owner's role passes on.
      def stand(token)
        node = node_of(token)
        return "token" unless node
        return "not waiting" unless @status == "wait"
        i = seat_index(node)
        return "not seated" unless i
        @seats[i] = nil
        pass_owner if @owner == node
        changed
        "ok"
      end

      # The owner puts a CPU in an empty seat (on) or takes one out (off);
      # seat -1 with on fills every empty seat.
      def cpu(token, seat, on)
        node = node_of(token)
        return "token" unless node
        return "not waiting" unless @status == "wait"
        return "not owner" unless @owner == node
        seat = seat.to_i
        targets = seat.negative? ? (0..3).to_a : [seat]
        return "no seat" unless targets.all? { |i| (0..3).cover?(i) }
        n = 0
        targets.each do |i|
          s = @seats[i]
          if on && s.nil?
            @seats[i] = cpu_seat
            n += 1
          elsif !on && s && s["kind"] == "cpu"
            @seats[i] = nil
            n += 1
          end
        end
        return "no change" if n.zero?
        name_cpus
        changed
        "ok"
      end

      # ------------------------------------------------------------ local rules

      # The owner sets local rule item (RULE_ITEMS) to value, in the lobby
      # only: the game is played by the rules it started with. Returns "ok"
      # or why not ("no rule", "value").
      def set_rule(token, item, value)
        node = node_of(token)
        return "token" unless node
        return "not waiting" unless @status == "wait"
        return "not owner" unless @owner == node
        item = item.to_i
        return "no rule" unless (0...RULE_ITEMS.size).cover?(item)
        value = value.to_i
        return "value" unless rule_choices(item).include?(value)
        return "no change" if rule_values[item] == value
        name, key = RULE_ITEMS[item]
        base = base_rule
        if name == "turn"
          t = [value % 1000 * 1000, value / 1000 * 1000]
          @time_choice = t == host_time ? nil : t
        elsif name == "cpu"
          @cpu_choice = value == host_cpu ? nil : RULE_CPU[value]
          @ai = ai_for(cpu_level)
        elsif name == "delay"
          @delay_choice = value * 1000 == host_delay_ms ? nil : value * 1000
        else
          own = host_values[item]
          Array(key).each do |k|
            v = case name
                when "game" then RULE_GAMES[value]
                when "aka" then value == aka_total(base["aka_dora"]) ? base["aka_dora"] : RULE_AKA[value]
                else value == 1
                end
            # Back to the host's value: no choice is kept (for the three
            # abortive draws, all three as the host has them). The extra
            # round's two keys go back one by one (its value is the one of
            # the game chosen, not of the host's game).
            back = name == "extra" ? v == base[k] : (value == own || v == base[k])
            if back then @choice.delete(k) else @choice[k] = v end
          end
        end
        @rule = effective_rule
        changed
        "ok"
      end

      # The rule values in RULE_ITEMS order (the view's "ru", "rx", "ry").
      def rule_values
        rule_values_of(@rule.to_h, time_ms, cpu_index(cpu_level), spectator_delay_ms)
      end

      # The host's own values of the items.
      def host_values
        rule_values_of(base_rule, host_time, host_cpu, host_delay_ms)
      end

      # The values an item may take: the screen's choices and the setting's.
      def rule_choices(item)
        name, = RULE_ITEMS[item]
        own = host_values[item]
        case name
        when "aka" then (RULE_AKA.keys + [own]).uniq.sort
        when "turn" then (RULE_TIMES.map { |m, b| m + b * 1000 } + [own]).uniq
        when "cpu" then [0, 1, 2]
        when "delay" then (RULE_DELAYS + [own]).uniq.sort
        else [0, 1]
        end
      end

      def rule_values_of(r, time, cpu, delay_ms)
        RULE_ITEMS.map do |name, key|
          case name
          when "game" then r["game_type"].to_s.start_with?("tonpuu") ? 1 : 0
          when "aka" then aka_total(r["aka_dora"])
          when "turn" then time_code(time)
          when "cpu" then cpu
          when "delay" then delay_ms / 1000
          when "abortive" then key.all? { |k| r[k] } ? 1 : 0
          when "extra" then r[r["game_type"].to_s.start_with?("tonpuu") ? "nan_iri" : "nishi_iri"] ? 1 : 0
          else r[key] ? 1 : 0
          end
        end
      end

      def aka_total(h)
        h.is_a?(Hash) ? h.values.sum(&:to_i) : 0
      end

      # The host's rules (Engine::RULE_DEFAULTS and the table's "rule"
      # setting), as riichi_engine keys.
      def base_rule
        Engine::RULE_DEFAULTS.merge((@opts["rule"] || {}).transform_keys(&:to_s))
      end

      def effective_rule
        Engine.rule(base_rule.merge(@choice))
      end

      # Item 10's value for [time for a move, bank] (ms): the seconds for a
      # move plus 1000 times the seconds of the bank.
      def time_code(time)
        time[0].to_i / 1000 + time[1].to_i / 1000 * 1000
      end

      # The host's [time for a move, bank] (ms), the table's settings.
      def host_time
        [@opts["turn_ms"].to_i, @opts["bank_ms"].to_i]
      end

      # The table's [time for a move, bank] (ms): the owner's choice or the
      # host's.
      def time_ms
        @time_choice || host_time
      end

      def turn_ms
        time_ms[0]
      end

      def bank_ms
        time_ms[1]
      end

      # The CPUs' level: the owner's choice or the setting's.
      def cpu_level
        @cpu_choice || @opts["cpu_level"].to_s
      end

      # RULE_CPU's index of a level (what ai_for plays: normal when unknown).
      def cpu_index(level)
        RULE_CPU.index(level.to_s) || 1
      end

      def host_cpu
        cpu_index(@opts["cpu_level"])
      end

      # What spectators see is this old (ms): the owner's choice or the
      # setting's.
      def spectator_delay_ms
        @delay_choice || host_delay_ms
      end

      def host_delay_ms
        @opts["spectator_delay_ms"].to_i
      end

      # What is left of a seat's bank (ms).
      def bank_left(seat)
        @banks ? @banks[seat].to_i : 0
      end

      # A seat's move is over (it acted, or its time ran out): what it took
      # beyond the time for a move comes off its bank.
      def spend_bank(seat, now)
        return unless @banks && @wait_from && human?(seat)
        over = now - @wait_from - turn_ms
        @banks[seat] = [@banks[seat].to_i - over, 0].max if over.positive?
      end

      # The owner starts the game: four seats taken, at least one human. The
      # seats are drawn (who sits where, so who deals first).
      def start(token, now)
        node = node_of(token)
        return "token" unless node
        return "not waiting" unless @status == "wait"
        return "not owner" unless @owner == node
        return "seats" unless @seats.all?
        return "no human" if @seats.none? { |s| s["kind"] == "human" }
        @seats = @seats.shuffle(random: Random.new(SecureRandom.random_number(2**32)))
        name_cpus
        start_game(now)
        @log&.call("mahjong: #{@name}: game started (#{@seats.map { |s| s['name'] }.join(', ')}; " \
                   "rules #{rule_values.inspect})")
        tick(now)
        "ok"
      end

      def seat_of(token)
        return nil unless token.is_a?(String) && !token.empty?
        @seats.index { |s| s && s["kind"] == "human" && s["token"] == token }
      end

      def human?(seat)
        s = @seats[seat]
        s && s["kind"] == "human"
      end

      def away?(seat)
        s = @seats[seat]
        return false unless s && s["kind"] == "human"
        member_away?(s["node"])
      end

      # ------------------------------------------------------------ actions

      # A player's action: type (Engine::DAHAI ...) and tiles (names). sv is
      # the state version the player saw. Returns "ok" or why not.
      def act(token, sv, type, tiles, now)
        seat = seat_of(token)
        return (node_of(token) ? "not seated" : "token") unless seat
        return "stale" unless sv == @sv
        if type == Engine::NEXT
          return next_now(seat, now) ? "ok" : "not offered"
        end
        return "not playing" unless @status == "play"
        a = Engine.match(offers(seat), type, tiles)
        unless a
          @stats["refused"] += 1
          return "not offered"
        end
        a[:seat] = seat
        if @state.phase == :naki_wait
          # An answer to the calls is the seat's own: the others' views and
          # the put stay as they are (README "Calls on a discard"), only
          # the seat's view moves on (seat_version).
          @decl[seat] = a
          @answered << seat unless @answered.include?(seat)
          @unsaved = true
        else
          spend_bank(seat, now)
          @deadline = nil
          apply(a, now)
        end
        tick(now)
        "ok"
      end

      # What a seat may do now ([[type, [tile names]], ...]).
      def offers(seat)
        return [] if seat.nil? || seat.negative?
        case @status
        when "result" then return human?(seat) ? [[Engine::NEXT, []]] : []
        when "over" then return human?(seat) && @seats[seat]["node"] == @owner ? [[Engine::NEXT, []]] : []
        when "play" then nil
        else return []
        end
        return [] if @state.phase == :naki_wait && @decl.key?(seat)
        Engine.offers(@state, seat, @rule)
      end

      # ------------------------------------------------------------ time

      # Moves the game on: draws, CPU turns, timeouts, the next round.
      def tick(now)
        @now = now
        aw = bits { |i| away?(i) }
        if aw != @away_bits
          @log&.call("mahjong: #{@name}: away seats #{(0..3).select { |i| aw[i] == 1 }.inspect}") if @status != "wait"
          @away_bits = aw
          changed
        end
        expire_members(now)
        200.times { break unless step(now) }
        note_for_spectators(now)
      end

      # ------------------------------------------------------------ spectators

      # With a spectator delay, what the game looked like at every state
      # version and status, kept for spectator_delay_ms: [[time, game part
      # of the public view], ...]. The first entry is what spectators see
      # (the newest one at least the delay old, or the oldest kept). When it
      # moves on, the table counts as changed, so spectators ask again.
      def note_for_spectators(now)
        delay = spectator_delay_ms
        return if delay <= 0
        key = [@sv, @status]
        if @spec_key != key
          @spec_key = key
          @spec_hist << [now, game_part(public_view(now)).merge(hands_part)]
        end
        @spec_hist.shift while @spec_hist.size > 1 && @spec_hist[1][0] <= now - delay
        first = @spec_hist.first
        return if first.nil? || first.equal?(@spec_shown)
        @spec_shown = first
        changed
      end

      def game_part(v)
        out = {}
        GAME_KEYS.each { |k| out[k] = v[k] if v.key?(k) }
        out.delete("dl") # a deadline in the past says nothing
        out
      end

      # What the public put and table show: the people as they are now, the
      # game as it was spectator_delay_ms ago. No hand but the winners' at
      # a win, as public_view. A spectator's own view (hands) has the four
      # hands too ("sh", "sd", hands_part), as old as the rest.
      def spectator_view(now, hands: false)
        v = public_view(now)
        e = spectator_delay_ms.positive? && @spec_hist.first
        unless e
          v.merge!(hands_part) if hands
          return v
        end
        GAME_KEYS.each { |k| v.delete(k) }
        v.merge!(e[1])
        v.delete("sh") unless hands
        v.delete("sd") unless hands
        v
      end

      def step(now)
        case @status
        when "result"
          return false if now < @next_at
          next_round(now)
          true
        when "over"
          return false if @opts["humans"].to_i.zero? || @next_at.nil? || now < @next_at
          to_lobby
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
            return set_deadline(1 << seat, now + turn_ms + bank_left(seat), now) if @deadline.nil?
            return false if now < turn_deadline(seat)
            @stats["timeouts"] += 1
            @stats["away_turns"] += 1 if away?(seat)
            spend_bank(seat, now)
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

      # The calls on a discard. Every seat the engine offers something gets
      # one answer: the CPUs at once, the humans by their own act or a pass
      # at the common deadline (call_ms from the discard). Once all have
      # answered, the engine's priority decides (ron over pon and kan over
      # chi; several rons by the rule: double ron, three rons a draw).
      def step_calls(now)
        st = @state
        seats = st.pending_actions.keys.sort
        humans = seats.select { |s| human?(s) }
        if @deadline.nil? && humans.any? { |s| !@decl.key?(s) }
          if humans.size >= 2
            @stats["multi_human_calls"] += 1
            @log&.call("mahjong: #{@name}: calls: humans #{humans.inspect} may call (cpus #{(seats - humans).inspect})")
          end
          # No change of the view for it: the discard just made one, and a
          # window with a human in it must not look different from one
          # with CPUs only.
          set_deadline(bits { |i| humans.include?(i) && !@decl.key?(i) }, now + @opts["call_ms"], now, bump: false)
        end
        seats.each do |seat|
          next if @decl.key?(seat) || human?(seat)
          @decl[seat] = Engine.cpu_choice(st, seat, @rule, @ai) || { type: :skip, seat: seat }
        end
        waiting = humans.reject { |s| @decl.key?(s) }
        # An away seat passes after its short wait; the others keep theirs.
        if @deadline && !waiting.empty? && now >= away_deadline
          waiting.select { |s| away?(s) }.each do |s|
            @stats["timeouts"] += 1
            @stats["away_calls"] += 1
            @decl[s] = { type: :skip, seat: s }
          end
          waiting = humans.reject { |s| @decl.key?(s) }
        end
        unless waiting.empty?
          return false if now < @deadline
          waiting.each do |s|
            @stats["timeouts"] += 1
            @stats["away_calls"] += 1 if away?(s)
            @decl[s] = { type: :skip, seat: s }
          end
        end
        human_called = @decl.any? { |s, a| human?(s) && a[:type].to_sym != :skip }
        return wait_cpu(now) if !human_called && !cpu_ready?(now)
        resolve_calls(now)
        true
      end

      def resolve_calls(now)
        st = @state
        decl = @decl
        clear_decl
        @deadline = nil
        @deadline_bits = 0
        @cpu_at = nil
        won = Engine.resolve_calls(decl, st.last_dahai[:seat], @rule)
        keep = won ? Engine.winners_of(won) : []
        if won && keep.size >= 2
          @stats["multi_ron_#{won[:type]}"] += 1
          @log&.call("mahjong: #{@name}: #{won[:type]} by #{keep.inspect}")
        end
        st.pending_actions.keys.sort.each do |seat|
          next if keep.include?(seat)
          apply({ type: :skip, seat: seat }, now)
        end
        # The last pass says nothing of who could have called.
        @event = [Engine::SKIP, -1] if @event && @event[0] == Engine::SKIP
        apply(won, now) if won
      end

      # The answers to the calls are gone (decided, or a new round). A seat
      # whose view moved on by its own answer (seat_version) is one ahead
      # of the others: the change of the table that follows has to be two,
      # so every view's version goes past what that seat saw.
      def clear_decl
        @decl = {}
        return if @answered.empty?
        @answered = []
        changed
      end

      # The version in a seat's view: the table's, one more after the
      # seat's own answer to the calls (its buttons go; nobody else sees a
      # change).
      def seat_version(seat)
        @ver + (seat >= 0 && @answered.include?(seat) ? 1 : 0)
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

      # The deadline of the seats in mask (bits); the wait starts at from.
      def set_deadline(mask, at, from, bump: true)
        @deadline = at
        @deadline_bits = mask
        @wait_from = from
        bump ? changed : (@unsaved = true)
        false
      end

      # When an away seat's wait ends (away_wait_ms from the start of the
      # wait, never later than everybody's deadline).
      def away_deadline
        return @deadline if @wait_from.nil?
        [@deadline, @wait_from + @opts["away_wait_ms"]].min
      end

      # The deadline of the seat whose turn it is: shorter while it is away.
      def turn_deadline(seat)
        away?(seat) ? away_deadline : @deadline
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
        @deadline = nil unless @state.phase == :naki_wait
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
                  "honba" => flow.next_honba, "oya" => flow.next_oya_index, "reason" => flow.reason.to_s }
        @result = res
        @status = "result"
        @next_at = now + @opts["result_ms"]
        @deadline = nil
        @cpu_at = nil
        clear_decl
        @stats["rounds"] += 1
        @stats["round_#{res['kind']}"] += 1
        @stats["double_ron"] += 1 if Array(res["wins"]).size >= 2
        pts = Array(res["wins"]).map { |w| w["points"] }
        @log&.call("mahjong: #{@name}: round over: #{res['kind']} #{pts.inspect} #{@game['scores'].inspect}")
      end

      # The "next" button: on a round's result (any seated human) or a
      # finished game (the owner: back to the lobby).
      def next_now(seat, now)
        case @status
        when "result" then next_round(now)
        when "over"
          return false unless offers(seat).any?
          to_lobby
        else return false
        end
        tick(now)
        true
      end

      def next_round(now)
        f = @flow
        @game["rounds"] += 1
        # With sudden_death riichi_engine ends the extra round itself (after
        # its fourth round at the latest); without it the west round goes on
        # until somebody reaches the threshold (west 4 is followed by west 1
        # again), and the host ends the game after west 4.
        west_over = @game["bakaze"] == "sha" && f["bakaze"] == "sha" && f["kyoku"].to_i < @game["kyoku"].to_i
        if f["end"] || west_over || @game["rounds"] >= MAX_ROUNDS
          # Why the game ended (the view's "fr"): the engine's reason (tobi,
          # normal_end, all_last_oya_agari, all_last_oya_tenpai,
          # sudden_death), "west" after west 4 (without sudden_death),
          # "rounds" at MAX_ROUNDS.
          @final_reason = if f["end"] then f["reason"]
                          elsif west_over then "west"
                          else "rounds"
                          end
          @final = final_results.map { |r| [r.seat, r.rank, r.score, (r.point * 10).round] }
          @status = "over"
          @next_at = now + @opts["over_ms"]
          @stats["games"] += 1
          @log&.call("mahjong: #{@name}: game over (#{@final_reason}): #{@final.inspect}")
        else
          @game.merge!("bakaze" => f["bakaze"], "kyoku" => f["kyoku"], "honba" => f["honba"], "oya" => f["oya"])
          new_round
        end
        changed
      end

      # The ranks at the end of a game. The riichi sticks still on the table
      # go to the top. Equal points rank by seat from the first dealer
      # (riichi_engine ranks equals by seat number, and the first dealer
      # here is always seat 0).
      def final_results
        scores = (0..3).to_h { |s| [s, @game["scores"][s]] }
        ranked = Engine::API.calculate_ranked_results(scores: scores, rule: @rule)
        left = @game["kyoutaku"].to_i
        return ranked unless left.positive?

        top = ranked.first.seat
        scores[top] += left * 1000
        @game["scores"][top] = scores[top]
        @game["kyoutaku"] = 0
        Engine::API.calculate_ranked_results(scores: scores, rule: @rule)
      end

      # The end of a game: back to the lobby, the seats as they were (the
      # CPUs stay; members that left during the game were replaced by CPUs).
      def to_lobby
        @status = "wait"
        @state = nil
        @game = nil
        @banks = nil
        @result = nil
        @flow = nil
        @final = nil
        @final_reason = nil
        @event = nil
        @deadline = nil
        @deadline_bits = 0
        @next_at = nil
        clear_decl
        @sv += 1
        changed
      end

      def start_game(now)
        @game = { "bakaze" => "ton", "kyoku" => 1, "honba" => 0, "kyoutaku" => 0, "oya" => 0,
                  "scores" => [@rule.initial_score] * 4, "rounds" => 0 }
        @final = nil
        @final_reason = nil
        new_round
        changed
      end

      def new_round
        # The banks are full again at the start of every round.
        @banks = [bank_ms] * 4
        @state = Engine.setup(@game, @rule)
        @status = "play"
        @result = nil
        @flow = nil
        clear_decl
        @deadline = nil
        @deadline_bits = 0
        @cpu_at = nil
        @event = nil
        @sv += 1
      end

      # ------------------------------------------------------------ views

      # What everybody may see: no hand but the winners' at a win.
      def public_view(now)
        @now = now
        v = { "v" => @ver, "sv" => @sv, "t" => @name, "st" => @status,
              "nm" => @seats.map { |s| s ? s["name"].to_s : "" },
              "hu" => bits { |i| human?(i) },
              "sk" => @seats.map { |s| s.nil? ? 0 : (s["kind"] == "human" ? 1 : 2) },
              "aw" => bits { |i| away?(i) },
              "ow" => (@owner && seat_index(@owner)) || -1,
              "mb" => member_list }
        ru = rule_values
        v["ru"] = ru[0, RULE_RU]
        v["rx"] = ru[RULE_RU...RULE_RX]
        v["ry"] = ru[RULE_RX..]
        # Item 10 in "ru" is the seconds for a move; "tb" is the bank's
        # seconds (the table app adds them up again), and in the lobby "tc"
        # the item's choices (time_code).
        v["ru"][10] = ru[10] % 1000
        v["tb"] = ru[10] / 1000
        if @status == "wait"
          v["tc"] = rule_choices(10)
          v["dc"] = rule_choices(16) # the spectator delays to choose from (seconds)
        end
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
          v["dl"] = deadline_view(now)
        end
        v["res"] = result_view if @result && (@status == "result" || @status == "over")
        v["fin"] = @final if @final
        v["fr"] = @final_reason if @final && @final_reason
        v
      end

      # Counts for the host's status (Host#status_now, the console's admin
      # page): no names, no nodes, no tokens.
      def summary(now)
        humans = (0..3).count { |i| human?(i) }
        { "st" => @status, "members" => @members.size, "humans" => humans,
          "cpus" => @seats.count { |s| s && s["kind"] == "cpu" },
          "away" => (0..3).count { |i| human?(i) && away?(i) },
          "round" => @game ? [Engine::BAKAZE.index(@game["bakaze"]), @game["kyoku"]] : nil }
      end

      # "dl": [seats, ms left] and, on a seat's own move with a bank, the
      # bank's ms (the last part of the ms left; the time for the move is
      # what comes before it). An away seat's move shows no bank (it is
      # played for after away_wait_ms).
      #
      # In the calls on a discard nobody learns who else may call (README
      # "Calls on a discard"): a seat that still has to answer sees its own
      # bit, every other seat the three bits of the others (the same
      # whoever they are: "the others are answering"), and the public view
      # (spectators, the put, table) nothing.
      def deadline_view(now, seat = nil)
        return nil unless @deadline
        st = @state
        if st && st.phase == :naki_wait
          return nil if seat.nil? || seat.negative?
          ms = [@deadline - now, 0].max
          return [1 << seat, ms] if human?(seat) && st.pending_actions.key?(seat) && !@decl.key?(seat)
          return [0b1111 & ~(1 << seat), ms]
        end
        out = [@deadline_bits, [shown_deadline - now, 0].max]
        if st.phase == :dahai && human?(st.current_seat) && !away?(st.current_seat)
          b = bank_left(st.current_seat)
          out << b if b.positive?
        end
        out
      end

      # The deadline a view shows: an away seat's own turn ends sooner.
      def shown_deadline
        st = @state
        return @deadline unless st && st.phase == :dahai
        turn_deadline(st.current_seat)
      end

      # The members in the order they joined: [name, seat (-1 none), flags]
      # (flags: 1 away, 2 owner).
      def member_list
        @members.sort_by { |_n, m| m["at"].to_i }.map do |node, m|
          [m["name"].to_s, seat_index(node) || -1, (member_away?(node) ? 1 : 0) | (@owner == node ? 2 : 0)]
        end
      end

      # One seat's view (seat -1: a spectator member): the public one, the
      # hand, what it may do and the help its screen asked for (assist, the
      # level of README "Assist"; a screen that does not say gets 1).
      def view(seat, now, assist = ASSIST_DEFAULT)
        v = seat >= 0 ? public_view(now) : spectator_view(now, hands: true)
        v["me"] = seat
        if seat >= 0
          v["v"] = seat_version(seat)
          v["dl"] = deadline_view(now, seat) if v.key?("dl")
        end
        if seat >= 0 && @state && @status != "wait"
          h, d = hand_of(seat)
          v["h"] = h
          v["dt"] = d
        end
        a = offers(seat)
        v["a"] = a.map { |t, ts| [t, Tiles.pack(ts).b] }
        wt, uk = assist_help(seat, a, assist)
        v["wt"] = wt if wt
        v["uk"] = uk if uk
        v
      end

      # The help for one seat's screen at its level (README "Assist"), as
      # [wt, uk] (binary strings or nil): level 1 the waits after each
      # discard that declares riichi; 2 the waits after each discard that
      # leaves the hand tenpai, with melds or without riichi too; 3 as 2, and
      # when no discard leaves it tenpai, the shanten and the acceptance
      # after each discard. Worked out once per state version, seat and
      # level; the time each takes goes to @assist_ms.
      #   wt: per discard the tile, the number of waits n, n pairs [wait, left]
      #   uk: per discard the tile, the shanten after it, the number of
      #       tiles n that bring it down, n pairs [tile, left]
      def assist_help(seat, offers, level)
        level = level.to_i
        return [nil, nil] if level <= 0 || seat.negative? || @state.nil? || @status != "play"
        c = @assist[[seat, level]]
        return c[1] if c && c[0] == @sv
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        out = level == 1 ? [riichi_help(seat, offers), nil] : tenpai_help(seat, offers, level)
        @assist[[seat, level]] = [@sv, out]
        note_assist_ms((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0) if out[0] || out[1]
        out
      end

      # A seat's hand as a view shows it: [the tiles sorted, without the
      # drawn one (bytes), the drawn tile (-1: none)].
      def hand_of(seat)
        st = @state
        hand = st.hands[seat].tiles.map(&:to_s)
        drawn = nil
        if st.phase == :dahai && st.current_seat == seat && st.last_tsumo
          drawn = st.last_tsumo.to_s
          hand.delete_at(hand.index(drawn))
        end
        [Tiles.pack(Tiles.sort(hand)).b, drawn ? Tiles.code(drawn) : -1]
      end

      # The four hands for the spectators (README "Spectators"): "sh" the
      # hands as hand_of gives them, "sd" the drawn tiles. Never in the
      # public view, the put or table.
      def hands_part
        return {} unless @state && @status != "wait"
        hs = (0..3).map { |s| hand_of(s) }
        { "sh" => hs.map(&:first), "sd" => hs.map(&:last) }
      end

      def riichi_help(seat, offers)
        o = offers.find { |t, _ts| t == Engine::RIICHI }
        o ? waits_bytes(Engine.waits_after(@state, seat, o[1])) : nil
      end

      def tenpai_help(seat, offers, level)
        o = offers.find { |t, _ts| t == Engine::DAHAI }
        return [nil, nil] unless o
        names = o[1].uniq
        st = @state
        melds = st.fuuros[seat].size
        hand = st.hands[seat]
        tenpai = names.select { |n| Engine.shanten(hand.remove(n).to_34, melds).zero? }
        waits = Engine.waits_after(st, seat, tenpai).reject { |_d, w| w.empty? }
        return [waits_bytes(waits), nil] unless waits.empty?
        return [nil, nil] if level < 3
        out = []
        Engine.ukeire_after(st, seat, names).each do |d, sh, list|
          out << Tiles.code(d) << sh << list.size
          list.each { |w, left| out << Tiles.code(w) << left }
        end
        [nil, out.pack("C*").b]
      end

      def waits_bytes(list)
        out = []
        list.each do |d, waits|
          out << Tiles.code(d) << waits.size
          waits.each { |w, left| out << Tiles.code(w) << left }
        end
        out.pack("C*").b
      end

      # The help's times (ms), the last ASSIST_TIMES of them (assist_times).
      ASSIST_TIMES = 5000

      def note_assist_ms(ms)
        @assist_ms << ms
        @assist_ms.shift if @assist_ms.size > ASSIST_TIMES
        @stats["assist"] += 1
      end

      def assist_times
        @assist_ms.dup
      end

      # A member's view by its token (nil: not a member).
      def member_view(token, now, assist = ASSIST_DEFAULT)
        node = node_of(token)
        return nil unless node
        view(seat_index(node) || -1, now, assist)
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
          meld_order(f, kind, from).each { |t| out << Tiles.code(t) }
        end
        out.pack("C*").b
      end

      # A meld's tiles in the order a table shows them: the called tile where
      # it lies sideways (first when taken from the left, second from across,
      # last from the right; for an added kan the last of the first three, the
      # added tile after them).
      def meld_order(f, kind, from)
        tiles = f.tiles.map(&:to_s)
        called = f.respond_to?(:called_tile) && f.called_tile ? f.called_tile.to_s : nil
        return tiles if called.nil? || from.zero? || kind == 3 || !(i = tiles.index(called))
        tiles.delete_at(i)
        n = kind == 5 ? 3 : tiles.size + 1
        at = { 3 => 0, 2 => 1, 1 => n - 1 }[from]
        tiles.insert(at, called)
      end

      def result_view
        r = @result
        v = { "k" => r["kind"], "d" => r["delta"], "rd" => r["round"] }
        v["f"] = r["from"] unless r["from"].nil?
        if r["wins"]
          v["wn"] = r["wins"].map do |w|
            x = { "w" => w["winner"], "y" => w["yaku"], "pt" => w["points"],
                  "h" => Tiles.pack(Tiles.sort(w["hand"])).b, "ag" => Tiles.code(w["agari"]) }
            # The han of each yaku (-1: a yakuman), in the order of "y".
            x["yh"] = w["yaku_han"] if w["yaku_han"]
            # Pao: [[the seat that pays, the yakuman], ...].
            x["pa"] = w["pao"] if w["pao"]
            x
          end
        end
        v["tp"] = r["tenpai"] if r["tenpai"]
        v["ng"] = r["nagashi"] if r["nagashi"]
        v["rs"] = r["ron_seats"] if r["ron_seats"]
        v
      end

      # ------------------------------------------------------------ saving
      #
      # changed, dirty?, unsaved? and save are the framework's (Game). A
      # change only a seat's own view shows (an answer to the calls) sets
      # @unsaved: saved, not put (Host#step).

      def to_saved(now)
        { "format" => SAVE_FORMAT, "name" => @name, "ver" => @ver, "sv" => @sv, "status" => @status,
          "seats" => @seats, "owner" => @owner,
          "members" => saved_members,
          "counts" => [@join_count, @sit_count],
          "game" => @game, "round" => @state&.to_json,
          "decl" => @decl.to_h { |k, a| [k.to_s, saved_action(a)] },
          "deadline_left" => @deadline && [@deadline - now, 0].max, "deadline_bits" => @deadline_bits,
          "wait_spent" => @deadline && @wait_from && [now - @wait_from, 0].max,
          "cpu_left" => @cpu_at && [@cpu_at - now, 0].max, "next_left" => @next_at && [@next_at - now, 0].max,
          "result" => @result, "flow" => @flow, "final" => @final, "final_reason" => @final_reason, "event" => @event,
          "banks" => @banks,
          "rules" => { "choice" => @choice, "turn_ms" => @time_choice&.at(0), "bank_ms" => @time_choice&.at(1),
                       "cpu" => @cpu_choice, "delay_ms" => @delay_choice } }
      end

      def saved_action(a)
        a.transform_keys(&:to_s).transform_values { |x| x.is_a?(Symbol) ? x.to_s : x }
      end

      # A saved state of SAVE_FORMAT back (Game#load_saved: then resume_clock).
      def restore(d, now)
        @ver = d["ver"].to_i + 1
        @sv = d["sv"].to_i
        @status = d["status"]
        @seats = d["seats"]
        @owner = d["owner"]
        @members = d["members"] || {}
        @join_count, @sit_count = d["counts"] || [0, 0]
        name_cpus
        @game = d["game"]
        @state = d["round"] ? Engine::API.deserialize_round_state(d["round"]) : nil
        @decl = (d["decl"] || {}).to_h do |k, a|
          [k.to_i, a.to_h { |kk, x| [kk.to_sym, kk == "type" ? x.to_sym : x] }]
        end
        @deadline_bits = d["deadline_bits"].to_i
        @result = d["result"]
        @flow = d["flow"]
        @final = d["final"]
        @final_reason = d["final_reason"]
        @event = d["event"]
        rules = d["rules"].is_a?(Hash) ? d["rules"] : {}
        @choice = rules["choice"].is_a?(Hash) ? rules["choice"] : {}
        # A table saved before the bank chose a fixed time ("turn_ms" alone).
        @time_choice = rules["turn_ms"] && [rules["turn_ms"].to_i, rules["bank_ms"].to_i]
        @cpu_choice = RULE_CPU.include?(rules["cpu"]) ? rules["cpu"] : nil
        @delay_choice = rules["delay_ms"]&.to_i
        @rule = effective_rule
        @ai = ai_for(cpu_level)
        # A game saved before the bank starts with full banks.
        @banks = if d["banks"].is_a?(Array) && d["banks"].size == 4 then d["banks"].map(&:to_i)
                 elsif @game then [bank_ms] * 4
                 end
        @log&.call("mahjong: #{@name}: resumed (#{@status}, state #{@sv}, #{@members.size} members)")
      end

      # Times read back are relative to when they were saved; a host started
      # again calls this with its own clock. Members count as just seen.
      def resume_clock(now, d = saved)
        return unless d
        @deadline = d["deadline_left"] && now + d["deadline_left"]
        @wait_from = @deadline && now - d["wait_spent"].to_i
        @cpu_at = d["cpu_left"] && now + d["cpu_left"]
        @next_at = d["next_left"] && now + d["next_left"]
        super
      end

      # ------------------------------------------------------------ setup

      def reset_all
        @ver = 1
        @sv = 0
        @assist = {}          # [seat, level] => [state version, [wt, uk]]
        @assist_ms = []
        @spec_hist = []       # README "Spectators"
        @spec_key = nil
        @spec_shown = nil
        @now = 0
        @status = "wait"
        @seats = [nil] * 4
        reset_members
        @owner = nil
        @sit_count = 0
        @away_bits = 0
        @game = nil
        @state = nil
        @banks = nil
        @decl = {}
        @deadline = nil
        @deadline_bits = 0
        @cpu_at = nil
        @next_at = nil
        @result = nil
        @flow = nil
        @final = nil
        @final_reason = nil
        @event = nil
        @answered = []        # seats whose own answer to the calls moved their view on
        @dirty = true
        @unsaved = false
        return unless @opts["humans"].to_i.zero?
        @seats = (0..3).map { cpu_seat }
        name_cpus
        start_game(0)
      end

      # The owner's role goes to the seated member who sat first (none: the
      # next to sit).
      def pass_owner
        seated = @seats.compact.select { |s| s["kind"] == "human" }
        @owner = seated.min_by { |s| s["sat"].to_i }&.fetch("node")
      end

      def cpu_seat
        { "kind" => "cpu" }
      end

      # The CPUs are numbered among themselves in seat order (CPU1, CPU2,
      # CPU3 whichever seats the players took).
      def name_cpus
        n = 0
        @seats.each { |s| s["name"] = "CPU#{n += 1}" if s && s["kind"] == "cpu" }
      end

      def ai_for(level)
        case level.to_s
        when "easy" then ::Mahjong::Cpu::Ai::EasyAi.new
        when "hard" then ::Mahjong::Cpu::Ai::HardAi.new
        else ::Mahjong::Cpu::Ai::NormalAi.new
        end
      end
    end
  end
end
