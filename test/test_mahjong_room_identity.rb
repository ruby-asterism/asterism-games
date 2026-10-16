# frozen_string_literal: true

require_relative "test_helper"

# Who joins a table in a room (README "Who joins"): the seats' node IDs and
# the host's own names, which the router binds to their callers; nobody
# else. Outside a room nothing is checked.
class TestMahjongRoomIdentity < Minitest::Test
  include MahjongTestHelper

  ROOM = "0123456789abcdef"

  def room_table(**opts)
    M::Table.new("t", { "room_id" => ROOM, "cpu_ms" => 0 }.merge(opts.transform_keys(&:to_s)))
  end

  def test_outside_a_room_nothing_is_checked
    t = human_table
    assert t.join("wasm-aaaaaa", "A", 0)["token"]
    assert t.join("fmruby-aaaaaa", "B", 0)["token"]
    assert t.mine("wasm-aaaaaa")
  end

  def test_join_and_mine_take_no_secret
    assert_equal 1, M::Remote::METHODS[:join]
    assert_equal 0, M::Remote::METHODS[:mine]
    r = M::Remote.new(room_table(trusted_nodes: %w[wasm-0101]), -> { 0 })
    assert_equal({ "error" => "identity" }, r.join("A", from: "wasm-abcdef"), "a caller that is not a seat")
    assert_equal({ "error" => "identity" }, r.mine(from: "wasm-abcdef"))
    tok = r.join("A", from: "wasm-0101")["token"]
    assert tok
    assert_equal tok, r.mine(from: "wasm-0101")["token"]
  end

  def test_a_hosts_tables_get_the_room_id
    Dir.mktmpdir do |dir|
      cfg = AsterismGames::Config.new({ "state_dir" => dir, "tables" => [{ "name" => "mahjong1", "game" => "mahjong" }] }, {}).data
      host = AsterismGames::Host.new(cfg.merge("room_id" => ROOM), log: ->(_) {})
      assert_equal ROOM, host.games["mahjong1"].opts["room_id"]
      host2 = AsterismGames::Host.new(cfg, log: ->(_) {})
      assert_nil host2.games["mahjong1"].opts["room_id"]
    end
  end

  # ------------------------------------------- seats (console 0.3.0)

  def seat_table(**opts)
    room_table(trusted_nodes: %w[wasm-0101 wasm-0102], trusted_prefix: "games", seat_reuse_ms: 60_000, **opts)
  end

  def test_a_seat_and_the_hosts_names_join
    t = seat_table
    a = t.join("wasm-0101", "A", 0)
    assert a["token"], "the router binds the seat's name"
    assert_equal a["token"], t.mine("wasm-0101", 10)["token"]
    assert_equal a["token"], t.join("wasm-0101", "A", 10)["token"], "the same member again"
    assert t.join("games-bot-0", "Bot", 0)["token"], "the host's bots"
    assert_equal({ "error" => "identity" }, t.join("wasm-0103", "X", 0), "not a seat of this room")
    assert_equal({ "error" => "identity" }, t.join("wasm-abcdef", "X", 0), "a page without a seat")
    assert_equal({ "error" => "identity" }, t.mine("wasm-abcdef", 0))
  end

  def test_a_seat_silent_for_long_is_a_new_page_and_does_not_get_the_old_hand
    t = seat_table(cpu_ms: 0)
    a = t.join("wasm-0101", "A", 0)
    assert_equal "ok", t.sit(a["token"], 0, 0)
    assert_equal a["token"], t.mine("wasm-0101", 50_000)["token"], "silent less than seat_reuse_ms"
    # The member called at 50 s; the door gave the seat away after an hour.
    assert_nil t.mine("wasm-0101", 50_000 + 60_001), "the old membership is gone"
    b = t.join("wasm-0101", "B", 50_000 + 60_002)
    refute_equal a["token"], b["token"]
    assert_equal(-1, b["seat"], "not seated in A's seat")
    assert_nil t.node_of(a["token"]), "A's token works no more"
    assert_nil t.seat_of(a["token"])
  end
end
