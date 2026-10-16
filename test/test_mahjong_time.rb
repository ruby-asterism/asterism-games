# frozen_string_literal: true

require_relative "test_helper"

# The time for a move and the bank (README "Time"): a move that takes
# longer than turn_ms goes on into the seat's bank, the move is played for
# when both are used up, the banks are full at the start of a game and last
# it out; the owner chooses the time in the lobby (item 10); a table saved
# before the bank still loads.
class TestMahjongTime < Minitest::Test
  include MahjongTestHelper

  T = M::Table
  TURN = 10

  def soul_table(n = 1, **opts)
    # away_ms: nobody counts as away (the tests do not call the table)
    seated_table(n, **{ "turn_ms" => 5000, "bank_ms" => 20_000, "away_ms" => 10**9 }.merge(opts))
  end

  # Runs until it is seat's move (or the round is over); the time.
  def to_move(t, seat, now)
    run_until(t, now) { t.status != "play" || (t.state.phase == :dahai && t.state.current_seat == seat) }
  end

  def banks(t)
    t.instance_variable_get(:@banks)
  end

  def test_the_defaults_are_five_and_twenty
    assert_equal 5000, T::DEFAULTS["turn_ms"]
    assert_equal 20_000, T::DEFAULTS["bank_ms"]
    t = T.new("t", { "humans" => 4 })
    assert_equal 20_005, t.rule_values[TURN], "5 s a move, a bank of 20 s"
    assert_equal 5, t.public_view(0)["ru"][TURN], "a table app before MJ-E3 shows the seconds for a move"
    assert_equal 20, t.public_view(0)["tb"]
  end

  def test_the_bank_is_a_setting
    c = AsterismGames::Config.new({ "tables" => [{ "name" => "a", "turn_seconds" => 3, "bank_seconds" => 5 }] }, {})
    assert_equal 3000, c["tables"][0]["turn_ms"]
    assert_equal 5000, c["tables"][0]["bank_ms"]
    c = AsterismGames::Config.new({ "tables" => [{ "name" => "a" }] },
                                  { "MAHJONG_TURN_SECONDS" => "7", "MAHJONG_BANK_SECONDS" => "15" })
    assert_equal 7000, c["tables"][0]["turn_ms"]
    assert_equal 15_000, c["tables"][0]["bank_ms"]
    t = T.new("t", c["tables"][0])
    assert_equal [20_005, 5, 30, 60, 600, 15_007], t.rule_choices(TURN), "the host's own time is a choice"
  end

  def test_a_move_beyond_its_time_takes_the_rest_from_the_bank
    t, toks = soul_table
    seat, token = toks.first
    now = to_move(t, seat, 0)
    assert_equal [1 << seat, 25_000, 20_000], t.public_view(now)["dl"], "5 s and the bank of 20 s"
    t.tick(now + 4000)
    assert_equal [1 << seat, 21_000, 20_000], t.public_view(now + 4000)["dl"], "1 s of the move left"
    now += 8000
    t.tick(now)
    assert_equal [1 << seat, 17_000, 20_000], t.public_view(now)["dl"], "the move is over, 17 s of the bank left"
    tile = M::Tiles.name(t.view(seat, now)["dt"])
    assert_equal "ok", t.act(token, t.sv, E::DAHAI, [tile], now)
    assert_equal 17_000, banks(t)[seat], "8 s: 3 s off the bank"
    others = (0..3).to_a - [seat]
    assert_equal [20_000] * 3, others.map { |s| banks(t)[s] }
    now = to_move(t, seat, now)
    skip "the round ended first" unless t.status == "play"
    assert_equal [1 << seat, 22_000, 17_000], t.public_view(now)["dl"], "5 s and the bank that is left"
    assert_equal "ok", t.act(token, t.sv, E::DAHAI, [M::Tiles.name(t.view(seat, now)["dt"])], now + 4999)
    assert_equal 17_000, banks(t)[seat], "within the 5 s: the bank stays"
  end

  def test_a_move_is_played_for_when_the_bank_is_used_up
    t, toks = soul_table
    seat = toks.keys.first
    now = to_move(t, seat, 0)
    kawa = t.state.kawas[seat].count
    drawn = t.state.last_tsumo.to_s
    t.tick(now + 24_990)
    assert_equal kawa, t.state.kawas[seat].count, "the bank is not used up yet"
    t.tick(now + 25_000)
    assert_equal kawa + 1, t.state.kawas[seat].count, "the drawn tile is discarded"
    assert_equal drawn, t.state.kawas[seat].tiles.last.tile.to_s
    assert_equal 0, banks(t)[seat]
    now = to_move(t, seat, now + 25_000)
    skip "the round ended first" unless t.status == "play"
    assert_equal [1 << seat, 5000], t.public_view(now)["dl"], "no bank: 5 s, no bank part"
    kawa = t.state.kawas[seat].count
    t.tick(now + 4990)
    assert_equal kawa, t.state.kawas[seat].count
    t.tick(now + 5000)
    assert_equal kawa + 1, t.state.kawas[seat].count, "5 s and no more"
  end

  # The banks are full again at every round (README "Time").
  def test_the_bank_fills_at_every_round
    t, toks = soul_table(1, "over_ms" => 10**9)
    seat, token = toks.first
    now = to_move(t, seat, 0)
    t.tick(now + 15_000)
    assert_equal "ok", t.act(token, t.sv, E::DAHAI, [M::Tiles.name(t.view(seat, now + 15_000)["dt"])], now + 15_000)
    assert_equal 10_000, banks(t)[seat]
    # the next round
    t.instance_variable_set(:@flow, { "end" => false, "bakaze" => "ton", "kyoku" => 2, "honba" => 0, "oya" => 1 })
    t.instance_variable_set(:@status, "result")
    t.next_round(now + 15_000)
    assert_equal "play", t.status
    assert_equal [1, 2], [M::Engine::BAKAZE.index(t.state.bakaze) + 1, t.state.kyoku]
    assert_equal 20_000, banks(t)[seat], "a new round fills the bank"
    # the end of the game, the lobby, the next game
    t.instance_variable_set(:@flow, { "end" => true, "reason" => "normal_end" })
    t.instance_variable_set(:@status, "result")
    t.next_round(now + 16_000)
    assert_equal "over", t.status
    assert_equal "ok", t.act(token, t.sv, E::NEXT, [], now + 16_000)
    assert_equal "wait", t.status
    assert_nil banks(t)
    assert_equal "ok", t.start(token, now + 16_000)
    assert_equal [20_000] * 4, banks(t), "full again at the next game"
  end

  def test_an_away_seat_keeps_the_short_wait_and_its_bank
    t, toks = soul_table(1, "away_ms" => 1000, "away_wait_ms" => 500)
    seat, token = toks.first
    now = to_move(t, seat, 0)
    t.touch(t.node_of(token), now)
    kawa = t.state.kawas[seat].count
    t.tick(now + 1010)
    assert t.away?(seat), "not heard from for 1 s"
    assert_equal kawa + 1, t.state.kawas[seat].count, "played for once it is away (its short wait is over)"
    now = to_move(t, seat, now + 1010)
    skip "the round ended first" unless t.status == "play"
    assert_equal [1 << seat, 500], t.public_view(now)["dl"], "the short wait, no bank part"
    kawa = t.state.kawas[seat].count
    t.tick(now + 500)
    assert_equal kawa + 1, t.state.kawas[seat].count
    assert_equal 20_000, banks(t)[seat], "the short waits are within the 5 s: the bank stays"
  end

  def test_calls_keep_the_call_time
    t, toks = seated_table(4, "turn_ms" => 5000, "bank_ms" => 20_000, "call_ms" => 5000)
    st = t.state
    E.apply(st, { type: :tsumo }, t.rule) while st.phase == :tsumo
    4.times { |i| st.first_turn_flags[i] = false }
    dealer = st.current_seat
    caller = (dealer + 1) % 4
    st.hands[caller] = Mahjong::State::Hand.new(%w[8s 8s 1m 2m 3m 4p 5p 6p 7p 8p 9p 1z 1z])
    st.hands[dealer] = Mahjong::State::Hand.new(%w[8s 2z 2z 3z 3z 4z 4z 5z 5z 6z 6z 7z 7z 9m])
    st.last_tsumo = Mahjong::Tiles::Tile.new("9m")
    assert_equal "ok", t.act(toks[dealer], t.sv, E::DAHAI, ["8s"], 0)
    assert_equal :naki_wait, st.phase
    dl = t.view(caller, 0)["dl"]
    assert_equal [1 << caller, 5000], dl, "call_ms, no bank part"
  end

  # ------------------------------------------------------------ the local rule

  def test_the_owner_chooses_the_time_and_it_reaches_the_table
    t = human_table("turn_ms" => 5000, "bank_ms" => 20_000)
    tok = t.join("wasm-aaaaa0", "P0", 0)["token"]
    t.sit(tok, -1, 0)
    assert_equal [20_005, 5, 30, 60, 600], t.public_view(0)["tc"], "the host's 5+20 is the first choice"
    assert_equal "value", t.set_rule(tok, TURN, 7)
    assert_equal "value", t.set_rule(tok, TURN, 5003), "3+5 is not a choice any more"
    assert_equal "ok", t.set_rule(tok, TURN, 600)
    v = t.public_view(0)
    assert_equal [600, 0], [v["ru"][TURN], v["tb"]]
    assert_equal "ok", t.set_rule(tok, TURN, 5)
    v = t.public_view(0)
    assert_equal [5, 0], [v["ru"][TURN], v["tb"]]
    t.cpu(tok, -1, true)
    assert_equal "ok", t.start(tok, 0)
    refute t.public_view(0).key?("tc"), "the choices are for the lobby"
    seat = t.seat_of(tok)
    now = to_move(t, seat, 0)
    assert_equal [1 << seat, 5000], t.public_view(now)["dl"], "5 s and no bank"
    assert_equal [0] * 4, banks(t)
  end

  def test_a_fixed_time_has_no_bank
    t = human_table("turn_ms" => 5000, "bank_ms" => 20_000)
    tok = t.join("wasm-aaaaa0", "P0", 0)["token"]
    t.sit(tok, -1, 0)
    assert_equal "ok", t.set_rule(tok, TURN, 60)
    assert_equal [60, 0], [t.public_view(0)["ru"][TURN], t.public_view(0)["tb"]]
    assert_equal "ok", t.set_rule(tok, TURN, 30), "a table app before MJ-E3 steps through 10, 20, 30, 60"
    assert_equal [30_000, 0], [t.turn_ms, t.bank_ms]
    assert_equal "ok", t.set_rule(tok, TURN, 20_005)
    assert_empty t.instance_variable_get(:@time_choice).to_a, "the host's value again: no choice kept"
    t.set_rule(tok, TURN, 20)
    t.cpu(tok, -1, true)
    t.start(tok, 0)
    seat = t.seat_of(tok)
    now = to_move(t, seat, 0)
    assert_equal [1 << seat, 20_000], t.public_view(now)["dl"]
  end

  # ------------------------------------------------------------ saving

  def test_the_banks_are_saved
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, toks = soul_table(1, store: store)
      seat, token = toks.first
      now = to_move(t, seat, 0)
      t.tick(now + 9000)
      t.act(token, t.sv, E::DAHAI, [M::Tiles.name(t.view(seat, now + 9000)["dt"])], now + 9000)
      now = to_move(t, seat, now + 9000)
      skip "the round ended first" unless t.status == "play"
      t.save(now + 1000)
      u = human_table(store: store, "turn_ms" => 5000, "bank_ms" => 20_000)
      u.resume_clock(500_000)
      assert_equal 16_000, banks(u)[seat]
      assert_equal [1 << seat, 20_000, 16_000], u.public_view(500_000)["dl"], "1 s of the move gone"
    end
  end

  # A table saved before the bank: "rules" with "turn_ms" alone (a fixed
  # time the owner chose), no "banks".
  def test_a_table_saved_before_the_bank_loads
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, toks = seated_table(1, store: store, "turn_ms" => 20_000)
      seat = toks.keys.first
      now = to_move(t, seat, 0)
      t.save(now)
      path = Dir[File.join(dir, "*.json")].first
      d = JSON.parse(File.read(path))
      d.delete("banks")
      d["rules"] = { "choice" => {}, "turn_ms" => 30_000 }
      File.write(path, JSON.generate(d))
      u = human_table(store: store, "turn_ms" => 5000, "bank_ms" => 20_000)
      u.resume_clock(now)
      assert_equal [30_000, 0], [u.turn_ms, u.bank_ms], "the chosen fixed time, no bank"
      assert_equal [0] * 4, banks(u)
      assert_equal 30, u.public_view(now)["ru"][TURN]

      # no choice: the host's 5+20, the banks full
      d["rules"] = { "choice" => {}, "turn_ms" => nil }
      File.write(path, JSON.generate(d))
      w = human_table(store: store, "turn_ms" => 5000, "bank_ms" => 20_000)
      w.resume_clock(now)
      assert_equal [20_000] * 4, banks(w)
      assert_equal "play", w.status
      assert_equal seat, w.state.current_seat
    end
  end
end
