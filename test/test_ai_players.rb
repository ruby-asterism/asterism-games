# frozen_string_literal: true

require_relative "test_helper"

# AI players (README "AI players") with fake deciders: a seat for one,
# the decisions asked and answered, the CPU when an answer is late or
# fails, the day's limit and the game's, what an AI sees, and the keys
# kept out of logs. Also look / choose / points (README "Playing from a
# program").
class TestAIPlayers < Minitest::Test
  include MahjongTestHelper
  AI = AsterismGames::AI

  # A table with one human (seat by the draw), one AI player of kind and
  # two CPUs, started.
  def ai_table(kind = "claude", **opts)
    t = human_table(**opts)
    t.ai_kinds = %w[claude jev]
    tok = t.join("wasm-aaaaa0", "P0", 0)["token"]
    assert_equal "ok", t.sit(tok, 0, 0)
    assert_equal "ok", t.cpu(tok, 1, kind)
    assert_equal "ok", t.cpu(tok, -1, true)
    assert_equal "ok", t.start(tok, 0)
    [t, tok]
  end

  def ai_seat(t) = (0..3).find { |i| t.ai_seat?(i) }

  def test_the_owner_seats_an_ai_player_the_host_offers
    t = human_table
    tok = t.join("wasm-aaaaa0", "P0", 0)["token"]
    t.sit(tok, 0, 0)
    assert_equal "no ai", t.cpu(tok, 1, "claude"), "not offered without a key"
    assert_nil t.public_view(0)["ak"]
    t.ai_kinds = %w[claude jev]
    assert_equal %w[claude jev], t.public_view(0)["ak"]
    assert_equal "ok", t.cpu(tok, 1, "claude")
    assert_equal "ok", t.cpu(tok, 2, "jev")
    assert_equal "ok", t.cpu(tok, 3, true)
    v = t.public_view(0)
    assert_equal ["P0", "Claude", "Jev", "CPU1"], v["nm"]
    assert_equal [1, 2, 2, 2], v["sk"], "an AI seat is a CPU seat to the old screens"
    assert_equal ["", "claude", "jev", ""], v["ai"]
    assert_equal 2, t.summary(0)["ais"]
    assert_equal "ok", t.cpu(tok, 2, false), "an AI player goes out as a CPU does"
    assert_equal "ok", t.cpu(tok, 2, "claude")
    assert_equal ["P0", "Claude1", "Claude2", "CPU1"], t.public_view(0)["nm"]
    other = t.join("wasm-aaaaa1", "P1", 0)["token"]
    assert_equal "not owner", t.cpu(other, 3, "claude")
  end

  # Drives a table, answering each AI decision with answer.call(request)
  # => [n or nil, ms later] (nil n: a failure).
  def drive(t, now, until_status: "over", answer:)
    pending = []
    200_000.times do
      return now if t.status == until_status
      now += 10
      t.tick(now)
      t.ai_requests(now).each do |r|
        n, later = answer.call(r)
        pending << [now + later, r, n]
      end
      due, pending = pending.partition { |at, _, _| at <= now }
      due.each { |_, r, n| t.ai_answer(r[:seat], r[:key], n, now) }
    end
    flunk "the game did not reach #{until_status}"
  end

  def test_a_game_with_an_ai_player_and_the_cpu_when_it_is_late_or_fails
    t, = ai_table(rule: { "game_type" => "tonpuu" }, ai_turn_ms: 3000, ai_call_ms: 2000)
    seat = ai_seat(t)
    fake = AI::Fake.new
    count = 0
    seen = []
    answer = lambda do |r|
      count += 1
      v = r[:request]["view"]
      seen << v
      # Every 7th decision too late, every 11th a failure.
      if (count % 7).zero? then [0, 5000]
      elsif (count % 11).zero? then [nil, 50]
      else [fake.decide(r[:request]).n, 200]
      end
    end
    drive(t, 0, answer: answer)
    s = t.stats
    assert_operator s["ai_asked"], :>, 20
    assert_operator s["ai_moves"], :>, 10
    assert_operator s["ai_timeouts"], :>=, 1, "a late answer: the CPU played"
    assert_operator s["ai_failed"], :>=, 1, "a failure: the CPU played"
    assert_equal s["ai_asked"], s["ai_moves"] + s["ai_timeouts"] + s["ai_failed"]
    puts "\n  tonpuu with an AI player: #{s['ai_asked']} decisions asked, #{s['ai_moves']} played, " \
         "#{s['ai_timeouts']} late and #{s['ai_failed']} failed (the CPU played those)"
    # What it saw: its own hand only, the same as its screen.
    seen.each do |v|
      assert_equal seat, v["you"]
      v["seats"].each { |x| refute x.key?("hand"), "another seat's hand" }
      refute v.to_s.include?("ura"), "no ura dora"
      v["moves"].each { |m| refute m.key?("act") }
    end
  end

  def test_the_ai_deadline_is_its_own_and_one_move_is_not_asked
    t, = ai_table(ai_turn_ms: 30_000, turn_ms: 1000)
    seat = ai_seat(t)
    now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat && !t.ai_requests(0).empty? || (t.status != "play") }
    skip "the round ended before the AI's turn" unless t.status == "play"
    v = t.public_view(now)
    assert_equal 1 << seat, v["dl"][0]
    assert_operator v["dl"][1], :>, 20_000, "the AI seat waits ai_turn_ms (30 s), not turn_ms"
  end

  def test_the_days_limit_and_the_games_limit
    Dir.mktmpdir do |dir|
      t, tok = ai_table
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 0.001, prices: ->(_) { { "in" => 2.0, "out" => 10.0 } })
      hub = AI::Hub.new({ "claude" => AI::Fake.new }, budget, calls_per_game: 400, threads: 1)
      games = { "t" => t }
      hub.step(games, 0)
      assert_equal %w[claude], t.ai_kinds
      budget.record("claude", { "in" => 1000, "out" => 10 }) # $0.0021
      assert budget.over?
      hub.step(games, 10)
      assert_nil ai_seat(t), "the AI seat is a CPU now"
      assert_equal [], t.ai_kinds, "and no new one is offered"
      assert_equal 1, t.stats["ai_off"]
      hub.stop
    end
    t, = ai_table
    t.ai_calls_per_game = 2
    asked = 0
    drive(t, 0, until_status: "over", answer: lambda do |r|
      asked += 1
      [AI::Fake.new.decide(r[:request]).n, 10]
    end)
    assert_equal 2, asked, "no more than the game's decisions"
    assert_equal 1, t.stats["ai_off"]
  end

  def test_the_budget_counts_per_day_in_a_file
    Dir.mktmpdir do |dir|
      day = Time.utc(2026, 10, 17, 12)
      b = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 1.0,
                                                   prices: ->(k) { k == "claude" ? { "in" => 2.0, "out" => 10.0, "cache_read" => 0.1 } : { "in" => 0.042 } },
                                                   clock: -> { day })
      assert_in_delta 0.002 + 0.001 + 0.0001, b.record("claude", { "in" => 1000, "out" => 100, "cache_read" => 1000 })
      b.record("jev", { "in" => 1_000_000, "out" => 5 })
      b.record_failure("jev")
      s = b.summary(kinds: true)
      assert_equal "2026-10-17", s["date"]
      assert_equal 2, s["calls"]
      assert_in_delta 0.0031 + 0.042, s["usd"]
      assert_equal 1, s["kinds"]["jev"]["failed"]
      refute b.over?
      data = JSON.parse(File.read(File.join(dir, "u.json")))
      assert_equal ["2026-10-17"], data["days"].keys
      assert_equal "600", format("%o", File.stat(File.join(dir, "u.json")).mode & 0o777)
      day = Time.utc(2026, 10, 18, 12)
      b2 = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 1.0, prices: ->(_) { {} }, clock: -> { day })
      assert_equal 0, b2.summary["calls"], "a new day starts at 0"
    end
  end

  def test_the_hub_asks_on_threads_and_hands_the_answers_back
    Dir.mktmpdir do |dir|
      t, = ai_table
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 5.0, prices: ->(_) { { "in" => 2.0, "out" => 10.0 } })
      hub = AI::Hub.new({ "claude" => AI::Fake.new(delay_ms: 20) }, budget, threads: 2)
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) }
      games = { "t" => t }
      t0 = clock.call
      # The table on the host's clock (its deadlines are in that clock's ms).
      until t.stats["ai_moves"] >= 3 || clock.call - t0 > 20_000
        now = clock.call
        hub.step(games, now)
        t.tick(now)
        sleep 0.002
      end
      assert_operator t.stats["ai_moves"], :>=, 3
      assert_operator budget.summary["calls"], :>=, 3
      n, avg, = hub.times
      assert_operator n, :>=, 3
      assert_operator avg, :>=, 15
      hub.stop
    end
  end

  # The keys never reach a log, the usage file or an error's text.
  def test_the_keys_stay_out_of_the_logs
    key = "sk-ant-test-0123456789abcdef"
    tok = "cf-token-0123456789abcdef"
    Dir.mktmpdir do |dir|
      logs = []
      jev = AI::Jev.new("acct123", tok)
      stub = Object.new
      def stub.code = "401"
      def stub.body = "{}"
      orig = Net::HTTP.method(:start)
      Net::HTTP.define_singleton_method(:start) { |*_a, **_k, &_b| stub }
      begin
        e = assert_raises(AI::Error) { jev.decide({ "game" => "mahjong", "seat" => 0, "view" => { "moves" => [] } }) }
      ensure
        Net::HTTP.define_singleton_method(:start, orig)
      end
      assert_equal "jev: HTTP 401", e.message
      leaky = Object.new
      leaky.define_singleton_method(:decide) { |*_a, **_k| raise "Bearer #{tok} x-api-key #{key}" }
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 5.0, prices: ->(_) { {} })
      hub = AI::Hub.new({ "claude" => leaky }, budget, threads: 1, log: ->(m) { logs << m })
      t, = ai_table
      games = { "t" => t }
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) }
      t0 = clock.call
      until t.stats["ai_failed"] >= 1 || clock.call - t0 > 20_000
        hub.step(games, clock.call)
        t.tick(clock.call)
        sleep 0.002
      end
      hub.stop
      assert_operator t.stats["ai_failed"], :>=, 1
      text = logs.join("\n") + File.read(File.join(dir, "u.json")) + JSON.generate(t.summary(0))
      refute_includes text, key
      refute_includes text, tok
      assert(logs.any? { _1.include?("RuntimeError") }, logs.inspect)
      # Settings: no key, no offer.
      assert_equal({}, AI::Settings.new({}).deciders)
      assert_equal %w[jev], AI::Settings.new({ "CLOUDFLARE_ACCOUNT_ID" => "a", "CLOUDFLARE_API_TOKEN" => "b" }).deciders.keys
      assert_equal %w[claude jev], AI::Settings.new({ "ASTERISM_GAMES_AI_FAKE" => "1" }).deciders.keys
    end
  end

  # The request Claude gets: the model, the cached instructions, the
  # structured answer; and its answer read back.
  def test_the_claude_request
    skip "the anthropic gem is not installed" unless begin
      require "anthropic"
      true
    rescue LoadError
      false
    end
    c = AI::Claude.new("sk-ant-test", model: "claude-sonnet-5-5")
    got = nil
    usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)
    block = Struct.new(:type, :text)
    msg = Struct.new(:usage, :content, :stop_reason)
    messages = Object.new
    messages.define_singleton_method(:create) do |**params|
      got = params
      msg.new(usage.new(500, 9, 1200, 0), [block.new(:text, '{"n": 1}')], :end_turn)
    end
    client = Object.new
    client.define_singleton_method(:messages) { messages }
    c.instance_variable_set(:@client, client)
    view = { "moves" => [{ "n" => 0, "type" => "discard" }, { "n" => 1, "type" => "discard" }] }
    d = c.decide({ "game" => "mahjong", "seat" => 2, "instructions" => "RULES", "view" => view }, timeout: 12)
    assert_equal 1, d.n
    assert_equal({ "in" => 500, "out" => 9, "cache_write" => 1200, "cache_read" => 0 }, d.tokens)
    assert_equal :"claude-sonnet-5-5", got[:model]
    assert_equal({ type: "ephemeral" }, got[:system_][0][:cache_control])
    assert_includes got[:system_][0][:text], "RULES"
    assert_equal :json_schema, got[:output_config][:format_][:type]
    assert_equal :low, got[:output_config][:effort]
    assert_equal 12, got[:request_options][:timeout]
    assert_equal view, JSON.parse(got[:messages][0][:content])
    # A move it was not offered is an error (the CPU plays).
    messages.define_singleton_method(:create) { |**_| msg.new(usage.new(1, 1, 0, 0), [block.new(:text, '{"n": 7}')], :end_turn) }
    e = assert_raises(AI::TokenError) { c.decide({ "view" => view }) }
    assert_equal 1, e.tokens["in"]
  end

  def test_look_choose_and_points
    t, tokens = seated_table(1, turn_ms: 60_000)
    seat, tok = tokens.first
    now = run_until(t, 0) { t.status == "play" && t.state.phase == :dahai && t.state.current_seat == seat }
    v = t.look_public(seat, now)
    assert_equal seat, v["you"]
    assert_equal t.state.hands[seat].count, v["hand"].size + (v["drawn"] ? 1 : 0)
    refute_empty v["moves"]
    assert(v["moves"].all? { |m| m["n"].is_a?(Integer) && m["text"].is_a?(String) })
    assert_equal 4, v["seats"].size
    assert v["round"]["wind"]
    assert_equal "stale", t.choose(tok, v["sv"] - 1, 0, now)
    assert_equal "no such move", t.choose(tok, v["sv"], 99, now)
    d = v["moves"].find { |m| m["type"] == "discard" }
    assert_equal "ok", t.choose(tok, v["sv"], d["n"], now)
    assert_equal d["tile"], t.state.kawas[seat].tiles.last.tile.to_s
    p = t.points_of(seat)
    assert p.key?("waits")
    assert_equal({ "error" => "not playing" }, t.points_of(nil))
    # The remote: describe is a text, look by token.
    r = M::Remote.new(t, -> { now })
    assert_match(/choose\(token, sv, n\)/, r.describe)
    assert_equal seat, r.look(tok, from: "wasm-aaaaa0")["you"]
    assert_equal({ "error" => "token" }, r.look("nope", from: "x"))
  end

  # points on a tenpai hand: the waits scored by ron and tsumo.
  def test_points_of_a_tenpai_hand
    t, tokens = seated_table(1, turn_ms: 60_000)
    seat, = tokens.first
    run_until(t, 0) { t.status == "play" && t.state.phase == :dahai && t.state.current_seat == seat }
    st = t.state
    tiles = %w[1m 2m 3m 4p 5p 6p 7s 8s 9s 2z 2z 5m 6m].map { ::Mahjong::Tiles::Tile.new(_1) }
    st.hands[seat] = ::Mahjong::State::Hand.new(tiles + [::Mahjong::Tiles::Tile.new("1z")])
    st.last_tsumo = ::Mahjong::Tiles::Tile.new("1z")
    p = t.points_of(seat)
    after = p["waits"].select { |w| w["discard"] == "1z" }
    assert_equal %w[4m 7m], after.map { _1["wait"] }.sort
    w = after.first
    assert w["tsumo"]["han"].to_i >= 1, w.inspect # menzen tsumo at least
    assert w["ron"]["no_yaku"] || w["ron"]["han"], w.inspect
  end
end
