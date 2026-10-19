# frozen_string_literal: true

require_relative "mahjong_text"

module AsterismGames
  module Play
    # The mahjong table as lines of text, from a member's view (README
    # "Views"): the lobby, the round (the four seats with their rivers and
    # melds, the hand with its letters, what can be done now), the result
    # and the end of the game. The words are the table app's (fmruby-core
    # flash/app/game/mahjong): 東1局, 本場, 供託, ドラ, リーチ, ポン ...
    class MahjongScreen
      include MahjongText

      KIND_NAMES = { 1 => "チー", 2 => "ポン", 3 => "暗槓", 4 => "明槓", 5 => "加槓" }.freeze
      CALL_NAMES = { RIICHI => "リーチ", TSUMO => "ツモ", ANKAN => "カン", KAKAN => "カン", DAIMINKAN => "カン",
                     PON => "ポン", CHI => "チー", RON => "ロン", KYUUSHU => "九種九牌", SANCHAHOU => "三家和" }.freeze
      DRAWS = { "kyuushu_kyuuhai" => "九種九牌で流局", "sanchahou" => "三家和で流局", "suufon_renda" => "四風連打で流局",
                "suukaikan" => "四槓散了で流局", "suucha_riichi" => "四家立直で流局" }.freeze
      ENDS = { "tobi" => "トビ", "all_last_oya_agari" => "アガリ止め", "all_last_oya_tenpai" => "テンパイ止め",
               "sudden_death" => "サドンデス", "west" => "西4局まで", "rounds" => "局数の上限",
               "normal_end" => "最後の局まで" }.freeze
      STATES = { "wait" => "待ち合わせ", "play" => "対局中", "result" => "対局中", "over" => "終局" }.freeze

      attr_reader :style

      # style: "emoji" or "mpsz"; cursor: a terminal (columns by CHA, the
      # red fives in red).
      def initialize(style: "emoji", cursor: false, path: "")
        @style = style
        @cursor = cursor
        @path = path
        @slot = style == "emoji" ? 2 : 3
      end

      # The screen: lines (Strings). note: the last answer or news; pending:
      # a choice being made ([type, options]).
      def lines(v, note: "", pending: nil)
        return ["卓: #{v['error']}"] if v["error"]
        @v = v
        @me = v["me"].to_i
        out = case v["st"]
              when "wait" then lobby
              when "play" then round
              when "result" then round(top_only: true) + [""] + result
              when "over" then round(top_only: true) + [""] + result + [""] + over
              else ["#{@path}: #{v['st']}"]
              end
        out += choice_lines(pending) if pending
        out << "  #{note}" unless note.to_s.empty?
        out << hint
        out
      end

      # ------------------------------------------------------------ parts

      def name_of(seat)
        return "自分" if seat == @me
        n = (@v["nm"] || [])[seat].to_s
        n.empty? ? "空き" : n
      end

      def oya = (@v["r"] || [])[4].to_i

      def wind_of(seat) = WINDS[(seat - oya) % 4]

      def seat_order
        @me >= 0 ? [1, 2, 3, 0].map { |d| (@me + d) % 4 } : (0..3).map { |d| (oya + d) % 4 }
      end

      def row = Row.new(cursor: @cursor)

      # A tile in its slot (the red five in red on a terminal).
      def tile_cell(r, code, cols = @slot)
        t = tile(code, @style)
        t = "\e[31m#{t}\e[0m" if @cursor && red?(code)
        r.cell(t, cols)
      end

      def bytes(s) = s.to_s.b.unpack("C*")

      def round_name(rd)
        "#{WINDS[rd[0].to_i % 4]}#{rd[1]}局 #{rd[2]}本場"
      end

      def seconds(ms) = (ms.to_i + 999) / 1000

      # ------------------------------------------------------------ lobby

      def lobby
        v = @v
        out = ["#{v['t'] || @path}  待ち合わせ#{"  ゲームホスト #{v['hv']}" if v['hv']}"]
        sk = v["sk"] || [0, 0, 0, 0]
        ai = v["ai"] || []
        4.times do |s|
          tags = []
          tags << "卓の主" if v["ow"] == s
          tags << (ai[s].to_s.empty? ? "CPU" : "AI") if sk[s] == 2
          tags << "途切れ" if v["aw"].to_i[s] == 1
          tags << "自分" if s == @me
          n = sk[s].zero? ? "空き" : (v["nm"] || [])[s].to_s
          out << "  席#{s + 1}  #{n}#{" (#{tags.join(', ')})" unless tags.empty?}"
        end
        out << "  ルール: #{rules_text}" if v["ru"]
        watchers = (v["mb"] || []).select { |m| m[1] == -1 }.map(&:first)
        out << "  観戦: #{watchers.join(' ')}" unless watchers.empty?
        out
      end

      def rules_text
        ru = @v["ru"]
        game = ru[0].to_i == 1 ? "東風" : "半荘"
        kuitan = ru[1].to_i == 1 ? "あり" : "なし"
        bank = @v["tb"].to_i
        time = bank.positive? ? "#{ru[10]}+#{bank}秒" : "#{ru[10]}秒"
        "#{game} 喰いタン#{kuitan} 赤#{ru[2]} 持ち時間 #{time}"
      end

      # ------------------------------------------------------------ round

      def round(top_only: false)
        v = @v
        r = v["r"] || []
        out = []
        if r.size >= 4
          h = row.text("#{round_name(r)}  供託#{r[3]}  残り#{r[5]}  ドラ ")
          bytes(v["dora"]).each { |t| tile_cell(h, t) }
          out << h.to_s.rstrip
        end
        return out if top_only
        names = seat_order.map { |s| name_of(s) }
        nw = [[names.map { |n| width(n) }.max.to_i, 4].max, 10].min
        river_col = 2 + 1 + nw + 1 + 6 + 2
        seat_order.each do |s|
          out << seat_line(s, nw, river_col)
          melds = meld_line(s, river_col)
          out << melds if melds
          out << hand_line(s, river_col) if @me.negative? && v["sh"]
        end
        if (cl = v["cl"]) && cl.size > 2 && CALL_NAMES[cl[0]]
          seats = cl[0] == SANCHAHOU ? cl[2..] : [cl[2]]
          out << "  #{seats.map { |s| "#{wind_of(s)} #{name_of(s)}" }.join('、')}: #{CALL_NAMES[cl[0]]}"
        end
        if @me >= 0 && v["h"]
          out << ""
          out.concat(my_hand)
        end
        out
      end

      def seat_line(s, nw, river_col)
        v = @v
        sc = (v["sc"] || [])[s]
        mark = v["ri"].to_i[s] == 1 ? "*" : " "
        away = v["aw"].to_i[s] == 1 ? " (途切れ)" : ""
        r = row.text("#{wind_of(s)} ").text(fit(name_of(s), nw)).text(" #{sc.to_s.rjust(6)}#{mark}")
        r.to(river_col)
        riichi_next = false
        bytes((v["kw"] || [])[s]).each do |b|
          code = b & 0x3F
          riichi = b & 0x40 != 0 || riichi_next
          if b & 0x80 != 0 # called away: the tile is in the meld (a riichi mark moves on)
            riichi_next = riichi
            next
          end
          riichi_next = false
          if riichi
            r.cell("[", 1)
            tile_cell(r, code, 2)
            r.cell("]", 2)
          else
            tile_cell(r, code)
          end
        end
        r.text(away) unless away.empty?
        r.to_s.rstrip
      end

      # The melds of a seat: each meld's tiles (a closed kan with its ends
      # face down).
      def melds_of(s)
        b = bytes((@v["fu"] || [])[s])
        out = []
        i = 0
        while i + 2 < b.size
          kind = b[i]
          n = b[i + 2]
          tiles = b[i + 3, n]
          tiles = [BACK, *tiles[1..-2], BACK] if kind == 3 && tiles.size == 4
          out << tiles
          i += 3 + n
        end
        out
      end

      # The melds of a seat, under its river.
      def meld_line(s, river_col)
        melds = melds_of(s)
        return nil if melds.empty?
        r = row.text("   鳴き").to(river_col)
        melds.each do |tiles|
          tiles.each { |t| tile_cell(r, t) }
          r.cell("", 1)
        end
        r.to_s.rstrip
      end

      # A spectator's line of a seat's hand (sh, sd).
      def hand_line(s, river_col)
        r = row.text("   手牌").to(river_col)
        bytes((@v["sh"] || [])[s]).each { |t| tile_cell(r, t) }
        d = (@v["sd"] || [])[s].to_i
        if d >= 0 && (@v["sd"] || [])[s]
          r.cell("", @slot)
          tile_cell(r, d)
        end
        r.to_s.rstrip
      end

      # The member's hand and drawn tile, the letters under them; the red
      # fives and the riichi help (wt) after.
      def my_hand
        h = bytes(@v["h"])
        dt = @v["dt"].to_i
        tiles = row
        letters = row
        h.each_with_index do |t, i|
          tile_cell(tiles, t)
          letters.cell(LETTERS[i], @slot)
        end
        if dt >= 0 && @v.key?("dt")
          tiles.cell("", @slot)
          letters.cell("", @slot)
          tile_cell(tiles, dt)
          letters.cell(LETTERS[h.size], @slot)
        end
        out = [tiles.to_s.rstrip, letters.to_s.rstrip]
        all = h + (dt >= 0 && @v.key?("dt") ? [dt] : [])
        reds = all.each_index.select { |i| red?(all[i]) }.map { |i| LETTERS[i] }
        out << "赤: #{reds.join(' ')}" if !reds.empty? && @style == "emoji"
        out.concat(waits_lines(all))
        out
      end

      # wt (README "Assist"): per discard the tile, n, n pairs [wait, left].
      def waits_lines(all)
        b = bytes(@v["wt"])
        return [] if b.empty?
        parts = []
        i = 0
        while i + 1 < b.size
          t = b[i]
          n = b[i + 1]
          pairs = b[i + 2, n * 2].each_slice(2).map { |w, left| "#{mpsz(w)}(#{left})" }
          letter = all.index(t)
          parts << "#{letter ? LETTERS[letter] : mpsz(t)}→ #{pairs.join(' ')}"
          i += 2 + n * 2
        end
        ["待ち: #{parts.join('  ')}"]
      end

      # ------------------------------------------------------------ result

      def result
        res = @v["res"] or return []
        out = []
        rd = res["rd"]
        head = rd.is_a?(Array) && rd.size > 2 ? "#{round_name(rd)}  " : ""
        wins = res["wn"] || []
        if wins.empty?
          k = res["k"].to_s
          h = DRAWS[k] || "流局"
          ng = res["ng"] || []
          h += "  流し満貫: #{ng.map { |s| name_of(s) }.join(' ')}" unless ng.empty?
          out << "#{head}#{h}"
        end
        wins.each do |w|
          ws = w["w"].to_i
          what = if res["k"] == "tsumo_agari"
                   "#{wind_of(ws)} #{name_of(ws)} ツモ"
                 else
                   f = res["f"]
                   "#{wind_of(ws)} #{name_of(ws)} ロン#{" (#{wind_of(f)} #{name_of(f)} から)" if f}"
                 end
          out << "#{head}#{what}"
          r = row.text("  ")
          bytes(w["h"]).each { |t| tile_cell(r, t) }
          r.cell("", @slot)
          tile_cell(r, w["ag"].to_i)
          melds_of(ws).each do |tiles|
            r.cell("", @slot)
            tiles.each { |t| tile_cell(r, t) }
          end
          out << r.to_s.rstrip
          ys = w["y"] || []
          ys.each_index { |i| out << "  #{yaku_label(w, i)}" }
          pao = (w["pa"] || []).map { |pa| "#{name_of(pa[0].to_i)} (#{pa[1]})" }
          out << "  #{w['pt']}#{"  包: #{pao.join(' ')}" unless pao.empty?}"
        end
        out << "点数:"
        d = res["d"] || [0, 0, 0, 0]
        sc = @v["sc"] || [0, 0, 0, 0]
        tp = res["tp"]
        nw = [[(0..3).map { |s| width(name_of(s)) }.max, 4].max, 10].min
        seat_order.each do |s|
          dv = d[s].to_i
          after = sc[s].to_i
          mark = tp.is_a?(Array) && res["k"] == "ryuukyoku" ? (tp.include?(s) ? " テンパイ" : " ノーテン") : ""
          change = dv.zero? ? "±0" : format("%+d", dv)
          out << "  #{wind_of(s)} #{fit(name_of(s), nw)} #{(after - dv).to_s.rjust(6)} → #{after.to_s.rjust(6)}  #{change}#{mark}"
        end
        if (ok = @v["ok"]).is_a?(Array) && @v["st"] == "result"
          done = ok[0].to_i.digits(2).count(1)
          all = (ok[0].to_i | ok[1].to_i).digits(2).count(1)
          out << "OK を待っています (#{done}/#{all})  あと #{seconds(ok[2])} 秒"
        end
        out
      end

      # "断么九 1翻", "ドラ 2翻" (the engine names the dora with its count),
      # "大三元 役満".
      def yaku_label(w, i)
        s = w["y"][i].to_s
        h = (w["yh"] || [])[i]
        return s if h.nil?
        s = s.sub(/ \d+\z/, "")
        return "#{s} ダブル役満" if h <= -2
        h.negative? ? "#{s} 役満" : "#{s} #{h}翻"
      end

      def over
        why = ENDS[@v["fr"].to_s]
        out = ["終局#{" (#{why})" if why}"]
        (@v["fin"] || []).sort_by { |f| f[1] }.each do |seat, rank, score, pt|
          out << format("  %d位 %s %6d (%+.1f)", rank, fit(name_of(seat), 10), score, pt.to_i / 10.0)
        end
        out
      end

      # ------------------------------------------------------------ the bottom

      def choice_lines(pending)
        type, opts = pending
        if type == RIICHI
          list = opts.map do |_, ts|
            l = MahjongText.hand_tiles(@v).index(ts[0])
            "#{l ? LETTERS[l] : ''} #{tile(ts[0], @style)}"
          end
          return ["リーチ: 切る牌を選ぶ (文字か 6s): #{list.join('  ')}"]
        end
        list = opts.each_with_index.map do |(t, ts), i|
          name = CALL_NAMES[t] || t.to_s
          tiles = ts.empty? ? "" : " #{ts.map { |x| tile(x, @style) }.join(@style == 'emoji' ? ' ' : '')}"
          "#{i + 1}: #{name}#{tiles}"
        end
        ["どれにする (番号か牌): #{list.join('  ')}"]
      end

      # What can be done now (the last line before the prompt).
      def hint
        v = @v
        opts = MahjongText.options(v)
        types = opts.map(&:first).uniq
        case v["st"]
        when "wait"
          return "観戦中: sit で座る、quit で出る" if @me.negative?
          owner = v["ow"] == @me
          return "stand、cpu [席] (空きを CPU で)、nocpu 席、tonpuu / hanchan、start、quit" if owner
          return "4 席がそろったら卓の主が始める (stand、quit)"
        when "over"
          return "ok で待ち合わせに戻す (quit で出る)" if types.include?(NEXT)
          return "次へ: 卓の主が待ち合わせに戻す (quit で出る)"
        when "result"
          return "ok で次へ" if types.include?(NEXT)
          return @me.negative? ? "観戦中" : "次の局を待っています"
        end
        r = v["r"] || []
        return "#{round_name(r)} が始まります" if v["in"]
        return "観戦中 (quit で出る)#{turn_text(r)}" if @me.negative?
        if types.include?(DAHAI)
          words = ["打つ牌 (文字か 6s)"]
          words << "riichi" if types.include?(RIICHI)
          words << "tsumo" if types.include?(TSUMO)
          words << "kan" if (types & KANS).any?
          words << "kyuushu" if types.include?(KYUUSHU)
          return "自分の番: #{words.join('、')}#{time_text}"
        end
        unless types.empty?
          words = []
          words << "ron" if types.include?(RON)
          words << "pon" if types.include?(PON)
          words << "chi" if types.include?(CHI)
          words << "kan" if (types & KANS).any?
          words << "tsumo" if types.include?(TSUMO)
          words << "pass" if types.include?(SKIP)
          ls = v["ls"]
          what = ls ? " (#{wind_of(ls[0])} #{name_of(ls[0])} の #{tile(ls[1], @style)})" : ""
          return "鳴ける#{what}: #{words.join('、')}#{time_text}"
        end
        dl = v["dl"]
        return "ほかの人の答えを待っています" if r[7] == 2 && dl && dl[0].to_i & (1 << @me) == 0 && dl[0].to_i.positive?
        turn_text(r).strip
      end

      def turn_text(r)
        cur = r[6]
        return "" if cur.nil? || cur.negative? || r[7].to_i >= 2
        "  #{wind_of(cur)}家 (#{name_of(cur)}) の番です"
      end

      def time_text
        dl = @v["dl"]
        return "" unless dl.is_a?(Array) && @me >= 0 && dl[0].to_i[@me] == 1
        ms = dl[1].to_i
        bank = dl[2].to_i
        # The move's own time first, then the bank (the last part of ms).
        return "  あと #{seconds([ms - bank, 0].max)}+#{seconds([bank, ms].min)}秒" if bank.positive?
        "  あと #{seconds(ms)}秒"
      end
    end
  end
end
