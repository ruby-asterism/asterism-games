# frozen_string_literal: true

require_relative "test_helper"

# The rules of riichi_engine 0.1.1.fmrb3 the host turns on (README "Rules"):
# nagashi mangan, pao, double yakuman, the abortive draws, and why a game
# ended; and that tables saved before them still load.
class TestMahjongRoundEnds < Minitest::Test
  include MahjongTestHelper

  T = M::Table
  NAGASHI = 12
  ABORTIVE = 11
  DOUBLE_YAKUMAN = 13
  NOTEN = %w[1m 4m 7m 1p 4p 7p 1s 4s 7s 2z 3z 4z 6z].freeze

  # Four members seated, the first the owner, its rules set (item =>
  # value) and started: [table, {seat => token}].
  def table4(rules = {}, **opts)
    t = human_table(**{ "result_ms" => 60_000, "call_ms" => 60_000, "turn_ms" => 60_000 }.merge(opts))
    toks = (0...4).map do |i|
      tok = t.join("wasm-aaaaa#{i}", "P#{i}", 0)["token"]
      assert_equal "ok", t.sit(tok, -1, 0)
      tok
    end
    rules.each { |item, value| assert_equal "ok", t.set_rule(toks[0], item, value) }
    assert_equal "ok", t.start(toks[0], 0)
    [t, toks.to_h { |tok| [t.seat_of(tok), tok] }]
  end

  def tile(n)
    Mahjong::Tiles::Tile.new(n)
  end

  def give(state, seat, names)
    state.hands[seat] = Mahjong::State::Hand.new(names)
  end

  # The state at seat's discard, after the first turns: every flag of the
  # first go-around cleared, no dora that counts.
  def at_discard(t, seat, hand, drawn)
    st = t.state
    E.apply(st, { type: :tsumo }, t.rule) while st.phase == :tsumo
    4.times { |i| st.first_turn_flags[i] = false }
    4.times { |i| give(st, i, NOTEN) }
    give(st, seat, hand + [drawn])
    st.current_seat = seat
    st.phase = :dahai
    st.last_tsumo = tile(drawn)
    st.dora_hyouji = [tile("9m")]
    st
  end

  # Every key the host sets reaches riichi_engine's RuleConfig as the host
  # has it (and the engine knows each one).
  def test_the_hosts_rule_keys_reach_the_engine
    t, = table4
    r = t.rule
    E::RULE_DEFAULTS.each do |k, v|
      assert Mahjong::Config::RuleConfig::DEFAULTS.key?(k), "riichi_engine knows #{k}"
      assert_equal v, r.public_send(k), k
    end
    %i[suufon_renda? suukaikan? suucha_riichi? nagashi_mangan? double_yakuman? minkan_dora_after_discard?
       agari_yame?].each { |m| assert r.public_send(m), m }
    refute r.tenpai_yame?
    refute r.triple_ron_draw?, "three rons all win"
    assert_equal %w[daisangen daisuushii], r.pao
  end

  # ------------------------------------------------------------ nagashi mangan

  # The last discard of the wall: seat n's river is all terminals and
  # honours (none called), the others' are not; nobody is tenpai.
  def last_discard(rules = {})
    t, seats = table4(rules)
    cur = t.state.oya_seat
    n = (cur + 1) % 4
    st = at_discard(t, cur, NOTEN, "5s")
    st.wall = Mahjong::Tiles::Wall.new([])
    4.times do |s|
      st.kawas[s] = Mahjong::State::Kawa.new
      (s == n ? %w[1m 9p 1z 7z] : %w[1m 5p 1z]).each { |x| st.kawas[s].add(x) }
    end
    assert_equal "ok", t.act(seats[cur], t.sv, E::DAHAI, ["5s"], 0)
    assert_equal "result", t.status
    [t, n, cur]
  end

  def test_nagashi_mangan_is_paid_in_place_of_the_noten_payments
    t, n, oya = last_discard
    res = t.public_view(0)["res"]
    assert_equal "ryuukyoku", res["k"]
    assert_equal [n], res["ng"]
    assert_equal [], res["tp"]
    # a child's mangan by tsumo: 4000 from the dealer, 2000 from each child
    want = (0..3).map { |s| s == n ? 8000 : (s == oya ? -4000 : -2000) }
    assert_equal want, res["d"]
    assert_equal 100_000, t.public_view(0)["sc"].sum
  end

  def test_no_nagashi_mangan_when_the_owner_turns_it_off
    t, = last_discard(NAGASHI => 0)
    res = t.public_view(0)["res"]
    refute res.key?("ng")
    assert_equal [0, 0, 0, 0], res["d"], "four noten: nothing moves"
  end

  # ------------------------------------------------------------ pao

  # Seat w has pons of the white and green dragons and the red one called
  # from the dealer's discard (recorded by the engine at the pon); it waits
  # on 9p (tanki).
  def daisangen_table
    t, seats = table4
    oya = t.state.oya_seat
    w = (oya + 1) % 4
    st = at_discard(t, oya, %w[7z 1m 4m 7m 1p 4p 7p 1s 4s 7s 2z 3z 4z], "6z")
    st.menzen_flags[w] = false
    st.fuuros[w] = %w[5z 6z].map do |x|
      Mahjong::State::Fuuro.new(type: :pon, tiles: [tile(x)] * 3, called_tile: tile(x), from_seat: (w + 2) % 4)
    end
    give(st, w, %w[7z 7z 2m 3m 4m 9p 9p])
    assert_equal "ok", t.act(seats[oya], t.sv, E::DAHAI, ["7z"], 0)
    pon = t.view(w, 0)["a"].find { |x, _| x == E::PON }
    assert pon, "the pon of the third dragon is offered"
    assert_equal "ok", t.act(seats[w], t.sv, E::PON, M::Tiles.unpack(pon[1]), 0)
    t.tick(0)
    assert_equal({ "daisangen" => oya }, t.state.pao_seats[w], "the engine records who let the yakuman be made")
    [t, seats, w, oya]
  end

  def test_pao_on_a_ron_splits_the_yakuman_with_the_discarder
    t, seats, w, oya = daisangen_table
    st = t.state
    # the winner discards 1s and waits on 9p; the seat across deals in 9p
    give(st, w, %w[2m 3m 4m 9p 1s])
    st.current_seat = w
    st.phase = :dahai
    assert_equal "ok", t.act(seats[w], t.sv, E::DAHAI, ["1s"], 0)
    t.tick(0)
    other = (w + 2) % 4
    give(st, other, NOTEN + ["9p"])
    st.current_seat = other
    st.phase = :dahai
    st.last_tsumo = tile("9p")
    assert_equal "ok", t.act(seats[other], t.sv, E::DAHAI, ["9p"], 0)
    ron = t.view(w, 0)["a"].find { |x, _| x == E::RON }
    assert ron, "the ron is offered"
    assert_equal "ok", t.act(seats[w], t.sv, E::RON, [], 0)
    res = t.public_view(0)["res"]
    win = res["wn"][0]
    assert_includes win["y"], "大三元"
    assert_equal [[oya, "大三元"]], win["pa"]
    # a child's yakuman by ron, 32000: half from the seat liable, half from the discarder
    d = res["d"]
    assert_equal 32_000, d[w]
    assert_equal(-16_000, d[oya])
    assert_equal(-16_000, d[other])
    assert_operator reply_bytes(t.view(w, 0)), :<, 3800
  end

  def test_pao_on_a_tsumo_the_seat_liable_pays_it_all
    t, seats, w, oya = daisangen_table
    st = t.state
    give(st, w, %w[2m 3m 4m 9p 9p])
    st.current_seat = w
    st.phase = :dahai
    st.last_tsumo = tile("9p")
    tsumo = t.view(w, 0)["a"].find { |x, _| x == E::TSUMO_AGARI }
    assert tsumo, "the tsumo is offered"
    assert_equal "ok", t.act(seats[w], t.sv, E::TSUMO_AGARI, [], 0)
    res = t.public_view(0)["res"]
    assert_equal [[oya, "大三元"]], res["wn"][0]["pa"]
    want = (0..3).map { |s| s == w ? 32_000 : (s == oya ? -32_000 : 0) }
    assert_equal want, res["d"]
  end

  # ------------------------------------------------------------ double yakuman

  def suuankou_tanki(rules = {})
    t, seats = table4(rules)
    s = (t.state.oya_seat + 1) % 4
    at_discard(t, s, %w[1m 1m 1m 3p 3p 3p 5s 5s 5s 7z 7z 7z 2z], "2z")
    assert_equal "ok", t.act(seats[s], t.sv, E::TSUMO_AGARI, [], 0)
    [t.public_view(0)["res"]["wn"][0], s]
  end

  def test_a_double_yakuman_has_han_minus_two
    w, s = suuankou_tanki
    assert_equal s, w["w"]
    i = w["y"].index("四暗刻単騎")
    assert i, w["y"].inspect
    assert_equal(-2, w["yh"][i])
    assert_includes w["pt"], "16000/32000", "a child's double yakuman by tsumo"
  end

  def test_one_yakuman_when_the_owner_turns_double_yakuman_off
    w, = suuankou_tanki(DOUBLE_YAKUMAN => 0)
    assert_equal [-1], w["yh"].select(&:negative?)
    assert_includes w["pt"], "8000/16000"
  end

  # ------------------------------------------------------------ abortive draws

  # The first go-around: every seat discards the east wind.
  def four_winds(rules = {})
    t, seats = table4(rules)
    st = t.state
    oya = st.oya_seat
    4.times do |k|
      s = (oya + k) % 4
      E.apply(st, { type: :tsumo }, t.rule) while st.phase == :tsumo
      assert_equal s, st.current_seat
      4.times { |o| give(st, o, NOTEN) unless o == s } # nobody calls the wind
      give(st, s, %w[1z 2m 3m 5m 6m 8p 9p 2s 3s 5s 6s 8s 3z 4z])
      assert_equal "ok", t.act(seats[s], t.sv, E::DAHAI, ["1z"], 0)
      t.tick(0)
      break unless t.status == "play"
    end
    t
  end

  def test_four_winds_end_the_round_with_its_name
    t = four_winds
    res = t.public_view(0)["res"]
    assert_equal "suufon_renda", res["k"]
    assert_equal [0, 0, 0, 0], res["d"]
    honba = t.public_view(0)["r"][2]
    oya = t.state.oya_seat
    t.next_round(0)
    assert_equal oya, t.state.oya_seat, "the dealer keeps the seat"
    assert_equal honba + 1, t.state.honba
  end

  def test_no_abortive_draw_when_the_owner_turns_them_off
    t = four_winds(ABORTIVE => 0)
    assert_equal "play", t.status
  end

  # ------------------------------------------------------------ the end of a game

  def test_the_view_says_why_the_game_ended
    t, seats = table4
    t.instance_variable_set(:@flow, { "end" => true, "reason" => "tobi" })
    t.next_round(0)
    assert_equal "over", t.status
    assert_equal "tobi", t.public_view(0)["fr"]
    assert_equal "tobi", t.view(seats.keys.first, 0)["fr"]
    t2, = table4
    g = t2.instance_variable_get(:@game)
    g["bakaze"] = "sha"
    g["kyoku"] = 4
    t2.instance_variable_set(:@flow, { "end" => false, "bakaze" => "sha", "kyoku" => 1, "honba" => 0, "oya" => 0 })
    t2.next_round(0)
    assert_equal "west", t2.public_view(0)["fr"], "the host ends the game after west 4"
    assert_equal "ok", t2.act(t2.instance_variable_get(:@seats)[t2.public_view(0)["ow"]]["token"], t2.sv, E::NEXT, [], 0)
    refute t2.public_view(0).key?("fr"), "back in the lobby"
  end

  def test_the_engines_reason_reaches_the_view
    t, = table4
    res = { "kind" => "tsumo_agari", "wins" => [{ "winner" => t.state.oya_seat }], "from" => nil }
    g = t.instance_variable_get(:@game)
    g["bakaze"] = "nan"
    g["kyoku"] = 4
    g["oya"] = t.state.oya_seat
    g["scores"] = (0..3).map { |s| s == t.state.oya_seat ? 40_000 : 20_000 }
    flow = E.next_round(g, t.state, res, t.rule)
    assert flow.game_end?
    assert_equal :all_last_oya_agari, flow.reason
  end

  # ------------------------------------------------------------ saved tables

  # A table saved by the host before these rules (no pao or kan dora in the
  # round, no reason in the flow, no final reason) is read back and plays on.
  def test_a_table_saved_before_the_new_rules_still_loads
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, seats = table4({}, store: store)
      t.save(0)
      d = store.read("t")
      round = JSON.parse(d["round"])
      round.delete("pao_seats")
      round.delete("pending_kan_dora")
      d["round"] = JSON.generate(round)
      d.delete("final_reason")
      store.write("t", d)
      u = human_table(store: store, "turn_ms" => 60_000)
      u.resume_clock(0)
      assert_equal "play", u.status
      assert_equal({ 0 => {}, 1 => {}, 2 => {}, 3 => {} }, u.state.pao_seats)
      seat = u.state.current_seat
      E.apply(u.state, { type: :tsumo }, u.rule) while u.state.phase == :tsumo
      a = u.view(seat, 0)["a"].find { |x, _| x == E::DAHAI }
      assert_equal "ok", u.act(seats[seat], u.sv, E::DAHAI, [M::Tiles.unpack(a[1]).last], 0)
    end
  end
end
