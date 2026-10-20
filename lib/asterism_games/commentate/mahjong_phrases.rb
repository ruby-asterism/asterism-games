# frozen_string_literal: true

module AsterismGames
  module Commentate
    # The words of the commentary (README "Commentary"): an event of
    # MahjongEvents into a line, in Japanese, the way the table app says
    # things (東1局, 本場, 供託, ドラ, リーチ, ポン). Pure: the view gives the
    # names, rng (anything with rand(n)) chooses among the phrasings.
    #
    #   line = MahjongPhrases.line(event, view, rng, tone: "zundamon")
    #   # => {"type", "prio", "text", "speech", "ptext", "pspeech", "clips"}
    #
    # "text" is the caption, "speech" the same for a voice (the tiles and
    # the yaku as they are read: サンマン, リーチ). "ptext" / "pspeech" are
    # the line with the hands hidden: the same when the event does not
    # touch a hand, a shorter one when part of it does (a riichi's waits),
    # nil when all of it does (a tenpai): then nothing is said. "clips" are
    # the keys of the fixed phrases (mahjong_voice.yml) a voice plays
    # before the line: never one that tells a hand.
    #
    # The tone (TONES) is the character's way of speaking: the plain one,
    # and ずんだもん's (〜なのだ) when the voice is VOICEVOX's ずんだもん. A
    # tone has phrasings of its own for every event (the same number as
    # the plain ones, so one choice gives the same line in both), and a
    # few words for an AI asked to speak in it (C3).
    module MahjongPhrases
      WIND_TEXT = { "east" => "東", "south" => "南", "west" => "西", "north" => "北" }.freeze
      WIND_READ = { "east" => "トン", "south" => "ナン", "west" => "シャー", "north" => "ペー" }.freeze
      HONOR_TEXT = %w[東 南 西 北 白 發 中].freeze
      HONOR_READ = %w[トン ナン シャー ペー ハク ハツ チュン].freeze
      SUIT_TEXT = { "m" => "萬", "p" => "筒", "s" => "索" }.freeze
      SUIT_READ = { "m" => "マン", "p" => "ピン", "s" => "ソー" }.freeze
      NUM_READ = %w[イー リャン サン スー ウー ロー チー パー キュー].freeze
      CALL_TEXT = { "chi" => "チー", "pon" => "ポン", "open_kan" => "カン", "closed_kan" => "カン",
                    "added_kan" => "カン" }.freeze
      CALL_KIND = { "chi" => "チー", "pon" => "ポン", "open_kan" => "大明槓", "closed_kan" => "暗槓",
                    "added_kan" => "加槓" }.freeze
      CALL_KIND_READ = { "chi" => "チー", "pon" => "ポン", "open_kan" => "ダイミンカン", "closed_kan" => "アンカン",
                         "added_kan" => "カカン" }.freeze
      YAKU_READ = {
        "立直" => "リーチ", "ダブル立直" => "ダブルリーチ", "一発" => "イッパツ", "門前清自摸和" => "メンゼンツモ",
        "平和" => "ピンフ", "断么九" => "タンヤオ", "一盃口" => "イーペーコー", "二盃口" => "リャンペーコー",
        "七対子" => "チートイツ", "三色同順" => "サンショク", "三色同刻" => "サンショクドウコー", "一気通貫" => "イッツー",
        "混全帯么九" => "チャンタ", "純全帯么九" => "ジュンチャン", "対々和" => "トイトイ", "三暗刻" => "サンアンコー",
        "三槓子" => "サンカンツ", "混老頭" => "ホンロートー", "小三元" => "ショウサンゲン", "混一色" => "ホンイツ",
        "清一色" => "チンイツ", "嶺上開花" => "リンシャンカイホー", "槍槓" => "チャンカン", "海底摸月" => "ハイテイ",
        "河底撈魚" => "ホーテイ", "国士無双" => "コクシムソウ", "国士無双十三面" => "コクシムソウ ジューサンメン",
        "四暗刻" => "スーアンコー", "四暗刻単騎" => "スーアンコー タンキ", "大三元" => "ダイサンゲン", "字一色" => "ツーイーソー",
        "緑一色" => "リューイーソー", "清老頭" => "チンロートー", "小四喜" => "ショウスーシー", "大四喜" => "ダイスーシー",
        "四槓子" => "スーカンツ", "九蓮宝燈" => "チューレンポートー", "純正九蓮宝燈" => "ジュンセイ チューレンポートー",
        "天和" => "テンホー", "地和" => "チーホー"
      }.freeze
      LEVEL_READ = { "満貫" => "マンガン", "跳満" => "ハネマン", "倍満" => "バイマン", "三倍満" => "サンバイマン",
                     "役満" => "ヤクマン" }.freeze
      ABORT_TEXT = { "kyuushu_kyuuhai" => "九種九牌", "sanchahou" => "三家和", "suufon_renda" => "四風連打",
                     "suucha_riichi" => "四家立直", "suukaikan" => "四開槓" }.freeze
      ABORT_READ = { "kyuushu_kyuuhai" => "キューシュキューハイ", "sanchahou" => "サンチャホー",
                     "suufon_renda" => "スーフォンレンダ", "suucha_riichi" => "スーチャリーチ", "suukaikan" => "スーカイカン" }.freeze

      # The phrasings of each event: [caption, speech] templates; "strong"
      # for the big moments. %{...} are filled by fill (the speech's own
      # values where they are read differently).
      PHRASES = {
        "hello" => ["%{status_line}"],
        "round_start" => [
          "%{round}、親は%{dealer}。ドラは%{dora}。",
          "さあ%{round}が始まります。親は%{dealer}、ドラ%{dora}。",
          "%{round}。%{dealer}の親番です。ドラは%{dora}。"
        ],
        "round_start_game" => [
          "対局開始！ 東1局、起家は%{dealer}。ドラは%{dora}。",
          "さあ始まりました。東1局、親は%{dealer}。ドラは%{dora}。"
        ],
        "round_start_oorasu" => [
          "いよいよオーラス！ %{round}、親は%{dealer}。トップは%{leader}、%{lead_score}点。",
          "最後の局、オーラスです！ %{round}。%{leader}が%{lead_score}点でトップ、逃げ切れるか。",
          "オーラス！ %{round}。この一局で決まります。トップは%{leader}。"
        ],
        "round_start_oorasu_again" => [
          "オーラス続行、%{round}。親は%{dealer}。",
          "まだ終わらない！ %{round}。親の%{dealer}が粘ります。"
        ],
        "dora_discard" => [
          "%{name}、%{tile}を切りました。",
          "%{name}からドラの%{tile}。",
          "%{name}、%{tile}を手放します。"
        ],
        "red_discard" => [
          "%{name}、赤の%{plain}を切りました。",
          "%{name}から赤ドラ、%{plain}。"
        ],
        "call" => [
          "%{name}、%{call}！ %{called}。",
          "%{name}が%{called}を%{call}。",
          "%{call}！ %{name}、仕掛けました。"
        ],
        "kan" => [
          "%{name}、%{kind}！",
          "%{kind}です。%{name}がカンをしました。"
        ],
        "riichi" => [
          "%{name}、リーチ！ 待ちは%{waits}。",
          "リーチが入りました、%{name}。待ちは%{waits}。",
          "%{name}から%{turn}巡目のリーチ！ %{waits}待ち。"
        ],
        "riichi_public" => [
          "%{name}、リーチ！",
          "リーチが入りました、%{name}。",
          "%{name}から%{turn}巡目のリーチ！"
        ],
        "new_dora" => [
          "新ドラは%{dora}。",
          "カンドラがめくれて、ドラは%{dora}。"
        ],
        "wall" => [
          "残り%{left}枚。",
          "山は残り%{left}枚になりました。"
        ],
        "tenpai" => [
          "%{name}、テンパイ。待ちは%{waits}。",
          "%{name}の手がテンパイしました。%{waits}待ち。",
          "%{name}、静かにテンパイ。%{waits}待ちです。"
        ],
        "win" => [
          "%{by_word}！ %{name}、%{yaku}。%{points}。",
          "%{name}の%{by_word}！ %{yaku}で%{points}。",
          "%{name}、%{from_part}%{by_word}です。%{yaku}、%{points}。"
        ],
        "win_strong" => [
          "%{by_word}！！ %{name}、%{level}！ %{yaku}、%{points}！",
          "出ました%{level}！ %{name}の%{by_word}、%{yaku}。%{points}！",
          "大きい！ %{name}、%{from_part}%{by_word}で%{level}！ %{yaku}、%{points}！"
        ],
        "draw" => [
          "流局。%{tenpai_line}",
          "ここで流局です。%{tenpai_line}"
        ],
        "abort" => [
          "途中流局、%{kind}。",
          "%{kind}で流局です。"
        ],
        "lead_change" => [
          "逆転！ %{name}がトップに立ちました、%{score}点。",
          "トップが入れ替わります！ %{name}、%{score}点でトップ。",
          "ここで逆転、%{name}がトップへ！"
        ],
        "game_over" => [
          "終局！ トップは%{top}、%{top_score}点。%{ranks}",
          "対局終了。%{top}が%{top_score}点でトップです。%{ranks}"
        ]
      }.freeze

      # ずんだもん's phrasings (TONES): the same events, the same number of
      # phrasings, the endings 〜なのだ / 〜のだ.
      ZUNDAMON_PHRASES = {
        "hello" => ["%{status_line}"],
        "round_start" => [
          "%{round}なのだ。親は%{dealer}、ドラは%{dora}なのだ。",
          "さあ%{round}が始まるのだ！ 親は%{dealer}、ドラ%{dora}なのだ。",
          "%{round}、%{dealer}の親番なのだ。ドラは%{dora}なのだ。"
        ],
        "round_start_game" => [
          "対局開始なのだ！ 東1局、起家は%{dealer}。ドラは%{dora}なのだ。",
          "さあ始まったのだ！ 東1局、親は%{dealer}。ドラは%{dora}なのだ。"
        ],
        "round_start_oorasu" => [
          "いよいよオーラスなのだ！ %{round}、親は%{dealer}。トップは%{leader}、%{lead_score}点なのだ。",
          "最後の局、オーラスなのだ！ %{round}。%{leader}が%{lead_score}点でトップ、逃げ切れるのか。",
          "オーラスなのだ！ %{round}。この一局で決まるのだ。トップは%{leader}なのだ。"
        ],
        "round_start_oorasu_again" => [
          "オーラス続行なのだ、%{round}。親は%{dealer}なのだ。",
          "まだ終わらないのだ！ %{round}。親の%{dealer}が粘るのだ。"
        ],
        "dora_discard" => [
          "%{name}、%{tile}を切ったのだ。",
          "%{name}からドラの%{tile}なのだ。",
          "%{name}、%{tile}を手放したのだ。"
        ],
        "red_discard" => [
          "%{name}、赤の%{plain}を切ったのだ。",
          "%{name}から赤ドラ、%{plain}なのだ。"
        ],
        "call" => [
          "%{name}、%{call}なのだ！ %{called}。",
          "%{name}が%{called}を%{call}したのだ。",
          "%{call}なのだ！ %{name}、仕掛けたのだ。"
        ],
        "kan" => [
          "%{name}、%{kind}なのだ！",
          "%{kind}なのだ。%{name}がカンをしたのだ。"
        ],
        "riichi" => [
          "%{name}、リーチなのだ！ 待ちは%{waits}なのだ。",
          "リーチが入ったのだ、%{name}。待ちは%{waits}なのだ。",
          "%{name}から%{turn}巡目のリーチなのだ！ %{waits}待ちなのだ。"
        ],
        "riichi_public" => [
          "%{name}、リーチなのだ！",
          "リーチが入ったのだ、%{name}。",
          "%{name}から%{turn}巡目のリーチなのだ！"
        ],
        "new_dora" => [
          "新ドラは%{dora}なのだ。",
          "カンドラがめくれて、ドラは%{dora}なのだ。"
        ],
        "wall" => [
          "残り%{left}枚なのだ。",
          "山は残り%{left}枚になったのだ。"
        ],
        "tenpai" => [
          "%{name}、テンパイなのだ。待ちは%{waits}なのだ。",
          "%{name}の手がテンパイしたのだ。%{waits}待ちなのだ。",
          "%{name}、静かにテンパイなのだ。%{waits}待ちなのだ。"
        ],
        "win" => [
          "%{by_word}なのだ！ %{name}、%{yaku}。%{points}なのだ。",
          "%{name}の%{by_word}なのだ！ %{yaku}で%{points}なのだ。",
          "%{name}、%{from_part}%{by_word}なのだ。%{yaku}、%{points}なのだ。"
        ],
        "win_strong" => [
          "%{by_word}なのだ！！ %{name}、%{level}なのだ！ %{yaku}、%{points}なのだ！",
          "出たのだ、%{level}！ %{name}の%{by_word}、%{yaku}。%{points}なのだ！",
          "大きいのだ！ %{name}、%{from_part}%{by_word}で%{level}なのだ！ %{yaku}、%{points}なのだ！"
        ],
        "draw" => [
          "流局なのだ。%{tenpai_line}",
          "ここで流局なのだ。%{tenpai_line}"
        ],
        "abort" => [
          "途中流局なのだ、%{kind}。",
          "%{kind}で流局なのだ。"
        ],
        "lead_change" => [
          "逆転なのだ！ %{name}がトップに立ったのだ、%{score}点。",
          "トップが入れ替わるのだ！ %{name}、%{score}点でトップなのだ。",
          "ここで逆転、%{name}がトップなのだ！"
        ],
        "game_over" => [
          "終局なのだ！ トップは%{top}、%{top_score}点。%{ranks}",
          "対局終了なのだ。%{top}が%{top_score}点でトップなのだ。%{ranks}"
        ]
      }.freeze

      # The characters' tones: which VOICEVOX characters speak in each, its
      # phrasings, and how to ask an AI to speak so (C3). Any other
      # character, and the browser's voice, speak plain.
      TONES = {
        "plain" => {
          "speakers" => [],
          "phrases" => PHRASES,
          "prompt" => "落ち着いた実況の口調で、です・ます調で話す。"
        },
        "zundamon" => {
          "speakers" => ["ずんだもん"],
          "phrases" => ZUNDAMON_PHRASES,
          "prompt" => "ずんだもんの口調で話す。語尾は「〜なのだ」「〜のだ」、一人称は「ボク」。明るく元気に、短く。"
        }
      }.freeze

      # Words a speech synthesiser reads wrongly (VOICEVOX: 流局 ナガレキョク,
      # 起家 オコリカ, 跳満 トベミツル, 三萬 サンヨロズ): the speech and the
      # fixed phrases are read through this (reading), longest first. The
      # tiles and the yaku are read by their own tables already; these are
      # the words of the phrasings and what could slip through. 本場, 供託,
      # 巡目, 親番, 終局, 逆転 are read rightly as they are (checked on
      # VOICEVOX 0.25.0) and stay kanji.
      SPEECH_READ = {
        "途中流局" => "途中リューキョク", "流局" => "リューキョク", "起家" => "チーチャ", "東1局" => "トン1局",
        "三倍満" => "サンバイマン", "跳満" => "ハネマン", "倍満" => "バイマン", "満貫" => "マンガン", "役満" => "ヤクマン",
        "立直" => "リーチ", "一発" => "イッパツ", "裏ドラ" => "ウラドラ", "赤ドラ" => "アカドラ",
        "符" => "フ", "翻" => "ハン", "暗槓" => "アンカン", "加槓" => "カカン",
        "大明槓" => "ダイミンカン", "聴牌" => "テンパイ", "和了" => "ホーラ"
      }.freeze
      SPEECH_READ_RE = Regexp.union(SPEECH_READ.keys.sort_by { |k| -k.size })

      LEVEL_CLIP = { "満貫" => "mangan", "跳満" => "haneman", "倍満" => "baiman", "三倍満" => "sanbaiman",
                     "役満" => "yakuman" }.freeze

      module_function

      # The tone of a VOICEVOX character (nil: the browser's voice).
      def tone_for(speaker)
        TONES.find { |_, t| t["speakers"].include?(speaker) }&.first || "plain"
      end

      def phrases(tone) = (TONES[tone] || TONES["plain"])["phrases"]

      # The keys of the fixed phrases played before the line of ev
      # (mahjong_voice.yml): the round's name, riichi, the call, ron or
      # tsumo and the level, ... Nothing for what tells a hand (a tenpai)
      # or for the small things (a discard, the wall).
      def clips(ev)
        case ev["type"]
        when "round_start"
          return ["oorasu"] if ev["oorasu"]
          return ["game_start"] if ev["game_start"]
          r = ev["round"]
          r.is_a?(Hash) && r["wind"] && r["number"] ? ["round_#{r['wind']}#{r['number']}"] : []
        when "riichi" then ["riichi"]
        when "call"
          c = ev["call"].to_s
          return ["kan"] if c.end_with?("kan")
          %w[chi pon].include?(c) ? [c] : []
        when "win"
          out = [ev["by"] == "ron" ? "ron" : "tsumo"]
          out << LEVEL_CLIP[ev["level"]] if LEVEL_CLIP[ev["level"]]
          out
        when "draw" then ["ryuukyoku"]
        when "abort" then ["abort"]
        when "lead_change" then ["lead_change"]
        when "game_over" then ["game_over"]
        else []
        end
      end

      # The line of an event in view (the view the event came from).
      def line(ev, view, rng = Random.new, tone: "plain")
        key, pkey = keys_of(ev)
        book = phrases(tone)
        vals = values(ev, view, tone)
        i = rng.rand(book.fetch(key).size)
        text, speech = fill(book[key][i], vals)
        out = { "type" => ev["type"], "prio" => ev["prio"].to_i, "text" => text, "speech" => speech }
        if ev["hands"]
          out["ptext"] = nil
          out["pspeech"] = nil
        elsif pkey
          pt = book.fetch(pkey)
          out["ptext"], out["pspeech"] = fill(pt[i % pt.size], vals)
        else
          out["ptext"] = text
          out["pspeech"] = speech
        end
        out["clips"] = clips(ev)
        out
      end

      # The phrasing's key, and the one with the hands hidden (nil: the same).
      def keys_of(ev)
        case ev["type"]
        when "round_start"
          return ["round_start_oorasu_again", nil] if ev["oorasu"] && ev["again"]
          return ["round_start_oorasu", nil] if ev["oorasu"]
          return ["round_start_game", nil] if ev["game_start"]
          ["round_start", nil]
        when "dora_discard" then [ev["red"] && !ev["dora"] ? "red_discard" : "dora_discard", nil]
        when "call" then [ev["call"].to_s.end_with?("kan") ? "kan" : "call", nil]
        when "riichi" then ev["waits"] ? %w[riichi riichi_public] : ["riichi_public", nil]
        when "win" then [ev["level"] ? "win_strong" : "win", nil]
        else [ev["type"], nil]
        end
      end

      # The values of the templates: {key => [caption, speech]}.
      def values(ev, view, tone = "plain")
        z = tone == "zundamon"
        v = {}
        seats = Array(view.is_a?(Hash) ? view["seats"] : nil)
        name = ->(i) { seat_name(seats, i) }
        both = ->(s) { [s, s] }
        v["name"] = both.call(name.call(ev["seat"])) if ev.key?("seat")
        r = ev["round"] || (view.is_a?(Hash) ? view["round"] : nil)
        if r.is_a?(Hash)
          v["round"] = round_words(r)
          v["dealer"] = both.call(name.call(r["dealer"]))
        end
        if ev["dora"].is_a?(Array)
          d = ev["dora"].compact
          v["dora"] = d.empty? ? %w[なし なし] : tiles_words(d)
        elsif ev["dora"].is_a?(String) && ev["type"] == "new_dora"
          v["dora"] = tile_words(ev["dora"])
        end
        if ev["tile"]
          v["tile"] = tile_words(ev["tile"])
          v["plain"] = tile_words(MahjongEvents.plain(ev["tile"]))
        end
        v["waits"] = tiles_words(ev["waits"]) if ev["waits"]
        v["turn"] = both.call(ev["turn"].to_s) if ev["turn"]
        v["left"] = both.call(ev["left"].to_s) if ev["left"]
        if ev["type"] == "call"
          v["call"] = [CALL_TEXT[ev["call"]] || ev["call"].to_s, CALL_TEXT[ev["call"]] || ev["call"].to_s]
          v["kind"] = [CALL_KIND[ev["call"]] || ev["call"].to_s, CALL_KIND_READ[ev["call"]] || ev["call"].to_s]
          tiles = Array(ev["tiles"])
          v["tiles"] = tiles_words(tiles, sep: "")
          # A pon or a kan is one tile said once; a chi its run.
          v["called"] = ev["call"] == "chi" ? tiles_words(tiles, sep: "") : tile_words(tiles.min_by { |t| t.start_with?("0") ? 1 : 0 } || "")
        end
        if ev["type"] == "win"
          v["by_word"] = ev["by"] == "ron" ? %w[ロン ロン] : %w[ツモ ツモ]
          v["yaku"] = yaku_words(ev["yaku"])
          # The level (満貫 ...) is said by the strong phrasings already.
          v["points"] = points_words(ev["level"] ? ev["points"].to_s.sub(ev["level"].to_s, "").squeeze(" ") : ev["points"])
          v["level"] = [ev["level"].to_s, LEVEL_READ[ev["level"]] || ev["level"].to_s]
          v["from_part"] = ev["by"] == "ron" && ev["from"].is_a?(Integer) ? both.call("#{name.call(ev['from'])}から") : ["", ""]
        end
        if ev["type"] == "draw"
          t = Array(ev["tenpai"])
          v["tenpai_line"] = if t.empty? then both.call(z ? "全員ノーテンなのだ。" : "全員ノーテン。")
                             elsif t.size == 4 then both.call(z ? "全員テンパイなのだ。" : "全員テンパイ。")
                             else both.call("テンパイは#{t.map { |i| name.call(i) }.join('、')}#{'なのだ' if z}。")
                             end
        end
        v["kind"] = [ABORT_TEXT[ev["kind"]] || ev["kind"].to_s, ABORT_READ[ev["kind"]] || ev["kind"].to_s] if ev["type"] == "abort"
        v["score"] = both.call(ev["score"].to_s) if ev["score"]
        if ev["type"] == "game_over"
          fin = Array(ev["final"]).sort_by { |f| f[1].to_i }
          top = fin.first || []
          v["top"] = both.call(name.call(top[0]))
          v["top_score"] = both.call(top[2].to_s)
          rest = fin.drop(1).map { |f| "#{f[1]}位 #{name.call(f[0])} #{f[2]}点" }.join("、")
          v["ranks"] = both.call(rest.empty? ? "" : "#{rest}。")
        end
        if ev["type"] == "round_start"
          sc = seats.map { |s| s["score"].to_i }
          unless sc.empty?
            li = sc.index(sc.max)
            v["leader"] = both.call(name.call(li))
            v["lead_score"] = both.call(sc[li].to_s)
          end
        end
        v["status_line"] = hello_words(ev, view, tone) if ev["type"] == "hello"
        v
      end

      # The speech as a synthesiser should read it: SPEECH_READ, and a tile
      # name that slipped through (5萬, 赤5筒, or an AI's 三萬 / 五筒) read
      # as a player says it.
      KANJI_NUM = "一二三四五六七八九"
      def reading(speech)
        s = speech.to_s.gsub(/(赤)?([0-9#{KANJI_NUM}])(萬|筒|索)/o) do
          red, d, suit = Regexp.last_match.captures
          d = (KANJI_NUM.index(d) + 1).to_s if KANJI_NUM.include?(d)
          red ||= d == "0"
          d = "5" if d == "0"
          "#{'アカ' if red}#{NUM_READ[d.to_i - 1]}#{SUIT_READ[SUIT_TEXT.key(suit)]}"
        end
        s.gsub(SPEECH_READ_RE) { |w| SPEECH_READ[w] }
      end

      # Fills a template from the values: [caption, speech].
      def fill(tpl, vals)
        text = tpl.gsub(/%\{(\w+)\}/) { (vals[Regexp.last_match(1)] || ["", ""])[0] }
        speech = tpl.gsub(/%\{(\w+)\}/) { (vals[Regexp.last_match(1)] || ["", ""])[1] }
        [text, reading(speech.delete("！").gsub(/\s+/, " ").strip)]
      end

      def seat_name(seats, i)
        return "?" unless i.is_a?(Integer)
        n = seats[i].is_a?(Hash) ? seats[i]["name"].to_s.strip : ""
        n.empty? ? "#{i + 1}番の席" : n
      end

      # 東1局 1本場 (供託 1): [caption, speech].
      def round_words(r)
        w = r["wind"].to_s
        text = "#{WIND_TEXT[w] || w}#{r['number']}局"
        read = "#{WIND_READ[w] || w}#{r['number']}局"
        h = r["honba"].to_i
        if h.positive?
          text += " #{h}本場"
          read += " #{h}本場"
        end
        [text, read]
      end

      # A tile: 3萬 / 赤5筒 / 東, and サンマン / アカウーピン / トン.
      def tile_words(name)
        n = name.to_s
        m = n.match(/\A([0-9])([mpsz])\z/) or return [n, n]
        d = m[1].to_i
        if m[2] == "z"
          return [HONOR_TEXT[d - 1] || n, HONOR_READ[d - 1] || n]
        end
        red = d.zero?
        d = 5 if red
        ["#{'赤' if red}#{d}#{SUIT_TEXT[m[2]]}", "#{'アカ' if red}#{NUM_READ[d - 1]}#{SUIT_READ[m[2]]}"]
      end

      def tiles_words(names, sep: "・")
        ws = names.map { |t| tile_words(t) }
        [ws.map(&:first).join(sep), ws.map(&:last).join("、")]
      end

      # 立直・ドラ 1 / リーチ、ドラ1.
      def yaku_words(list)
        list = Array(list)
        return %w[役なし 役なし] if list.empty?
        text = list.map { |y| y.to_s.strip.squeeze(" ") }.join("・")
        read = list.map { |y| yaku_read(y.to_s) }.join("、")
        [text, read]
      end

      def yaku_read(y)
        return YAKU_READ[y] if YAKU_READ.key?(y)
        if (m = y.match(/\A(役牌|自風|場風)\s*(\S+)\z/))
          i = HONOR_TEXT.index(m[2])
          tile = i ? HONOR_READ[i] : m[2]
          return { "役牌" => tile, "自風" => "ジカゼ #{tile}", "場風" => "バカゼ #{tile}" }[m[1]]
        end
        if (m = y.match(/\A(赤ドラ|裏ドラ|ドラ)\s*(\d+)\z/))
          return "#{{ '赤ドラ' => 'アカドラ', '裏ドラ' => 'ウラドラ', 'ドラ' => 'ドラ' }[m[1]]}#{m[2]}"
        end
        y
      end

      # 30符 2翻 2000点 → the same, read: 30フ 2ハン 2000点; 満貫 → マンガン.
      def points_words(pts)
        text = pts.to_s.strip
        read = text.gsub("符", "フ").gsub("翻", "ハン").gsub("点オール", "点オール").gsub("/", "、")
        LEVEL_READ.each { |k, r| read = read.gsub(k, r) }
        [text, read]
      end

      # What the first view says: where the table is.
      def hello_words(ev, _view, tone = "plain")
        z = tone == "zundamon"
        case ev["status"]
        when "play", "result"
          r = ev["round"] || {}
          rt, rr = round_words(r)
          left = r["wall_left"]
          sticks = r["riichi_sticks"].to_i
          extra = +""
          extra << "、供託#{sticks}本" if sticks.positive?
          extra << "、残り#{left}枚" if left
          return ["観戦を始めるのだ！ #{rt}#{extra}なのだ。", "観戦を始めるのだ！ #{rr}#{extra}なのだ。"] if z
          ["観戦を始めます。#{rt}#{extra}。", "観戦を始めます。#{rr}#{extra}。"]
        when "over" then [z ? "観戦を始めるのだ！ 対局は終わったところなのだ。" : "観戦を始めます。対局は終わったところです。"] * 2
        else [z ? "観戦を始めるのだ！ 卓は対局の始まりを待っているのだ。" : "観戦を始めます。卓は対局の始まりを待っています。"] * 2
        end
      end
    end
  end
end
