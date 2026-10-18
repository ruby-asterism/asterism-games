# frozen_string_literal: true

require_relative "test_helper"

# The start of a round and the result (README "Result"): after the deal a
# table with humans shows the round's name for deal_pause_ms (no clock
# runs, no CPU or AI plays); a result waits until every human there gave
# it an OK (the "next" of a screen, old ones too), away humans not
# counted, or moves on result_auto_ms after its count (per winner a step
# a yaku line and one for the points, a draw one step). A table without
# humans is as before.
class TestMahjongResultOk < Minitest::Test
  include MahjongTestHelper

  T = M::Table
  NOTEN = %w[1m 4m 7m 1p 4p 7p 1s 4s 7s 2z 3z 4z 6z].freeze
  STEP = T::COUNT_STEP_MS

  def give(state, seat, names)
    state.hands[seat] = Mahjong::State::Hand.new(names)
  end

  def tile(n)
    Mahjong::Tiles::Tile.new(n)
  end

  # Four humans (no one away unless the test says), the deal's pause off
  # unless given.
  def table4(**opts)
    seated_table(4, **{ "away_ms" => 10**9, "result_auto_ms" => 10_000, "call_ms" => 60_000,
                        "turn_ms" => 60_000 }.merge(opts))
  end

  # The round ends in a draw at `now` (the last discard, nobody tenpai).
  def draw_at(t, toks, now)
    st = t.state
    E.apply(st, { type: :tsumo }, t.rule) while st.phase == :tsumo
    4.times { |i| st.first_turn_flags[i] = false }
    cur = st.current_seat
    give(st, cur, NOTEN + ["5s"])
    st.last_tsumo = tile("5s")
    st.wall = Mahjong::Tiles::Wall.new([])
    4.times do |s|
      st.kawas[s] = Mahjong::State::Kawa.new
      %w[1m 5p 1z].each { |x| st.kawas[s].add(x) }
    end
    assert_equal "ok", t.act(toks[cur], t.sv, E::DAHAI, ["5s"], now)
    assert_equal "result", t.status
    assert_equal "ryuukyoku", t.public_view(now)["res"]["k"]
  end

  # Seat 2 discards 8s at `now` and ron_seats ron it (tanyao, 6s7s).
  def ron_at(t, toks, ron_seats, now)
    st = t.state
    E.apply(st, { type: :tsumo }, t.rule) while st.phase == :tsumo
    4.times { |i| st.first_turn_flags[i] = false }
    pairs = { 0 => "2p 2p", 1 => "4p 4p", 3 => "3p 3p" }
    4.times { |i| give(st, i, %w[1z 1z 2z 2z 3z 3z 4z 4z 5z 5z 6z 6z 7z]) }
    ron_seats.each { |i| give(st, i, %w[2m 3m 4m 5p 6p 7p 3s 4s 5s 6s 7s] + pairs[i].split) }
    give(st, 2, %w[8s 1z 1z 2z 2z 3z 3z 4z 4z 5z 5z 6z 6z 7z])
    st.current_seat = 2
    st.phase = :dahai
    st.last_tsumo = tile("8s")
    st.dora_hyouji = [tile("1z")]
    assert_equal "ok", t.act(toks[2], t.sv, E::DAHAI, ["8s"], now)
    ron_seats.each { |s| assert_equal "ok", t.act(toks[s], t.sv, E::RON, [], now) }
    assert_equal "result", t.status
    t.public_view(now)["res"]
  end

  def next_at(t)
    t.instance_variable_get(:@next_at)
  end

  # ------------------------------------------------------------ the count

  def test_the_count_is_a_step_a_yaku_line_and_one_for_the_points
    one = { "kind" => "ron_agari", "wins" => [{ "yaku" => %w[a b c] }] }
    assert_equal 4 * STEP, T.count_ms(one)
    two = { "kind" => "ron_agari", "wins" => [{ "yaku" => %w[a b] }, { "yaku" => %w[a b c d e] }] }
    assert_equal (3 + 6) * STEP, T.count_ms(two), "a double ron: the winners one after the other"
    three = { "kind" => "ron_agari", "wins" => [{ "yaku" => %w[a] }] * 3 }
    assert_equal 6 * STEP, T.count_ms(three)
    assert_equal STEP, T.count_ms({ "kind" => "ryuukyoku", "tenpai" => [0, 2] }), "a draw: one step"
    assert_equal STEP, T.count_ms({ "kind" => "sanchahou", "ron_seats" => [1, 2, 3] })
    assert_equal STEP, T.count_ms({ "kind" => "ryuukyoku", "nagashi" => [1] })
    assert_equal 1000, STEP
    assert_equal 10_000, T::DEFAULTS["result_auto_ms"]
    assert_equal 2000, T::DEFAULTS["deal_pause_ms"]
  end

  def test_the_settings_and_the_environment
    c = AsterismGames::Config.new({ "tables" => [{ "name" => "a", "result_auto_seconds" => 7, "deal_pause_seconds" => 3 }] }, {})
    assert_equal 7000, c["tables"][0]["result_auto_ms"]
    assert_equal 3000, c["tables"][0]["deal_pause_ms"]
    c = AsterismGames::Config.new({ "tables" => [{ "name" => "a" }] },
                                  { "MAHJONG_RESULT_AUTO_SECONDS" => "15", "MAHJONG_DEAL_PAUSE_SECONDS" => "0" })
    assert_equal 15_000, c["tables"][0]["result_auto_ms"]
    assert_equal 0, c["tables"][0]["deal_pause_ms"]
  end

  # ------------------------------------------------------------ the deal

  def test_the_deal_pauses_with_the_rounds_name_and_no_clock
    t, toks = table4("deal_pause_ms" => 2000, "turn_ms" => 1000)
    oya = t.state.oya_seat
    assert_equal :tsumo, t.state.phase
    v = t.view(oya, 0)
    assert_equal 2000, v["in"], "the round's name shows for 2 s"
    assert_equal [0, 1, 0], v["r"][0, 3], "east 1, no honba"
    assert_nil v["dl"], "no clock yet"
    assert_equal [], v["a"], "nothing to do yet"
    sv = t.sv
    t.tick(1999)
    assert_equal 1, t.view(oya, 1999)["in"]
    assert_equal sv, t.sv, "nothing moves"
    assert_equal :tsumo, t.state.phase
    assert_equal "not offered", t.act(toks[oya], t.sv, E::DAHAI, ["1m"], 1999)
    t.tick(2000)
    v = t.view(oya, 2000)
    assert_nil v["in"]
    assert_equal :dahai, t.state.phase, "the dealer's first draw"
    assert_equal [1 << oya, 1000], v["dl"], "the clock runs from the end of the pause, in full"
    assert_operator t.sv, :>, sv
  end

  def test_no_cpu_or_ai_plays_while_the_rounds_name_shows
    t = nil
    20.times do
      t, = seated_table(1, "deal_pause_ms" => 2000, "away_ms" => 10**9)
      break unless t.human?(t.state.oya_seat)
    end
    oya = t.state.oya_seat
    refute t.human?(oya), "a CPU deals"
    t.tick(1000)
    assert_equal 0, t.state.kawas[oya].count, "the CPU waits"
    t.tick(2000)
    assert_equal 1, t.state.kawas[oya].count, "and plays at the end of the pause"

    # An AI dealer is not asked during the pause.
    t = nil
    20.times do
      t, = seated_table(1, "deal_pause_ms" => 2000, "away_ms" => 10**9)
      break unless t.human?(t.state.oya_seat)
    end
    oya = t.state.oya_seat
    t.instance_variable_get(:@seats)[oya]["ai"] = "claude"
    t.tick(1500)
    assert_empty t.ai_requests(1500)
    t.tick(2000)
    refute_empty t.ai_requests(2000), "asked once the pause is over"
  end

  def test_every_round_pauses_and_the_next_round_shows_its_name
    t, toks = table4("deal_pause_ms" => 2000)
    t.tick(2000)
    draw_at(t, toks, 2000)
    toks.each { |_s, tok| assert_equal "ok", t.act(tok, t.sv, E::NEXT, [], 3000) }
    assert_equal "play", t.status
    v = t.public_view(3000)
    assert_equal 2000, v["in"]
    assert_equal :tsumo, t.state.phase
  end

  def test_a_table_without_humans_does_not_pause
    t = cpu_table("deal_pause_ms" => 2000)
    assert_nil t.public_view(0)["in"]
    t.tick(10)
    assert_operator t.state.kawas.sum(&:count), :>, 0
  end

  def test_a_saved_pause_goes_on_after_a_restart
    Dir.mktmpdir do |d|
      store = AsterismGames::Store.new(d)
      t, = table4("deal_pause_ms" => 2000, store: store)
      t.save(500)
      u = human_table(store: store, "deal_pause_ms" => 2000, "away_ms" => 10**9)
      u.resume_clock(10_000)
      assert_equal 1500, u.public_view(10_000)["in"]
      sv = u.sv
      u.tick(11_499)
      assert_equal sv, u.sv
      u.tick(11_500)
      assert_operator u.sv, :>, sv
    end
  end

  # ------------------------------------------------------------ the OKs

  def test_the_result_waits_for_every_human
    t, toks = table4
    draw_at(t, toks, 100)
    assert_equal 100 + STEP + 10_000, next_at(t), "a draw: one step and 10 s"
    v = t.public_view(100)
    assert_equal [0, 0b1111, 11_000], v["ok"]
    seats = toks.keys.sort
    seats[0, 3].each_with_index do |s, i|
      assert_equal [[E::NEXT, ""]], t.view(s, 200)["a"].map { |a, b| [a, b] }
      assert_equal "ok", t.act(toks[s], t.sv, E::NEXT, [], 200 + i)
      assert_equal "result", t.status, "#{i + 1} of 4"
      assert_equal [], t.view(s, 300)["a"], "an OK is given once"
    end
    ok = t.public_view(300)["ok"]
    assert_equal 0b1111 & ~(1 << seats[3]), ok[0]
    assert_equal 1 << seats[3], ok[1]
    assert_equal 10_800, ok[2]
    assert_equal "ok", t.act(toks[seats[0]], t.sv, E::NEXT, [], 300), "a second press says ok and changes nothing"
    assert_equal "result", t.status
    assert_equal "ok", t.act(toks[seats[3]], t.sv, E::NEXT, [], 400)
    assert_equal "play", t.status, "all four: the next round"
    assert_nil t.public_view(400)["ok"]
  end

  def test_an_away_human_is_not_waited_for
    t, toks = table4
    draw_at(t, toks, 0)
    seats = toks.keys.sort
    gone = seats[1]
    t.node_left(t.instance_variable_get(:@seats)[gone]["node"], 10)
    t.tick(10)
    assert t.away?(gone)
    assert_equal 0b1111 & ~(1 << gone), t.public_view(10)["ok"][1], "the away seat is not waited for"
    (seats - [gone]).each { |s| assert_equal "ok", t.act(toks[s], t.sv, E::NEXT, [], 20) }
    assert_equal "play", t.status
  end

  def test_nobody_presses_the_result_moves_on_after_the_count_and_10_s
    t, toks = table4
    res = ron_at(t, toks, [1], 0)
    n = res["wn"][0]["y"].size
    assert_operator n, :>=, 2
    assert_equal (n + 1) * STEP + 10_000, next_at(t), "the yaku lines, the points, 10 s"
    t.tick(next_at(t) - 1)
    assert_equal "result", t.status
    assert_equal [0, 0b1111, 1], t.public_view(next_at(t) - 1)["ok"]
    t.tick(next_at(t))
    assert_equal "play", t.status
  end

  def test_one_ok_short_still_moves_on_by_itself
    t, toks = table4
    draw_at(t, toks, 0)
    seats = toks.keys.sort
    seats[0, 3].each { |s| t.act(toks[s], t.sv, E::NEXT, [], 10) }
    t.tick(10_999)
    assert_equal "result", t.status
    t.tick(11_000)
    assert_equal "play", t.status
  end

  def test_a_double_ron_counts_both_winners
    t, toks = table4
    res = ron_at(t, toks, [0, 1], 0)
    assert_equal 2, res["wn"].size
    steps = res["wn"].sum { |w| w["y"].size + 1 }
    assert_equal steps * STEP + 10_000, next_at(t)
    assert_equal [0, 0b1111, steps * STEP + 10_000], t.public_view(0)["ok"]
  end

  def test_an_old_screens_next_is_its_ok
    # A screen before the OKs knows nothing of "ok": it sends "next" as
    # before, and that is the seat's OK.
    t, toks = table4
    draw_at(t, toks, 0)
    seats = toks.keys.sort
    old = seats[2]
    assert_includes t.view(old, 0)["a"].map(&:first), E::NEXT
    assert_equal "ok", t.act(toks[old], t.sv, E::NEXT, [], 50)
    assert_equal 1 << old, t.public_view(50)["ok"][0]
    (seats - [old]).each { |s| t.act(toks[s], t.sv, E::NEXT, [], 60) }
    assert_equal "play", t.status
  end

  def test_all_humans_away_waits_for_the_time
    t, toks = table4
    draw_at(t, toks, 0)
    4.times { |i| t.node_left("wasm-aaaaa#{i}", 0) }
    t.tick(5000)
    assert_equal "result", t.status, "nobody there to press: the time decides"
    assert_equal 0, t.public_view(5000)["ok"][1]
    t.tick(11_000)
    assert_equal "play", t.status
  end

  def test_a_table_without_humans_moves_on_after_result_ms
    t = cpu_table("result_ms" => 8000)
    now = run_until(t, 0) { t.status == "result" }
    v = t.public_view(now)
    assert_nil v["ok"], "no OKs to wait for"
    assert_equal now + 8000, next_at(t), "result_ms from the result, as before"
    rounds = t.instance_variable_get(:@game)["rounds"]
    t.tick(now + 7999)
    assert_equal rounds, t.instance_variable_get(:@game)["rounds"]
    t.tick(now + 8000)
    assert_equal rounds + 1, t.instance_variable_get(:@game)["rounds"]
  end

  def test_the_spectators_delayed_view_has_no_oks
    t, toks = table4
    draw_at(t, toks, 0)
    assert t.game_part(t.public_view(0)).key?("res")
    refute t.game_part(t.public_view(0)).key?("ok")
  end

  def test_the_oks_and_the_time_survive_a_restart
    Dir.mktmpdir do |d|
      store = AsterismGames::Store.new(d)
      t, toks = table4(store: store)
      draw_at(t, toks, 0)
      s = toks.keys.min
      t.act(toks[s], t.sv, E::NEXT, [], 1000)
      t.save(1000)
      u = human_table(store: store, "away_ms" => 10**9, "result_auto_ms" => 10_000)
      u.resume_clock(50_000)
      assert_equal "result", u.status
      assert_equal [1 << s, 0b1111 & ~(1 << s), 10_000], u.public_view(50_000)["ok"]
      u.tick(59_999)
      assert_equal "result", u.status
      u.tick(60_000)
      assert_equal "play", u.status
    end
  end

  def test_the_end_of_the_game_is_as_before
    t, toks = table4("over_ms" => 10**9)
    draw_at(t, toks, 0)
    t.instance_variable_set(:@flow, { "end" => true, "reason" => "normal_end" })
    toks.each { |_s, tok| t.act(tok, t.sv, E::NEXT, [], 10) }
    assert_equal "over", t.status
    assert_nil t.public_view(10)["ok"]
    owner = t.public_view(10)["ow"]
    others = toks.keys - [owner]
    assert_equal [], t.view(others.first, 10)["a"]
    assert_equal "ok", t.act(toks[owner], t.sv, E::NEXT, [], 20)
    assert_equal "wait", t.status
  end
end
