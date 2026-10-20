# frozen_string_literal: true

require_relative "test_helper"
require "asterism_games/play"
require "asterism_games/play/mahjong_screen"

# Watch games (README "Watch games"): the owner, who need not be seated,
# fills the four seats with CPUs and AI players and starts a game nobody
# plays; one game and the table is back in the lobby, it stops when every
# member has left, its record is marked and counts for no person.
class TestMahjongWatch < Minitest::Test
  include MahjongTestHelper
  AI = AsterismGames::AI

  def table(**opts)
    t = human_table(rule: { "game_type" => "tonpuu" }, over_ms: 1000, **opts)
    t.ai_kinds = %w[claude jev]
    t
  end

  # A member joins (and is seen on the network, so it stays there however
  # long the test's clock runs).
  def member(t, node, now = 0)
    tok = t.join(node, node.upcase, now)["token"]
    t.node_joined(node, now)
    tok
  end

  def owner(t) = t.instance_variable_get(:@owner)

  def seats(t) = t.instance_variable_get(:@seats)

  # Ticks until the status is want, answering the AI players' requests at
  # once with the fake decider.
  def run_until(t, want, now = 0, limit: 400_000)
    fake = AI::Fake.new
    limit.times do
      return now if t.status == want
      now += 10
      t.tick(now)
      t.ai_requests(now).each { |r| t.ai_answer(r[:seat], r[:key], fake.decide(r[:request]).n, now) }
    end
    flunk "the table did not reach #{want} (#{t.status})"
  end

  def test_the_first_member_of_an_empty_table_is_the_owner_without_a_seat
    t = table
    r = t.join("a", "A", 0)
    assert r["owner"], "nobody seated, nobody else: the owner"
    assert_equal(-1, r["seat"])
    b = t.join("b", "B", 0)
    refute b["owner"]
    v = t.member_view(r["token"], 0)
    assert_equal 1, v["mo"], "the owner's own view says so"
    assert_equal(-1, v["ow"], "no seated owner")
    refute t.member_view(b["token"], 0).key?("mo")
    assert_equal [["A", -1, 2], ["B", -1, 0]], v["mb"]
  end

  def test_somebody_sitting_takes_the_role_as_before
    t = table
    a = member(t, "a")
    b = member(t, "b")
    assert_equal "a", owner(t)
    assert_equal "ok", t.sit(b, -1, 0)
    assert_equal "b", owner(t), "the first seated is the owner, as before"
    assert_equal "not owner", t.cpu(a, -1, true)
    assert_equal "ok", t.sit(a, -1, 0)
    assert_equal "b", owner(t), "still the first who sat"
    assert_equal "ok", t.stand(b)
    assert_equal "a", owner(t), "the owner stands: the seated one takes over"
    assert_equal "ok", t.stand(a)
    assert_equal "a", owner(t), "nobody seated: the owner keeps the role, unseated"
    t.leave(a)
    assert_equal "b", owner(t), "and when it leaves, the one who joined first of those left"
  end

  def test_a_normal_game_is_as_before
    t = table
    a = member(t, "a")
    assert_equal "ok", t.sit(a, -1, 0)
    assert_equal "ok", t.cpu(a, -1, true)
    v = t.member_view(a, 0)
    assert_equal 0, v["wc"], "a person is seated: no watch game"
    assert_equal "human", t.start_watch(a, 0)
    assert_equal "ok", t.start(a, 0)
    refute t.watch?
    refute t.public_view(0).key?("wm")
  end

  def test_start_watch_and_its_refusals
    t = table
    a = member(t, "a")
    b = member(t, "b")
    assert_equal "token", t.start_watch("nope", 0)
    assert_equal "seats", t.start_watch(a, 0)
    assert_equal 0, t.public_view(0)["wc"]
    assert_equal "ok", t.cpu(a, 0, "claude")
    assert_equal "ok", t.cpu(a, 1, "claude")
    assert_equal "ok", t.cpu(a, 2, "jev")
    assert_equal "ok", t.cpu(a, 3, true)
    assert_equal 2, t.public_view(0)["wc"], "two Claude seats: over the limit"
    assert_equal "ai limit", t.start_watch(a, 0)
    assert_equal "ok", t.cpu(a, 1, "jev")
    assert_equal 1, t.public_view(0)["wc"]
    assert_equal "not owner", t.start_watch(b, 0)
    assert_equal "no human", t.start(a, 0), "start still wants a person"
    assert_equal "ok", t.start_watch(a, 0)
    assert t.watch?
    assert_equal "play", t.status
    assert_equal "not waiting", t.start_watch(a, 0)
    v = t.member_view(b, 0)
    assert_equal 1, v["wm"]
    assert_equal(-1, v["me"])
    assert v["sh"], "a member watching sees the four hands"
    assert_equal true, t.status_extra(0)["watch"]
    assert_equal %w[claude jev jev], seats(t).filter_map { |s| s["ai"] }.sort
  end

  def test_four_jev_seats_are_allowed
    t = table
    a = member(t, "a")
    4.times { |i| assert_equal "ok", t.cpu(a, i, "jev") }
    assert_equal 1, t.public_view(0)["wc"]
    assert_equal "ok", t.start_watch(a, 0)
  end

  def test_one_game_then_the_lobby_marked_and_not_in_a_persons_stats
    t = table(abandon_ms: 1000)
    a = member(t, "a")
    assert_equal "ok", t.cpu(a, 0, "claude")
    assert_equal "ok", t.cpu(a, -1, true)
    assert_equal "ok", t.start_watch(a, 0)
    now = run_until(t, "over")
    assert t.watch?, "away humans do not abandon a watch game (abandon_ms 1 s, nobody seated)"
    assert_equal 1, t.public_view(now)["wm"]
    now = run_until(t, "wait", now)
    refute t.watch?, "one game: back in the lobby"
    refute t.public_view(now).key?("wm")
    assert_equal 1, t.public_view(now)["wc"], "the seats stay: another watch game may start"
    assert_equal "a", owner(t)
    page = t.records_page
    assert_equal 1, page["total"]
    assert_equal true, page["records"][0]["watch"], "the list marks it"
    assert_equal true, t.record_answer(page["records"][0]["id"])["watch"]
    rows = t.stats_answer(0, "", "table")["rows"]
    assert_equal %w[claude cpu], rows.map { |r| r["kind"] }.sort, "counted per kind, no person"
    assert_equal 4, rows.sum { |r| r["games"] }
  end

  def test_a_normal_game_record_has_no_mark
    t = table
    a = member(t, "a")
    t.sit(a, -1, 0)
    t.cpu(a, -1, true)
    t.start(a, 0)
    t.instance_variable_get(:@opts)["abandon_ms"] = 0
    run_until(t, "over")
    refute t.records_page["records"][0].key?("watch")
  end

  def test_everybody_leaving_stops_it_unrecorded
    lines = []
    # CPUs that take a second a move: with none, a tonpuu can end (and be
    # recorded) within the test's few ticks of 200 steps each.
    t = table(cpu_ms: 1000)
    t.instance_variable_set(:@log, ->(m) { lines << m })
    a = member(t, "a")
    b = member(t, "b")
    t.cpu(a, -1, true)
    assert_equal "ok", t.start_watch(a, 0)
    t.tick(100)
    t.leave(a)
    t.tick(200)
    assert_equal "b", owner(t), "the owner left: b is the owner"
    assert t.watch?, "b is still watching"
    t.leave(b)
    t.tick(300)
    assert_equal "wait", t.status
    refute t.watch?
    assert_nil owner(t)
    assert_equal 0, t.records_page["total"]
    assert(lines.any? { |l| l.include?("watch game stopped: nobody at the table (not recorded)") })
  end

  def test_members_gone_for_long_are_forgotten_and_it_stops
    t = table
    a = t.join("a", "A", 0)["token"] # not seen on the network: away after away_ms
    t.cpu(a, -1, true)
    assert_equal "ok", t.start_watch(a, 0)
    t.tick(30_000)
    assert t.watch?
    t.tick(80_000)
    assert_equal "wait", t.status, "away six times away_ms: forgotten, nobody left"
  end

  def test_a_restarted_host_goes_on_with_the_watch_game
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t = table(store: store)
      a = member(t, "a")
      t.cpu(a, -1, true)
      assert_equal "ok", t.start_watch(a, 0)
      t.save(0, force: true)
      t2 = table(store: store)
      assert t2.watch?
      assert_equal "play", t2.status
    end
  end

  def test_play_keys_for_a_watch_game
    tx = AsterismGames::Play::MahjongText
    lobby = { "st" => "wait", "me" => -1, "ow" => -1, "mo" => 1, "sk" => [2, 2, 2, 2], "ai" => ["claude", "", "", ""],
              "ak" => %w[claude jev], "wc" => 1 }
    assert_equal [:cmd, "watch", []], tx.key_command("w", lobby)
    assert_equal [:cmd, "cpu", []], tx.key_command("c", lobby), "the owner without a seat fills seats"
    assert_equal [:error, tx::WATCH_AI_NOTE], tx.key_command("w", lobby.merge("wc" => 2))
    assert_equal [:error, "卓の主だけができる"], tx.key_command("w", lobby.merge("mo" => nil))
    old = lobby.reject { |k, _| k == "wc" }
    assert_equal [:error, "このゲームホストは観戦対局ができない"], tx.key_command("w", old)
    # A then a seat: CPU -> Claude -> Jev -> CPU; empty -> CPU.
    assert_equal [:ai_pick, true], tx.key_command("a", lobby)
    assert_equal [:cmd, "ai", %w[2 claude]], tx.key_command("2", lobby, ai_pick: true)
    assert_equal [:cmd, "ai", %w[1 jev]], tx.key_command("1", lobby, ai_pick: true)
    assert_equal [:cmd, "cpu", ["1"]], tx.key_command("1", lobby.merge("ai" => ["jev", "", "", ""]), ai_pick: true)
    assert_equal [:cmd, "cpu", ["3"]], tx.key_command("3", lobby.merge("sk" => [2, 2, 0, 2]), ai_pick: true)
    assert_equal [:ai_pick, false], tx.key_command("x", lobby, ai_pick: true)
    assert_equal [:error, "ゲームホストが AI を出していない"], tx.key_command("a", lobby.merge("ak" => nil))
    # The seated owner of an old host is as before.
    seated = { "st" => "wait", "me" => 0, "ow" => 0, "sk" => [1, 2, 2, 2] }
    assert_equal [:cmd, "start", []], tx.key_command(:enter, seated)
  end

  def test_play_screen_for_a_watch_game
    s = AsterismGames::Play::MahjongScreen.new(style: "mpsz", cursor: false, path: "h/games/mahjong1")
    lobby = { "st" => "wait", "t" => "mahjong1", "me" => -1, "ow" => -1, "mo" => 1, "nm" => %w[Claude CPU1 CPU2 CPU3],
              "sk" => [2, 2, 2, 2], "ai" => ["claude", "", "", ""], "ak" => %w[claude jev], "wc" => 1,
              "mb" => [["Alice", -1, 2], ["Bob", -1, 0]] }
    lines = s.lines(lobby, keys: {})
    assert_includes lines, "  観戦: Alice(卓の主) Bob"
    assert_equal "[1][2][3][4]座る [A]AI [W]観戦で始める [:]打ち込む [Q]閉じる", lines.last.sub("観戦中 (卓の主): ", "")
    assert lines.last.start_with?("観戦中 (卓の主): ")
    assert_includes s.lines(lobby.merge("wc" => 2), keys: {}), "  #{AsterismGames::Play::MahjongText::WATCH_AI_NOTE}"
    assert_match(/\AAI: \[1\]-\[4\]/, s.lines(lobby, keys: { ai_pick: true }).last)
  end

  # The game's decisions are each AI seat's own (games 0.20.0): four AI
  # seats play a tonpuu to its end with the default 400 each.
  def test_four_ai_seats_play_to_the_end_with_their_own_decisions
    t = table
    t.ai_calls_per_game = 400
    a = member(t, "a")
    assert_equal "ok", t.cpu(a, 0, "claude")
    (1..3).each { |i| assert_equal "ok", t.cpu(a, i, "jev") }
    assert_equal "ok", t.start_watch(a, 0)
    asked = Hash.new(0)
    fake = AI::Fake.new
    now = 0
    400_000.times do
      break if t.status == "over"
      now += 10
      t.tick(now)
      t.ai_requests(now).each do |r|
        asked[r[:seat]] += 1
        t.ai_answer(r[:seat], r[:key], fake.decide(r[:request]).n, now)
      end
    end
    assert_equal "over", t.status
    assert_equal 4, (0..3).count { |i| t.ai_seat?(i) }, "every AI seat is still an AI player at the end"
    assert_equal 0, t.stats["ai_off"]
    assert_equal 4, asked.size
    assert(asked.values.all? { |n| n < 400 })
    puts "\n  watch tonpuu with four AI seats: #{asked.values.sum} decisions (#{asked.sort.map { |k, n| "seat #{k}: #{n}" }.join(', ')}), none turned into a CPU"
  end

  def test_each_ai_seat_stops_at_its_own_count
    t = table
    t.ai_calls_per_game = 5
    a = member(t, "a")
    assert_equal "ok", t.cpu(a, 0, "claude")
    (1..3).each { |i| assert_equal "ok", t.cpu(a, i, "jev") }
    assert_equal "ok", t.start_watch(a, 0)
    asked = Hash.new(0)
    fake = AI::Fake.new
    now = 0
    400_000.times do
      break if t.status == "over"
      now += 10
      t.tick(now)
      t.ai_requests(now).each do |r|
        asked[r[:seat]] += 1
        t.ai_answer(r[:seat], r[:key], fake.decide(r[:request]).n, now)
      end
    end
    assert_equal "over", t.status
    assert_equal({ 0 => 5, 1 => 5, 2 => 5, 3 => 5 }, asked, "five each, not five for the table")
    assert_equal 4, t.stats["ai_off"], "one seat at a time"
  end
end
