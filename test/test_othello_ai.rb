# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "asterism_games/play/othello"

# AI players at the othello table (README "AI players", games 0.17.0) with
# fake deciders: Jev only (Claude is refused), the seat put in and taken
# out, the lobby's "ak" and the seats' "ai", the moves asked and played,
# the CPU when an answer is out of range, late or failed, the day's limit
# and the game's, the status's "ais", and `play othello`'s A key.
class TestOthelloAI < Minitest::Test
  O = AsterismGames::Othello
  AI = AsterismGames::AI
  Tty = AsterismGames::Play::OthelloTty

  def table(**opts)
    O::Table.new("othello1", { "cpu_ms" => 0, "ai_turn_ms" => 3000 }.merge(opts.transform_keys(&:to_s)))
  end

  # A table where one human sat (the owner); the host offers kinds.
  def lobby(kinds = %w[jev], **opts)
    t = table(**opts)
    t.ai_kinds = kinds
    tok = t.join("node-a", "A", 0)["token"]
    assert_equal "ok", t.sit(tok, 0, 0)
    [t, tok]
  end

  # A started game: the human against Jev.
  def jev_game(**opts)
    t, tok = lobby(**opts)
    assert_equal "ok", t.cpu(tok, 1, "jev")
    assert_equal "ok", t.start(tok, 0)
    [t, tok, (0..1).find { |i| t.ai_seat?(i) }]
  end

  # Plays the game to its end: the human's moves by the CPU's choice, the
  # AI seat's decisions answered by answer.call(request) => [n or nil, ms
  # later]; nil answer: never answered.
  def drive(t, tok, answer:, now: 0)
    pending = []
    100_000.times do
      return now if t.status == "over"
      now += 10
      t.tick(now)
      if t.status == "play"
        human = t.seats.index { |s| s["kind"] == "human" }
        if t.game.turn - 1 == human
          sq = O::Cpu.choose(t.game.board, human + 1)
          assert_equal "ok", t.move(tok, t.game.n, O::Board.code(sq), now)
        end
      end
      t.ai_requests(now).each do |r|
        n, later = answer.call(r)
        pending << [now + later, r, n] if later
      end
      due, pending = pending.partition { |at, _, _| at <= now }
      due.each { |_, r, n| t.ai_answer(r[:seat], r[:key], n, now) }
    end
    flunk "the game did not end"
  end

  def test_the_owner_seats_jev_and_takes_it_out
    t, tok = lobby
    assert_equal %w[jev], t.public_view(0)["ak"]
    assert_nil t.public_view(0)["ai"]
    assert_equal "ok", t.cpu(tok, 1, "jev")
    v = t.public_view(0)
    assert_equal %w[A Jev], v["nm"]
    assert_equal [1, 2], v["sk"], "an AI seat is a CPU seat to the old screens"
    assert_equal ["", "jev"], v["ai"]
    assert_equal 1, t.summary(0)["ais"]
    assert_equal 1, t.summary(0)["cpus"]
    assert_equal "no change", t.cpu(tok, 1, "jev")
    assert_equal "ok", t.cpu(tok, 1, true), "Jev back into a CPU"
    assert_equal %w[A CPU], t.public_view(0)["nm"]
    assert_nil t.public_view(0)["ai"]
    assert_equal 0, t.summary(0)["ais"]
    assert_equal "ok", t.cpu(tok, 1, "jev"), "a CPU into Jev"
    assert_equal "ok", t.cpu(tok, 1, false), "Jev out as a CPU goes out"
    assert_equal [1, 0], t.public_view(0)["sk"]
    assert_equal "ok", t.cpu(tok, -1, "jev"), "seat -1 fills the empty seat"
    assert_equal ["", "jev"], t.public_view(0)["ai"]
    assert_equal "no change", t.cpu(tok, 0, "jev"), "a human seat stays"
    other = t.join("node-b", "B", 0)["token"]
    assert_equal "not owner", t.cpu(other, 1, true)
    assert_equal "ok", t.start(tok, 0)
    assert_nil t.public_view(0)["ak"], "no choice during a game"
    assert_equal "not waiting", t.cpu(tok, 1, true)
  end

  def test_claude_is_refused_and_no_key_offers_nothing
    t, tok = lobby([])
    assert_nil t.public_view(0)["ak"], "no key: no ak"
    assert_equal "no ai", t.cpu(tok, 1, "jev")
    assert_nil t.public_view(0)["ai"], "the seat stays as it was"
    # Through the host's hub: Claude and Jev deciders, othello offers Jev only.
    Dir.mktmpdir do |dir|
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 5.0, prices: ->(_) { { "in" => 0.0, "out" => 0.0 } })
      hub = AI::Hub.new({ "claude" => AI::Fake.new, "jev" => AI::Fake.new }, budget, threads: 1)
      hub.step({ "t" => t }, 0)
      assert_equal %w[jev], t.ai_kinds
      assert_equal %w[jev], t.public_view(0)["ak"]
      assert_equal "no ai", t.cpu(tok, 1, "claude"), "Claude never sits at othello"
      assert_equal "ok", t.cpu(tok, 1, true)
      assert_equal "no ai", t.cpu(tok, 1, "claude")
      assert_equal %w[A CPU], t.public_view(0)["nm"], "the CPU stays"
      hub.stop
      # A host with Claude's key only: othello offers nothing.
      t2, = lobby([])
      hub2 = AI::Hub.new({ "claude" => AI::Fake.new }, budget, threads: 1)
      hub2.step({ "t" => t2 }, 0)
      assert_equal [], t2.ai_kinds
      assert_nil t2.public_view(0)["ak"]
      hub2.stop
    end
    assert_equal %w[claude jev], AI.kinds_for("mahjong", %w[claude jev]), "mahjong as before"
    assert_equal %w[jev], AI.kinds_for("othello", %w[claude jev])
    assert_equal [], AI.kinds_for("board", %w[claude jev])
  end

  def test_jev_plays_the_fake_deciders_moves
    t, tok, seat = jev_game
    fake = AI::Fake.new
    seen = []
    drive(t, tok, answer: lambda do |r|
      req = r[:request]
      seen << req
      [fake.decide(req).n, 100]
    end)
    assert_operator seen.size, :>, 5
    req = seen.first
    assert_equal "othello", req["game"]
    assert_equal seat, req["seat"]
    assert_match(/Othello/, req["instructions"])
    v = req["view"]
    assert_equal ".BW"[seat + 1], v["you"]
    assert_equal 8, v["board"].size
    assert_equal({ "n" => 0, "square" => v["moves"][0]["square"], "turns" => v["moves"][0]["turns"],
                   "text" => v["moves"][0]["text"] }, v["moves"][0])
    assert_equal (0...v["moves"].size).to_a, v["moves"].map { _1["n"] }
    assert(seen.all? { |q| q["view"]["moves"].size > 1 }, "one legal move is not asked")
    s = t.stats
    assert_equal s["ai_asked"], s["ai_moves"]
    assert_equal 0, s["ai_failed"] + s["ai_timeouts"]
    assert_equal "over", t.status
  end

  def test_the_cpu_plays_when_the_answer_is_out_of_range_late_or_failed
    t, tok, = jev_game(ai_turn_ms: 2000)
    count = 0
    drive(t, tok, answer: lambda do |r|
      count += 1
      case count % 4
      when 1 then [99, 50]              # not one of the moves
      when 2 then [0, 5000]             # too late
      when 3 then [nil, 50]             # the decider failed
      else [0, 50]
      end
    end)
    s = t.stats
    assert_operator s["ai_failed"], :>=, 2
    assert_operator s["ai_timeouts"], :>=, 1
    assert_operator s["ai_moves"], :>=, 1
    assert_equal "over", t.status, "the game goes on to its end"
  end

  def test_an_ai_turn_shows_its_time_and_the_cpu_plays_without_an_answer
    t, tok, seat = jev_game(ai_turn_ms: 2000)
    human = 1 - seat
    now = 0
    if t.game.turn - 1 == human
      sq = O::Cpu.choose(t.game.board, human + 1)
      t.move(tok, t.game.n, O::Board.code(sq), now)
    end
    assert_equal seat, t.public_view(now)["tn"]
    assert_operator t.public_view(now)["dl"], :>, 1000, "the AI seat's time shows"
    n = t.game.n
    t.tick(now + 1999)
    assert_equal n, t.game.n, "still thinking"
    t.tick(now + 2000)
    assert_operator t.game.n, :>, n, "the CPU played"
    assert_equal 1, t.stats["ai_timeouts"]
  end

  def test_the_days_limit_and_the_games_limit
    Dir.mktmpdir do |dir|
      t, = jev_game
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 0.001, prices: ->(_) { { "in" => 2.0, "out" => 10.0 } })
      hub = AI::Hub.new({ "jev" => AI::Fake.new }, budget, calls_per_game: 400, threads: 1)
      games = { "t" => t }
      hub.step(games, 0)
      budget.record("jev", { "in" => 1000, "out" => 10 })
      assert budget.over?
      hub.step(games, 10)
      assert_equal [false, false], [t.ai_seat?(0), t.ai_seat?(1)], "Jev is a CPU now"
      assert_includes t.public_view(10)["nm"], "CPU"
      assert_equal [], t.ai_kinds
      assert_equal 1, t.stats["ai_off"]
      assert_equal 0, t.summary(10)["ais"]
      hub.stop
      t.tick(20_000)
      assert_operator t.game.n, :>=, 0
    end
    t, tok, = jev_game
    t.ai_calls_per_game = 2
    asked = 0
    drive(t, tok, answer: lambda do |r|
      asked += 1
      [AI::Fake.new.decide(r[:request]).n, 10]
    end)
    assert_equal 2, asked, "no more than the game's decisions"
    assert_equal 1, t.stats["ai_off"]
    assert_equal "over", t.status
  end

  def test_the_hub_asks_jev_on_threads
    Dir.mktmpdir do |dir|
      t, tok, = jev_game(cpu_ms: 0)
      budget = AI::Budget.new(File.join(dir, "u.json"), daily_usd: 5.0, prices: ->(_) { { "in" => 0.042, "out" => 0.0 } })
      hub = AI::Hub.new({ "claude" => AI::Fake.new, "jev" => AI::Fake.new(delay_ms: 5) }, budget, threads: 2)
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) }
      games = { "t" => t }
      t0 = clock.call
      until t.status == "over" || clock.call - t0 > 20_000
        now = clock.call
        hub.step(games, now)
        t.tick(now)
        human = t.seats.index { |s| s["kind"] == "human" }
        if t.status == "play" && t.game.turn - 1 == human
          sq = O::Cpu.choose(t.game.board, human + 1)
          t.move(tok, t.game.n, O::Board.code(sq), now)
        end
        sleep 0.002
      end
      assert_equal "over", t.status
      assert_operator t.stats["ai_moves"], :>=, 3
      assert_equal t.stats["ai_moves"], budget.day["jev"]["calls"], "counted in the same budget, as jev"
      assert_nil budget.day["claude"]
      hub.stop
    end
  end

  def test_an_ai_seat_survives_a_restart
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t = O::Table.new("othello1", { "cpu_ms" => 0, "ai_turn_ms" => 3000 }, store: store)
      t.ai_kinds = %w[jev]
      tok = t.join("node-a", "A", 0)["token"]
      t.sit(tok, 0, 0)
      t.cpu(tok, 1, "jev")
      t.save(0)
      t2 = O::Table.new("othello1", { "cpu_ms" => 0 }, store: store)
      assert_equal ["", "jev"], t2.public_view(0)["ai"]
    end
  end

  # ------------------------------------------------------------ play othello

  def lobby_view(**over)
    { "st" => "wait", "me" => 0, "ow" => 0, "sk" => [1, 0], "nm" => ["A", ""], "ak" => ["jev"] }.merge(over)
  end

  def test_play_othellos_a_key
    assert_equal [:cmd, "ai jev"], Tty.key_command("a", lobby_view, nil), "Jev into the empty seat"
    assert_equal [:cmd, "ai jev"], Tty.key_command("A", lobby_view("sk" => [1, 2], "nm" => %w[A CPU]), nil),
                 "a CPU into Jev"
    v = lobby_view("sk" => [1, 2], "nm" => %w[A Jev], "ai" => ["", "jev"])
    assert_equal [:cmd, "cpu"], Tty.key_command("a", v, nil), "again: back to the CPU"
    assert_equal [:cmd, "cpu"], Tty.key_command("a", v.merge("ak" => nil), nil), "back even when no longer offered"
    assert_equal [:note, "the host offers no AI players"], Tty.key_command("a", lobby_view("ak" => nil), nil)
    assert_equal [:note, "the owner seats an AI player"], Tty.key_command("a", lobby_view("ow" => 1), nil)
    assert_equal [:note, "the other seat is a player's"], Tty.key_command("a", lobby_view("sk" => [1, 1]), nil)
    assert_equal [:cmd, "ai jev"], Tty.key_command("a", lobby_view("st" => "over"), nil), "after a game too"
    assert_equal [:none], Tty.key_command("a", lobby_view("st" => "play"), nil), "not during a game"
    assert_equal [:cmd, "cpu"], Tty.key_command("c", v, nil)
  end

  def test_play_othellos_screen_names_jev_and_its_thinking
    out = StringIO.new
    tty = Tty.allocate
    tty.instance_variable_set(:@out, out)
    tty.instance_variable_set(:@path, "h/games/othello1")
    tty.instance_variable_set(:@note, "")
    tty.instance_variable_set(:@keys, true)
    tty.instance_variable_set(:@typing, false)
    tty.instance_variable_set(:@confirm, false)
    tty.instance_variable_set(:@view, lobby_view)
    tty.draw
    assert_includes out.string, "[A] Jev"
    out.truncate(0)
    out.rewind
    tty.instance_variable_set(:@view, lobby_view("sk" => [1, 2], "nm" => %w[A Jev], "ai" => ["", "jev"]))
    tty.draw
    assert_includes out.string, "Jev (AI)"
    assert_includes out.string, "[A] back to the CPU"
    out.truncate(0)
    out.rewind
    tty.instance_variable_set(:@view, lobby_view("ak" => nil))
    tty.draw
    refute_includes out.string, "[A]", "a host without AI players: as before"
    out.truncate(0)
    out.rewind
    tty.instance_variable_set(:@view, { "st" => "play", "me" => 0, "ow" => 0, "sk" => [1, 2], "nm" => %w[A Jev],
                                        "ai" => ["", "jev"], "tn" => 1, "n" => 0, "bd" => O::Board.new.to_s,
                                        "lg" => "e3f4c5d6", "cnt" => [2, 2], "dl" => 29_500 })
    tty.draw
    assert_includes out.string, "Jev is thinking, 30 s left"
  end
end
