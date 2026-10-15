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
      SANCHAHOU = 13 # an event only: three rons, a draw (never offered)

      TYPE_OF = {
        dahai: DAHAI, riichi: RIICHI, tsumo_agari: TSUMO_AGARI, ankan: ANKAN, kakan: KAKAN,
        pon: PON, chi: CHI, daiminkan: DAIMINKAN, ron_agari: RON, skip: SKIP, kyuushu_kyuuhai: KYUUSHU,
        sanchahou: SANCHAHOU
      }.freeze
      SYM_OF = TYPE_OF.invert.freeze

      BAKAZE = %w[ton nan sha pei].freeze

      module_function

      # The host's rule defaults: Mahjong Soul's defaults where riichi_engine
      # can choose (README "Rules"). A table's "rule" settings go over these.
      RULE_DEFAULTS = {
        "game_type" => "hanchan",
        "initial_score" => 25_000,
        "oka_origin" => 30_000,
        "uma" => [15_000, 5_000, -5_000, -15_000],
        "aka_dora" => { "m" => 1, "p" => 1, "s" => 1 },
        "kuitan" => true,
        "kazoe_yakuman" => true,
        "kiriage_mangan" => false,
        "double_ron" => true,
        "triple_ron_draw" => false,
        "multiple_yakuman" => true,
        "double_yakuman" => true,
        "tobi" => true,
        "nishi_iri" => true,
        "nishi_iri_threshold" => 30_000,
        # Abortive draws besides nine kinds (four winds, four kans, four
        # riichi), nagashi mangan, pao (liability), when the kan dora of an
        # open or added kan shows (after the discard), agari-yame and
        # tenpai-yame for the last dealer in the lead.
        "suufon_renda" => true,
        "suukaikan" => true,
        "suucha_riichi" => true,
        "nagashi_mangan" => true,
        "pao" => %w[daisangen daisuushii],
        "minkan_dora_after_discard" => true,
        "agari_yame" => true,
        "tenpai_yame" => false
      }.freeze

      def rule(overrides = {})
        ::Mahjong::Config::RuleConfig.new(RULE_DEFAULTS.merge(overrides.transform_keys(&:to_s)))
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

      # The screen's help (README "Views", "Assist"): what the seat can see
      # of each tile kind, 34 counts: its own hand (a discard among them goes
      # to the river), the rivers (a called tile is counted in its meld),
      # every meld and the dora indicators. Only what the seat sees, so the
      # help tells nothing of the other hands.
      def seen_counts(state, seat)
        set = ::Mahjong::Tiles::TileSet
        seen = Array.new(34, 0)
        state.hands[seat].tiles.each { |t| seen[set.tile_index(t)] += 1 }
        4.times do |s|
          state.kawas[s].tiles.each { |k| seen[set.tile_index(k.tile)] += 1 unless k.called }
          state.fuuros[s].each { |f| f.tiles.each { |t| seen[set.tile_index(t)] += 1 } }
        end
        state.dora_hyouji.each { |t| seen[set.tile_index(t)] += 1 }
        seen
      end

      # The waits after each discard: [[discard, [[wait, left], ...]], ...]
      # in tile names, the waits as riichi_engine's wait judge gives them
      # (MachiJudge, the same judge that offers the riichi; it takes a
      # concealed hand of any size, so a hand with melds too). left is 4 less
      # what the seat can see of the wait (seen_counts). Whether a wait has a
      # yaku is not judged.
      def waits_after(state, seat, discards)
        set = ::Mahjong::Tiles::TileSet
        seen = seen_counts(state, seat)
        hand = state.hands[seat]
        discards.map do |name|
          rest = hand.remove(name).to_34
          waits = ::Mahjong::Scoring::Judges::MachiJudge.machi_tile_indices(rest).sort
          [name, waits.map { |i| [set.from_index(i), [4 - seen[i], 0].max] }]
        end
      end

      # The shanten of a concealed hand (34 counts) next to melds melds
      # (0: tenpai): riichi_engine's own count (Cpu::Analysis::Shanten, the
      # fork's fix/shanten-melds), which takes the melds as sets already
      # made, counts seven pairs and kokushi for a closed hand only, and
      # works out each suit once per pattern (the tests compare it with the
      # wait judge).
      def shanten(t34, melds)
        ::Mahjong::Cpu::Analysis::Shanten.calculate(t34, melds: melds)
      end

      # For each discard, the shanten after it and the tiles that would bring
      # it down (the acceptance): [[discard, shanten, [[tile, left], ...]],
      # ...], left as in waits_after; a tile the seat can see all four of is
      # left out (riichi_engine's CPU counts the acceptance the same way).
      def ukeire_after(state, seat, discards)
        set = ::Mahjong::Tiles::TileSet
        seen = seen_counts(state, seat)
        melds = state.fuuros[seat].size
        hand = state.hands[seat]
        done = {}
        discards.map do |name|
          rest = hand.remove(name).to_34
          key = rest.join(",")
          done[key] ||= begin
            sh = shanten(rest, melds)
            list = []
            34.times do |i|
              left = 4 - seen[i]
              next if rest[i] >= 4 || left <= 0
              rest[i] += 1
              list << [set.from_index(i), left] if shanten(rest, melds) < sh
              rest[i] -= 1
            end
            [sh, list]
          end
          [name, done[key][0], done[key][1]]
        end
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

      # What a discard that several seats called comes to (decisions: seat =>
      # action, skips included): the engine's priority with the rule's double
      # ron and three-ron draw, equals in turn order after the discarder. The
      # engine action to apply (a ron with :seats for several winners,
      # :sanchahou for three rons) or nil when everybody passed.
      def resolve_calls(decisions, discarder, rule)
        pending = decisions.reject { |_s, a| a[:type].to_sym == :skip }.to_h { |s, a| [s, [a]] }
        API.resolve_pending_action(pending, from_seat: discarder, rule: rule)
      end

      # The seats an action resolved by resolve_calls keeps (the winners).
      def winners_of(action)
        Array(action[:seats] || action[:seat])
      end

      # Scores a finished round. Returns the result for the screen and the
      # data for the next round: {"kind", "delta" => [4], "from", "wins" =>
      # [{"winner", "yaku", "han", "fu", "points", "hand", "agari"}, ...],
      # "tenpai", "ron_seats"}. A double ron has a win for each winner, in
      # turn order from the discarder; only the first takes the honba and the
      # riichi sticks (README "Rules").
      def score(state, info, rule)
        kind = info[:result_type].to_sym
        delta = [0, 0, 0, 0]
        res = { "kind" => kind.to_s, "delta" => delta }
        case kind
        when :tsumo_agari, :ron_agari
          ron = kind == :ron_agari
          tile = ron ? (state.chankan_tile || state.last_dahai[:tile]) : state.last_tsumo
          seats = Array(info[:winners]).map { |w| w[:seat] }
          seats = [info[:winner_seat]] if seats.empty?
          res["from"] = info[:loser_seat]
          res["wins"] = seats.each_with_index.map do |w, i|
            honba = i.zero? ? state.honba : 0
            sticks = i.zero? ? state.kyoutaku : 0
            winner, sr = evaluate(state, w, ron, tile, rule, honba: honba, kyoutaku: sticks)
            ch = sr.score_changes(winner_seat: w, loser_seat: info[:loser_seat], oya_seat: state.oya_seat)
            4.times { |s| delta[s] += ch[s].to_i }
            win = { "winner" => w, "agari" => tile.to_s, "yaku" => winner[:yaku].map { |y| y[:display].to_s },
                    "yaku_han" => winner[:yaku].map { |y| y[:han].to_i },
                    "han" => winner[:han], "fu" => winner[:fu], "points" => sr.display.to_s,
                    "hand" => winner[:hand_tiles].map(&:to_s) }
            # Pao: who pays for which yakuman ([[seat, the yaku's name], ...]).
            unless Array(winner[:pao]).empty?
              names = winner[:yaku].to_h { |y| [y[:name].to_s, y[:display].to_s] }
              win["pao"] = winner[:pao].map { |p| [p[:seat], names[p[:yaku].to_s] || p[:yaku].to_s] }
            end
            win
          end
          state.kyoutaku = 0
        when :ryuukyoku
          # Nagashi mangan (the rule's, a seat whose river is all terminals
          # and honours, none called) is paid in place of the no-ten payments;
          # tenpai still decides whether the dealer keeps the seat.
          tp = API.tenpai_seats(state)
          ng = Array(info[:nagashi_seats])
          pay = if ng.empty?
                  API.calculate_tenpai_payments(tp)
                else
                  API.calculate_nagashi_mangan_payments(ng, oya_seat: state.oya_seat)
                end
          4.times { |s| delta[s] = pay[s].to_i }
          res["tenpai"] = tp
          res["nagashi"] = ng unless ng.empty?
        when :sanchahou
          res["ron_seats"] = Array(info[:ron_seats])
        else
          res["tenpai"] = []
        end
        4.times { |s| state.scores[s] += delta[s] }
        res
      end

      # The engine's evaluation of a win by seat (after the winning action).
      def evaluate(state, seat, ron, tile, rule, honba: state.honba, kyoutaku: state.kyoutaku)
        snap = ::Mahjong::Snapshots::WinEvaluationSnapshot.new(
          bakaze: state.bakaze, oya_index: state.oya_seat, honba: honba,
          kyoutaku: kyoutaku, jikaze: BAKAZE[(seat - state.oya_seat) % 4]
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
          winners: Array(res["wins"]).map { |w| { seat: w["winner"] } },
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
