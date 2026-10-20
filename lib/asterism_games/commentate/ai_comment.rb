# frozen_string_literal: true

require "fileutils"
require "monitor"
require_relative "../ai"
require_relative "mahjong_events"
require_relative "mahjong_phrases"

module AsterismGames
  module Commentate
    # The AI's one-liners (README "Commentary", "The AI's one-liners"): at
    # the big moments of a table (a riichi, a win, a draw, the lead
    # changing hands, the last round, the end) and after a quiet stretch,
    # Claude (Haiku by default) is asked for a short free line, said after
    # the fixed commentary in the same voice.
    #
    # - Which scenes: Scenes.rank of the lines a view made; at most one call
    #   every MIN_INTERVAL_S, or OUTRANK_INTERVAL_S for a scene bigger than
    #   the last one asked about (a win after a riichi); a scene that comes
    #   sooner waits (the biggest one, let go after PENDING_S); one at a
    #   time, only for the
    #   tables a page watches (nobody watching: nothing is spent).
    # - The ask: Prompt.system (the fixed part: the role, mahjong's rules in
    #   short, the tone, the length, whether the hands may be told; cached)
    #   and Prompt.user (the table now and what just happened). With the
    #   hands hidden (--public, or a page with H) the AI gets no hand.
    # - The answer: dropped when the table has moved on (another round or
    #   phase, stale?) or it came later than MAX_AGE_S after the ask, or it
    #   failed or took longer than TIMEOUT_S (one line in the log, no
    #   retry, never the key or the words).
    # - The cost: counted from the tokens (the cache's writes and reads
    #   too) in an AI::Budget of its own, under XDG_STATE_HOME; no call
    #   once today's money reaches the limit.
    #
    # The commenter is anything with say(system:, user:, timeout:) that
    # returns an AI::Said: AI::Commentator (Claude) or Fake (the tests, and
    # ASTERISM_GAMES_AI_FAKE=1: no API is called).
    class AIComment
      DEFAULT_MODEL = "claude-haiku-5-5"
      DEFAULT_DAILY_USD = 3.0
      KIND = "commentary"
      MIN_INTERVAL_S = 20
      OUTRANK_INTERVAL_S = 8
      QUIET_S = 60
      PENDING_S = 15
      MAX_AGE_S = 15
      TIMEOUT_S = 8
      RECENT = 3

      # USD per million tokens: input, output, a 5-minute cache write
      # (1.25 x input), a cache read (0.1 x input). The published prices
      # (checked 2026-10-20). A model not here is counted at the dearest
      # (so the daily limit still holds).
      PRICES = {
        "claude-haiku-5-5" => { "in" => 0.10, "out" => 0.50, "cache_write" => 0.125, "cache_read" => 0.01 },
        "claude-haiku-4-5" => { "in" => 1.0, "out" => 5.0, "cache_write" => 1.25, "cache_read" => 0.10 },
        "claude-sonnet-5-5" => { "in" => 2.0, "out" => 10.0, "cache_write" => 2.5, "cache_read" => 0.20 },
        "claude-opus-5-5" => { "in" => 4.0, "out" => 20.0, "cache_write" => 5.0, "cache_read" => 0.20 },
        "claude-fable-5-1" => { "in" => 10.0, "out" => 50.0, "cache_write" => 12.5, "cache_read" => 0.25 }
      }.freeze

      def self.prices(model) = PRICES[model.to_s] || PRICES["claude-fable-5-1"]

      # $XDG_STATE_HOME/asterism-games/ (~/.local/state/... by default).
      def self.state_dir(env = ENV)
        xdg = env["XDG_STATE_HOME"].to_s
        base = xdg.start_with?("/") ? xdg : File.join(Dir.home, ".local", "state")
        File.join(base, "asterism-games")
      end

      def self.fake_env?(env = ENV) = %w[1 true yes].include?(env["ASTERISM_GAMES_AI_FAKE"].to_s.downcase)

      # From the options (--ai, --ai-model, --ai-daily-usd) and the
      # environment: [AIComment, nil] or [nil, the status saying why not].
      def self.from_options(opts, env: ENV, log: nil, commenter: nil, clock: nil)
        return [nil, { "state" => "off", "note" => "off" }] if opts[:ai] == false
        model = opts[:ai_model] || DEFAULT_MODEL
        daily = opts[:ai_daily_usd] || DEFAULT_DAILY_USD
        fake = commenter.nil? && fake_env?(env)
        unless commenter
          if fake
            commenter = Fake.new(delay_ms: 600)
          else
            key = env["ANTHROPIC_API_KEY"].to_s
            if key.empty?
              log&.call("AI: off (no ANTHROPIC_API_KEY): set it for the AI's one-liners (README \"Commentary\")")
              return [nil, { "state" => "off", "note" => "no_key" }]
            end
            begin
              commenter = AI::Commentator.new(key, model: model)
            rescue LoadError
              log&.call("AI: off: ANTHROPIC_API_KEY is set but the anthropic gem is missing; " \
                        "`gem install anthropic` and the AI's one-liners come")
              return [nil, { "state" => "off", "note" => "no_gem" }]
            end
          end
        end
        dir = state_dir(env)
        FileUtils.mkdir_p(dir, mode: 0o700)
        path = File.join(dir, fake ? "commentary_ai_usage.fake.json" : "commentary_ai_usage.json")
        budget = AI::Budget.new(path, daily_usd: daily, prices: ->(_) { prices(model) })
        kw = { model: model, budget: budget, log: log, fake: fake }
        kw[:clock] = clock if clock
        ai = new(commenter, **kw)
        log&.call("AI: #{fake ? 'fakes (ASTERISM_GAMES_AI_FAKE): no API is called' : model}, " \
                  "today $#{format('%.4f', budget.usd_today)} of $#{format('%.2f', daily)} (counted in #{path})")
        [ai, nil]
      end

      attr_reader :budget, :model, :calls

      # deliver: called with (table, text, job) for an answer that is still
      # fresh; changed: called after a call (the money changed); targets:
      # the tables to comment on (nil: all); hands: whether the AI may see
      # the hands now. The hub sets these (attach). async: false runs each
      # call in the caller's thread (the tests).
      def initialize(commenter, model: DEFAULT_MODEL, budget:, log: nil, fake: false,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, async: true, tone: "plain")
        @commenter = commenter
        @model = model
        @budget = budget
        @log = log
        @fake = fake
        @clock = clock
        @async = async
        @tone = tone
        @lock = Monitor.new
        @tables = {} # id => {"view", "line_at", "quiet_at", "pending", "recent"}
        @busy = false
        @last_call = nil
        @last_rank = nil
        @calls = 0
        @deliver = nil
        @changed = nil
        @targets = nil
        @hands = -> { true }
        @queue = nil
        @worker = nil
      end

      attr_accessor :tone

      def attach(deliver:, changed: nil, targets: nil, hands: nil, tone: nil)
        @deliver = deliver
        @changed = changed
        @targets = targets
        @hands = hands if hands
        @tone = tone if tone
        self
      end

      # What the page's bar shows.
      def status
        s = { "state" => @fake ? "fake" : "on", "model" => @model, "usd" => @budget.usd_today.round(4),
              "limit_usd" => @budget.daily_usd }
        s["state"] = "over" if @budget.over?
        s
      end

      # A view of a table and the lines it made (the hub calls this for
      # every view).
      def observe(table, view, lines, now = @clock.call)
        @lock.synchronize do
          t = (@tables[table] ||= { "line_at" => now, "quiet_at" => now, "recent" => [] })
          t["view"] = view
          t["line_at"] = now unless lines.empty?
          rank = lines.map { |l| Scenes.rank(l) }.compact.max
          if rank
            sc = { "rank" => rank, "kind" => Scenes.kind(lines), "lines" => lines, "at" => now }.merge(Scenes.where(view))
            t["pending"] = sc if t["pending"].nil? || rank >= t["pending"]["rank"]
          end
        end
        try_fire(now)
      end

      # Every few seconds (the runner): a quiet table gets a scene of its own.
      def tick(now = @clock.call)
        @lock.synchronize do
          @tables.each_value do |t|
            v = t["view"]
            next unless t["pending"].nil? && v.is_a?(Hash) && v["status"] == "play"
            next if now - t["line_at"] < QUIET_S || now - t["quiet_at"] < QUIET_S
            t["pending"] = { "rank" => 0, "kind" => "quiet", "lines" => [], "at" => now,
                             "quiet_s" => (now - t["line_at"]).round }.merge(Scenes.where(v))
          end
        end
        try_fire(now)
      end

      # An AI line was said at table: the quiet time counts from it.
      def heard(table, text, now = @clock.call)
        @lock.synchronize do
          t = @tables[table] or return
          t["line_at"] = now
          t["recent"] << text
          t["recent"].shift while t["recent"].size > RECENT
        end
      end

      def stop
        @queue&.push(:stop)
      end

      # Why an answer is not said any more (nil: it is): the table is in
      # another round or phase, the host started again, or it is late.
      def self.stale?(job, view, now)
        return "late" if now - job["asked_at"] > MAX_AGE_S
        return "gone" unless view.is_a?(Hash)
        where = Scenes.where(view)
        return "another round" if where["round"] != job["round"]
        return "another phase" unless same_phase?(job["status"], where["status"])
        return "the host started again" if where["sv"].to_i < job["sv"].to_i
        nil
      end

      # The phase a scene was in, and the table's now: the same, or the
      # result of the last round turned into the end (a win's line still
      # fits the end's screen).
      def self.same_phase?(was, now) = was == now || (was == "result" && now == "over")

      # A line as it may be said: one line of text, no quotes, no
      # decorations or emoji; nil when nothing is left, or when it is far
      # longer than asked and cannot be cut at a sentence's end.
      def self.clean(text, max: 60)
        s = text.to_s.gsub(/[\r\n]+/, " ").strip
        s = s.sub(/\A(ずんだもん|実況|AI|ひとこと)\s*[:：]\s*/, "")
        s = s.gsub(/[「」『』"“”*#_`~|<>\[\]]/, "")
        s = s.gsub(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{3030}\u{303D}]/, "")
        s = s.gsub(/[ 　]+/, " ").strip
        return nil if s.empty?
        return s if s.size <= max
        cut = s[0, max]
        i = cut.rindex(/[。！？!?]/)
        i && i >= 8 ? cut[0..i] : nil
      end

      private

      def log(m) = @log&.call("AI: #{m}")

      def try_fire(now)
        return if @deliver.nil?
        targets = @targets&.call
        return if targets && targets.empty?
        return if @budget.over?
        hands = @hands.call ? true : false
        job = nil
        @lock.synchronize do
          return if @busy
          return if @last_call && now - @last_call < OUTRANK_INTERVAL_S
          best = nil
          @tables.each do |id, t|
            sc = t["pending"] or next
            if now - sc["at"] > PENDING_S || stale_scene?(sc, t["view"])
              t["pending"] = nil
              next
            end
            next if targets && !targets.include?(id)
            best = [id, t, sc] if best.nil? || sc["rank"] > best[2]["rank"]
          end
          return unless best
          id, t, sc = best
          if sc["kind"] == "quiet"
            sc = sc.merge("topic" => Topics.pick(t["view"], hands: hands, last: t["topic"], n: t["quiets"].to_i))
            t["topic"] = sc["topic"] && sc["topic"]["key"]
            t["quiets"] = t["quiets"].to_i + 1
          end
          # A scene bigger than the last one asked about (a win after a
          # riichi) waits OUTRANK_INTERVAL_S, any other MIN_INTERVAL_S.
          gap = @last_rank && sc["rank"] > @last_rank ? OUTRANK_INTERVAL_S : MIN_INTERVAL_S
          return if @last_call && now - @last_call < gap
          t["pending"] = nil
          t["quiet_at"] = now if sc["kind"] == "quiet"
          @busy = true
          @last_call = now
          @last_rank = sc["rank"]
          @calls += 1
          job = { "table" => id, "kind" => sc["kind"], "rank" => sc["rank"], "asked_at" => now, "hands" => hands,
                  "topic" => sc["topic"] && sc["topic"]["key"],
                  "round" => sc["round"], "status" => sc["status"], "sv" => sc["sv"],
                  "system" => Prompt.system(tone: @tone, hands: hands),
                  "user" => Prompt.user(t["view"], sc, hands: hands, recent: t["recent"].dup, tone: @tone) }
        end
        submit(job)
      end

      def stale_scene?(sc, view)
        w = Scenes.where(view)
        w["round"] != sc["round"] || !AIComment.same_phase?(sc["status"], w["status"])
      end

      def submit(job)
        return run(job) unless @async
        @lock.synchronize do
          unless @worker&.alive?
            @queue = Thread::Queue.new
            @worker = Thread.new do
              loop do
                j = @queue.pop
                break if j == :stop
                run(j)
              end
            end
          end
        end
        @queue.push(job)
      end

      def run(job)
        said = @commenter.say(system: job["system"], user: job["user"], timeout: TIMEOUT_S)
        usd = @budget.record(KIND, said.tokens)
        tk = said.tokens
        log("#{job['kind']}#{job['topic'] ? " (#{job['topic']})" : ''}#{job['hands'] ? '' : ' (hands hidden)'}: " \
            "#{format('%.1f', said.ms.to_i / 1000.0)} s, stop #{said.stop || '-'}, " \
            "tokens in #{tk['in'].to_i} " \
            "cache_write #{tk['cache_write'].to_i} cache_read #{tk['cache_read'].to_i} out #{tk['out'].to_i}, " \
            "$#{format('%.5f', usd)} (today $#{format('%.4f', @budget.usd_today)})")
        text = AIComment.clean(said.text)
        return log("#{job['kind']}: an answer that is not a line, dropped") unless text
        now = @clock.call
        view = @lock.synchronize { @tables.dig(job["table"], "view") }
        if (why = AIComment.stale?(job, view, now))
          return log("#{job['kind']}: a stale answer dropped (#{why})")
        end
        heard(job["table"], text, now)
        @deliver.call(job["table"], text, job)
      rescue AI::TokenError => e
        @budget.record(KIND, e.tokens)
        log("#{job['kind']}: dropped (#{e.message})")
      rescue AI::Error => e
        @budget.record_failure(KIND)
        log("#{job['kind']}: dropped (#{e.message})")
      rescue StandardError => e
        log("#{job['kind']}: dropped (#{e.class})")
      ensure
        @lock.synchronize { @busy = false }
        @changed&.call
      end

      # Which lines make a scene, and how big it is.
      module Scenes
        RANKS = { "game_over" => 5, "lead_change" => 4, "draw" => 2, "abort" => 2, "riichi" => 1 }.freeze
        WORDS = { "game_over" => "終局", "win_strong" => "大きな和了 (満貫以上)", "win" => "和了",
                  "lead_change" => "逆転", "oorasu" => "オーラス", "draw" => "流局", "abort" => "途中流局",
                  "riichi" => "リーチ", "quiet" => "静かな時間" }.freeze

        module_function

        # nil: not a scene. A win of a mangan or more (prio 3) and the
        # lead changing hands rank above a plain win; the last round
        # (a round start of prio 3) with a win.
        def rank(line)
          return nil if line["ai"]
          case line["type"]
          when "win" then line["prio"].to_i >= 3 ? 4 : 3
          when "round_start" then line["prio"].to_i >= 3 ? 3 : nil
          else RANKS[line["type"]]
          end
        end

        # The scene's name: its biggest line's.
        def kind(lines)
          l = lines.select { |x| rank(x) }.max_by { |x| rank(x) }
          return "quiet" unless l
          case l["type"]
          when "win" then l["prio"].to_i >= 3 ? "win_strong" : "win"
          when "round_start" then "oorasu"
          else l["type"]
          end
        end

        # Where the table is: {"round" => [wind, number, honba], "status", "sv"}.
        def where(view)
          return { "round" => nil, "status" => nil, "sv" => nil } unless view.is_a?(Hash)
          r = view["round"].is_a?(Hash) ? view["round"] : {}
          { "round" => [r["wind"], r["number"], r["honba"]], "status" => view["status"], "sv" => view["sv"] }
        end
      end

      # What a quiet minute is about, chosen here so that the AI does not
      # wander (with an open question Haiku spent seconds and hundreds of
      # tokens): one of the leader's lead, a seat in tenpai without riichi
      # (only with the hands shown), the dora, the wall left, the last
      # discard; in turn, never the one of the last quiet minute.
      module Topics
        P = MahjongPhrases
        ORDER = %w[lead dama dora wall last_discard].freeze

        module_function

        # {"key", "text"}, or nil when the view has nothing to talk about.
        def pick(view, hands: false, last: nil, n: 0)
          all = candidates(view, hands: hands)
          return nil if all.empty?
          keys = ORDER.select { |k| all.key?(k) }
          keys -= [last] if keys.size > 1
          k = keys[n % keys.size]
          { "key" => k, "text" => all[k] }
        end

        def candidates(view, hands: false)
          return {} unless view.is_a?(Hash)
          seats = Array(view["seats"])
          name = ->(i) { P.seat_name(seats, i) }
          out = {}
          sc = seats.map { |x| x["score"].to_i }
          if sc.size >= 2
            order = sc.each_index.sort_by { |i| [-sc[i], i] }
            a, b = order
            out["lead"] = "トップは#{name.call(a)} (#{sc[a]}点)、2位の#{name.call(b)}との差は#{sc[a] - sc[b]}点。"
          end
          if hands
            seats.each_with_index do |x, i|
              next if x["riichi"]
              w = MahjongEvents.waits_of(x)
              next unless w && !w.empty?
              out["dama"] = "#{name.call(i)}はリーチをかけずにテンパイしている (待ち #{w.map { |t| P.tile_words(t)[0] }.join('・')})。"
              break
            end
          end
          dora = Array(view["dora_indicators"]).map { |t| MahjongEvents.dora_of(t) }.compact
          unless dora.empty?
            seen = seats.sum do |x|
              (Array(x["river"]) + Array(x["melds"]).flat_map { |m| Array(m["tiles"]) })
                .count { |t| dora.include?(MahjongEvents.plain(t)) }
            end
            out["dora"] = "ドラは#{dora.map { |t| P.tile_words(t)[0] }.join('・')}。河と鳴きに見えているのは#{seen}枚。"
          end
          left = view.dig("round", "wall_left")
          out["wall"] = "山の残りは#{left}枚。" if left.is_a?(Integer)
          ld = view["last_discard"]
          if ld.is_a?(Hash) && ld["tile"]
            out["last_discard"] = "直前に#{name.call(ld['seat'])}が#{P.tile_words(ld['tile'])[0]}を切った。"
          end
          out
        end
      end

      # The words of the ask. The system part is fixed for a tone and
      # whether the hands may be told (four texts in all, each the same to
      # the byte every time, so the cache holds); the user part is the
      # table now.
      module Prompt
        P = MahjongPhrases

        HANDS = <<~TEXT
          観戦用の様子なので、各席の手牌と待ちが見えている。手牌と待ちに触れてよい (例: 誰の待ちが山に残っていそうか、誰が危ない牌を抱えているか、誰の手が高そうか)。ただし打ち手には見えていないことを忘れず、観戦者への語りかけとして言う。
        TEXT
        NO_HANDS = <<~TEXT
          手牌は見えない (配信用で、公開の情報だけで実況する)。手牌・待ち・聴牌しているかどうかを推測で言わない。河・鳴き・リーチ・点数・残り枚数など、誰にでも見える情報だけで話す。
        TEXT

        SYSTEM = <<~TEXT
          あなたは麻雀の観戦実況の「ひとこと」係です。Asterism のゲームホストで打たれている 4 人麻雀の卓を外から見て、決まりの実況 (リーチ・鳴き・和了・点数・順位などを決まった文で伝える係) の後に、短い自由なひとことを添えます。事実は決まりの実況がもう伝えているので、同じ事実を繰り返さず、その場面の意味、緊張感、見どころ、次の展開への期待を、観戦者に語りかけるように言ってください。

          ## 答え方
          - 日本語で 40 字以内、1〜2 文。
          - 答えは実況の文だけ。前置き、説明、かぎかっこ、記号の飾り、絵文字、顔文字、改行、話し手の名前は付けない。
          - 牌は「3萬」「5筒」「7索」「赤5筒」「東」「白」「發」「中」のように書く (漢数字や英字の記号は使わない)。
          - 与えられた様子に無いことは言わない。点数・役・順位を推測で言わない。打ち手の名前は様子にある名前をそのまま使う。
          - 打ち手を馬鹿にしない。特定の打ち手だけを応援しすぎない。
          - 口調: %<tone>s

          ## 手牌
          %<hands>s
          ## 麻雀の要点
          - 4 人で打つ。東風戦は東場の 4 局、半荘は南場までの 8 局。親 (東家) が和了るか聴牌で流局すると連荘になり、本場が 1 つ増える。
          - 持ち点は 25000 点から。最後の局 (オーラス) が終わった時の点数で順位が決まる。トップ争い、2 着争い、ラス回避、親の連荘、オーラスの逆転が見どころ。
          - 手牌は 13 枚。ツモで 14 枚にして 4 面子 1 雀頭 (または七対子・国士無双) を作ると和了。他家の捨て牌で和了るのがロン、自分で引いて和了るのがツモ。
          - 聴牌はあと 1 枚で和了れる形。待ちの牌が河や他家の手にたくさん見えていると、残りが少なく和了りにくい。
          - リーチ: 門前で聴牌したら 1000 点を供託して宣言する。以後は手を変えられない。一発・裏ドラで高くなることがある。他家は安全な牌 (リーチ者の河にある牌) を切って守る (オリ) か、勝負するかを選ぶ。
          - 鳴き: チー (上家の捨て牌で順子)、ポン (誰の捨て牌でも刻子)、カン (4 枚)。鳴くと速くなるが、門前でなくなりリーチできず、役も限られる。
          - ドラ: ドラ表示牌の次の牌がドラで、1 枚 1 翻。赤5 もドラ。カンをすると新しいドラがめくれる。
          - 点数は翻と符で決まる。5 翻で満貫 (子 8000 点、親 12000 点)、6〜7 翻で跳満、8〜10 翻で倍満、11〜12 翻で三倍満、13 翻以上か特別な役で役満。
          - 流局: 山が尽きると流局し、聴牌の人がノーテンの人から合わせて 3000 点を受け取る。九種九牌・四風連打などの途中流局もある。
          - 河は各席が捨てた牌の並び。河から、何が安全か、手が速いか、何を集めていそうかが読める。残り枚数が少ないと、和了るか流局かの瀬戸際になる。
          - 1 局の流れ: 局の始まり、打牌の繰り返し (途中にリーチや鳴き)、和了か流局、次の局。

          ## 様子の読み方
          ユーザの文は、その時点の卓の様子の要約 (局、本場、供託、残り枚数、ドラ、各席の名前・家・点数・リーチ・鳴き・河の最後の数枚%<hand_note>s、和了や終局の結果) と、場面 (リーチ、和了、流局、逆転、オーラス、終局、静かな時間)、直前の出来事 (決まりの実況が言った文)、最近のひとことです。その場面ならではのひとことを言ってください。場面が静かな時間のときは、ユーザの文の「話題」の 1 つだけについて言ってください (ほかの話を広げない)。最近のひとことと同じ言い回しは避けてください。
        TEXT

        @cache = {}
        @cache_lock = Mutex.new

        module_function

        def system(tone: "plain", hands: true)
          key = [tone, hands ? true : false]
          @cache_lock.synchronize do
            @cache[key] ||= format(SYSTEM, tone: (MahjongPhrases::TONES[tone] || MahjongPhrases::TONES["plain"])["prompt"],
                                           hands: hands ? HANDS : NO_HANDS,
                                           hand_note: hands ? "、手牌と待ち" : "").freeze
          end
        end

        WIND = { "east" => "東家", "south" => "南家", "west" => "西家", "north" => "北家" }.freeze
        STATUS = { "play" => "対局中", "result" => "局の結果", "over" => "終局", "wait" => "対局前" }.freeze

        # The table now and what just happened (sc: the scene).
        def user(view, sc, hands: true, recent: [], tone: "plain")
          v = view.is_a?(Hash) ? view : {}
          seats = Array(v["seats"])
          out = ["卓の様子 (sv #{v['sv']}):"]
          r = v["round"].is_a?(Hash) ? v["round"] : nil
          if r
            rt, = P.round_words(r)
            dora = Array(v["dora_indicators"]).map { |t| MahjongEvents.dora_of(t) }.compact
            line = +"#{rt}、供託#{r['riichi_sticks'].to_i}本"
            line << "、残り#{r['wall_left']}枚" if r["wall_left"]
            line << "、ドラ #{tiles(dora)} (表示牌 #{tiles(Array(v['dora_indicators']))})" unless dora.empty?
            line << "。状態: #{STATUS[v['status']] || v['status']}"
            line << "、手番 #{P.seat_name(seats, r['turn'])}" if v["status"] == "play" && r["turn"].is_a?(Integer)
            out << "#{line}。"
          else
            out << "状態: #{STATUS[v['status']] || v['status'] || '不明'}。"
          end
          seats.each_with_index { |s, i| out << seat_line(s, i, r, hands) }
          (res = result_line(v, seats)) && out << res
          (fin = final_line(v, seats)) && out << fin
          out << ""
          out << "場面: #{Scenes::WORDS[sc['kind']] || sc['kind']}"
          out << "直前の出来事:"
          said = Array(sc["lines"]).map { |l| hands ? l["text"] : (l.key?("ptext") ? l["ptext"] : l["text"]) }.compact
          if said.empty?
            out << "- しばらく動きがない (#{sc['quiet_s'] || QUIET_S} 秒)。"
            out << "話題: #{sc['topic']['text']}" if sc["topic"]
          else
            said.each { |t| out << "- #{t}" }
          end
          unless recent.empty?
            out << ""
            out << "最近のひとこと:"
            recent.each { |t| out << "- #{t}" }
          end
          out.join("\n")
        end

        def seat_line(s, i, r, hands)
          name = s["name"].to_s.strip.empty? ? "#{i + 1}番の席" : s["name"].to_s.strip
          w = WIND[s["wind"]] || ""
          w += "(親)" if r && r["dealer"] == i
          parts = ["- #{name} #{w} #{s['score']}点"]
          parts << "リーチ中" if s["riichi"]
          melds = Array(s["melds"])
          parts << "鳴き #{melds.map { |m| meld_words(m) }.join('、')}" unless melds.empty?
          river = Array(s["river"])
          parts << "河 #{river.size}枚#{river.empty? ? '' : " (最後: #{tiles(river.last(6), sep: ' ')})"}"
          if hands && s["hand"].is_a?(Array)
            parts << "手牌 #{tiles(s['hand'], sep: '')}#{s['drawn'] ? " ツモ #{tiles([s['drawn']])}" : ''}"
            w8 = MahjongEvents.waits_of(s)
            parts << (w8 && !w8.empty? ? "待ち #{tiles(w8)}" : "ノーテン") if s["drawn"].nil?
          end
          parts.join("、")
        end

        def meld_words(m)
          kind = P::CALL_KIND[m["type"]] || m["type"].to_s
          "#{kind} #{tiles(Array(m['tiles']), sep: '')}"
        end

        def result_line(v, seats)
          res = v["result"]
          return nil unless res.is_a?(Hash) && %w[result over].include?(v["status"])
          case res["kind"].to_s
          when "tsumo_agari", "ron_agari"
            Array(res["wins"]).map do |w|
              by = res["kind"] == "ron_agari" ? "ロン (#{P.seat_name(seats, res['from'])}から)" : "ツモ"
              "結果: #{P.seat_name(seats, w['seat'])}の#{by}、#{Array(w['yaku']).join('・')}、#{w['points']}。"
            end.join("\n")
          when "ryuukyoku"
            t = Array(res["tenpai"]).map { |i| P.seat_name(seats, i) }
            "結果: 流局。テンパイ #{t.empty? ? 'なし' : t.join('、')}。"
          else "結果: 途中流局 (#{P::ABORT_TEXT[res['kind']] || res['kind']})。"
          end
        end

        def final_line(v, seats)
          fin = v["final"]
          return nil unless v["status"] == "over" && fin.is_a?(Array) && !fin.empty?
          "終局の順位: #{fin.sort_by { |f| f[1].to_i }.map { |f| "#{f[1]}位 #{P.seat_name(seats, f[0])} #{f[2]}点" }.join('、')}。"
        end

        def tiles(names, sep: "・")
          names.map { |t| P.tile_words(t)[0] }.join(sep)
        end
      end

      # A commenter for the tests and for trying the page without a key
      # (ASTERISM_GAMES_AI_FAKE=1): says a line of its own after delay_ms
      # (naming the scene it was asked about), every fail_every-th fails,
      # every slow_every-th takes longer than its time limit. The first
      # call counts a cache write, the others a cache read, as the API
      # would. requests: what it was asked.
      class Fake
        attr_reader :requests

        # stop: a stop reason to fail with as a cut answer would
        # ("max_tokens"), counting its tokens.
        def initialize(delay_ms: 0, fail_every: 0, slow_every: 0, text: nil, stop: nil)
          @stop = stop
          @delay_ms = delay_ms
          @fail_every = fail_every
          @slow_every = slow_every
          @text = text
          @requests = []
          @lock = Mutex.new
        end

        def count = @lock.synchronize { @requests.size }

        def say(system:, user:, timeout: TIMEOUT_S)
          i = @lock.synchronize { (@requests << { "system" => system, "user" => user }).size }
          if @slow_every.positive? && (i % @slow_every).zero?
            sleep(timeout + 0.2)
            raise AI::Error, "fake: Net::ReadTimeout"
          end
          sleep(@delay_ms / 1000.0) if @delay_ms.positive?
          raise AI::Error, "fake: failing on purpose (#{i})" if @fail_every.positive? && (i % @fail_every).zero?
          if @stop
            raise AI::TokenError.new("fake: cut (stop_reason #{@stop}, out 200)",
                                     { "in" => 300, "out" => 200, "cache_write" => 0, "cache_read" => 1500 })
          end
          scene = user[/^場面: (.+)$/, 1] || "この"
          text = @text ? @text.call(system, user, i) : "偽のひとこと#{i}、#{scene}の場面なのだ！"
          AI::Said.new(text: text, ms: @delay_ms, stop: "end_turn",
                       tokens: { "in" => 300, "out" => 25, "cache_write" => i == 1 ? 1500 : 0,
                                 "cache_read" => i == 1 ? 0 : 1500 })
        end
      end
    end
  end
end
