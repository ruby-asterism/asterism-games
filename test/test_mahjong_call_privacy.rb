# frozen_string_literal: true

require_relative "test_helper"

# The calls on a discard keep their secret (README "Calls on a discard"):
# nobody learns who else may call, or who has answered. Each seat sees its
# own choices only; the others' views, the spectators' and the put are the
# same whoever may call.
class TestMahjongCallPrivacy < Minitest::Test
  include MahjongTestHelper

  HONOURS = %w[1z 1z 2z 2z 3z 3z 4z 4z 5z 5z 6z 6z 7z].freeze
  RON = %w[2m 3m 4m 5p 6p 7p 3s 4s 5s 6s 7s 4p 4p].freeze   # seat 1: 8s by ron (tanyao)
  PON = %w[8s 8s 1m 9m 1p 9p 1s 9s 1z 2z 3z 4z 5z].freeze  # seat 3: a pon of 8s

  # Four members, a spectator; seat 2 discards 8s. pon: seat 3 may pon it
  # too (seat 1 may ron it either way). The seats are given their names
  # back in seat order so two tables compare.
  def table(pon:)
    t, toks = seated_table(4, "call_ms" => 5000, "result_ms" => 60_000)
    seats = t.instance_variable_get(:@seats)
    nodes = seats.map { |x| x["node"] }
    sp = t.join("wasm-cccccc", "W", 0)["token"]
    st = t.state
    E.apply(st, { type: :tsumo }, t.rule) while st.phase == :tsumo
    4.times { |i| st.first_turn_flags[i] = false }
    4.times { |i| st.hands[i] = Mahjong::State::Hand.new(HONOURS) }
    st.hands[1] = Mahjong::State::Hand.new(RON)
    st.hands[3] = Mahjong::State::Hand.new(PON) if pon
    st.hands[2] = Mahjong::State::Hand.new(%w[8s] + HONOURS)
    st.current_seat = 2
    st.phase = :dahai
    st.last_tsumo = Mahjong::Tiles::Tile.new("8s")
    st.dora_hyouji = [Mahjong::Tiles::Tile.new("1z")]
    assert_equal "ok", t.act(toks[2], t.sv, E::DAHAI, ["8s"], 0)
    assert_equal :naki_wait, st.phase
    [t, toks, sp, nodes]
  end

  # A view without what differs between two tables anyway (who sits where,
  # the members' names, the seat's own hand, and the four hands a spectator
  # sees: it plays no part).
  def neutral(v)
    v.reject { |k, _| %w[nm mb ow t h dt sh].include?(k) }
  end

  def views(t, sp, now)
    { 0 => t.view(0, now), 1 => t.view(1, now), 2 => t.view(2, now), :spec => t.member_view(sp, now),
      :put => t.spectator_view(now), :table => t.public_view(now) }
  end

  def test_each_seat_sees_its_own_choices_only
    t, = table(pon: true)
    assert_equal [E::RON, E::SKIP], t.view(1, 0)["a"].map(&:first)
    assert_equal [E::PON, E::SKIP], t.view(3, 0)["a"].map(&:first)
    [0, 2].each { |s| assert_equal [], t.view(s, 0)["a"] }
    assert_equal [0b0010, 5000], t.view(1, 0)["dl"], "its own bit"
    assert_equal [0b1000, 5000], t.view(3, 0)["dl"]
    assert_equal [0b1110, 5000], t.view(0, 0)["dl"], "the others are answering, whoever they are"
    assert_equal [0b1011, 5000], t.view(2, 0)["dl"]
    [t.public_view(0), t.spectator_view(0)].each { |v| assert_nil v["dl"], "nothing in the public view" }
    v = t.view(-1, 0)
    assert_nil v["dl"], "nothing for a spectator"
    assert_equal [], v["a"]
  end

  # A second candidate (seat 3) changes nothing in any view but its own,
  # before it answers and after: seat 1 (the other candidate), seats 0 and
  # 2, the spectator, the put and the public view are the same as at a
  # table where seat 3 could not call.
  def test_another_seat_that_may_call_changes_no_other_view
    a, toks_a, sp_a = table(pon: true)
    b, _toks_b, sp_b = table(pon: false)
    va = views(a, sp_a, 0)
    vb = views(b, sp_b, 0)
    va.each_key { |k| assert_equal neutral(vb[k]), neutral(va[k]), "#{k} before seat 3 answers" }

    a.save(0)
    pon = a.view(3, 100)["a"].find { |x, _| x == E::PON }
    assert_equal "ok", a.act(toks_a[3], a.sv, E::PON, M::Tiles.unpack(pon[1]), 100)
    assert_equal :naki_wait, a.state.phase, "seat 1 has not answered"
    refute a.dirty?, "no put for an answer"
    assert a.unsaved?, "but saved"
    va = views(a, sp_a, 100)
    vb = views(b, sp_b, 100)
    va.each_key { |k| assert_equal neutral(vb[k]), neutral(va[k]), "#{k} after seat 3 answered" }
    v3 = a.view(3, 100)
    assert_equal [], v3["a"], "its own buttons go"
    assert_equal a.public_view(100)["v"] + 1, v3["v"], "its own view moves on"
    assert_equal [0b0111, 4900], v3["dl"]
  end

  # Once decided, every view moves past what the answering seat saw, and
  # the screens ask again.
  def test_after_the_calls_every_version_moves_on
    t, toks, = table(pon: true)
    pon = t.view(3, 0)["a"].find { |x, _| x == E::PON }
    assert_equal "ok", t.act(toks[3], t.sv, E::PON, M::Tiles.unpack(pon[1]), 10)
    seen = t.view(3, 10)["v"]
    assert_equal "ok", t.act(toks[1], t.sv, E::SKIP, [], 20)
    assert_equal 3, t.state.current_seat, "the pon stood"
    assert_operator t.public_view(20)["v"], :>, seen
    assert_equal t.public_view(20)["v"], t.view(3, 20)["v"]
  end

  # When everybody passed, the last event does not name a seat that could
  # have called.
  def test_the_passes_name_nobody
    t, toks, = table(pon: true)
    assert_equal "ok", t.act(toks[3], t.sv, E::SKIP, [], 10)
    assert_equal "ok", t.act(toks[1], t.sv, E::SKIP, [], 20)
    refute_equal :naki_wait, t.state.phase
    ev = t.public_view(20)["ev"]
    refute(ev && ev[0] == E::SKIP && ev[1] >= 0, "the event #{ev.inspect} names a seat")
  end

  # The same over whole games: at every step of four-member hanchan no
  # view but a candidate's own carries a bit of another seat that may still
  # call, and no seat's offers show in another view.
  def test_over_games_no_view_shows_another_candidate
    t, toks = seated_table(4, "call_ms" => 1000, "turn_ms" => 1000, "result_ms" => 0, "over_ms" => 10**9)
    sp = t.join("wasm-cccccc", "W", 0)["token"]
    now = 0
    windows = 0
    rng = Random.new(5)
    until t.status == "over" || now > 6_000_000
      if t.status == "play" && t.state.phase == :naki_wait
        windows += 1
        pend = t.state.pending_actions.keys
        4.times do |s|
          v = t.view(s, now)
          dl = v["dl"]
          next unless dl
          mine = pend.include?(s) && !t.instance_variable_get(:@decl).key?(s)
          assert_equal(mine ? 1 << s : 0b1111 & ~(1 << s), dl[0], "seat #{s}'s dl")
        end
        [t.member_view(sp, now), t.spectator_view(now), t.public_view(now)].each do |v|
          assert_nil v["dl"]
          assert_equal [], v["a"] if v.key?("a")
        end
      end
      acted = false
      4.times do |s|
        a = t.view(s, now)["a"]
        next if a.empty?
        o = a.find { |x, _| [E::TSUMO_AGARI, E::RON, E::NEXT].include?(x) } ||
            (rng.rand < 0.3 && a.find { |x, _| [E::PON, E::CHI].include?(x) }) ||
            a.find { |x, _| x == E::SKIP } || a.find { |x, _| x == E::DAHAI }
        next unless o
        tiles = o[0] == E::DAHAI ? [M::Tiles.unpack(o[1]).last] : M::Tiles.unpack(o[1])
        tiles = [] if [E::TSUMO_AGARI, E::RON, E::NEXT, E::SKIP].include?(o[0])
        acted = true if t.act(toks[s], t.sv, o[0], tiles, now) == "ok"
        break
      end
      now += 10 unless acted
      t.tick(now)
    end
    assert_operator windows, :>, 10
  end
end
