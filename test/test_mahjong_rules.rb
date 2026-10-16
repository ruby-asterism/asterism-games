# frozen_string_literal: true

require_relative "test_helper"

# Seats, tokens, refusals, the timeout, saving, and the engine behaviour
# the host relies on (the fixes of the riichi_engine fork).
class TestMahjongRules < Minitest::Test
  include MahjongTestHelper

  def sit(t, node = "wasm-aaaaaa", now = 0)
    tok = t.join(node, "Player", now)["token"]
    t.sit(tok, -1, now)
    [t.seat_of(tok), tok]
  end

  # ------------------------------------------------------------ the lobby

  def test_join_gives_a_token_and_the_same_one_back
    t = human_table
    r = t.join("wasm-aaaaaa", "Player", 0)
    assert_equal 32, r["token"].size
    assert_equal(-1, r["seat"])
    assert_equal r, t.join("wasm-aaaaaa", "Player", 0), "the same node gets its membership back"
    assert_equal r, t.mine("wasm-aaaaaa")
    assert_nil t.mine("wasm-bbbbbb")
    assert_equal "wait", t.status
  end

  def test_owner_seats_cpus_and_start
    t = human_table
    a = t.join("wasm-aaaaaa", "A", 0)["token"]
    b = t.join("wasm-bbbbbb", "B", 0)["token"]
    assert_equal "ok", t.sit(b, 2, 0)
    assert_equal "ok", t.sit(a, 0, 0)
    assert_equal "taken", t.sit(a, 2, 0)
    assert_equal true, t.mine("wasm-bbbbbb")["owner"], "the first who sat is the owner"
    assert_equal "not owner", t.cpu(a, -1, true)
    assert_equal "seats", t.start(b, 0)
    assert_equal "ok", t.cpu(b, 1, true)
    assert_equal "not owner", t.start(a, 0)
    assert_equal "seats", t.start(b, 0)
    assert_equal "ok", t.cpu(b, -1, true)
    v = t.public_view(0)
    assert_equal [1, 2, 1, 2], v["sk"]
    assert_equal 2, v["ow"]
    assert_equal [["A", 0, 2 & 0], ["B", 2, 2]], v["mb"]
    assert_equal "ok", t.start(b, 0)
    assert_equal "play", t.status
    assert_equal "not waiting", t.sit(a, 1, 0)
    assert_equal %w[A B], t.public_view(0)["nm"].reject { |n| n.start_with?("CPU") }.sort
  end

  def test_owner_passes_on_when_the_owner_stands
    t = human_table
    a = t.join("wasm-aaaaaa", "A", 0)["token"]
    b = t.join("wasm-bbbbbb", "B", 0)["token"]
    t.sit(a, 0, 0)
    t.sit(b, 1, 0)
    assert_equal "ok", t.stand(a)
    assert_equal true, t.mine("wasm-bbbbbb")["owner"]
    assert_equal "ok", t.sit(a, 3, 0)
    assert_equal false, t.mine("wasm-aaaaaa")["owner"]
    assert_equal "ok", t.sit(b, 2, 0), "a seated member moves"
    assert_equal [0, 0, 1, 1], t.public_view(0)["sk"]
  end

  def test_a_spectator_sees_no_hand
    t, = seated_table(1)
    s = t.join("wasm-cccccc", "Watcher", 0)["token"]
    v = t.member_view(s, 0)
    assert_equal(-1, v["me"])
    assert_nil v["h"]
    assert_equal [], v["a"]
    assert_equal "not seated", t.act(s, t.sv, E::DAHAI, ["1m"], 0)
  end

  # A player's name set on its screen: a join again from the same node
  # changes it (the same token and seat), in the lobby and during a game,
  # in the names and the member list; the host's limits still apply.
  def test_a_join_again_changes_the_name
    t = M::Table.new("t", {})
    a = t.join("wasm-aaaaaa", "Old", 0)["token"]
    assert_equal "ok", t.sit(a, 2, 0)
    r = t.join("wasm-aaaaaa", "あたらしい名前", 10)
    assert_equal a, r["token"]
    assert_equal 2, r["seat"]
    assert_equal "あたらしい名前", t.public_view(10)["nm"][2]
    assert_equal ["あたらしい名前", 2, 2], t.public_view(10)["mb"][0]
    t.cpu(a, -1, true)
    assert_equal "ok", t.start(a, 10)
    seat = t.seat_of(a)
    v0 = t.public_view(10)["v"]
    t.join("wasm-aaaaaa", "Third", 20)
    assert_equal "Third", t.public_view(20)["nm"][seat], "during a game, at the seat"
    assert_operator t.public_view(20)["v"], :>, v0, "the screens ask again"
    t.join("wasm-aaaaaa", "x" * 40 + "\u0001", 30)
    assert_equal "x" * 32, t.public_view(30)["nm"][seat], "cut to 32 bytes, no control characters"
    t.join("wasm-aaaaaa", "", 40)
    assert_equal "wasm-aaaaaa", t.public_view(40)["nm"][seat], "an empty name is the node ID"
  end

  def test_members_away_and_back
    t, toks = seated_table(2, "away_ms" => 5000)
    seat = toks.keys.first
    t.touch("wasm-aaaaa0", 0)
    t.touch("wasm-aaaaa1", 0)
    t.tick(4000)
    assert_equal 0, t.public_view(4000)["aw"]
    t.touch("wasm-aaaaa1", 4000)
    t.tick(6000)
    away = t.public_view(6000)["aw"]
    assert_equal 1 << t.seat_of(toks.values.find { |x| t.node_of(x) == "wasm-aaaaa0" }), away
    t.touch("wasm-aaaaa0", 6500)
    t.tick(6500)
    assert_equal 0, t.public_view(6500)["aw"]
    assert seat
  end

  # Plan A (mj2.md 11.1): an away seat waits away_wait_ms instead of the
  # full times, and gets the full times again once it is back.
  def test_an_away_seat_discards_after_the_short_wait
    t, toks = seated_table(2, "turn_ms" => 20_000, "away_ms" => 5000, "away_wait_ms" => 2000)
    nodes = toks.transform_values { |tok| t.node_of(tok) }
    seat = toks.keys.min
    other = (toks.keys - [seat]).first
    keep = ->(now) { t.touch(nodes[other], now) }
    now = run_until(t, 0) { keep.(t.instance_variable_get(:@now)); t.state.phase == :dahai && t.state.current_seat == seat }
    t.touch(nodes[seat], now)
    keep.(now)
    v = t.public_view(now)
    assert_equal [1 << seat, 20_000], v["dl"], "present: the full time"
    kawa = t.state.kawas[seat].count
    keep.(now + 4900)
    t.tick(now + 4900)
    assert_equal kawa, t.state.kawas[seat].count, "not away yet: still waiting"
    keep.(now + 5100)
    t.tick(now + 5100)
    assert_equal kawa + 1, t.state.kawas[seat].count, "away: the short wait (2 s from the start) is over"
    assert_equal 1, t.stats["away_turns"]
    # Away from the start of its next turn: 2 s, not 20.
    now = run_until(t, now + 5100) { keep.(t.instance_variable_get(:@now)); t.status != "play" || (t.state.phase == :dahai && t.state.current_seat == seat) }
    skip "the round ended first" unless t.status == "play"
    assert_equal [1 << seat, 2000], t.public_view(now)["dl"]
    kawa = t.state.kawas[seat].count
    keep.(now + 1990)
    t.tick(now + 1990)
    assert_equal kawa, t.state.kawas[seat].count
    keep.(now + 2000)
    t.tick(now + 2000)
    assert_equal kawa + 1, t.state.kawas[seat].count
    # Back: the full time again.
    now = run_until(t, now + 2000) { keep.(t.instance_variable_get(:@now)); t.touch(nodes[seat], t.instance_variable_get(:@now)); t.status != "play" || (t.state.phase == :dahai && t.state.current_seat == seat) }
    skip "the round ended first" unless t.status == "play"
    assert_equal 0, t.public_view(now)["aw"]
    assert_equal [1 << seat, 20_000], t.public_view(now)["dl"]
  end

  def test_a_seat_that_comes_back_mid_turn_gets_its_full_time
    t, toks = seated_table(1, "turn_ms" => 20_000, "away_ms" => 5000, "away_wait_ms" => 2000)
    seat, token = toks.first
    node = t.node_of(token)
    now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat }
    t.touch(node, now)
    t.tick(now)
    assert_equal [1 << seat, 20_000], t.public_view(now)["dl"]
    kawa = t.state.kawas[seat].count
    # Back within away_ms: never away, the turn keeps its 20 s.
    t.touch(node, now + 4000)
    t.tick(now + 8000)
    assert_equal kawa, t.state.kawas[seat].count
    assert_equal 0, t.public_view(now + 8000)["aw"]
    assert_equal [1 << seat, 12_000], t.public_view(now + 8000)["dl"]
  end

  def test_an_away_seat_passes_a_call_early_and_the_others_keep_their_time
    t, toks = calls_table([1], pon: true, "away_ms" => 3000, "away_wait_ms" => 1000)
    present = t.node_of(toks[3])
    [0, 2].each { |s| t.touch(t.node_of(toks[s]), 0) }
    t.touch(present, 2900)
    t.tick(2900)
    assert_equal :naki_wait, t.state.phase
    assert_equal [0b0010, 2100], t.view(1, 2900)["dl"]
    assert_equal [0b1000, 2100], t.view(3, 2900)["dl"]
    t.touch(present, 3100)
    t.tick(3100)
    assert_equal :naki_wait, t.state.phase, "seat 3 still has its time"
    assert_equal [0b1000, 1900], t.view(3, 3100)["dl"]
    assert_equal [0b1101, 1900], t.view(1, 3100)["dl"], "seat 1 (away) has passed"
    assert_equal 1, t.stats["away_calls"]
    pon = t.view(3, 3100)["a"].find { |a, _| a == E::PON }
    assert_equal "ok", t.act(toks[3], t.sv, E::PON, M::Tiles.unpack(pon[1]), 3200)
    assert_equal 3, t.state.current_seat, "the pon stood"
  end

  # The called tile is where a table lays it sideways (fu in the views).
  def test_melds_put_the_called_tile_where_it_lies_sideways
    t, = seated_table(1)
    tl = ->(*n) { n.map { |x| Mahjong::Tiles::Tile.new(x) } }
    fu = ->(type, tiles, called, from) { Mahjong::State::Fuuro.new(type: type, tiles: tl.(*tiles), called_tile: Mahjong::Tiles::Tile.new(called), from_seat: from) }
    order = ->(f, seat) { M::Tiles.unpack(t.send(:fuuro_bytes, [f], seat).byteslice(3..)) }
    assert_equal %w[4s 3s 5s], order.(fu.(:chi, %w[3s 4s 5s], "4s", 1), 2), "from the left: first"
    assert_equal %w[7z 7z 7z], order.(fu.(:pon, %w[7z 7z 7z], "7z", 0), 2)
    assert_equal %w[5m 0m 5m], order.(fu.(:pon, %w[0m 5m 5m], "0m", 0), 2), "from across: second"
    assert_equal %w[5m 5m 0m], order.(fu.(:pon, %w[0m 5m 5m], "0m", 3), 2), "from the right: last"
    assert_equal %w[5m 5m 0m 5m], order.(fu.(:kakan, %w[0m 5m 5m 5m], "0m", 3), 2), "an added kan: last of the three"
    assert_equal %w[5m 5m 5m 0m], order.(fu.(:daiminkan, %w[0m 5m 5m 5m], "0m", 3), 2), "an open kan from the right: last"
  end

  def test_the_away_wait_is_a_setting
    c = AsterismGames::Config.new({ "tables" => [{ "name" => "a", "away_wait_seconds" => 3 }] }, {})
    assert_equal 3000, c["tables"][0]["away_wait_ms"]
    c = AsterismGames::Config.new({ "tables" => [{ "name" => "a" }] }, { "MAHJONG_AWAY_WAIT_SECONDS" => "1.5" })
    assert_equal 1500, c["tables"][0]["away_wait_ms"]
    assert_equal 2000, M::Table::DEFAULTS["away_wait_ms"]
  end

  def test_the_game_goes_back_to_the_lobby
    t, toks = seated_table(1, "over_ms" => 1000)
    seat, token = toks.first
    t.instance_variable_set(:@flow, { "end" => true })
    t.instance_variable_set(:@game, t.instance_variable_get(:@game).merge("scores" => [25_000] * 4))
    t.next_round(0)
    assert_equal "over", t.status
    assert_equal [[E::NEXT, ""]], t.view(seat, 0)["a"].map { |a, b| [a, b] }
    assert_equal "ok", t.act(token, t.sv, E::NEXT, [], 0)
    assert_equal "wait", t.status
    assert_equal 1, t.public_view(0)["sk"].count(1), "the seats stay"
    assert_equal "ok", t.start(token, 0)
    assert_equal "play", t.status
  end

  def test_two_tables_are_independent
    a, = seated_table(1)
    b = M::Table.new("u", { "cpu_ms" => 0, "result_ms" => 0 })
    assert_equal "play", a.status
    assert_equal "wait", b.status
    refute_equal a.name, b.name
  end

  def test_view_and_act_need_the_token
    t, toks = seated_table(1)
    token = toks.values.first
    r = M::Remote.new(t, -> { 0 })
    assert_equal({ "error" => "token" }, r.view("", 1))
    assert_equal({ "error" => "token" }, r.view(nil, 1))
    assert_equal({ "error" => "token" }, r.view("0" * 32, 1))
    assert_equal({ "error" => "token" }, r.view(token.upcase, 1))
    assert_equal "token", r.act("bad", t.sv, E::DAHAI, "\x00".b)
    assert_equal "token", r.act(nil, t.sv, E::DAHAI, "\x00".b)
    assert r.view(token, 1)["h"], "the right token gets the hand"
    pub = r.table
    assert_nil pub["h"]
    assert_nil pub["a"]
  end

  def test_refuses_what_is_not_offered
    t, toks = seated_table(1)
    seat, token = toks.first
    now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat }
    v = t.view(seat, now)
    hand = t.state.hands[seat].tiles.map(&:to_s)
    missing = M::Tiles::NAMES.find { |n| n != "back" && hand.none? { |h| h == n } }
    assert_equal "not offered", t.act(token, t.sv, E::DAHAI, [missing], now)
    assert_equal "not offered", t.act(token, t.sv, E::RON, [], now)
    assert_equal "not offered", t.act(token, t.sv, E::PON, [hand[0], hand[0]], now)
    assert_equal "not offered", t.act(token, t.sv, 99, [], now)
    assert_equal "stale", t.act(token, t.sv - 1, E::DAHAI, [hand[0]], now)
    assert_equal "not offered", M::Remote.new(t, -> { now }).act(token, t.sv, E::DAHAI, "\xFF".b)
    assert_equal 4, t.stats["refused"]
    assert_equal :dahai, t.state.phase
    assert_equal seat, t.state.current_seat, "nothing was played"
    tile = M::Tiles.name(v["dt"])
    assert_equal "ok", t.act(token, t.sv, E::DAHAI, [tile], now)
    assert_equal tile, t.state.kawas[seat].tiles.last.tile.to_s
  end

  def test_a_human_who_does_not_decide_discards_the_drawn_tile
    t, toks = seated_table(1, "turn_ms" => 1000)
    seat = toks.keys.first
    now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat }
    drawn = t.state.last_tsumo.to_s
    kawa = t.state.kawas[seat].count
    timeouts = t.stats["timeouts"] # a call passed for the seat before its turn counts too
    t.tick(now + 990)
    assert_equal kawa, t.state.kawas[seat].count, "not before the time"
    v = t.public_view(now + 990)
    assert_equal 1 << seat, v["dl"][0]
    assert_operator v["dl"][1], :<=, 20
    t.tick(now + 1001)
    assert_equal kawa + 1, t.state.kawas[seat].count
    assert_equal drawn, t.state.kawas[seat].tiles.last.tile.to_s
    assert_equal timeouts + 1, t.stats["timeouts"]
  end

  def test_saved_and_read_back_mid_round
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, toks = seated_table(1, store: store, "turn_ms" => 60_000)
      seat, token = toks.first
      now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat && t.state.kawas[seat].count >= 3 }
      t.touch("wasm-aaaaa0", now) # present (a restarted host counts everybody as just seen)
      t.save(now)
      u = human_table(store: store, "turn_ms" => 60_000)
      u.resume_clock(now)
      a = t.view(seat, now)
      b = u.view(seat, now)
      assert_equal a.reject { |k, _| %w[v aw mb].include?(k) }, b.reject { |k, _| %w[v aw mb].include?(k) }
      assert_operator b["v"], :>, a["v"], "the version goes on from the saved one"
      assert_equal seat, u.seat_of(token), "the token still holds"
      assert_equal t.mine("wasm-aaaaa0"), u.mine("wasm-aaaaa0"), "the membership too"
      # Both go on the same way: the same discard, then the CPUs until the
      # player's next turn (the wall and the CPUs are the same).
      tile = M::Tiles.name(a["dt"])
      [t, u].each { |x| assert_equal "ok", x.act(token, x.sv, E::DAHAI, [tile], now) }
      n1 = run_until(t, now) { t.status != "play" || (t.state.phase == :dahai && t.state.current_seat == seat) || t.state.phase == :naki_wait }
      n2 = run_until(u, now) { u.status != "play" || (u.state.phase == :dahai && u.state.current_seat == seat) || u.state.phase == :naki_wait }
      assert_equal t.view(seat, n1).reject { |k, _| %w[v dl aw mb].include?(k) }, u.view(seat, n2).reject { |k, _| %w[v dl aw mb].include?(k) }
    end
  end

  def test_saved_in_the_lobby
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t = human_table(store: store)
      a = t.join("wasm-aaaaaa", "A", 0)["token"]
      t.sit(a, 1, 0)
      t.cpu(a, 2, true)
      t.save(0)
      u = human_table(store: store)
      u.resume_clock(0)
      assert_equal t.public_view(0).reject { |k, _| k == "v" }, u.public_view(0).reject { |k, _| k == "v" }
      assert_equal "ok", u.cpu(a, -1, true), "still the owner"
    end
  end

  def test_the_deadline_left_is_kept_across_a_restart
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, toks = seated_table(1, store: store, "turn_ms" => 10_000)
      seat = toks.keys.first
      now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat }
      t.save(now + 4000)
      u = human_table(store: store, "turn_ms" => 10_000)
      u.resume_clock(1_000_000)
      assert_equal [1 << seat, 6000], u.public_view(1_000_000)["dl"]
    end
  end

  # ------------------------------------------------------------ calls

  # A table of four humans with seat 2 to discard 8s, and the given seats
  # able to ron it (tanyao, 6s7s); seat 3 may also pon 8s when pon is set.
  def calls_table(ron_seats, pon: false, **opts)
    t, toks = seated_table(4, "call_ms" => 5000, "result_ms" => 60_000, **opts)
    st = t.state
    E.apply(st, { type: :tsumo }, t.rule) while st.phase == :tsumo
    4.times { |i| st.first_turn_flags[i] = false }
    pairs = { 0 => "2p 2p", 1 => "4p 4p", 3 => "3p 3p" }
    4.times { |i| give(st, i, %w[1z 1z 2z 2z 3z 3z 4z 4z 5z 5z 6z 6z 7z]) }
    ron_seats.each { |i| give(st, i, %w[2m 3m 4m 5p 6p 7p 3s 4s 5s 6s 7s] + pairs[i].split) }
    give(st, 3, %w[8s 8s 1m 9m 1p 9p 1s 9s 1z 2z 3z 4z 5z]) if pon
    give(st, 2, %w[8s 1z 1z 2z 2z 3z 3z 4z 4z 5z 5z 6z 6z 7z])
    st.current_seat = 2
    st.phase = :dahai
    st.last_tsumo = Mahjong::Tiles::Tile.new("8s")
    st.dora_hyouji = [Mahjong::Tiles::Tile.new("1z")] # dora 2z: none in the ron hands
    tok2 = toks[2]
    assert_equal "ok", t.act(tok2, t.sv, E::DAHAI, ["8s"], 0)
    [t, toks]
  end

  def test_the_host_waits_for_every_human_then_decides
    t, toks = calls_table([1], pon: true)
    assert_equal :naki_wait, t.state.phase
    assert_equal 1, t.stats["multi_human_calls"]
    assert_equal [0b0010, 5000], t.view(1, 0)["dl"], "both seats get the same deadline, each its own bit"
    assert_equal [0b1000, 5000], t.view(3, 0)["dl"]
    assert_nil t.public_view(0)["dl"], "nobody else learns who may call"
    pon = t.view(3, 0)["a"].find { |a, _| a == E::PON }
    assert_equal "ok", t.act(toks[3], t.sv, E::PON, M::Tiles.unpack(pon[1]), 100)
    assert_equal :naki_wait, t.state.phase, "seat 1 has not answered"
    assert_equal [0b0010, 4900], t.view(1, 100)["dl"]
    assert_equal [0b0111, 4900], t.view(3, 100)["dl"], "seat 3 waits for the others, whoever they are"
    assert_equal [], t.view(3, 100)["a"], "an answer is final"
    assert_equal "ok", t.act(toks[1], t.sv, E::RON, [], 200)
    assert_equal "result", t.status
    assert_equal [1], t.public_view(200)["res"]["wn"].map { |w| w["w"] }, "ron over pon"
  end

  def test_an_unanswered_call_passes_at_the_deadline
    t, toks = calls_table([1], pon: true)
    pon = t.view(3, 0)["a"].find { |a, _| a == E::PON }
    assert_equal "ok", t.act(toks[3], t.sv, E::PON, M::Tiles.unpack(pon[1]), 100)
    t.tick(4999)
    assert_equal :naki_wait, t.state.phase
    t.tick(5000)
    assert_equal :dahai, t.state.phase
    assert_equal 3, t.state.current_seat, "seat 1 passed, the pon stood"
  end

  def test_double_ron
    t, toks = calls_table([0, 1])
    [0, 1].each { |s| assert_equal "ok", t.act(toks[s], t.sv, E::RON, [], 10) }
    assert_equal "result", t.status
    res = t.public_view(10)["res"]
    assert_equal [0, 1].sort, res["wn"].map { |w| w["w"] }.sort
    assert_equal [0, 1], res["wn"].map { |w| w["w"] }, "in turn order from the discarder (seat 2: 3, 0, 1)"
    assert_equal 2, res["f"]
    assert_equal 0, res["d"].sum
    assert_operator res["d"][2], :<, 0
    assert_equal 1, t.stats["double_ron"]
  end

  def test_double_ron_honba_and_sticks_go_to_the_first
    t, toks = calls_table([0, 1])
    t.state.honba = 2
    t.state.kyoutaku = 1
    tile = Mahjong::Tiles::Tile.new("8s")
    base = [0, 1].to_h { |s| [s, E.evaluate(t.state, s, true, tile, t.rule, honba: 0, kyoutaku: 0)[1].payments[:ron_pay]] }
    [0, 1].each { |s| assert_equal "ok", t.act(toks[s], t.sv, E::RON, [], 10) }
    d = t.instance_variable_get(:@result)["delta"]
    assert_equal base[0] + 600 + 1000, d[0], "seat 0 (first after the discarder, seat 2) takes the honba and the stick"
    assert_equal base[1], d[1]
    assert_equal(-(base[0] + base[1] + 600), d[2])
  end

  def test_double_ron_off_keeps_the_head_bump
    t, toks = calls_table([0, 1], "rule" => { "double_ron" => false })
    [0, 1].each { |s| assert_equal "ok", t.act(toks[s], t.sv, E::RON, [], 10) }
    assert_equal [0], t.public_view(10)["res"]["wn"].map { |w| w["w"] }, "the head bump: seat 0 is before seat 1 after seat 2"
  end

  def test_three_rons_are_a_draw_when_triple_ron_draw_is_on
    t, toks = calls_table([0, 1, 3], "rule" => { "triple_ron_draw" => true })
    [0, 1, 3].each { |s| assert_equal "ok", t.act(toks[s], t.sv, E::RON, [], 10) }
    res = t.public_view(10)["res"]
    assert_equal "sanchahou", res["k"]
    assert_equal [0, 1, 3], res["rs"]
    assert_equal [0, 0, 0, 0], res["d"]
    flow = t.instance_variable_get(:@flow)
    assert_equal 1, flow["honba"]
  end

  def test_three_rons_all_win_by_default
    t, toks = calls_table([0, 1, 3])
    [0, 1, 3].each { |s| assert_equal "ok", t.act(toks[s], t.sv, E::RON, [], 10) }
    assert_equal [3, 0, 1], t.public_view(10)["res"]["wn"].map { |w| w["w"] }
  end

  def test_multiple_yakuman_setting
    [[true, 64_000, "2倍役満"], [false, 32_000, "役満"]].each do |on, pay, level|
      rule = E.rule("multiple_yakuman" => on)
      s = E.setup({ "bakaze" => "ton", "kyoku" => 1, "honba" => 0, "kyoutaku" => 0, "oya" => 0,
                    "scores" => [25_000] * 4 }, rule)
      give(s, 1, %w[5z 5z 5z 6z 6z 6z 7z 7z 1z 1z 1z 2z 2z])
      4.times { |i| s.first_turn_flags[i] = false }
      s.last_dahai = { seat: 2, tile: Mahjong::Tiles::Tile.new("7z") }
      _w, sr = E.evaluate(s, 1, true, Mahjong::Tiles::Tile.new("7z"), rule)
      assert_equal pay, sr.payments[:ron_pay], "multiple_yakuman #{on}"
      assert_includes sr.display, level
    end
  end

  def test_the_host_rule_defaults
    r = E.rule
    assert r.double_ron?
    refute r.triple_ron_draw?
    assert r.multiple_yakuman?
    assert r.nishi_iri?
    assert_equal 30_000, r.nishi_iri_threshold
    assert_equal [15_000, 5_000, -5_000, -15_000], r.uma
    refute E.rule("double_ron" => false).double_ron?
  end

  # ------------------------------------------------------------ the engine

  def round_state
    E.setup({ "bakaze" => "ton", "kyoku" => 1, "honba" => 0, "kyoutaku" => 0, "oya" => 0,
              "scores" => [25_000] * 4 }, E.rule)
  end

  def give(state, seat, names)
    state.hands[seat] = Mahjong::State::Hand.new(names)
  end

  def test_red_five_discard_keeps_the_red_five
    s = round_state
    E.apply(s, { type: :tsumo }, E.rule)
    give(s, 0, %w[0m 5m 1p 2p 3p 4s 5s 6s 7z 7z 1z 2z 3z 4z])
    s.last_tsumo = Mahjong::Tiles::Tile.new("4z")
    E.apply(s, { type: :dahai, seat: 0, tile: "5m" }, E.rule)
    assert_equal "5m", s.kawas[0].tiles.last.tile.to_s
    assert_includes s.hands[0].tiles.map(&:to_s), "0m", "the red five stays in the hand"
  end

  # A hand that is tenpai only after discarding 9m (waits 1s and 4s); a 1s
  # in a river and a 4s as a dora indicator are seen.
  def riichi_ready_state
    s = round_state
    E.apply(s, { type: :tsumo }, E.rule)
    give(s, 0, %w[1m 2m 3m 4p 5p 6p 7s 8s 9s 1z 1z 2s 3s 9m])
    s.last_tsumo = Mahjong::Tiles::Tile.new("9m")
    4.times { |i| s.first_turn_flags[i] = false }
    s.kawas[2].add(Mahjong::Tiles::Tile.new("1s"))
    s.dora_hyouji = [Mahjong::Tiles::Tile.new("4s")]
    s
  end

  def test_riichi_waits_after_each_riichi_discard
    s = riichi_ready_state
    o = E.offers(s, 0, E.rule).find { |t, _| t == E::RIICHI }
    assert_equal ["9m"], o[1]
    assert_equal [["9m", [["1s", 3], ["4s", 3]]]], E.waits_after(s, 0, o[1])
    # the waits of a discard that is not offered, for the counting: after
    # 3s the hand waits on nothing
    assert_equal [["3s", []]], E.waits_after(s, 0, ["3s"])
  end

  def test_riichi_waits_count_the_seats_own_hand_and_melds
    s = riichi_ready_state
    give(s, 0, %w[1m 2m 3m 4p 5p 6p 7s 8s 9s 1z 1z 2s 3s 1s])
    s.last_tsumo = Mahjong::Tiles::Tile.new("1s")
    s.fuuros[1] = [Mahjong::State::Fuuro.new(type: :pon, tiles: [Mahjong::Tiles::Tile.new("4s")] * 3,
                                             called_tile: Mahjong::Tiles::Tile.new("4s"), from_seat: 2)]
    # discarding the drawn 1s: 1s seen twice (the river, the discard), 4s four times (pon, indicator)
    waits = E.waits_after(s, 0, ["1s"])
    assert_equal [["1s", [["1s", 2], ["4s", 0]]]], waits
  end

  def test_a_seat_that_may_riichi_gets_the_waits_in_its_view
    t, toks = seated_table(1)
    seat = toks.keys.first
    now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat }
    s = t.state
    give(s, seat, %w[1m 2m 3m 4p 5p 6p 7s 8s 9s 1z 1z 2s 3s 9m])
    s.last_tsumo = Mahjong::Tiles::Tile.new("9m")
    t.instance_variable_set(:@assist, {})
    v = t.view(seat, now)
    assert_includes v["a"].map(&:first), E::RIICHI
    b = v["wt"].bytes
    assert_equal [M::Tiles.code("9m"), 2, M::Tiles.code("1s")], b[0, 3]
    assert_equal M::Tiles.code("4s"), b[4]
    assert_equal 6, b.size
    # nobody else gets it, and nothing when riichi is not offered
    (0..3).each { |o| assert_nil t.view(o, now)["wt"] unless o == seat }
    assert_nil t.public_view(now)["wt"]
  end

  def test_riichi_seat_is_offered_the_drawn_tile
    s = round_state
    E.apply(s, { type: :tsumo }, E.rule)
    s.riichi_flags[0] = true
    o = E.offers(s, 0, E.rule)
    assert_equal [[E::DAHAI, [s.last_tsumo.to_s]]], o.select { |t, _| t == E::DAHAI }
    assert_equal ["ok"], [E.match(o, E::DAHAI, [s.last_tsumo.to_s]) ? "ok" : "no"]
  end

  def test_dora_counts_the_tile_after_the_indicator
    s = round_state
    E.apply(s, { type: :tsumo }, E.rule)
    give(s, 0, %w[2m 3m 4m 5m 6m 7m 2p 3p 4p 6s 7s 8s 5p 5p])
    4.times { |i| s.first_turn_flags[i] = false } # not a tenhou
    s.last_tsumo = Mahjong::Tiles::Tile.new("5p")
    w = s.wanpai
    w.instance_variable_set(:@dora_hyouji, [Mahjong::Tiles::Tile.new("1m")])
    s.dora_hyouji = w.dora_hyouji.dup
    winner, = E.evaluate(s, 0, false, s.last_tsumo, E.rule)
    assert_includes winner[:yaku].map { |y| y[:display] }, "ドラ 1", "1m points to 2m, one in the hand"
  end

  def test_seeds_give_different_walls
    10.times { assert_match(/\A[0-9A-Za-z]{24}\z/, E.new_seed) }
    a = Mahjong::Tiles::Wall.build(seed: "round-001").to_a
    b = Mahjong::Tiles::Wall.build(seed: "round-002").to_a
    refute_equal a, b, "the whole seed counts, not only the part before '-'"
  end

  def test_houtei_on_the_last_discard
    s = round_state
    4.times { |i| give(s, i, []) }
    give(s, 0, %w[3s])
    give(s, 1, %w[1m 2m 3m 4p 5p 6p 7s 8s 9s 9m 9m 2s 4s])
    4.times { |i| s.first_turn_flags[i] = false }
    s.wall = Mahjong::Tiles::Wall.new([])
    s.phase = :dahai
    s.last_tsumo = Mahjong::Tiles::Tile.new("3s")
    E.apply(s, { type: :dahai, seat: 0, tile: "3s" }, E.rule)
    assert_includes E.offers(s, 1, E.rule).map(&:first), E::RON, "houtei is the only yaku"
    r = E.apply(s, { type: :ron_agari, seat: 1 }, E.rule)
    res = E.score(s, r.round_end_info, E.rule)
    assert_includes res["wins"][0]["yaku"], "河底撈魚"
  end

  def test_a_seat_that_could_ron_may_pon
    s = round_state
    4.times { |i| give(s, i, []) }
    give(s, 0, %w[5p])
    give(s, 1, %w[2m 3m 4m 6s 7s 8s 3p 4p 5p 5p 5p 8m 8m])
    4.times { |i| s.first_turn_flags[i] = false }
    s.phase = :dahai
    s.last_tsumo = Mahjong::Tiles::Tile.new("5p")
    E.apply(s, { type: :dahai, seat: 0, tile: "5p" }, E.rule)
    o = E.offers(s, 1, E.rule).map(&:first)
    assert_includes o, E::RON
    pon = E.offers(s, 1, E.rule).find { |t, _| t == E::PON }
    E.apply(s, E.match([pon], E::PON, pon[1]).merge(seat: 1), E.rule)
    assert_equal :pon, s.fuuros[1].last.type
  end

  def test_resolve_calls_goes_by_turn_order
    one = E.rule("double_ron" => false)
    d = { 0 => { type: :ron_agari, seat: 0 }, 2 => { type: :ron_agari, seat: 2 }, 3 => { type: :pon, seat: 3 } }
    assert_equal 2, E.resolve_calls(d, 1, one)[:seat], "seat 2 is next after seat 1"
    assert_equal 0, E.resolve_calls(d, 3, one)[:seat]
    assert_equal [2, 0], E.resolve_calls(d, 1, E.rule)[:seats], "double ron, in turn order"
    assert_equal 3, E.resolve_calls({ 0 => { type: :chi, seat: 0 }, 3 => { type: :pon, seat: 3 } }, 2, E.rule)[:seat]
    assert_nil E.resolve_calls({ 1 => { type: :skip, seat: 1 } }, 0, E.rule)
  end
end
