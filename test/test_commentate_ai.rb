# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zlib"
require "stringio"
require "socket"
require "asterism_games/commentate"
require "asterism_games/commentate/mahjong"

# The AI's one-liners of the commentary (README "Commentary", "The AI's
# one-liners"): which scenes are asked about and how often, the ask (its
# fixed, cached part and the table now), the hands kept from the AI when
# they are hidden, stale answers dropped, the money counted and the daily
# limit, the speech read as the fixed lines are, and the request Claude
# would get. No API is ever called: the commenter is a Fake, and the
# Claude client is pointed at a server of this test.
class TestCommentateAI < Minitest::Test
  C = AsterismGames::Commentate
  A = C::AIComment
  AI = AsterismGames::AI
  FIXTURE = File.join(__dir__, "fixtures/commentate_tonpuu.json.gz")

  def recorded
    @recorded ||= JSON.parse(Zlib::GzipReader.open(FIXTURE, &:read))
  end

  def setup
    @dir = Dir.mktmpdir("commentate-ai")
    @now = 1000.0
    @logs = []
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def budget(daily: 3.0, clock: -> { Time.at(1_760_000_000) })
    AI::Budget.new(File.join(@dir, "usage.json"), daily_usd: daily, prices: ->(_) { A.prices(A::DEFAULT_MODEL) },
                                                  clock: clock)
  end

  # An AIComment on a Fake, its calls in this thread, delivering into out.
  def ai_with(fake = A::Fake.new, daily: 3.0, hands: true, targets: nil, b: nil)
    out = []
    ai = A.new(fake, budget: b || budget(daily: daily), clock: -> { @now }, async: false, log: ->(m) { @logs << m })
    ai.attach(deliver: ->(id, text, job) { out << [id, text, job] }, hands: -> { hands }, targets: targets)
    [ai, out]
  end

  def view(status: "play", round: ["east", 1, 0], sv: 1, hands: true)
    seats = 4.times.map do |i|
      s = { "seat" => i, "name" => "CPU#{i + 1}", "score" => 25_000, "wind" => %w[east south west north][i],
            "riichi" => false, "river" => %w[1z 9m 2p], "melds" => [], "hand_count" => 13 }
      s["hand"] = %w[1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 5s 6s] if hands
      s["drawn"] = nil if hands
      s
    end
    { "status" => status, "sv" => sv, "seats" => seats,
      "round" => { "wind" => round[0], "number" => round[1], "honba" => round[2], "riichi_sticks" => 0,
                   "dealer" => 0, "wall_left" => 40, "turn" => 1 },
      "dora_indicators" => ["3p"], "rules" => { "game" => "tonpuu" } }
  end

  def line(type, prio, text = "#{type}の文。", ptext: :same)
    l = { "type" => type, "prio" => prio, "text" => text, "speech" => text }
    l["ptext"] = ptext == :same ? text : ptext
    l
  end

  # ------------------------------------------------------------ scenes

  def test_which_lines_are_scenes
    assert_nil A::Scenes.rank(line("call", 1))
    assert_nil A::Scenes.rank(line("tenpai", 1))
    assert_nil A::Scenes.rank(line("round_start", 1)), "a round starting is not, the last one is"
    assert_equal 3, A::Scenes.rank(line("round_start", 3))
    assert_equal 1, A::Scenes.rank(line("riichi", 2))
    assert_equal 3, A::Scenes.rank(line("win", 2))
    assert_equal 4, A::Scenes.rank(line("win", 3)), "a mangan or more"
    assert_equal 4, A::Scenes.rank(line("lead_change", 3))
    assert_equal 2, A::Scenes.rank(line("draw", 2))
    assert_equal 2, A::Scenes.rank(line("abort", 2))
    assert_equal 5, A::Scenes.rank(line("game_over", 2))
    assert_nil A::Scenes.rank(line("ai", 0).merge("ai" => true)), "never its own lines"
    assert_equal "win_strong", A::Scenes.kind([line("win", 3), line("lead_change", 3)])
    assert_equal "oorasu", A::Scenes.kind([line("round_start", 3)])
  end

  def test_a_big_scene_is_asked_about_and_small_ones_are_not
    fake = A::Fake.new
    ai, out = ai_with(fake)
    v = view
    ai.observe("h/t", v, [line("call", 1), line("tenpai", 1)])
    assert_equal 0, fake.count
    ai.observe("h/t", v, [line("riichi", 2, "CPU1、リーチ！ 待ちは4索・7索。")])
    assert_equal 1, fake.count
    assert_equal 1, out.size
    id, text, job = out.first
    assert_equal "h/t", id
    assert_equal "偽のひとこと1、リーチの場面なのだ！", text
    assert_equal "riichi", job["kind"]
    assert_equal 1, job["sv"]
    assert_includes fake.requests[0]["user"], "CPU1、リーチ！ 待ちは4索・7索。"
  end

  def test_the_lower_bound_of_the_interval
    fake = A::Fake.new
    ai, out = ai_with(fake)
    v = view
    ai.observe("h/t", v, [line("riichi", 2)])
    @now += 5
    ai.observe("h/t", v.merge("sv" => 2), [line("riichi", 2, "二人目のリーチ。")])
    assert_equal 1, fake.count, "not within 20 s"
    @now += 10
    ai.tick
    assert_equal 1, fake.count
    @now += 5.5 # 20.5 s after the first call, the waiting scene is 15.5 s old: let go
    ai.tick
    assert_equal 1, fake.count, "a scene that waited longer than PENDING_S is let go"
    # A win after a riichi outranks it: it waits OUTRANK_INTERVAL_S (8 s)
    # only, the biggest of those waiting.
    @now += 30
    ai.observe("h/t", v.merge("sv" => 3), [line("riichi", 2)])
    assert_equal 2, fake.count
    @now += 5
    r = v.merge("status" => "result", "sv" => 4)
    ai.observe("h/t", r, [line("win", 3, "ロン！！ 満貫！"), line("lead_change", 3, "逆転！")])
    ai.observe("h/t", r.merge("sv" => 5), [line("riichi", 2)]) # smaller: does not replace it
    assert_equal 2, fake.count, "not within 8 s"
    @now += 2.9
    ai.tick
    assert_equal 2, fake.count
    @now += 0.2 # 8.1 s after the riichi's call
    ai.tick
    assert_equal 3, fake.count
    assert_equal "win_strong", out.last[2]["kind"]
    assert_includes fake.requests.last["user"], "- ロン！！ 満貫！\n- 逆転！"
    # After the win (rank 4), a smaller or equal scene waits the full 20 s.
    ai.observe("h/t", view(round: ["east", 2, 0], sv: 6), [line("round_start", 1)])
    @now += 9
    ai.observe("h/t", view(round: ["east", 2, 0], sv: 7), [line("riichi", 2)])
    assert_equal 3, fake.count, "a riichi after a win is not bigger: 20 s"
    @now += 11.1
    ai.tick
    assert_equal 4, fake.count
    # The end outranks the riichi: 8 s.
    @now += 8.1
    ai.observe("h/t", view(round: ["east", 2, 0], sv: 8).merge("status" => "over"), [line("game_over", 2)])
    assert_equal 5, fake.count
    assert_equal "game_over", out.last[2]["kind"]
    fake = A::Fake.new
    ai, = ai_with(fake)
    # A scene of a round that is over is let go too.
    @now += 25
    ai.observe("h/t", v.merge("sv" => 6), [line("riichi", 2)])
    @now += 1
    ai.observe("h/t", v.merge("sv" => 7, "status" => "result"), [line("draw", 2)])
    @now += 2
    ai.observe("h/t", view(round: ["east", 2, 0], sv: 8), [line("round_start", 1)])
    @now += 30
    ai.tick
    assert_equal 1, fake.count, "the draw of the round before was not asked about"
  end

  def test_a_quiet_minute
    fake = A::Fake.new
    ai, out = ai_with(fake)
    v = view
    ai.observe("h/t", v, [line("call", 1)])
    @now += 59
    ai.tick
    assert_equal 0, fake.count
    @now += 2
    ai.tick
    assert_equal 1, fake.count
    assert_equal "quiet", out.last[2]["kind"]
    assert_match(/場面: 静かな時間\n直前の出来事:\n- しばらく動きがない \(61 秒\)。/, fake.requests[0]["user"])
    @now += 30
    ai.tick
    assert_equal 1, fake.count, "the quiet counts again from the AI's line"
    @now += 31
    ai.tick
    assert_equal 2, fake.count
    # Not between rounds, not before the game.
    ai2, = ai_with(f2 = A::Fake.new)
    ai2.observe("h/t", v.merge("status" => "result"), [])
    @now += 120
    ai2.tick
    assert_equal 0, f2.count
  end

  def test_one_at_a_time_and_only_for_the_tables_watched
    fake = A::Fake.new
    watched = []
    ai, out = ai_with(fake, targets: -> { watched })
    ai.observe("h/t", view, [line("riichi", 2)])
    assert_equal 0, fake.count, "nobody watching: nothing is spent"
    watched << "h/t"
    @now += 1
    ai.observe("h/t", view(sv: 2), [line("riichi", 2)])
    assert_equal 1, fake.count
    assert_equal 1, out.size
  end

  # ------------------------------------------------------------ stale answers

  def test_a_stale_answer_is_dropped
    job = { "asked_at" => 100.0, "round" => ["east", 1, 0], "status" => "play", "sv" => 10 }
    v = view(sv: 12)
    assert_nil A.stale?(job, v, 103.0)
    assert_equal "late", A.stale?(job, v, 100.0 + A::MAX_AGE_S + 0.1)
    assert_equal "another round", A.stale?(job, view(round: ["east", 2, 0], sv: 13), 103.0)
    assert_equal "another round", A.stale?(job, view(round: ["east", 1, 1], sv: 13), 103.0), "a new honba too"
    assert_equal "another phase", A.stale?(job, v.merge("status" => "result"), 103.0)
    win = job.merge("status" => "result")
    assert_nil A.stale?(win, v.merge("status" => "over"), 103.0), "the last win's line fits the end too"
    assert_equal "another phase", A.stale?(win, v.merge("status" => "play"), 103.0)
    assert_equal "the host started again", A.stale?(job, view(sv: 2), 103.0)
    assert_equal "gone", A.stale?(job, nil, 103.0)
    # In the flow: the round moves on while the AI answers.
    ai = nil
    fake = A::Fake.new(text: lambda do |_s, _u, _i|
      ai.observe("h/t", view(round: ["east", 2, 0], sv: 5), [line("round_start", 1)])
      "遅れたひとことなのだ。"
    end)
    ai, out = ai_with(fake)
    ai.observe("h/t", view, [line("riichi", 2)])
    assert_equal 1, fake.count
    assert_empty out
    assert @logs.any? { |m| m.include?("a stale answer dropped (another round)") }
    refute @logs.any? { |m| m.include?("遅れた") }, "the words are not logged"
    # Too slow.
    fake = A::Fake.new(text: lambda do |_s, _u, _i|
      @now += A::MAX_AGE_S + 1
      "ひとこと。"
    end)
    ai, out = ai_with(fake)
    ai.observe("h/t", view, [line("riichi", 2)])
    assert_empty out
    assert @logs.any? { |m| m.include?("(late)") }
  end

  # ------------------------------------------------------------ the hands

  def test_the_hands_hidden_are_not_told_to_the_ai
    [true, false].each do |hands|
      fake = A::Fake.new
      ai, = ai_with(fake, hands: hands)
      ai.observe("h/t", view, [line("riichi", 2, "CPU1、リーチ！ 待ちは4索・7索。", ptext: "CPU1、リーチ！"),
                               line("tenpai", 1, "CPU2、テンパイ。待ちは1萬。", ptext: nil)])
      req = fake.requests.first
      if hands
        assert_includes req["user"], "手牌 1萬2萬3萬"
        assert_includes req["user"], "待ち 4索・7索"
        assert_includes req["user"], "- CPU1、リーチ！ 待ちは4索・7索。"
        assert_includes req["system"], "手牌と待ちに触れてよい"
      else
        refute_includes req["user"], "手牌"
        refute_includes req["user"], "待ち"
        refute_includes req["user"], "テンパイ"
        assert_includes req["user"], "- CPU1、リーチ！"
        assert_includes req["system"], "手牌は見えない"
        refute_includes req["system"], "手牌と待ちに触れてよい"
      end
    end
  end

  def test_the_hub_hides_the_hands_from_the_ai_with_public_or_a_page_with_h
    [[true, false], [false, true], [false, false]].each do |pub, page_hides|
      fake = A::Fake.new
      ai, = ai_with(fake)
      ai.instance_variable_set(:@async, false)
      hub = C::MahjongHub.new(public: pub, ai: ai, rng: Random.new(1), clock: -> { Time.at(@now) })
      page = C::Server::Client.new(nil, hide: page_hides)
      hub.subscribe(page)
      recorded.each do |v|
        @now += 1.5
        hub.update("games", "mahjong1", v)
        hub.tick
      end
      refute_empty fake.requests
      told = fake.requests.any? { |r| r["user"].include?("手牌 ") }
      if pub || page_hides
        refute told, "public=#{pub} H=#{page_hides}: no hand to the AI"
        refute fake.requests.any? { |r| r["user"].include?("待ち") }
      else
        assert told
      end
      lines = hub.tables["games/mahjong1"]["lines"].select { |l| l["ai"] }
      refute_empty lines
      lines.each do |l|
        assert_equal "ai", l["type"]
        if pub || page_hides
          assert_equal l["text"], l["ptext"], "said without the hands: a page with H shows it"
        else
          assert_nil l["ptext"], "made with the hands: a page with H does not show it"
        end
      end
    end
  end

  # ------------------------------------------------------------ the prompt

  def test_the_fixed_part_is_the_same_every_time_and_the_rest_changes
    fake = A::Fake.new
    ai, = ai_with(fake)
    ai.tone = "zundamon"
    ai.observe("h/t", view, [line("riichi", 2)])
    @now += 25
    ai.observe("h/t", view(sv: 9), [line("draw", 2)].map { |l| l.merge("text" => "流局なのだ。") })
    s1, s2 = fake.requests.map { |r| r["system"] }
    assert_equal s1, s2
    assert s1.frozen?
    assert_same A::Prompt.system(tone: "zundamon", hands: true), A::Prompt.system(tone: "zundamon", hands: true)
    assert_includes s1, C::MahjongPhrases::TONES["zundamon"]["prompt"], "the tone of the voice"
    assert_includes s1, "40 字以内、1〜2 文"
    assert_includes s1, "前置き"
    assert_includes s1, "満貫"
    assert_operator s1.size, :>, 1200, "long enough for the cache (Haiku 5.5 caches from 512 tokens)"
    refute_includes s1, "sv", "nothing that changes"
    refute_equal fake.requests[0]["user"], fake.requests[1]["user"]
    assert_includes fake.requests[1]["user"], "最近のひとこと:\n- 偽のひとこと1"
    assert_includes fake.requests[1]["user"], "卓の様子 (sv 9)"
    plain = A::Prompt.system(tone: "plain", hands: false)
    assert_includes plain, C::MahjongPhrases::TONES["plain"]["prompt"]
    refute_equal plain, s1
  end

  def test_the_table_now_in_words
    v = recorded.find { |x| x["status"] == "result" }
    u = A::Prompt.user(v, { "kind" => "win", "lines" => [line("win", 2, "ロン！")] }, hands: true)
    assert_match(/^東\d局/, u.lines[1])
    assert_match(/ドラ \S+ \(表示牌 /, u)
    assert_match(/^結果: CPU\dのロン \(CPU\dから\)、/, u)
    assert_equal 4, u.lines.count { |l| l.start_with?("- CPU") }
    over = recorded.last
    u = A::Prompt.user(over, { "kind" => "game_over", "lines" => [line("game_over", 2)] }, hands: false)
    assert_match(/^終局の順位: 1位 CPU4 33600点、2位/, u)
    refute_includes u, "手牌"
  end

  def test_the_answer_cleaned
    assert_equal "いい勝負なのだ！", A.clean("「いい勝負なのだ！」\n")
    assert_equal "いい勝負なのだ！", A.clean("ずんだもん: いい勝負なのだ！🔥")
    assert_equal "どっちが勝つのか。", A.clean("**どっちが勝つのか。**")
    assert_nil A.clean("   ")
    long = "#{'あ' * 30}。#{'い' * 40}。"
    assert_equal "#{'あ' * 30}。", A.clean(long), "cut at a sentence's end"
    assert_nil A.clean("う" * 90), "far too long and no end to cut at"
  end

  def test_the_speech_is_read_as_the_fixed_lines_are
    hub = C::MahjongHub.new(rng: Random.new(1))
    hub.update("h", "t", recorded[100])
    l = hub.ai_line("h/t", "三萬と赤5筒が流局を呼ぶのだ！ 跳満もあるのだ。")
    assert_equal "三萬と赤5筒が流局を呼ぶのだ！ 跳満もあるのだ。", l["text"], "the caption as it came"
    assert_equal "サンマンとアカウーピンがリューキョクを呼ぶのだ ハネマンもあるのだ。", l["speech"]
    assert l["ai"]
    assert_equal 0, l["prio"]
    assert_empty l["clips"]
    assert_nil hub.ai_line("h/nope", "x"), "a table not there"
    assert_equal "キューソーとイーピン", C::MahjongPhrases.reading("九索と一筒")
  end

  # ------------------------------------------------------------ money

  def test_the_money_counted_and_the_daily_limit
    t = Time.at(1_760_000_000)
    b = budget(daily: 0.00025, clock: -> { t })
    fake = A::Fake.new
    ai, out = ai_with(fake, b: b)
    ai.observe("h/t", view, [line("riichi", 2)])
    d = b.day["commentary"]
    assert_equal 1, d["calls"]
    assert_equal 1500, d["cache_write"]
    # 300 in x 0.10 + 25 out x 0.50 + 1500 cache write x 0.125, per million.
    assert_in_delta (300 * 0.10 + 25 * 0.50 + 1500 * 0.125) / 1e6, d["usd"], 1e-6
    @now += 25
    ai.observe("h/t", view(sv: 2), [line("riichi", 2)])
    d = b.day["commentary"]
    assert_equal 2, d["calls"]
    assert_equal 1500, d["cache_read"], "the second reads the cache"
    first = (300 * 0.10 + 25 * 0.50 + 1500 * 0.125) / 1e6
    assert_in_delta first + (300 * 0.10 + 25 * 0.50 + 1500 * 0.01) / 1e6, d["usd"], 1e-6 # kept to 6 places
    assert b.over?, "the limit is reached"
    assert_equal "over", ai.status["state"]
    @now += 25
    ai.observe("h/t", view(sv: 3), [line("riichi", 2)])
    assert_equal 2, fake.count, "no call over the limit"
    assert_equal 2, out.size
    # The next day starts at 0.
    t += 86_400
    sleep 1.05 # the budget reads its file again at most once a second
    refute b.over?
    @now += 25
    ai.observe("h/t", view(sv: 4), [line("riichi", 2)])
    assert_equal 3, fake.count
    assert_equal({ "state" => "on", "model" => "claude-haiku-5-5", "usd" => b.usd_today.round(4), "limit_usd" => 0.00025 },
                 ai.status)
  end

  def test_the_prices
    assert_equal 0.10, A.prices("claude-haiku-5-5")["in"]
    assert_equal 0.50, A.prices("claude-haiku-5-5")["out"]
    assert_equal 0.01, A.prices("claude-haiku-5-5")["cache_read"]
    assert_equal A.prices("claude-fable-5-1"), A.prices("claude-somebody-9"), "an unknown model at the dearest"
  end

  # ------------------------------------------------------------ failures

  def test_failures_are_one_line_and_nothing_said
    fake = A::Fake.new(fail_every: 1)
    b = budget
    ai, out = ai_with(fake, b: b)
    ai.observe("h/t", view, [line("riichi", 2)])
    assert_empty out
    assert_equal 1, b.day["commentary"]["failed"]
    assert_equal ["AI: riichi: dropped (fake: failing on purpose (1))"], @logs
    # An answer that is not a line.
    fake = A::Fake.new(text: ->(*) { "🔥🔥" })
    ai, out = ai_with(fake)
    @logs.clear
    ai.observe("h/t", view, [line("riichi", 2)])
    assert_empty out
    assert_match(/not a line, dropped/, @logs.last)
  end

  def test_a_cut_answer_is_logged_with_its_stop_reason
    fake = A::Fake.new(stop: "max_tokens")
    b = budget
    ai, out = ai_with(fake, b: b)
    ai.observe("h/t", view, [line("riichi", 2)])
    assert_empty out
    assert_equal ["AI: riichi: dropped (fake: cut (stop_reason max_tokens, out 200))"], @logs
    assert_equal 200, b.day["commentary"]["out"]
    # A line said: its stop reason in the log's line.
    @logs.clear
    ai, = ai_with(A::Fake.new)
    ai.observe("h/t", view, [line("riichi", 2)])
    assert_match(/\AAI: riichi: 0\.0 s, stop end_turn, tokens in 300 /, @logs.first)
  end

  # ------------------------------------------------------------ the quiet minute's topic

  def topic_view
    v = view
    v["seats"][0]["score"] = 33_000
    v["seats"][2]["score"] = 27_000
    v["seats"][1]["riichi"] = true
    v["seats"][3]["river"] = %w[4p 4p 1z]
    v["last_discard"] = { "seat" => 3, "tile" => "1z" }
    v
  end

  def test_the_topics_of_a_quiet_minute
    all = A::Topics.candidates(topic_view, hands: true)
    assert_equal "トップはCPU1 (33000点)、2位のCPU3との差は6000点。", all["lead"]
    assert_equal "CPU1はリーチをかけずにテンパイしている (待ち 4索・7索)。", all["dama"], "riichi seats are left out"
    assert_equal "ドラは4筒。河と鳴きに見えているのは2枚。", all["dora"]
    assert_equal "山の残りは40枚。", all["wall"]
    assert_equal "直前にCPU4が東を切った。", all["last_discard"]
    refute A::Topics.candidates(topic_view, hands: false).key?("dama"), "no hand when the hands are hidden"
    assert_equal({}, A::Topics.candidates(nil))
    # In turn, never the last one twice.
    keys = 6.times.map { |n| A::Topics.pick(topic_view, hands: true, n: n)["key"] }
    assert_equal %w[lead dama dora wall last_discard lead], keys
    refute_equal "lead", A::Topics.pick(topic_view, hands: true, last: "lead", n: 0)["key"]
    hidden = 5.times.map { |n| A::Topics.pick(topic_view, hands: false, n: n)["key"] }
    refute_includes hidden, "dama"
  end

  def test_a_quiet_minute_asks_about_one_topic
    fake = A::Fake.new
    ai, out = ai_with(fake)
    ai.observe("h/t", topic_view, [line("call", 1)])
    topics = []
    4.times do
      @now += 61
      ai.tick
      topics << out.last[2]["topic"]
    end
    assert_equal 4, fake.count
    assert_equal 4, topics.uniq.size, "a different topic each time: #{topics}"
    fake.requests.each_with_index do |r, i|
      t = A::Topics.candidates(topic_view, hands: true)[topics[i]]
      assert_includes r["user"], "- しばらく動きがない (61 秒)。\n話題: #{t}"
    end
    assert_includes fake.requests[0]["system"], "「話題」の 1 つだけについて言ってください"
    assert_match(/\(lead\)/, @logs.find { |m| m.include?("quiet") })
    # The hands hidden: the dama topic never comes.
    fake = A::Fake.new
    ai, out = ai_with(fake, hands: false)
    ai.observe("h/t", topic_view, [line("call", 1)])
    6.times do
      @now += 61
      ai.tick
    end
    refute fake.requests.any? { |r| r["user"].include?("テンパイ") }
    refute out.any? { |o| o[2]["topic"] == "dama" }
  end

  def test_async_calls_do_not_hold_the_hub
    fake = A::Fake.new(delay_ms: 300)
    out = Queue.new
    ai = A.new(fake, budget: budget, log: ->(m) { @logs << m })
    ai.attach(deliver: ->(id, text, _job) { out << [id, text] })
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ai.observe("h/t", view, [line("riichi", 2)])
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 0.1, "observe returns at once"
    id, text = out.pop(timeout: 3)
    assert_equal "h/t", id
    assert_match(/偽のひとこと1/, text)
  ensure
    ai&.stop
  end

  # ------------------------------------------------------------ the recorded game

  # A recorded tonpuu (4 rounds and the end), a view every 1.5 s: a few
  # calls a round, never two within 20 s.
  def test_a_recorded_game_asks_a_few_times_a_round
    fake = A::Fake.new
    ai, = ai_with(fake)
    times = []
    fake.define_singleton_method(:say) do |**kw|
      times << kw
      super(**kw)
    end
    asked = []
    ai.attach(deliver: ->(_id, _text, job) { asked << [job["asked_at"], job["kind"]] })
    hub = C::MahjongHub.new(json: StringIO.new, ai: ai, rng: Random.new(1), clock: -> { Time.at(@now) })
    rounds = 0
    prev = nil
    recorded.each do |v|
      # The recording has one view per change; the host keeps a round's
      # result on the table for result_seconds (8 by default).
      if prev && prev["status"] == "result"
        4.times do
          @now += 2
          hub.tick
        end
      else
        @now += 1.5
      end
      rounds += 1 if hub.update("games", "mahjong1", v).any? { |l| l["type"] == "round_start" }
      hub.tick
      prev = v
    end
    rounds += 1 # the first round started before the first view
    calls = fake.count
    assert_operator calls, :>=, rounds, "at least one a round"
    assert_operator calls, :<=, rounds * 3, "a few a round, not more"
    gaps = asked.map(&:first).each_cons(2).map { |a, b| b - a }
    assert gaps.all? { |g| g >= A::OUTRANK_INTERVAL_S }, gaps.inspect
    # A gap under 20 s only for a scene bigger than the one before.
    asked.each_cons(2) do |(t1, k1), (t2, k2)|
      next if t2 - t1 >= A::MIN_INTERVAL_S
      assert_operator rank_of(k2), :>, rank_of(k1), "#{k1} then #{k2} after #{t2 - t1} s"
    end
    # The wins are said: every win of the game (4) gets its line, here the
    # riichi before most of them notwithstanding.
    lines = hub.tables["games/mahjong1"]["lines"]
    wins = lines.each_index.select { |i| lines[i]["type"] == "win" }
    voiced = wins.count do |i|
      lines[(i + 1)..].take_while { |l| l["ai"] || !%w[round_start game_over].include?(l["type"]) }.any? { |l| l["ai"] }
    end
    assert_equal 4, wins.size
    assert_operator voiced, :>=, 3, "most wins get an AI line (#{voiced} of #{wins.size})"
  end

  def rank_of(kind)
    { "game_over" => 5, "win_strong" => 4, "lead_change" => 4, "win" => 3, "oorasu" => 3, "draw" => 2, "abort" => 2,
      "riichi" => 1, "quiet" => 0 }.fetch(kind)
  end

  # ------------------------------------------------------------ options and setup

  def test_options
    o = C.parse([], env: {})
    assert o[:ai]
    assert_equal "claude-haiku-5-5", o[:ai_model]
    assert_equal 3.0, o[:ai_daily_usd]
    o = C.parse(%w[--ai off --ai-model claude-sonnet-5-5 --ai-daily-usd 0.5], env: {})
    refute o[:ai]
    assert_equal "claude-sonnet-5-5", o[:ai_model]
    assert_equal 0.5, o[:ai_daily_usd]
    assert_raises(ArgumentError) { C.parse(%w[--ai maybe], env: {}) }
    assert_raises(ArgumentError) { C.parse(%w[--ai-daily-usd -1], env: {}) }
    assert_raises(ArgumentError) { C.parse(%w[--ai-daily-usd lots], env: {}) }
    assert_match(/--ai on\|off/, C.usage)
    assert_match(/--ai-daily-usd USD/, C.usage)
  end

  def test_from_options
    env = { "XDG_STATE_HOME" => @dir }
    ai, st = A.from_options({ ai: false }, env: env)
    assert_nil ai
    assert_equal({ "state" => "off", "note" => "off" }, st)
    ai, st = A.from_options({ ai: true }, env: env, log: ->(m) { @logs << m })
    assert_nil ai
    assert_equal "no_key", st["note"]
    assert_match(/no ANTHROPIC_API_KEY/, @logs.last)
    ai, st = A.from_options({ ai: true, ai_daily_usd: 1.5 }, env: env.merge("ASTERISM_GAMES_AI_FAKE" => "1"))
    assert_nil st
    assert_equal "fake", ai.status["state"]
    assert_equal 1.5, ai.status["limit_usd"]
    assert_equal File.join(@dir, "asterism-games", "commentary_ai_usage.fake.json"), ai.budget.path,
                 "the fakes' money apart from the real one"
    assert_equal File.join(@dir, "asterism-games"), A.state_dir(env)
    assert_equal File.join(Dir.home, ".local", "state", "asterism-games"), A.state_dir({ "XDG_STATE_HOME" => "rel" })
    # With a key, the real client (no call is made by building it).
    if gem_there?
      ai, st = A.from_options({ ai: true }, env: env.merge("ANTHROPIC_API_KEY" => "sk-ant-test"), log: ->(m) { @logs << m })
      assert_nil st
      assert_equal "on", ai.status["state"]
      assert_equal File.join(@dir, "asterism-games", "commentary_ai_usage.json"), ai.budget.path
      refute @logs.any? { |m| m.include?("sk-ant-test") }, "the key is never logged"
    end
  end

  def test_the_status_on_the_page
    hub = C::MahjongHub.new(ai_status: { "state" => "off", "note" => "no_key" })
    assert_equal({ "state" => "off", "note" => "no_key" }, hub.status["ai"])
    ai, = ai_with
    hub = C::MahjongHub.new(ai: ai)
    assert_equal "on", hub.status["ai"]["state"]
    js = File.read(File.join(__dir__, "../lib/asterism_games/commentate/assets/commentate.js"))
    assert_includes js, "キーなし"
    assert_includes js, "AI_STALE_MS"
    assert_includes File.read(File.join(__dir__, "../lib/asterism_games/commentate/assets/index.html")), 'id="ai"'
  end

  def test_a_page_with_h_tells_the_server
    hub = C::MahjongHub.new
    s = C::Server.new(hub, port: 0).start
    sock = TCPSocket.new("127.0.0.1", s.port)
    sock.write("GET /events?hide=1 HTTP/1.1\r\nHost: 127.0.0.1:#{s.port}\r\n\r\n")
    sock.wait_readable(3)
    sock.readpartial(4096)
    refute hub.hands_for_ai?
    sock.close
    page = C::Server::Client.new(nil)
    hub2 = C::MahjongHub.new
    hub2.subscribe(page)
    assert hub2.hands_for_ai?, "a page without H"
    page.hide = true
    refute hub2.hands_for_ai?
    assert_equal false, C::MahjongHub.new(public: true).hands_for_ai?
  ensure
    s&.stop
  end

  # ------------------------------------------------------------ the request Claude gets

  def gem_there?
    return false if GEM_ONLY # the gem's own tests load nothing of anthropic
    require "anthropic"
    true
  rescue LoadError
    false
  end

  # A Messages API of this test (never Anthropic's): it records the
  # request and answers with status and body.
  def fake_api(status, body, delay: 0)
    server = TCPServer.new("127.0.0.1", 0)
    got = {}
    th = Thread.new do
      s = server.accept
      head = +""
      head << s.readpartial(65_536) until head.include?("\r\n\r\n")
      h, b = head.split("\r\n\r\n", 2)
      len = h[/content-length: (\d+)/i, 1].to_i
      b << s.readpartial(65_536) while b.bytesize < len
      got[:head] = h
      got[:body] = JSON.parse(b)
      sleep delay
      s.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
              "Connection: close\r\n\r\n#{body}")
      s.close
    rescue IOError, SystemCallError
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}", got
  ensure
    th&.join(5)
    server&.close
  end

  def test_the_claude_request
    skip "the anthropic gem is not loaded here" unless gem_there?
    answer = { "id" => "msg_test", "type" => "message", "role" => "assistant", "model" => "claude-haiku-5-5",
               "content" => [{ "type" => "text", "text" => "見逃せないのだ！" }], "stop_reason" => "end_turn",
               "stop_sequence" => nil,
               "usage" => { "input_tokens" => 310, "output_tokens" => 21, "cache_creation_input_tokens" => 0,
                            "cache_read_input_tokens" => 1180 } }
    sys = A::Prompt.system(tone: "zundamon", hands: true)
    fake_api(200, JSON.generate(answer)) do |base, got|
      c = AI::Commentator.new("sk-ant-test", model: "claude-haiku-5-5", base_url: base)
      said = c.say(system: sys, user: "卓の様子", timeout: 5)
      assert_equal "見逃せないのだ！", said.text
      assert_equal({ "in" => 310, "out" => 21, "cache_write" => 0, "cache_read" => 1180 }, said.tokens)
      b = got[:body]
      assert_equal "claude-haiku-5-5", b["model"]
      assert_equal AI::Commentator::MAX_TOKENS, b["max_tokens"]
      assert_equal [{ "type" => "text", "text" => sys, "cache_control" => { "type" => "ephemeral" } }], b["system"]
      assert_equal({ "effort" => "low" }, b["output_config"])
      assert_equal [{ "role" => "user", "content" => "卓の様子" }], b["messages"]
      assert_equal({ "type" => "disabled" }, b["thinking"], "no thinking for a line of 40 characters")
      assert_equal 200, b["max_tokens"], "two short sentences, with room"
      refute b.key?("temperature")
      assert_equal "end_turn", said.stop
      assert_match(%r{^POST /v1/messages }, got[:head])
      assert_match(/^x-api-key: sk-ant-test\r?$/i, got[:head])
    end
    # Refused, an error status, too slow: an error (no retry), the key never in it.
    fake_api(200, JSON.generate(answer.merge("stop_reason" => "refusal"))) do |base, _|
      e = assert_raises(AI::TokenError) { AI::Commentator.new("sk-ant-test", model: "m", base_url: base).say(system: "s", user: "u") }
      assert_equal 310, e.tokens["in"]
    end
    # Cut at max_tokens: dropped, the stop reason in the message (the log's line).
    fake_api(200, JSON.generate(answer.merge("stop_reason" => "max_tokens", "usage" => answer["usage"].merge("output_tokens" => 200)))) do |base, _|
      e = assert_raises(AI::TokenError) { AI::Commentator.new("sk-ant-test", model: "m", base_url: base).say(system: "s", user: "u") }
      assert_equal "claude: cut (stop_reason max_tokens, out 200)", e.message
      assert_equal 200, e.tokens["out"], "what was spent is counted"
    end
    fake_api(429, JSON.generate({ "type" => "error", "error" => { "type" => "rate_limit_error", "message" => "x" } })) do |base, _|
      e = assert_raises(AI::Error) { AI::Commentator.new("sk-ant-test", model: "m", base_url: base).say(system: "s", user: "u") }
      assert_equal "claude: HTTP 429 RateLimitError", e.message
    end
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fake_api(200, JSON.generate(answer), delay: 3) do |base, _|
      e = assert_raises(AI::Error) do
        AI::Commentator.new("sk-ant-test", model: "m", base_url: base).say(system: "s", user: "u", timeout: 0.5)
      end
      assert_equal "claude: APITimeoutError", e.message
      refute_includes e.message, "sk-ant-test"
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 4.5
  end
end
