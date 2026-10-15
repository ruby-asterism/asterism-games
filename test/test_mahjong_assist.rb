# frozen_string_literal: true

require_relative "test_helper"

# The screen's help by level (README "Assist"): which views get wt / uk,
# the shanten against riichi_engine's own count, the acceptance, the call
# with and without the level, and the largest help in one message.
class TestMahjongAssist < Minitest::Test
  include MahjongTestHelper

  SH = ::Mahjong::Cpu::Analysis::Shanten
  MJ = ::Mahjong::Scoring::Judges::MachiJudge
  LIMIT = 3800

  def tile(n) = Mahjong::Tiles::Tile.new(n)

  def give(state, seat, names)
    state.hands[seat] = Mahjong::State::Hand.new(names)
  end

  # A seated table at the seat's discard, its hand set to names (the last
  # one drawn).
  def at_discard(names, melds: [])
    t, toks = seated_table(1)
    seat = toks.keys.first
    now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat }
    s = t.state
    give(s, seat, names)
    s.fuuros[seat] = melds
    s.menzen_flags[seat] = melds.empty?
    s.last_tsumo = tile(names.last)
    4.times { |i| s.first_turn_flags[i] = false }
    t.instance_variable_set(:@assist, {})
    [t, seat, now, toks[seat]]
  end

  def counts(names)
    t = Array.new(34, 0)
    names.each { |n| t[Mahjong::Tiles::TileSet.tile_index(tile(n))] += 1 }
    t
  end

  def test_the_shanten_is_the_engines_for_closed_hands
    rng = Random.new(3)
    wall = (0...34).flat_map { |i| [i] * 4 }
    3000.times do
      t = Array.new(34, 0)
      wall.shuffle(random: rng).first(13).each { |i| t[i] += 1 }
      assert_equal SH.calculate(t.dup), E.shanten(t, 0), t.inspect
    end
  end

  # With melds the engine's count does not apply (it takes the hand as all
  # there is); tenpai here is what the wait judge says.
  def test_with_melds_shanten_zero_is_the_wait_judges_tenpai
    rng = Random.new(5)
    n = 0
    4000.times do
      k = rng.rand(1..3)
      t = Array.new(34, 0)
      (4 - k).times do
        if rng.rand < 0.5
          s = rng.rand(3)
          b = rng.rand(7)
          3.times { |j| t[s * 9 + b + j] += 1 }
        else
          t[rng.rand(34)] += 3
        end
      end
      t[rng.rand(34)] += 2
      i = (0...34).select { |x| t[x].positive? }.sample(random: rng)
      t[i] -= 1
      next if t.any? { |x| x >= 4 } # a wait on a fifth tile: tenpai by count, no wait
      n += 1
      assert_equal MJ.tenpai?(t), E.shanten(t, k).zero?, t.inspect
    end
    assert_operator n, :>, 1000
    # one meld: three sets and a single tile is tenpai, not 2-shanten
    assert_equal 0, E.shanten(counts(%w[1m 2m 3m 4p 5p 6p 7s 8s 9s 1z]), 1)
    assert_equal 2, SH.calculate(counts(%w[1m 2m 3m 4p 5p 6p 7s 8s 9s 1z]))
  end

  def test_acceptance_after_each_discard
    t, seat, = at_discard(%w[1m 2m 3m 4p 5p 6p 7s 8s 1z 2z 5m 7m 9p 4z])
    s = t.state
    # the rivers and melds of the random game so far would count too
    4.times do |i|
      s.kawas[i] = Mahjong::State::Kawa.new
      s.fuuros[i] = [] unless i == seat
    end
    s.kawas[1].add(tile("6m"))
    s.dora_hyouji = [tile("2z")]
    uk = E.ukeire_after(s, seat, %w[1z 9p])
    d, sh, list = uk.first
    assert_equal "1z", d
    assert_equal 2, sh
    left = list.to_h
    assert_equal 3, left["6m"]       # one in a river
    assert_equal 2, left["2z"]       # one in the hand, one the indicator
    assert_nil left["1z"]            # discarded: no help
    assert_operator list.size, :>, 5
  end

  def test_the_levels_in_the_view
    # one call (pon of 2z), no riichi; the hand after discarding 9p is tenpai on 6s-9s
    pon = Mahjong::State::Fuuro.new(type: :pon, tiles: [tile("2z")] * 3, called_tile: tile("2z"), from_seat: 1)
    t, seat, now = at_discard(%w[1m 2m 3m 4p 5p 6p 7s 8s 1z 1z 9p], melds: [pon])
    refute(t.view(seat, now, 1)["a"].any? { |x, _| x == E::RIICHI })
    assert_nil t.view(seat, now, 0)["wt"]
    assert_nil t.view(seat, now, 1)["wt"]
    v = t.view(seat, now, 2)
    b = v["wt"].bytes
    assert_equal [M::Tiles.code("9p"), 2, M::Tiles.code("6s"), M::Tiles.code("9s")], [b[0], b[1], b[2], b[4]]
    assert_equal 6, b.size
    assert_nil v["uk"]
    assert_nil t.view(seat, now, 3)["uk"], "tenpai: the waits, not the acceptance"
    # nobody else, and not the public view
    (0..3).each { |o| assert_nil t.view(o, now, 3)["wt"] unless o == seat }
    assert_nil t.public_view(now)["wt"]

    # not tenpai: level 3 gives the acceptance, 2 nothing
    t, seat, now = at_discard(%w[1m 2m 3m 4p 5p 6p 7s 8s 1z 2z 5m 7m 9p 3z])
    assert_nil t.view(seat, now, 2)["wt"]
    assert_nil t.view(seat, now, 2)["uk"]
    v = t.view(seat, now, 3)
    assert_nil v["wt"]
    uk = parse_uk(v["uk"])
    names = v["a"].find { |x, _| x == E::DAHAI }[1].bytes.uniq
    assert_equal names.sort, uk.keys.sort
    assert_equal 2, uk.values.map(&:first).min
    assert_operator uk[M::Tiles.code("1z")][1].size, :>, 0
  end

  def test_level_one_is_the_riichi_help_and_the_default
    t, seat, now, = at_discard(%w[1m 2m 3m 4p 5p 6p 7s 8s 9s 1z 1z 2s 3s 9m])
    assert_includes t.view(seat, now)["a"].map(&:first), E::RIICHI
    assert_equal t.view(seat, now, 1)["wt"], t.view(seat, now)["wt"]
    # level 2 also marks the riichi discard (the only tenpai discard here)
    assert_equal t.view(seat, now, 1)["wt"], t.view(seat, now, 2)["wt"]
    assert_nil t.view(seat, now, 0)["wt"]
  end

  def test_the_call_takes_the_level_or_not
    t, seat, now, tok = at_discard(%w[1m 2m 3m 4p 5p 6p 7s 8s 1z 2z 5m 7m 9p 3z])
    r = M::Remote.new(t, -> { now })
    assert_equal(-1, M::Remote::METHODS[:view])
    assert_nil r.view(tok)["uk"]
    refute_nil r.view(tok, 3)["uk"]
    assert_nil r.view(tok, 0)["uk"]
    refute_nil r.view(tok, 9)["uk"], "a level past 3 is 3"
    assert_nil r.view(tok, -2)["wt"]
    assert_equal({ "error" => "token" }, r.view("x", 3))
    assert_operator t.assist_times.size, :>, 0
  end

  def parse_uk(s)
    b = s.bytes
    out = {}
    i = 0
    while i + 2 < b.size
      n = b[i + 2]
      out[b[i]] = [b[i + 1], (0...n).map { |j| [b[i + 3 + 2 * j], b[i + 4 + 2 * j]] }]
      i += 3 + 2 * n
    end
    out
  end

  # The largest view with the acceptance: the long names and full rivers of
  # the worst case, the other three seats with four kans each, and uk at a
  # size no hand reaches (fourteen discards, each with all 34 kinds); and the
  # largest uk of random hands.
  def test_worst_case_acceptance_view_fits
    t, toks = seated_table(4)
    seat = toks.keys.first
    12.times { |i| t.join("wasm-bbbb#{format('%02d', i)}", "名前" * 5 + "ab", 0) }
    st = t.state
    4.times do |s|
      t.instance_variable_get(:@seats)[s]["name"] = "名前" * 5 + "ab"
      24.times { |i| st.kawas[s].add(tile(M::Tiles::NAMES[i % 37]), riichi: i == 3) }
      next if s == seat
      st.fuuros[s] = 4.times.map do |k|
        tl = tile("#{k + 1}z")
        Mahjong::State::Fuuro.new(type: :kakan, tiles: [tl] * 4, called_tile: tl, from_seat: (s + 1) % 4)
      end
    end
    v = t.view(seat, 0)
    v["a"] = [[E::DAHAI, (0..13).to_a.pack("C*").b], [E::RIICHI, (0..13).to_a.pack("C*").b],
              [E::TSUMO_AGARI, "".b], [E::ANKAN, "\x01".b], [E::ANKAN, "\x02".b], [E::ANKAN, "\x03".b],
              [E::KYUUSHU, "".b]]
    v["dl"] = [15, 25_000, 20_000] # a move with a bank (README "Time")
    v["uk"] = 14.times.flat_map { |d| [d, 6, 34] + 34.times.flat_map { |w| [w, 4] } }.pack("C*").b
    bytes = reply_bytes(v)
    puts "\n  worst case acceptance view: #{bytes} B (uk #{v['uk'].bytesize} B)"
    assert_operator bytes, :<, LIMIT

    rng = Random.new(11)
    wall = (0...34).flat_map { |i| [i] * 4 }
    worst = 0
    ms = []
    300.times do
      names = wall.shuffle(random: rng).first(14).map { |i| Mahjong::Tiles::TileSet.from_index(i) }
      give(st, seat, names)
      st.fuuros[seat] = []
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      uk = E.ukeire_after(st, seat, names.uniq)
      ms << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
      worst = [worst, uk.sum { |_d, _s, l| 3 + 2 * l.size }].max
    end
    ms.sort!
    puts "  random hands: uk at most #{worst} B; #{format('%.1f', ms[ms.size / 2])} / " \
         "#{format('%.1f', ms[ms.size * 95 / 100])} / #{format('%.1f', ms.last)} ms (median / 95% / max)"
    assert_operator worst, :<, 14 * 71
  end
end
