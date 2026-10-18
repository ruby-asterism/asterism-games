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

  # One call turns a seat round the lobby's cycle (empty, CPU, Claude, Jev,
  # empty: the table apps' seat button); a refused AI leaves the seat as
  # it was, and seat -1 changes only empty seats.
  def test_one_call_changes_a_cpu_or_ai_seat_into_another_kind
    t = human_table
    t.ai_kinds = %w[claude jev]
    tok = t.join("wasm-aaaaa0", "P0", 0)["token"]
    t.sit(tok, 0, 0)
    assert_equal "ok", t.cpu(tok, 1, true)
    assert_equal "no change", t.cpu(tok, 1, true)
    assert_equal "ok", t.cpu(tok, 1, "claude"), "a CPU into Claude"
    assert_equal ["", "claude", "", ""], t.public_view(0)["ai"]
    assert_equal "no change", t.cpu(tok, 1, "claude")
    assert_equal "ok", t.cpu(tok, 1, "jev"), "Claude into Jev"
    assert_equal ["P0", "Jev"], t.public_view(0)["nm"][0, 2]
    assert_equal "ok", t.cpu(tok, 1, false), "Jev out"
    assert_equal [1, 0, 0, 0], t.public_view(0)["sk"]
    assert_equal "ok", t.cpu(tok, 1, "jev")
    assert_equal "ok", t.cpu(tok, 1, true), "an AI player back into a CPU"
    assert_equal ["P0", "CPU1"], t.public_view(0)["nm"][0, 2]
    assert_equal "ok", t.cpu(tok, 2, "claude")
    assert_equal "ok", t.cpu(tok, -1, true), "seat -1 fills the empty seat only"
    assert_equal ["", "", "claude", ""], t.public_view(0)["ai"]
    t.ai_kinds = %w[jev]
    assert_equal "no ai", t.cpu(tok, 1, "claude"), "the day's limit or no key"
    assert_equal ["P0", "CPU1", "Claude", "CPU2"], t.public_view(0)["nm"], "the CPU stays"
    assert_equal "no change", t.cpu(tok, 0, "jev"), "a human seat stays"
    assert_equal 1, t.public_view(0)["sk"][0]
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

  # A table with one human, a claude and a jev player and a CPU, started.
  def two_kinds_table(**opts)
    t = human_table(**opts)
    t.ai_kinds = %w[claude jev]
    tok = t.join("wasm-aaaaa0", "P0", 0)["token"]
    assert_equal "ok", t.sit(tok, 0, 0)
    assert_equal "ok", t.cpu(tok, 1, "claude")
    assert_equal "ok", t.cpu(tok, 2, "jev")
    assert_equal "ok", t.cpu(tok, -1, true)
    assert_equal "ok", t.start(tok, 0)
    t
  end

  def ai_kinds_seated(t) = (0..3).select { |i| t.ai_seat?(i) }.map { |i| t.instance_variable_get(:@seats)[i]["ai"] }.sort

  def test_a_kinds_own_limit_stops_that_kind_only
    Dir.mktmpdir do |dir|
      day = Time.utc(2026, 10, 17, 12)
      t = two_kinds_table
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 100.0, kind_usd: { "claude" => 0.001 },
                                                        prices: ->(_) { { "in" => 2.0, "out" => 10.0 } }, clock: -> { day })
      logs = []
      hub = AI::Hub.new({ "claude" => AI::Fake.new, "jev" => AI::Fake.new }, budget, threads: 1, log: ->(m) { logs << m })
      games = { "t" => t }
      hub.step(games, 0)
      assert_equal %w[claude jev], t.ai_kinds
      budget.record("claude", { "in" => 1000, "out" => 10 }) # $0.0021
      assert budget.over?("claude")
      refute budget.over?("jev")
      refute budget.over?, "the total is far from 100"
      hub.step(games, 10)
      hub.step(games, 20)
      assert_equal %w[jev], ai_kinds_seated(t), "the claude seat is a CPU, the jev seat stays"
      assert_equal %w[jev], t.ai_kinds, "jev is still offered"
      assert_equal %w[claude], hub.over
      said = logs.grep(/today's limit/)
      assert_equal 1, said.size, "once"
      assert_match(/today's limit for claude \(\$0\.001\) is reached/, said[0])
      # jev goes on asking: drive the table with the hub until a jev request goes out.
      asked = hub.stats["asked"]
      200.times do |i|
        break if hub.stats["asked"] > asked
        hub.step(games, 30 + i * 1000)
        t.tick(30 + i * 1000)
      end
      assert_operator hub.stats["asked"], :>, asked, "jev is asked after claude stopped"
      # A new day: claude is offered again.
      day = Time.utc(2026, 10, 18, 12)
      sleep 1.1 # the budget reads its file again after a second
      hub.step(games, 300_000)
      assert_equal %w[claude jev], t.ai_kinds
      assert_equal [], hub.over
      hub.stop
    end
  end

  def test_a_kind_without_its_own_limit_follows_the_total
    Dir.mktmpdir do |dir|
      t = two_kinds_table
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 0.01, kind_usd: { "jev" => 5.0 },
                                                        prices: ->(_) { { "in" => 2.0, "out" => 10.0 } })
      hub = AI::Hub.new({ "claude" => AI::Fake.new, "jev" => AI::Fake.new }, budget, threads: 1)
      games = { "t" => t }
      budget.record("jev", { "in" => 4000 }) # $0.008: jev's own limit is far, the total is not reached
      hub.step(games, 0)
      assert_equal %w[claude jev], ai_kinds_seated(t)
      budget.record("jev", { "in" => 1000 }) # $0.010 in all: the total reaches 0.01
      refute budget.over?("jev"), "jev has its own limit"
      assert budget.over?("claude"), "claude follows the total of every kind"
      assert_equal 0.01, budget.limit_usd("claude")
      assert_equal 5.0, budget.limit_usd("jev")
      hub.step(games, 10)
      assert_equal %w[jev], ai_kinds_seated(t)
      assert_equal %w[jev], t.ai_kinds
      s = budget.summary
      assert_equal 0.01, s["limit_usd"]
      assert_equal({ "jev" => 5.0 }, s["kind_limit_usd"])
      hub.stop
    end
  end

  def test_without_kinds_limits_all_stop_together_as_before
    Dir.mktmpdir do |dir|
      t = two_kinds_table
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 0.001, prices: ->(_) { { "in" => 2.0, "out" => 10.0 } })
      logs = []
      hub = AI::Hub.new({ "claude" => AI::Fake.new, "jev" => AI::Fake.new }, budget, threads: 1, log: ->(m) { logs << m })
      games = { "t" => t }
      hub.step(games, 0)
      budget.record("jev", { "in" => 1000 }) # $0.002 by jev alone stops both
      assert budget.over?("claude")
      assert budget.over?("jev")
      hub.step(games, 10)
      hub.step(games, 20)
      assert_equal [], ai_kinds_seated(t)
      assert_equal [], t.ai_kinds
      assert_equal 1, t.stats["ai_off"], "one ai_off! for all the seats, as in 0.14.0"
      assert_equal ["games: AI players: today's limit of $0.001 is reached; no more AI players today, " \
                    "those seated are played by the CPU"], logs.grep(/today's limit/)
      refute budget.summary.key?("kind_limit_usd")
      assert_equal "at most $0.001 a day", AI::Hub.limits_text(%w[claude jev], budget)
      hub.stop
    end
  end

  def test_the_kinds_limits_from_the_environment
    logs = []
    s = AI::Settings.new({ "ASTERISM_GAMES_AI_DAILY_USD_CLAUDE" => "10", "ASTERISM_GAMES_AI_DAILY_USD_JEV" => "2.5" })
    assert_equal({ "claude" => 10.0, "jev" => 2.5 }, s.kind_daily_usd(log: ->(m) { logs << m }))
    assert_empty logs
    assert_equal({}, AI::Settings.new({}).kind_daily_usd)
    assert_equal({ "jev" => 0.0 }, AI::Settings.new({ "ASTERISM_GAMES_AI_DAILY_USD_JEV" => "0" }).kind_daily_usd)
    bad = AI::Settings.new({ "ASTERISM_GAMES_AI_DAILY_USD_CLAUDE" => "ten", "ASTERISM_GAMES_AI_DAILY_USD_JEV" => "-1" })
    assert_equal({}, bad.kind_daily_usd(log: ->(m) { logs << m }))
    assert_equal 2, logs.size
    assert_match(/ASTERISM_GAMES_AI_DAILY_USD_CLAUDE is not a number.*ignored, claude follows ASTERISM_GAMES_AI_DAILY_USD/, logs[0])
    assert_match(/ASTERISM_GAMES_AI_DAILY_USD_JEV/, logs[1])
    b = AI::Budget.new("/nonexistent/u.json", daily_usd: 3.0, kind_usd: { "claude" => 10.0, "jev" => 2.0 }, prices: ->(_) { {} })
    assert_equal "at most $10.0 a day for claude, $2.0 for jev", AI::Hub.limits_text(%w[claude jev], b)
    b = AI::Budget.new("/nonexistent/u.json", daily_usd: 3.0, kind_usd: { "claude" => 10.0 }, prices: ->(_) { {} })
    assert_equal "at most $10.0 a day for claude, $3.0 for jev with every kind's together",
                 AI::Hub.limits_text(%w[claude jev], b)
  end

  def test_the_kinds_on_the_hosts_status
    Dir.mktmpdir do |dir|
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 3.0, kind_usd: { "claude" => 0.001 },
                                                        prices: ->(_) { { "in" => 2.0, "out" => 10.0 } })
      hub = AI::Hub.new({ "claude" => AI::Fake.new, "jev" => AI::Fake.new }, budget, threads: 1)
      cfg = AsterismGames::Config.new({ "state_dir" => dir, "node" => "games-host", "app" => "games", "ai_hub" => hub,
                                        "tables" => [{ "name" => "mahjong1", "game" => "mahjong" }] }, {})
      host = AsterismGames::Host.new(cfg, log: ->(_m) {})
      budget.record("claude", { "in" => 1000 })
      st = host.tables_status["ai_today"]
      assert_equal 1, st["calls"]
      assert_equal 3.0, st["limit_usd"]
      assert_equal({ "usd" => 0.002, "limit_usd" => 0.001, "own" => true, "over" => true }, st["kinds"]["claude"])
      assert_equal({ "usd" => 0.0, "limit_usd" => 3.0, "own" => false, "over" => false }, st["kinds"]["jev"])
      hub.stop
    end
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
      e = nil
      seen = fake_typesafe(401, '{"error":"invalid key"}') do |base|
        jev = AI::Jev.new(tok, base: base)
        e = assert_raises(AI::Error) { jev.decide({ "game" => "mahjong", "seat" => 0, "view" => { "moves" => [] } }) }
      end
      assert_equal "jev: HTTP 401", e.message
      assert_includes seen[0][:head], "Bearer #{tok}"
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
      assert_equal %w[jev], AI::Settings.new({ "TYPESAFE_API_KEY" => "b" }).deciders.keys
      assert_equal({}, AI::Settings.new({ "CLOUDFLARE_ACCOUNT_ID" => "a", "CLOUDFLARE_API_TOKEN" => "b" }).deciders)
      assert_equal %w[claude jev], AI::Settings.new({ "ASTERISM_GAMES_AI_FAKE" => "1" }).deciders.keys
    end
  end

  # A fake TypeSafe API on 127.0.0.1: answers every POST with status and
  # body (after delay seconds); yields its base URL; returns what it got
  # ([{head:, body:}]).
  def fake_typesafe(status, body, delay: 0)
    require "socket"
    server = TCPServer.new("127.0.0.1", 0)
    seen = []
    th = Thread.new do
      loop do
        c = server.accept
        head = +""
        while (line = c.gets) && line != "\r\n"
          head << line
        end
        len = head[/^content-length:\s*(\d+)/i, 1].to_i
        got = c.read(len)
        seen << { head: head, body: got }
        sleep delay if delay.positive?
        reason = status == 200 ? "OK" : "Error"
        c.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\n" \
                "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        c.close
      rescue IOError, SystemCallError
        c&.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
    seen
  ensure
    th&.kill
    server&.close
  end

  JEV_VIEW = { "status" => "playing", "hand" => %w[1m 2m 3m],
               "moves" => [{ "n" => 0, "type" => "discard", "tile" => "1m", "text" => "discard 1m" },
                           { "n" => 1, "type" => "discard", "tile" => "3m", "text" => "discard 3m" }] }.freeze
  JEV_REQUEST = { "game" => "mahjong", "table" => "mahjong1", "seat" => 2, "instructions" => "how to play",
                  "view" => JEV_VIEW }.freeze

  # Jev through TypeSafe's API (POST /v1/systemone): the request's shape,
  # the answer read back, the tokens counted, a failure, a timeout.
  def test_the_jev_request
    key = "ts-key-test-abcdef0123456789"
    answer = { "model" => "jev-1.13.0",
               "answers" => { "move" => { "type" => "choice", "choice" => "1", "confidence" => 0.9,
                                          "probabilities" => { "0" => 0.05, "1" => 0.95 } } },
               "usage" => { "input_tokens" => 812, "output_tokens" => 21 } }
    d = nil
    seen = fake_typesafe(200, JSON.generate(answer)) do |base|
      d = AI::Jev.new(key, base: base).decide(JEV_REQUEST, timeout: 5)
    end
    assert_equal 1, d.n
    assert_equal({ "in" => 812, "out" => 21 }, d.tokens)
    assert_kind_of Integer, d.ms
    head = seen[0][:head]
    assert_match %r{\APOST /v1/systemone HTTP/1\.1\r\n}, head
    assert_includes head, "Authorization: Bearer #{key}"
    assert_match(%r{^Content-Type: application/json}i, head)
    sent = JSON.parse(seen[0][:body])
    assert_equal %w[model questions state], sent.keys.sort
    assert_equal "jev-latest", sent["model"]
    refute sent["state"].key?("moves")
    assert_equal %w[1m 2m 3m], sent["state"]["hand"]
    q = sent["questions"]["move"]
    assert_equal "choice", q["type"]
    assert_equal({ "0" => "discard 1m", "1" => "discard 3m" }, q["criteria"])
    assert_includes q["instructions"], "how to play"
    refute_includes seen[0][:body], key
    # The model is a setting.
    s = AI::Settings.new({ "TYPESAFE_API_KEY" => key, "ASTERISM_GAMES_JEV_MODEL" => "jev-1.14.0" })
    assert_equal "jev-1.14.0", s.jev_model
    assert_equal "jev-latest", AI::Settings.new({}).jev_model
    # What a decision costs: input tokens only.
    Dir.mktmpdir do |dir|
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 3.0, prices: ->(k) { AI::Settings.new({}).prices(k) })
      usd = budget.record("jev", d.tokens)
      assert_in_delta 812 * 0.042 / 1_000_000.0, usd, 1e-12
      e = budget.day["jev"]
      assert_equal [1, 812, 21], [e["calls"], e["in"], e["out"]]
    end
    # A choice that is not a move: a failure that still cost its tokens.
    bad = answer.merge("answers" => { "move" => { "type" => "choice", "choice" => "7" } })
    e = nil
    fake_typesafe(200, JSON.generate(bad)) do |base|
      e = assert_raises(AI::TokenError) { AI::Jev.new(key, base: base).decide(JEV_REQUEST, timeout: 5) }
    end
    assert_equal "jev: move 7 is not offered", e.message
    assert_equal({ "in" => 812, "out" => 21 }, e.tokens)
    # An error status, an answer that is not JSON, no answer in time.
    [[429, "{}", "jev: HTTP 429"], [529, "{}", "jev: HTTP 529"], [422, '{"detail":"x"}', "jev: HTTP 422"],
     [200, "<html>", "jev: not JSON"]].each do |status, body, msg|
      fake_typesafe(status, body) do |base|
        e = assert_raises(AI::Error) { AI::Jev.new(key, base: base).decide(JEV_REQUEST, timeout: 5) }
      end
      assert_equal msg, e.message
      refute_includes e.message, key
    end
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fake_typesafe(200, JSON.generate(answer), delay: 3) do |base|
      e = assert_raises(AI::Error) { AI::Jev.new(key, base: base).decide(JEV_REQUEST, timeout: 0.5) }
    end
    assert_equal "jev: Net::ReadTimeout", e.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 3
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
