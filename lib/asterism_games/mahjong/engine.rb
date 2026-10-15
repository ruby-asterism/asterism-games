# frozen_string_literal: true

require "riichi_engine"
require "securerandom"

module AsterismGames
  module Mahjong
    # The calls into riichi_engine 0.1.0 (RiichiEngine::API), with the
    # corrections this host needs around it. Each correction is marked
    # "engine 0.1.0:" with what goes wrong without it; README "riichi_engine"
    # lists them for the author.
    module Engine
      API = RiichiEngine::API

      # Action numbers on the wire (the table screen's buttons).
      DAHAI = 1
      RIICHI = 2
      TSUMO_AGARI = 3
      ANKAN = 4
      KAKAN = 5
      PON = 6
      CHI = 7
      DAIMINKAN = 8
      RON = 9
      SKIP = 10
      KYUUSHU = 11
      NEXT = 12

      TYPE_OF = {
        dahai: DAHAI, riichi: RIICHI, tsumo_agari: TSUMO_AGARI, ankan: ANKAN, kakan: KAKAN,
        pon: PON, chi: CHI, daiminkan: DAIMINKAN, ron_agari: RON, skip: SKIP, kyuushu_kyuuhai: KYUUSHU
      }.freeze
      SYM_OF = TYPE_OF.invert.freeze

      # Priority of a call (lower first) when several seats call one discard.
      CALL_PRIORITY = { RON => 1, DAIMINKAN => 2, PON => 2, CHI => 3 }.freeze

      BAKAZE = %w[ton nan sha pei].freeze

      # The CPU player: riichi_engine's, with the discard chosen the other way
      # round. engine 0.1.0: DahaiSelector (normal and hard) sorts the
      # candidates by ukeire ascending and takes the first, so it keeps the
      # hand that accepts the fewest tiles; most rounds end in a draw (8 of 9
      # in a CPU-only hanchan). Here the discard keeps the most acceptance.
      class CpuAi < ::Mahjong::Cpu::Ai::NormalAi
        def initialize(level = 2)
          super()
          @level = level
        end

        private

        # BaseAi#think_dahai with the discard of best_discard.
        def think_dahai(state, seat, available, _rule)
          agari = available.find { |a| a[:type] == :tsumo_agari }
          return agari if agari
          riichi = available.find { |a| a[:type] == :riichi }
          if riichi && ::Mahjong::Cpu::Judges::RiichiJudge.should_riichi?(state: state, seat: seat, level: level)
            return { type: :riichi, tile: riichi[:choices]&.first || state.last_tsumo.to_s }
          end
          ankan = available.find { |a| a[:type] == :ankan }
          return ankan if ankan
          { type: :dahai, tile: best_discard(state, seat) }
        end

        def best_discard(state, seat)
          hand = state.hands[seat]
          visible = []
          4.times do |s|
            state.kawas[s].tiles.each { |k| visible << k.tile }
            state.fuuros[s].each { |f| visible.concat(f.tiles) }
          end
          visible.concat(state.dora_hyouji)
          evals = ::Mahjong::Cpu::Analysis::TileEvaluator.evaluate_all_discards(hand, visible_tiles: visible)
          min = evals.values.map(&:shanten).min
          best = evals.select { |_t, r| r.shanten == min }.min_by do |t, r|
            tile = ::Mahjong::Tiles::Tile.new(t)
            danger = tile.jihai? ? 0 : (tile.routou? ? 1 : (tile.effective_number.between?(4, 6) ? 3 : 2))
            [-r.ukeire, danger, tile.aka? ? 1 : 0, t]
          end
          best ? best[0] : hand.tiles.last.to_s
        end
      end

      module_function

      def rule(game_type: "hanchan")
        ::Mahjong::Config::RuleConfig.new("game_type" => game_type)
      end

      # A seed for the wall. engine 0.1.0: Wall.build turns the seed into a
      # number with String#to_i(36), which stops at the first character that
      # is not 0-9a-z: "round-001" and "round-002" give the same wall. Only
      # [0-9a-z] here, and long enough to be unguessable.
      def new_seed
        SecureRandom.alphanumeric(24).downcase
      end

      def setup(game, rule)
        snap = ::Mahjong::Snapshots::GameSetupSnapshot.new(
          bakaze: game["bakaze"], kyoku: game["kyoku"], honba: game["honba"],
          kyoutaku: game["kyoutaku"], oya_index: game["oya"], scores: int_keys(game["scores"])
        )
        API.setup_round(game_snapshot: snap, rule: rule, seed: new_seed)
      end

      # {seat => value} from a Hash with String keys or an Array.
      def int_keys(h)
        return h.each_with_index.to_h { |v, i| [i, v] } if h.is_a?(Array)
        h.to_h { |k, v| [k.to_i, v] }
      end

      # What a seat may do now, as [[type, [tile names]], ...]:
      #   DAHAI   one entry, the tiles it may discard
      #   RIICHI  one entry, the discards that declare riichi
      #   ANKAN / KAKAN  one entry per tile
      #   PON / CHI      one entry per pair of tiles from the hand
      #   the others     no tiles
      def offers(state, seat, rule)
        list = API.available_round_actions(state: state, seat: seat, rule: rule)
        out = []
        dahai = []
        list.each do |a|
          t = TYPE_OF[a[:type].to_sym]
          next unless t
          case t
          when DAHAI then dahai << a[:tile].to_s
          when RIICHI then out << [RIICHI, a[:choices].map(&:to_s)]
          when ANKAN, KAKAN then out << [t, [a[:tile].to_s]]
          when PON then out << [PON, Array(a[:tiles]).map(&:to_s)]
          when CHI
            if a[:choices]
              a[:choices].each { |c| out << [CHI, c.map(&:to_s)] }
            else
              out << [CHI, Array(a[:tiles]).map(&:to_s)]
            end
          else out << [t, []]
          end
        end
        # engine 0.1.0: available_round_actions gives a seat in riichi no
        # discard at all (only a tsumo win, when there is one), which leaves
        # the turn stuck. A seat in riichi discards the tile it drew.
        if state.phase == :dahai && state.current_seat == seat && state.riichi_flags[seat] && state.last_tsumo
          dahai << state.last_tsumo.to_s
        end
        out.unshift([DAHAI, dahai.uniq]) unless dahai.empty?
        out
      end

      # Whether [type, tiles] (from a player) is one of the offers; returns
      # the engine action Hash (without the seat) or nil.
      def match(offers, type, tiles)
        offers.each do |t, ts|
          next unless t == type
          case t
          when DAHAI, RIICHI
            return { type: SYM_OF[t], tile: tiles[0] } if tiles.size == 1 && ts.include?(tiles[0])
          when ANKAN, KAKAN
            return { type: SYM_OF[t], tile: ts[0] } if tiles == ts
          when PON, CHI
            return { type: SYM_OF[t], tiles: ts } if tiles == ts
          else
            return { type: SYM_OF[t] } if tiles.empty?
          end
        end
        nil
      end

      # The CPU's choice among the engine's actions for a seat (as an engine
      # action with the seat), or nil when it has nothing to choose.
      def cpu_choice(state, seat, rule, ai)
        avail = API.available_round_actions(state: state, seat: seat, rule: rule)
        a = ai.think(state: state, seat: seat, available: avail, rule: rule)
        if a.nil?
          # A seat in riichi with no win (see offers): it discards the drawn tile.
          return { type: :dahai, seat: seat, tile: state.last_tsumo.to_s } if state.phase == :dahai && state.current_seat == seat
          return state.phase == :naki_wait && state.pending_actions.key?(seat) ? { type: :skip, seat: seat } : nil
        end
        a = a.dup
        a[:seat] = seat
        a[:tiles] = a.delete(:choices).first if a[:type].to_sym == :chi && a[:choices]
        a[:tile] = a[:tile].to_s if a[:tile]
        a
      end

      # Applies one action (with :seat) to the state, with the corrections.
      # Returns the engine's RoundFlowResult.
      def apply(state, action, rule)
        type = action[:type].to_sym
        seat = action[:seat]
        before = seat ? state.hands[seat].tiles.dup : nil
        was_riichi = seat ? state.riichi_flags[seat] : false
        put_exact_first(state, seat, action) if seat
        if %i[pon chi daiminkan ron_agari].include?(type) && state.pending_actions[seat]
          # engine 0.1.0: the check for "a higher priority action" looks at
          # the seat's own other options too, so a seat that could ron may not
          # pon. The seat chose: only its choice is left pending.
          state.pending_actions[seat] = state.pending_actions[seat].select { |p| p[:type].to_sym == type }
        end
        result = API.apply_round_action(state: state, action: action, rule: rule)
        fix_kan_fuuro(state, seat, type, before) if %i[ankan daiminkan].include?(type)
        # engine 0.1.0: the ippatsu chance of a riichi is never cleared by the
        # player's own next discard (only by calls and kans).
        state.ippatsu_flags[seat] = false if type == :dahai && was_riichi
        result
      end

      # engine 0.1.0: Hand#remove takes the first tile of the same kind, so
      # discarding "5m" from a hand with 0m and 5m may take the red five (and
      # the river shows a 5m: the red five is gone from the game), and a chi
      # or pon may move the wrong one. Put the exact tiles first in the hand.
      def put_exact_first(state, seat, action)
        names = []
        names << action[:tile].to_s if action[:tile] && %i[dahai riichi kakan].include?(action[:type].to_sym)
        names.concat(Array(action[:tiles]).map(&:to_s)) if %i[pon chi].include?(action[:type].to_sym)
        return if names.empty?
        tiles = state.hands[seat].tiles.dup
        names.reverse_each do |n|
          i = tiles.index { |t| t.to_s == n }
          next unless i
          t = tiles.delete_at(i)
          tiles.unshift(t)
        end
        state.hands[seat] = ::Mahjong::State::Hand.new(tiles)
      end

      # engine 0.1.0: an ankan or daiminkan records four copies of the tile
      # named, so a red five in it disappears. Record the tiles that left the
      # hand (and the called one).
      def fix_kan_fuuro(state, seat, type, before)
        last = state.fuuros[seat].last
        return unless last && last.type == type
        kind = last.tiles.first
        mine = before.select { |t| t.same_kind?(kind) }
        tiles = type == :ankan ? mine.first(4) : mine.first(3) + [last.called_tile]
        state.fuuros[seat][-1] = ::Mahjong::State::Fuuro.new(type: type, tiles: tiles,
                                                           called_tile: last.called_tile, from_seat: last.from_seat)
      end

      # Who wins a discard that several seats called: the highest priority,
      # and between equals the first in turn order after the discarder.
      # engine 0.1.0: resolve_pending_action breaks ties by seat number, so a
      # double ron goes to seat 0 rather than to the one next in turn.
      def call_winner(decisions, discarder)
        best = nil
        decisions.each do |seat, a|
          t = TYPE_OF[a[:type].to_sym]
          next if t == SKIP
          key = [CALL_PRIORITY.fetch(t, 9), (seat - discarder) % 4]
          best = [key, seat, a] if best.nil? || (key <=> best[0]).negative?
        end
        best && [best[1], best[2]]
      end

      # Scores a finished round. Returns the result for the screen and the
      # data for the next round: {"kind", "winner", "from", "yaku", "han",
      # "fu", "points", "delta" => [4], "tenpai", "hand", "agari"}.
      def score(state, info, rule)
        kind = info[:result_type].to_sym
        delta = [0, 0, 0, 0]
        res = { "kind" => kind.to_s, "delta" => delta }
        case kind
        when :tsumo_agari, :ron_agari
          w = info[:winner_seat]
          ron = kind == :ron_agari
          tile = ron ? (state.chankan_tile || state.last_dahai[:tile]) : state.last_tsumo
          winner, sr = evaluate(state, w, ron, tile, rule)
          ch = sr.score_changes(winner_seat: w, loser_seat: info[:loser_seat], oya_seat: state.oya_seat)
          4.times { |s| delta[s] = ch[s].to_i }
          res.merge!("winner" => w, "from" => info[:loser_seat], "agari" => tile.to_s,
                     "yaku" => winner[:yaku].map { |y| y[:display].to_s },
                     "han" => winner[:han], "fu" => winner[:fu], "points" => sr.display.to_s,
                     "hand" => winner[:hand_tiles].map(&:to_s))
          state.kyoutaku = 0
        when :ryuukyoku
          tp = API.tenpai_seats(state)
          pay = API.calculate_tenpai_payments(tp)
          4.times { |s| delta[s] = pay[s].to_i }
          res["tenpai"] = tp
        else
          res["tenpai"] = []
        end
        4.times { |s| state.scores[s] += delta[s] }
        res
      end

      # engine 0.1.0: evaluate_win counts dora on the indicators
      # (state.dora_hyouji) instead of the tiles they point to, and its
      # houtei (a ron on the last discard) never holds because the phase is
      # already round_end. Evaluate with the dora tiles and the phase the win
      # was made in.
      def evaluate(state, seat, ron, tile, rule)
        snap = ::Mahjong::Snapshots::WinEvaluationSnapshot.new(
          bakaze: state.bakaze, oya_index: state.oya_seat, honba: state.honba,
          kyoutaku: state.kyoutaku, jikaze: BAKAZE[(seat - state.oya_seat) % 4]
        )
        dh = state.dora_hyouji
        uh = state.uradora_hyouji
        ph = state.phase
        begin
          state.dora_hyouji = state.wanpai.dora_tiles
          state.uradora_hyouji = state.wanpai.uradora_tiles
          state.phase = ron ? :naki_wait : :dahai
          flags = ron ? { chankan: !state.chankan_tile.nil? } : { rinshan: state.rinshan_flag == true }
          API.evaluate_win(state: state, seat: seat, agari_type: ron ? :ron : :tsumo, agari_tile: tile,
                           rule: rule, extra_flags: flags, snapshot: snap)
        ensure
          state.dora_hyouji = dh
          state.uradora_hyouji = uh
          state.phase = ph
        end
      end

      # What comes after a round: {"action" => "next"/"end", ...}.
      def next_round(game, state, res, rule)
        kind = res["kind"]
        info = {
          result_type: kind.to_sym,
          winners: res["winner"].nil? ? [] : [{ seat: res["winner"] }],
          losers: res["from"].nil? ? [] : [{ seat: res["from"] }],
          tenpai_seats: res["tenpai"] || []
        }
        prog = ::Mahjong::Snapshots::GameProgressSnapshot.new(
          bakaze: game["bakaze"], kyoku: game["kyoku"], honba: game["honba"],
          kyoutaku: state.kyoutaku, oya_index: game["oya"], scores: int_keys(game["scores"])
        )
        API.judge_next_game_round(progress_snapshot: prog, round_end_info: info, rule: rule)
      end
    end
  end
end
