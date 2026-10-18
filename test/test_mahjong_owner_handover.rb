# frozen_string_literal: true

require_relative "test_helper"

# Players that drop out (README): an owner away for owner_handover_ms
# hands the role to a member who is there, and a game whose humans are all
# away for abandon_ms (or have left) is abandoned without a record.
class TestMahjongOwnerHandover < Minitest::Test
  include MahjongTestHelper

  # Members joined (and seen on the network) in order; the first sits
  # (the owner), the others as seated says.
  def lobby(names, seated: [], **opts)
    lines = []
    t = human_table(**opts)
    t.instance_variable_set(:@log, ->(m) { lines << m })
    toks = names.to_h { |n| [n, t.join(n, n.upcase, 0)["token"]] }
    names.each { |n| t.node_joined(n, 0) }
    ([names.first] + seated).uniq.each { |n| assert_equal "ok", t.sit(toks[n], -1, 0) }
    [t, toks, lines]
  end

  def owner(t) = t.instance_variable_get(:@owner)

  def seats(t) = t.instance_variable_get(:@seats)

  def test_the_owner_away_for_a_minute_hands_the_role_to_a_seated_member
    t, toks, lines = lobby(%w[a b c], seated: %w[c])
    t.node_left("a", 1000)
    t.tick(60_999)
    assert_equal "a", owner(t), "away for less than a minute: still the owner"
    t.tick(61_000)
    assert_equal "c", owner(t), "the seated member before the one who joined earlier"
    assert t.member_reply("c")["owner"]
    assert(lines.any? { |l| l.include?("the owner a was away for 60 s: c is the owner now") })
    t.node_joined("a", 70_000)
    t.tick(70_000)
    assert_equal "c", owner(t), "back, the old owner does not take it back"
    assert_equal "ok", t.cpu(toks["c"], -1, true), "the new owner fills the seats"
    assert_equal "not owner", t.start(toks["a"], 70_000)
    assert_equal "ok", t.start(toks["c"], 70_000), "and starts"
  end

  def test_with_nobody_seated_the_role_goes_by_join_order
    t, = lobby(%w[a b c])
    t.node_left("a", 0)
    t.node_left("b", 0)
    t.tick(60_000)
    assert_equal "c", owner(t), "b is away too: c, the first who joined and is there"
  end

  def test_with_nobody_there_the_role_stays
    t, = lobby(%w[a b], seated: %w[b])
    t.node_left("a", 0)
    t.node_left("b", 0)
    t.tick(120_000)
    assert_equal "a", owner(t)
    t.node_joined("b", 130_000)
    t.tick(130_000)
    assert_equal "b", owner(t), "once someone is there again"
  end

  def test_during_a_game_too
    t, toks, = lobby(%w[a b], seated: %w[b])
    t.cpu(toks["a"], -1, true)
    assert_equal "ok", t.start(toks["a"], 0)
    t.node_left("a", 1000)
    t.tick(61_000)
    assert_equal "b", owner(t)
    assert_equal "play", t.status
  end

  def test_zero_turns_it_off
    t, = lobby(%w[a b], seated: %w[b], owner_handover_ms: 0)
    t.node_left("a", 0)
    t.tick(600_000)
    assert_equal "a", owner(t)
  end

  def test_the_settings_file_and_the_environment_name_it_in_seconds
    file = M::Table.settings[:file]
    env = M::Table.settings[:env]
    assert_equal ["owner_handover_ms", 1000], file["owner_handover_seconds"]
    assert_equal ["owner_handover_ms", 1000], env["MAHJONG_OWNER_HANDOVER_SECONDS"]
    assert_equal ["abandon_ms", 1000], file["abandon_seconds"]
    assert_equal ["abandon_ms", 1000], env["MAHJONG_ABANDON_SECONDS"]
    assert_equal 60_000, M::Table::DEFAULTS["owner_handover_ms"]
    assert_equal 180_000, M::Table::DEFAULTS["abandon_ms"]
  end

  # ------------------------------------------------------------ a table left alone

  # A game of a and b (seated) and two CPUs, started at 0.
  def game(**opts)
    t, toks, lines = lobby(%w[a b], seated: %w[b], **opts)
    t.cpu(toks["a"], -1, true)
    assert_equal "ok", t.start(toks["a"], 0)
    [t, toks, lines]
  end

  def test_a_game_whose_humans_are_all_away_for_three_minutes_ends
    t, toks, lines = game
    t.node_left("a", 1000)
    t.node_left("b", 1000)
    t.tick(180_999)
    refute_equal "wait", t.status, "away for less than three minutes"
    t.tick(181_000)
    assert_equal "wait", t.status, "back in the lobby"
    assert_equal 2, seats(t).count { |s| s && s["kind"] == "cpu" }, "the CPUs stay"
    assert_equal 0, seats(t).count { |s| s && s["kind"] == "human" }, "the away humans are off their seats"
    assert_equal 2, seats(t).count(&:nil?)
    assert t.member_reply("a")["token"], "still members (spectators)"
    assert_equal(-1, t.member_reply("a")["seat"])
    assert(lines.any? { |l| l.include?("game abandoned: no human there for 180 s") && l.include?("not recorded") })
    assert_equal 0, t.book.size, "nothing recorded"
    assert_equal 0, t.stats["games"]
    # Back, they sit again and play another game.
    t.node_joined("a", 190_000)
    t.tick(190_000)
    assert_equal "ok", t.sit(toks["a"], -1, 190_000)
  end

  def test_a_member_who_left_stops_counting_at_once
    t, toks, = game
    t.node_left("b", 1000)
    t.tick(2000)
    refute_equal "wait", t.status, "b is away (counts for three minutes)"
    assert t.leave(toks["a"]), "a leaves the table: its seat goes to a CPU"
    t.tick(3000)
    refute_equal "wait", t.status, "b still counts"
    t.tick(181_000)
    assert_equal "wait", t.status
  end

  def test_everyone_leaving_ends_it_at_once
    t, toks, = game
    t.leave(toks["a"])
    t.leave(toks["b"])
    t.tick(1000)
    assert_equal "wait", t.status
    assert_equal 0, t.book.size
  end

  def test_one_human_back_in_time_keeps_the_game
    t, = game
    t.node_left("a", 1000)
    t.node_left("b", 1000)
    t.tick(100_000)
    t.node_joined("b", 150_000)
    t.tick(150_000)
    t.tick(400_000)
    refute_equal "wait", t.status, "b is back: a stays seated, away, played for"
    assert_equal 2, seats(t).count { |s| s && s["kind"] == "human" }
  end

  def test_a_result_is_abandoned_too
    t, = game
    t.instance_variable_set(:@status, "result")
    t.instance_variable_set(:@next_at, 10**9)
    t.instance_variable_set(:@ok_humans, true)
    t.instance_variable_set(:@oks, [0] * 4)
    t.node_left("a", 0)
    t.node_left("b", 0)
    t.tick(180_000)
    assert_equal "wait", t.status
  end

  def test_a_table_of_cpus_plays_on
    t = cpu_table
    t.tick(1000)
    assert_equal "play", t.status
    t.tick(400_000)
    refute_equal "wait", t.status, "humans 0: nothing to abandon"
  end

  def test_zero_turns_abandoning_off
    t, = game(abandon_ms: 0)
    t.node_left("a", 0)
    t.node_left("b", 0)
    t.tick(600_000)
    refute_equal "wait", t.status
  end
end
