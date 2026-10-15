# frozen_string_literal: true

require_relative "test_helper"

# Seats, tokens, refusals, the timeout, saving and the corrections made
# around riichi_engine 0.1.0.
class TestMahjongRules < Minitest::Test
  include MahjongTestHelper

  def sit(t, node = "wasm-aaaaaa", now = 0)
    r = t.sit(node, "Player", now)
    [r["seat"], r["token"]]
  end

  def test_sit_gives_one_seat_and_its_token_back
    t = human_table
    seat, token = sit(t)
    assert_includes 0..3, seat
    assert_equal 32, token.size
    assert_equal "play", t.status
    assert_equal [seat, token], sit(t), "the same node gets its seat back"
    assert_equal({ "error" => "full" }, t.sit("fmruby-bbbbbb", "Other", 0))
  end

  def test_view_and_act_need_the_token
    t = human_table
    _seat, token = sit(t)
    r = M::Remote.new(t, -> { 0 })
    assert_equal({ "error" => "token" }, r.view(""))
    assert_equal({ "error" => "token" }, r.view(nil))
    assert_equal({ "error" => "token" }, r.view("0" * 32))
    assert_equal({ "error" => "token" }, r.view(token.upcase))
    assert_equal "token", r.act("bad", t.sv, E::DAHAI, "\x00".b)
    assert_equal "token", r.act(nil, t.sv, E::DAHAI, "\x00".b)
    assert r.view(token)["h"], "the right token gets the hand"
    pub = r.table
    assert_nil pub["h"]
    assert_nil pub["a"]
  end

  def test_refuses_what_is_not_offered
    t = human_table
    seat, token = sit(t)
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
    t = human_table("turn_ms" => 1000)
    seat, _token = sit(t)
    now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat }
    drawn = t.state.last_tsumo.to_s
    kawa = t.state.kawas[seat].count
    t.tick(now + 990)
    assert_equal kawa, t.state.kawas[seat].count, "not before the time"
    v = t.public_view(now + 990)
    assert_equal seat, v["dl"][0]
    assert_operator v["dl"][1], :<=, 20
    t.tick(now + 1001)
    assert_equal kawa + 1, t.state.kawas[seat].count
    assert_equal drawn, t.state.kawas[seat].tiles.last.tile.to_s
    assert_equal 1, t.stats["timeouts"]
  end

  def test_saved_and_read_back_mid_round
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t = human_table(store: store, "turn_ms" => 60_000)
      seat, token = sit(t)
      now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat && t.state.kawas[seat].count >= 3 }
      t.save(now)
      u = human_table(store: store, "turn_ms" => 60_000)
      u.resume_clock(now)
      a = t.view(seat, now)
      b = u.view(seat, now)
      assert_equal a.reject { |k, _| k == "v" }, b.reject { |k, _| k == "v" }
      assert_operator b["v"], :>, a["v"], "the version goes on from the saved one"
      assert_equal seat, u.seat_of(token), "the token still holds"
      # Both go on the same way: the same discard, then the CPUs until the
      # player's next turn (the wall and the CPUs are the same).
      tile = M::Tiles.name(a["dt"])
      [t, u].each { |x| assert_equal "ok", x.act(token, x.sv, E::DAHAI, [tile], now) }
      n1 = run_until(t, now) { t.status != "play" || (t.state.phase == :dahai && t.state.current_seat == seat) || t.state.phase == :naki_wait }
      n2 = run_until(u, now) { u.status != "play" || (u.state.phase == :dahai && u.state.current_seat == seat) || u.state.phase == :naki_wait }
      assert_equal t.view(seat, n1).reject { |k, _| %w[v dl].include?(k) }, u.view(seat, n2).reject { |k, _| %w[v dl].include?(k) }
    end
  end

  def test_the_deadline_left_is_kept_across_a_restart
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t = human_table(store: store, "turn_ms" => 10_000)
      seat, = sit(t)
      now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat }
      t.save(now + 4000)
      u = human_table(store: store, "turn_ms" => 10_000)
      u.resume_clock(1_000_000)
      assert_equal [seat, 6000], u.public_view(1_000_000)["dl"]
    end
  end

  # ------------------------------------------------------------ engine 0.1.0

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
    assert_equal "1m", s.dora_hyouji[0].to_s, "the state is left as it was"
    plain, = E::API.evaluate_win(state: s, seat: 0, agari_type: :tsumo, agari_tile: s.last_tsumo, rule: E.rule,
                                 extra_flags: {}, snapshot: Mahjong::Snapshots::WinEvaluationSnapshot.new(
                                   bakaze: "ton", oya_index: 0, honba: 0, kyoutaku: 0, jikaze: "ton"))
    refute_includes plain[:yaku].map { |y| y[:display] }, "ドラ 1", "the engine alone counts the indicator (if this fails, the engine was fixed)"
  end

  def test_seed_is_only_base36
    10.times { assert_match(/\A[0-9a-z]{24}\z/, E.new_seed) }
    a = Mahjong::Tiles::Wall.build(seed: "round-001").to_a
    b = Mahjong::Tiles::Wall.build(seed: "round-002").to_a
    assert_equal a, b, "the engine reads only the part before '-' (if this fails, the engine was fixed)"
  end

  def test_call_winner_goes_by_turn_order
    d = { 0 => { type: :ron_agari, seat: 0 }, 2 => { type: :ron_agari, seat: 2 }, 3 => { type: :pon, seat: 3 } }
    assert_equal 2, E.call_winner(d, 1)[0], "seat 2 is next after seat 1"
    assert_equal 0, E.call_winner(d, 3)[0]
    assert_equal 3, E.call_winner({ 0 => { type: :chi, seat: 0 }, 3 => { type: :pon, seat: 3 } }, 2)[0]
    assert_nil E.call_winner({ 1 => { type: :skip, seat: 1 } }, 0)
  end
end
