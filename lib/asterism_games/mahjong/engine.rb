# frozen_string_literal: true

require "riichi_engine"
require "securerandom"

module AsterismGames
  module Mahjong
    # The calls into riichi_engine (RiichiEngine::API): the engine's actions
    # as the wire's [type, tiles], the CPU's choice, scoring a round. The
    # engine is the fork with the fixes (README "riichi_engine").
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

      BAKAZE = %w[ton nan sha pei].freeze

      module_function

      def rule(game_type: "hanchan")
        ::Mahjong::Config::RuleConfig.new("game_type" => game_type)
      end

      # A seed for the wall, long enough to be unguessable.
      def new_seed
        SecureRandom.alphanumeric(24)
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
        return nil if a.nil?

        a = a.dup
        a[:seat] = seat
        a[:tiles] = a.delete(:choices).first if a[:type].to_sym == :chi && a[:choices]
        a[:tile] = a[:tile].to_s if a[:tile]
        a
      end

      # Applies one action (with :seat) to the state. Returns the engine's
      # RoundFlowResult.
      def apply(state, action, rule)
        API.apply_round_action(state: state, action: action, rule: rule)
      end

      # Who wins a discard that several seats called (decisions: seat =>
      # action, skips included): the engine's priority, and between equals
      # the first in turn order after the discarder. [seat, action] or nil.
      def call_winner(decisions, discarder)
        pending = decisions.reject { |_s, a| a[:type].to_sym == :skip }.to_h { |s, a| [s, [a]] }
        won = API.resolve_pending_action(pending, from_seat: discarder)
        won && [won[:seat], won]
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

      # The engine's evaluation of a win by seat (after the winning action).
      def evaluate(state, seat, ron, tile, rule)
        snap = ::Mahjong::Snapshots::WinEvaluationSnapshot.new(
          bakaze: state.bakaze, oya_index: state.oya_seat, honba: state.honba,
          kyoutaku: state.kyoutaku, jikaze: BAKAZE[(seat - state.oya_seat) % 4]
        )
        flags = ron ? { chankan: !state.chankan_tile.nil? } : { rinshan: state.rinshan_flag == true }
        API.evaluate_win(state: state, seat: seat, agari_type: ron ? :ron : :tsumo, agari_tile: tile,
                         rule: rule, extra_flags: flags, snapshot: snap)
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
