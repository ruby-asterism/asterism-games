# frozen_string_literal: true

require_relative "test_helper"

# Who is there (README "Who is there"): a member whose node leaves the
# network is away at once and back at once when it comes back (the host's
# on_leave / on_join); without those, a member is away after away_ms
# without a call, as before.
class TestPresence < Minitest::Test
  include MahjongTestHelper
  O = AsterismGames::Othello

  def othello(**opts)
    O::Table.new("othello1", { "cpu_ms" => 0 }.merge(opts.transform_keys(&:to_s)))
  end

  # A at seat 0, B at seat 1, C watching.
  def seated_othello(now = 0, **opts)
    t = othello(**opts)
    a = t.join("node-a", "A", now)["token"]
    b = t.join("node-b", "B", now)["token"]
    t.join("node-c", "C", now)
    t.sit(a, 0, now)
    t.sit(b, 1, now)
    t.tick(now)
    t.save(now)
    t
  end

  def flags(t, now, name)
    t.public_view(now)["mb"].find { |m| m[0] == name }[2]
  end

  def test_a_node_that_leaves_is_away_at_once_and_back_at_once
    t = seated_othello
    refute t.dirty?
    assert t.node_left("node-a", 1000)
    t.tick(1000)
    assert t.dirty?, "put at once"
    assert_equal 1, t.public_view(1000)["aw"], "seat 0 away 1 s after its last call (away_ms is 10 s)"
    assert_equal 1, flags(t, 1000, "A") & 1
    refute t.node_left("node-a", 1500), "already away"
    t.save(1500)
    assert t.node_joined("node-a", 2000)
    t.tick(2000)
    assert t.dirty?
    assert_equal 0, t.public_view(2000)["aw"], "back"
    refute t.node_joined("node-a", 2500), "nothing changed"
    refute t.node_left("node-x", 3000), "not a member"
    refute t.node_joined("node-x", 3000)
  end

  def test_without_the_network_s_word_a_member_is_away_after_away_ms
    t = seated_othello
    r = O::Remote.new(t, -> { @now })
    t.tick(9_000)
    assert_equal 0, t.public_view(9_000)["aw"]
    t.tick(10_001)
    assert_equal 3, t.public_view(10_001)["aw"], "no call for away_ms: away (the fallback)"
    @now = 10_500
    r.view(t.seats[0]["token"], from: "node-a")
    assert_equal 2, t.public_view(10_500)["aw"], "a call brings it back"
  end

  def test_a_node_seen_on_the_network_is_there_without_calling
    t = seated_othello
    t.node_joined("node-a", 0)
    t.tick(60_000)
    assert_equal 2, t.public_view(60_000)["aw"], "A's node is on the network: there, however long it does not call; B (never seen) is away"
    t.node_left("node-a", 60_000)
    assert_equal 3, t.public_view(60_000)["aw"]
    t.node_joined("node-a", 61_000)
    t.tick(200_000)
    assert_equal 2, t.public_view(200_000)["aw"], "back, and there again without a call"
  end

  def test_a_call_from_a_node_that_left_brings_it_back
    t = seated_othello
    r = O::Remote.new(t, -> { @now })
    t.node_left("node-b", 100)
    assert_equal 2, t.public_view(100)["aw"]
    @now = 200
    r.view(t.seats[1]["token"], from: "node-b")
    assert_equal 0, t.public_view(200)["aw"]
  end

  def test_rejoining_clears_the_away_mark
    t = seated_othello
    t.node_left("node-a", 100)
    assert_equal t.seats[0]["token"], t.join("node-a", "A", 200)["token"]
    assert_equal 0, t.public_view(200)["aw"]
  end

  def test_the_time_to_forget_counts_from_when_the_node_left
    t = seated_othello
    # C (watching) called last at 0 and its node left at 50 s: it is
    # forgotten six times away_ms (60 s) after it left, not after its call.
    t.node_left("node-c", 50_000)
    t.tick(70_000)
    assert t.public_view(70_000)["mb"].any? { |m| m[0] == "C" }, "60 s after its last call: still a member"
    t.tick(110_001)
    refute t.public_view(110_001)["mb"].any? { |m| m[0] == "C" }, "60 s after it left: forgotten"
    # A seated member stays however long it is away.
    t.node_left("node-a", 110_001)
    t.tick(1_000_000)
    assert_equal "A", t.public_view(1_000_000)["nm"][0]
    assert_equal 1, t.public_view(1_000_000)["aw"] & 1
  end

  def test_the_saved_form_has_no_presence
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t = O::Table.new("othello1", { "cpu_ms" => 0 }, store: store)
      a = t.join("node-a", "A", 0)["token"]
      t.sit(a, 0, 0)
      t.node_left("node-a", 100)
      t.save(100)
      saved = store.read("othello1")
      refute saved["members"]["node-a"].key?("left")
      refute saved["members"]["node-a"].key?("seen")
      t2 = O::Table.new("othello1", { "cpu_ms" => 0 }, store: store)
      t2.resume_clock(5_000)
      t2.tick(5_000)
      assert_equal 0, t2.public_view(5_000)["aw"], "read back: as just seen"
    end
  end

  def test_a_seat_gone_for_seat_reuse_ms_is_a_new_page_when_its_node_comes_back
    t = othello(room_id: "room-a", trusted_nodes: %w[wasm-0101 wasm-0102], seat_reuse_ms: 60_000)
    a = t.join("wasm-0101", "A", 0)["token"]
    assert_equal "ok", t.sit(a, 0, 0)
    t.node_left("wasm-0101", 1_000)
    assert t.node_joined("wasm-0101", 30_000)
    assert_equal a, t.mine("wasm-0101", 30_000)["token"], "back within seat_reuse_ms: the same member"
    t.node_left("wasm-0101", 40_000)
    assert t.node_joined("wasm-0101", 40_000 + 60_001)
    assert_nil t.mine("wasm-0101", 40_000 + 60_002), "gone for longer: another page, the old member left"
    assert_nil t.node_of(a)
  end

  def test_an_away_mahjong_seat_is_played_for_sooner
    t, tok = seated_table(1)
    seat = tok.keys.first
    t.node_left("wasm-aaaaa0", 10)
    t.tick(10)
    assert_equal 1 << seat, t.public_view(10)["aw"]
    assert_equal 1, t.summary(10)["away"]
    t.node_joined("wasm-aaaaa0", 20)
    t.tick(20)
    assert_equal 0, t.public_view(20)["aw"]
  end

  def test_the_host_tells_every_table
    Dir.mktmpdir do |dir|
      cfg = AsterismGames::Config.new({ "state_dir" => dir, "tables" => [{ "name" => "othello1", "game" => "othello" },
                                                                          { "name" => "othello2", "game" => "othello" }] }, {}).data
      host = AsterismGames::Host.new(cfg, log: ->(_) {})
      t1 = host.games["othello1"]
      t2 = host.games["othello2"]
      t1.join("node-a", "A", 0)
      t2.join("node-a", "A", 0)
      t2.join("node-b", "B", 0)
      host.node_left("node-a", 100)
      assert t1.member_away?("node-a")
      assert t2.member_away?("node-a")
      refute t2.member_away?("node-b")
      host.node_left("node-z", 100)
      assert_equal 1, host.stats["left"], "a node with no member changes nothing"
      host.node_joined("node-a", 200)
      refute t1.member_away?("node-a")
      refute t2.member_away?("node-a")
      assert_equal 1, host.stats["back"]
    end
  end
end
