# frozen_string_literal: true

module AsterismGames
  module Commentate
    # The sound of Family mruby's mahjong app at the commentary page
    # (README "Commentary", "The sound"): which of the app's effects a new
    # spectate view calls for, and the scene of the BGM. Pure functions, as
    # MahjongEvents: the same two views always give the same sounds.
    #
    #   sounds = MahjongSounds.effects(prev, cur)   # [[name, delay_ms], ...]
    #   scene  = MahjongSounds.scene(cur)           # "lobby", "play", "tense" or "none"
    #
    # The names are the app's (mahjong_sound.rb's SFX, the files in
    # assets/sounds/, sounds.json). The page hears the table as the app's
    # spectator does: a discard is discard_other whoever made it, and the
    # player's own sounds (a draw, the turn coming) are not played. In the
    # order the app plays them, at the same moments:
    #   a new round           round
    #   a call, a riichi      chi, pon, kan, riichi (the jingle of the call)
    #   a discard             discard_other
    #   a win                 ron or tsumo (the jingle), then points after
    #                         the shout (1 s), the winner's points
    #   a draw of the round   ryuukyoku (and the abortive draws: kyuushu for
    #                         nine kinds, ryuukyoku for the others; three
    #                         rons is the app's ryuukyoku jingle too)
    #   the end of the game   fanfare1 (a spectator's: the winner's), after
    #                         a win's shout when one is sounding
    # The BGM's scenes are the app's: the lobby (waiting), the game and its
    # results, the tense one (a riichi on the table, or TENSE_LEFT tiles or
    # fewer left), and none at the end of a game (the fanfare plays alone).
    module MahjongSounds
      TENSE_LEFT = 10 # mahjong_sound.rb's TENSE_LEFT (sounds.json's tense_left)
      SHOUT_MS = 1000 # how long the app shows a shout (a win's result waits for it)
      CALLS = { "chi" => "chi", "pon" => "pon", "open_kan" => "kan", "closed_kan" => "kan", "added_kan" => "kan" }.freeze
      DRAWS = %w[ryuukyoku suufon_renda suukaikan suucha_riichi sanchahou].freeze
      # Every name these functions give (the files the page needs).
      NAMES = %w[round chi pon kan riichi discard_other ron tsumo points ryuukyoku kyuushu fanfare1].freeze

      module_function

      # [[name, delay_ms], ...] for the step from prev to cur (nothing for the
      # first view: that one is old news, as in the app).
      def effects(prev, cur)
        return [] unless prev.is_a?(Hash) && cur.is_a?(Hash)
        out = []
        st = cur["status"]
        pst = prev["status"]
        same = %w[play result].include?(pst) && round_key(prev) == round_key(cur)
        if st == "play" && !same
          out << ["round", 0]
          return out
        end
        jingle = nil
        if same && %w[play result over].include?(st)
          ps = Array(prev["seats"])
          Array(cur["seats"]).each_with_index do |s, i|
            p = ps[i] || {}
            call = new_call(Array(p["melds"]), Array(s["melds"]))
            jingle = call if call
            jingle = "riichi" if s["riichi"] && !p["riichi"]
          end
        end
        res = cur["result"]
        win = false
        if %w[result over].include?(st) && res.is_a?(Hash) && (pst == "play" || prev["result"] != res)
          kind = res["kind"].to_s
          if %w[ron_agari tsumo_agari].include?(kind)
            jingle = kind == "ron_agari" ? "ron" : "tsumo"
            win = true
          elsif kind == "kyuushu_kyuuhai"
            jingle = "kyuushu"
          elsif DRAWS.include?(kind)
            jingle = "ryuukyoku"
          end
        end
        out << [jingle, 0] if jingle
        out << ["discard_other", 0] if st == "play" && pst == "play" && same && river_n(cur) > river_n(prev)
        if st == "over" && pst != "over"
          out << ["fanfare1", jingle ? SHOUT_MS : 0]
        elsif win
          out << ["points", SHOUT_MS]
        end
        out
      end

      # The BGM's scene for a view (nil: no table yet, the lobby's tune).
      def scene(view)
        return "lobby" unless view.is_a?(Hash)
        st = view["status"]
        return "lobby" if st == "wait"
        return "none" if st == "over"
        return "play" unless %w[play result].include?(st)
        riichi = Array(view["seats"]).any? { |s| s.is_a?(Hash) && s["riichi"] }
        left = view.dig("round", "wall_left")
        riichi || (st == "play" && left.is_a?(Integer) && left <= TENSE_LEFT) ? "tense" : "play"
      end

      def round_key(v)
        r = v["round"]
        r.is_a?(Hash) ? [r["wind"], r["number"], r["honba"]] : nil
      end

      def river_n(v)
        Array(v["seats"]).sum { |s| s.is_a?(Hash) ? Array(s["river"]).size : 0 }
      end

      # The jingle of a seat's new meld, or nil.
      def new_call(old, cur)
        return CALLS[cur.last["type"].to_s] if cur.size > old.size && cur.last.is_a?(Hash)
        cur.each_with_index do |m, j|
          o = old[j]
          return "kan" if o.is_a?(Hash) && m.is_a?(Hash) && o["type"] != m["type"] && m["type"] == "added_kan"
        end
        nil
      end
    end
  end
end
