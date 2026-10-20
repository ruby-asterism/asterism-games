# frozen_string_literal: true

module AsterismGames
  module Commentate
    # What happened at a mahjong table between two of its spectate views
    # (README "Spectate", "Commentary"): pure functions, no network, no
    # clock, no randomness, so the same views always give the same events
    # (and the host can take this over later).
    #
    #   events, memo = MahjongEvents.diff(prev, cur, memo)
    #
    # prev is the view before (nil for the first one), memo what the last
    # call returned ({} the first time): what has been said already this
    # round (the tenpai seats), the leader, and the round. Each event is a
    # Hash with "type", "prio" (0 small .. 3 the big moments) and its own
    # keys; "hands" => true when it tells something only the hands show
    # (a tenpai, the waits): hidden when the hands are hidden.
    #
    # The views come as the host puts them (after a change, and the last
    # one every 5 s again), so several moves may lie between two of them:
    # a river is compared tile by tile, a meld by count and type.
    module MahjongEvents
      # The tile names of the views: 1m..9m, 0m the red five, ..., 1z..7z.
      SUITS = %w[m p s].freeze
      LAST_WALL = 10 # "残り 10 枚"

      module_function

      # [events, memo].
      def diff(prev, cur, memo = {})
        memo = dup_memo(memo)
        out = []
        return [out, memo] unless cur.is_a?(Hash)
        prev = nil unless prev.is_a?(Hash)
        st = cur["status"]
        rk = round_key(cur)
        if prev.nil?
          out << { "type" => "hello", "prio" => 1, "status" => st, "round" => cur["round"] }.compact
          memo["round"] = rk
          memo["leader"] = leader(scores(cur), nil)
          memo["tenpai"] = tenpai_seats(cur).keys if st == "play"
          memo["oorasu"] = rk if rk && last_round?(cur)
          return [out, memo]
        end
        pst = prev["status"]
        new_round = st == "play" && (rk != memo["round"] || pst != "play" && pst != "result")
        if new_round
          memo["round"] = rk
          memo["tenpai"] = []
          first = cur.dig("round", "wind") == "east" && cur.dig("round", "number") == 1 && cur.dig("round", "honba").to_i.zero? &&
                  pst != "result"
          oorasu = last_round?(cur)
          ev = { "type" => "round_start", "prio" => oorasu ? 3 : 1, "round" => cur["round"],
                 "dora" => Array(cur["dora_indicators"]).map { |t| dora_of(t) } }
          ev["game_start"] = true if first
          if oorasu
            ev["oorasu"] = true
            ev["again"] = true if memo["oorasu"]
            memo["oorasu"] = rk
          end
          out << ev
          memo["leader"] = leader(scores(cur), memo["leader"])
          # A round just begun: nothing of it to compare with the last.
          return [out, memo]
        end
        same_round = %w[play result].include?(st) && %w[play result].include?(pst) && rk == round_key(prev)
        out.concat(moves(prev, cur, memo)) if same_round
        if %w[result over].include?(st) && cur["result"] && (pst == "play" || prev["result"] != cur["result"])
          out.concat(result_events(prev, cur, memo))
        end
        if st == "over" && pst != "over" && cur["final"]
          out << { "type" => "game_over", "prio" => 2, "final" => cur["final"] }
        end
        [out, memo]
      end

      # The events inside one round: discards (a dora, a red five), calls,
      # riichi, a new dora indicator, the wall running low, a tenpai.
      def moves(prev, cur, memo)
        out = []
        dora = Array(cur["dora_indicators"]).map { |t| dora_of(t) }
        ps = Array(prev["seats"])
        Array(cur["seats"]).each_with_index do |s, i|
          p = ps[i] || {}
          river = Array(s["river"])
          old = Array(p["river"])
          if river.size > old.size
            river[old.size..].each do |t|
              red = t.start_with?("0")
              if red || dora.include?(plain(t))
                out << { "type" => "dora_discard", "prio" => 0, "seat" => i, "tile" => t, "red" => red,
                         "dora" => dora.include?(plain(t)) }
              end
            end
          end
          call = new_meld(Array(p["melds"]), Array(s["melds"]))
          out << call.merge("type" => "call", "prio" => 1, "seat" => i) if call
          next unless s["riichi"] && !p["riichi"]
          ev = { "type" => "riichi", "prio" => 2, "seat" => i, "turn" => river.size }
          w = waits_of(s)
          ev["waits"] = w if w && !w.empty?
          memo["tenpai"] |= [i]
          out << ev
        end
        old_n = Array(prev["dora_indicators"]).size
        ind = Array(cur["dora_indicators"])
        out << { "type" => "new_dora", "prio" => 1, "indicator" => ind.last, "dora" => dora_of(ind.last) } if ind.size > old_n && old_n.positive?
        pw = prev.dig("round", "wall_left")
        cw = cur.dig("round", "wall_left")
        if pw.is_a?(Integer) && cw.is_a?(Integer) && pw > LAST_WALL && cw <= LAST_WALL
          out << { "type" => "wall", "prio" => 0, "left" => cw }
        end
        if cur["status"] == "play"
          tenpai_seats(cur).each do |i, w|
            next if memo["tenpai"].include?(i)
            memo["tenpai"] << i
            out << { "type" => "tenpai", "prio" => 1, "seat" => i, "waits" => w, "hands" => true }
          end
        end
        out
      end

      # The new meld of a seat between two lists, or nil: one more meld
      # (chi, pon, the kans), or a pon turned into an added kan.
      def new_meld(old, cur)
        if cur.size > old.size
          m = cur.last
          return { "call" => m["type"], "tiles" => m["tiles"], "from" => m["from"] }.compact
        end
        cur.each_with_index do |m, j|
          o = old[j]
          next unless o && o["type"] != m["type"] && m["type"] == "added_kan"
          return { "call" => "added_kan", "tiles" => m["tiles"] }
        end
        nil
      end

      # A win (each winner), a draw; the lead changing hands.
      def result_events(prev, cur, memo)
        r = cur["result"]
        out = []
        kind = r["kind"].to_s
        case kind
        when "tsumo_agari", "ron_agari"
          Array(r["wins"]).each do |w|
            pts = w["points"].to_s
            level = pts[/三倍満|倍満|跳満|満貫|役満/]
            level = "役満" if pts.include?("役満")
            big = !level.nil?
            out << { "type" => "win", "prio" => big ? 3 : 2, "by" => kind == "ron_agari" ? "ron" : "tsumo",
                     "seat" => w["seat"], "from" => r["from"], "yaku" => Array(w["yaku"]), "han" => w["han"],
                     "fu" => w["fu"], "points" => pts, "level" => level, "tile" => w["tile"] }.compact
          end
        when "ryuukyoku"
          out << { "type" => "draw", "prio" => 2, "tenpai" => Array(r["tenpai"]) }
        else
          out << { "type" => "abort", "prio" => 2, "kind" => kind }
        end
        before = scores(prev)
        after = scores(cur)
        changes = Array(r["changes"])
        after = before.each_with_index.map { |x, i| x.to_i + changes[i].to_i } if after == before && changes.size == 4
        old = memo["leader"] || leader(before, nil)
        now = leader(after, old)
        if old && now && now != old
          out << { "type" => "lead_change", "prio" => 3, "seat" => now, "was" => old, "score" => after[now] }
        end
        memo["leader"] = now
        out
      end

      # ------------------------------------------------------------ the table

      def round_key(v)
        r = v["round"]
        return nil unless r.is_a?(Hash)
        [r["wind"], r["number"], r["honba"]]
      end

      def scores(v)
        Array(v["seats"]).map { |s| s["score"].to_i }
      end

      # The seat with the most points; a tie keeps the one before (old).
      def leader(sc, old)
        return nil if sc.empty?
        top = sc.max
        return old if old && sc[old] == top
        sc.index(top)
      end

      # The last round of the game: south 4 in a hanchan, east 4 in a tonpuu
      # (a round after it, the west round, counts too).
      def last_round?(v)
        r = v["round"] or return false
        game = v.dig("rules", "game").to_s
        last = game.start_with?("tonpuu") || game == "east" ? "east" : "south"
        order = %w[east south west north]
        wi = order.index(r["wind"].to_s) or return false
        li = order.index(last)
        wi > li || (wi == li && r["number"].to_i == 4)
      end

      # The seats whose hand is tenpai now (not after riichi: riichi says
      # it): {seat => waits}, from the hands in the view.
      def tenpai_seats(v)
        out = {}
        Array(v["seats"]).each_with_index do |s, i|
          next if s["riichi"]
          w = waits_of(s)
          out[i] = w if w && !w.empty?
        end
        out
      end

      # The waits of a seat's hand (tile names, the red five as a five), or
      # nil when the hand is not there or not between two discards.
      def waits_of(seat)
        h = seat["hand"]
        return nil unless h.is_a?(Array) && seat["drawn"].nil? && (h.size % 3) == 1
        waits(h)
      end

      # The tiles that complete a hand of 3n+1 tiles (any n: the melds are
      # outside it): a standard hand (n sets and a pair), seven pairs,
      # thirteen orphans.
      def waits(hand)
        c = counts(hand)
        return [] if c.nil?
        out = []
        34.times do |t|
          next if c[t] >= 4
          c[t] += 1
          out << name34(t) if complete?(c, hand.size + 1)
          c[t] -= 1
        end
        out
      end

      def complete?(c, n)
        return true if n == 14 && (seven_pairs?(c) || orphans?(c))
        34.times do |t|
          next if c[t] < 2
          c[t] -= 2
          ok = sets?(c, 0)
          c[t] += 2
          return true if ok
        end
        false
      end

      # Whether the counts from index i on split into sets.
      def sets?(c, i)
        i += 1 while i < 34 && c[i].zero?
        return true if i >= 34
        if c[i] >= 3
          c[i] -= 3
          ok = sets?(c, i)
          c[i] += 3
          return true if ok
        end
        if i < 27 && i % 9 <= 6 && c[i + 1].positive? && c[i + 2].positive?
          c[i] -= 1
          c[i + 1] -= 1
          c[i + 2] -= 1
          ok = sets?(c, i)
          c[i] += 1
          c[i + 1] += 1
          c[i + 2] += 1
          return true if ok
        end
        false
      end

      def seven_pairs?(c) = c.count(2) == 7
      ORPHANS = [0, 8, 9, 17, 18, 26, 27, 28, 29, 30, 31, 32, 33].freeze
      def orphans?(c) = ORPHANS.all? { |t| c[t].positive? } && ORPHANS.sum { |t| c[t] } == 14

      # 34 counts (1m..9m 1p..9p 1s..9s 1z..7z), or nil for a name not a tile.
      def counts(names)
        c = Array.new(34, 0)
        names.each do |n|
          i = index34(n) or return nil
          c[i] += 1
        end
        c
      end

      def index34(name)
        m = name.to_s.match(/\A([0-9])([mpsz])\z/) or return nil
        d = m[1].to_i
        return (d.between?(1, 7) ? 26 + d : nil) if m[2] == "z"
        d = 5 if d.zero?
        SUITS.index(m[2]) * 9 + d - 1
      end

      def name34(i) = i >= 27 ? "#{i - 26}z" : "#{(i % 9) + 1}#{SUITS[i / 9]}"

      # A red five as the five.
      def plain(name) = name.to_s.start_with?("0") ? "5#{name[1]}" : name.to_s

      # The dora an indicator shows: the next of its suit (9 -> 1), the
      # winds in turn (north -> east), the dragons in turn (red -> white).
      def dora_of(ind)
        i = index34(ind) or return nil
        nxt = if i < 27 then (i / 9 * 9) + ((i % 9) + 1) % 9
              elsif i < 31 then 27 + (i - 27 + 1) % 4
              else 31 + (i - 31 + 1) % 3
              end
        name34(nxt)
      end

      def dup_memo(m)
        m = (m || {}).dup
        m["tenpai"] = Array(m["tenpai"]).dup
        m
      end
    end
  end
end
