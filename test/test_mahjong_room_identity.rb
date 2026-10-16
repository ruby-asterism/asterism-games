# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

# Who joins a table in a room (README "Who joins"): a browser's node ID
# comes from a secret of its own for the room, and join and mine refuse an
# ID that does not come from the secret sent with them.
class TestMahjongRoomIdentity < Minitest::Test
  include MahjongTestHelper

  ROOM = "0123456789abcdef"
  SECRET_A = "a" * 32
  SECRET_B = "b" * 32

  def room_table(**opts)
    M::Table.new("t", { "room_id" => ROOM, "cpu_ms" => 0 }.merge(opts.transform_keys(&:to_s)))
  end

  def id(secret, room = ROOM)
    M::Table.room_node_id(room, secret)
  end

  def test_the_node_id_comes_from_the_room_and_the_secret
    assert_match(/\Awasm-[0-9a-f]{6}\z/, id(SECRET_A), "the shape every browser ID has")
    assert_equal "wasm-#{Digest::SHA256.hexdigest("#{ROOM}:#{SECRET_A}")[0, 6]}", id(SECRET_A)
    refute_equal id(SECRET_A), id(SECRET_A, "fedcba9876543210"), "another room, another ID"
    refute_equal id(SECRET_A), id(SECRET_B)
  end

  def test_another_member_cannot_take_a_seat_by_its_id
    t = room_table
    a = t.join(id(SECRET_A), "A", 0, SECRET_A)
    assert a["token"]
    assert_equal "ok", t.sit(a["token"], 1, 0)
    # Somebody else calls under A's node ID: without A's secret nothing.
    [nil, "", SECRET_B, "x" * 32, SECRET_A.upcase].each do |s|
      assert_equal({ "error" => "identity" }, t.join(id(SECRET_A), "X", 0, s), "join with #{s.inspect}")
      assert_equal({ "error" => "identity" }, t.mine(id(SECRET_A), s), "mine with #{s.inspect}")
    end
    # Its own ID gets a membership of its own, not A's.
    b = t.join(id(SECRET_B), "B", 0, SECRET_B)
    refute_equal a["token"], b["token"]
    assert_equal(-1, b["seat"])
    assert_equal "A", t.public_view(0)["nm"][1]
  end

  def test_the_member_gets_its_seat_back_after_a_reload
    t = room_table
    a = t.join(id(SECRET_A), "A", 0, SECRET_A)
    t.sit(a["token"], 2, 0)
    # The page reloaded: the same secret from localStorage, the same ID.
    assert_equal a["token"], t.mine(id(SECRET_A), SECRET_A)["token"]
    r = t.join(id(SECRET_A), "A", 10, SECRET_A)
    assert_equal a["token"], r["token"]
    assert_equal 2, r["seat"]
  end

  def test_the_secret_is_kept_as_its_hash_and_saved
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t = M::Table.new("t", { "room_id" => ROOM }, store: store)
      t.join(id(SECRET_A), "A", 0, SECRET_A)
      t.save(0)
      text = File.read(Dir[File.join(dir, "*.json")].first)
      refute_includes text, SECRET_A, "the secret itself is not saved"
      u = M::Table.new("t", { "room_id" => ROOM }, store: store)
      assert u.mine(id(SECRET_A), SECRET_A)["token"]
      assert_equal({ "error" => "identity" }, u.mine(id(SECRET_A), SECRET_B))
    end
  end

  # Two secrets that give the same six digits (forced here): the second is
  # told it is taken, it does not get the first one's membership.
  def test_two_secrets_with_one_id_are_told_apart
    t = room_table
    def t.identity_error(_node, secret) = secret.is_a?(String) ? nil : "identity"
    a = t.join("wasm-abcdef", "A", 0, SECRET_A)
    assert a["token"]
    assert_equal({ "error" => "taken" }, t.join("wasm-abcdef", "B", 0, SECRET_B))
    assert_equal({ "error" => "taken" }, t.mine("wasm-abcdef", SECRET_B))
    assert_equal a["token"], t.mine("wasm-abcdef", SECRET_A)["token"]
  end

  def test_outside_a_room_nothing_is_checked
    t = human_table
    assert t.join("wasm-aaaaaa", "A", 0)["token"]
    assert t.join("fmruby-aaaaaa", "B", 0, "anything")["token"], "a secret is ignored"
    assert t.mine("wasm-aaaaaa")
  end

  def test_join_and_mine_take_the_secret_or_not
    assert_equal(-1, M::Remote::METHODS[:join])
    assert_equal(-1, M::Remote::METHODS[:mine])
    r = M::Remote.new(room_table, -> { 0 })
    call = Struct.new(:from).new(id(SECRET_A))
    Asterism.stub(:current_call, call) do
      assert_equal({ "error" => "identity" }, r.join("A"), "the old app's join in a room")
      tok = r.join("A", SECRET_A)["token"]
      assert tok
      assert_equal tok, r.mine(SECRET_A)["token"]
      assert_equal({ "error" => "identity" }, r.mine)
    end
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

  def test_a_seat_and_the_hosts_names_join_without_a_secret
    t = seat_table
    a = t.join("wasm-0101", "A", 0)
    assert a["token"], "the router binds the seat's name"
    assert_equal a["token"], t.mine("wasm-0101", nil, 10)["token"]
    assert_equal a["token"], t.join("wasm-0101", "A", 10, "ff" * 16)["token"], "a secret changes nothing for a seat"
    assert t.join("games-bot-0", "Bot", 0)["token"], "the host's bots"
    assert_equal({ "error" => "identity" }, t.join("wasm-0103", "X", 0), "not a seat of this room")
    assert_equal({ "error" => "identity" }, t.join("wasm-abcdef", "X", 0), "an old page without its secret")
  end

  def test_old_pages_with_their_secret_still_join_until_secret_ids_is_off
    t = seat_table
    assert t.join(id(SECRET_A), "A", 0, SECRET_A)["token"]
    off = seat_table(secret_ids: false)
    assert_equal({ "error" => "identity" }, off.join(id(SECRET_A), "A", 0, SECRET_A))
    assert off.join("wasm-0102", "B", 0)["token"], "the seats still join"
  end

  def test_a_seat_silent_for_long_is_a_new_page_and_does_not_get_the_old_hand
    t = seat_table(cpu_ms: 0)
    a = t.join("wasm-0101", "A", 0)
    assert_equal "ok", t.sit(a["token"], 0, 0)
    assert_equal a["token"], t.mine("wasm-0101", nil, 50_000)["token"], "silent less than seat_reuse_ms"
    # The member called at 50 s; the door gave the seat away after an hour.
    assert_nil t.mine("wasm-0101", nil, 50_000 + 60_001), "the old membership is gone"
    b = t.join("wasm-0101", "B", 50_000 + 60_002)
    refute_equal a["token"], b["token"]
    assert_equal(-1, b["seat"], "not seated in A's seat")
    assert_nil t.node_of(a["token"]), "A's token works no more"
    assert_nil t.seat_of(a["token"])
  end
end
