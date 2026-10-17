# frozen_string_literal: true

# Two ways to run (Rakefile):
#   rake test       every test: the gem's files (lib/) and the image's
#                   games (app/: mahjong, with riichi_engine)
#   rake test:gem   what the gem holds only (ASTERISM_GAMES_TEST_GEM=1):
#                   lib/ alone on the load path, mahjong never loaded
GEM_ONLY = ENV["ASTERISM_GAMES_TEST_GEM"] == "1"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../app", __dir__) unless GEM_ONLY
require "minitest/autorun"
require "tmpdir"
require "asterism"
require "asterism_games"
# mahjong first, as bin/asterism-games does (the default game).
require "asterism_games/mahjong" unless GEM_ONLY
require "asterism_games/othello"
require "asterism_games/board"

module GamesTestHelper
  # The bytes a view takes as the answer of a call: the reply payload
  # {"value" => view} and a call key with long names.
  CALL_KEY = "asterism/games-host-aaaaaa/games/mahjong1/call/wasm-aaaaaa"

  def reply_bytes(v)
    Asterism::Codec.pack({ "value" => v }).bytesize + CALL_KEY.bytesize
  end
end

module MahjongTestHelper
  include GamesTestHelper
  M = AsterismGames::Mahjong unless GEM_ONLY
  E = M::Engine unless GEM_ONLY
  CALL_KEY = GamesTestHelper::CALL_KEY

  def cpu_table(**opts)
    M::Table.new("t", { "humans" => 0, "cpu_ms" => 0, "result_ms" => 0 }.merge(opts.transform_keys(&:to_s)))
  end

  # A table with humans; a fixed time per move (no bank) unless bank_ms is
  # given.
  def human_table(store: nil, **opts)
    M::Table.new("t", { "cpu_ms" => 0, "result_ms" => 0, "turn_ms" => 1000, "bank_ms" => 0,
                        "call_ms" => 1000 }.merge(opts.transform_keys(&:to_s)), store: store)
  end

  # A game with n human members seated (nodes "wasm-aaaaa0".. ), the other
  # seats CPUs, started by the first. Returns [table, {seat => token}].
  def seated_table(n = 1, store: nil, now: 0, **opts)
    t = human_table(store: store, **opts)
    tokens = (0...n).map do |i|
      tok = t.join("wasm-aaaaa#{i}", "P#{i}", now)["token"]
      assert_equal "ok", t.sit(tok, -1, now)
      tok
    end
    t.cpu(tokens[0], -1, true) if n < 4
    assert_equal "ok", t.start(tokens[0], now)
    [t, tokens.to_h { |tok| [t.seat_of(tok), tok] }]
  end
  # What is wrong with a game record (README "Game records"), [] when
  # nothing: every round replayed from its deal by its moves (each discard
  # and call from the hand that holds it, the called tile the last
  # discard, the hand's size after each discard), the wins' hands as the
  # moves leave them, no tile more than four times, the points from round
  # to round (each seat's change by the result and its riichi stick) and
  # the final scores. final: the table's own final ranks, when given.
  def record_problems(rec, final = nil)
    out = []
    prev = nil
    rounds = rec["rounds"] || []
    out << "no rounds" if rounds.empty?
    rounds.each_with_index do |r, ri|
      tag = "record #{rec['id']} round #{ri}"
      out << "#{tag}: the scores do not follow the round before" if prev && r["scores"] != prev
      hands = r["hands"].map(&:dup)
      out << "#{tag}: the deal" unless hands.all? { |h| h.size == 13 }
      shown = []
      melds = [0, 0, 0, 0]
      riichi = []
      last = nil
      res = r["result"]
      out << "#{tag}: no result" unless res
      take = lambda do |seat, tile, what|
        i = hands[seat].index(tile)
        if i
          hands[seat].delete_at(i)
        else
          out << "#{tag}: #{what} #{tile} not in seat #{seat}'s hand"
        end
      end
      r["moves"].each do |m|
        seat, kind = m
        case kind
        when "draw" then hands[seat] << m[2]
        when "discard", "riichi"
          take.call(seat, m[2], kind)
          out << "#{tag}: seat #{seat} holds #{hands[seat].size} after a discard" unless hands[seat].size + melds[seat] * 3 == 13
          riichi << seat if kind == "riichi"
          shown << m[2]
          last = [seat, m[2]]
        when "chi", "pon", "open_kan"
          out << "#{tag}: #{kind} of #{m[2]} from #{m[4]}, not the last discard #{last.inspect}" unless last == [m[4], m[2]]
          m[3].each { |x| take.call(seat, x, kind) }
          shown.pop
          shown.concat(m[3] + [m[2]])
          melds[seat] += 1
        when "closed_kan"
          m[2].each { |x| take.call(seat, x, kind) }
          shown.concat(m[2])
          melds[seat] += 1
        when "added_kan"
          take.call(seat, m[2], kind)
          shown << m[2]
        when "dora" then shown << m[2]
        when "tsumo"
          w = res && Array(res["wins"]).find { |x| x["seat"] == seat }
          h = hands[seat].dup
          h.delete_at(h.index(m[2]) || h.size)
          out << "#{tag}: tsumo hand #{h.sort} / #{w && w['hand'].sort}" unless w && plain(w["hand"]) == plain(h)
        when "ron"
          w = res && Array(res["wins"]).find { |x| x["seat"] == seat }
          if res && res["kind"] == "ron_agari"
            out << "#{tag}: ron hand #{hands[seat].sort} / #{w && w['hand'].sort}" unless w && plain(w["hand"]) == plain(hands[seat])
            out << "#{tag}: ron on #{m[2]} from #{m[3]}, not the last discard #{last.inspect}" if last != [m[3], m[2]] && !r["moves"].any? { |x| x[1] == "added_kan" }
          end
        when "nine_kinds" then nil
        else out << "#{tag}: unknown move #{m.inspect}"
        end
      end
      counts = Hash.new(0)
      (hands.flatten + shown + r["dora_indicators"]).each { |x| counts[x.sub("0", "5")] += 1 }
      counts.each { |k, n| out << "#{tag}: #{n} of #{k}" if n > 4 }
      next unless res
      ends = r["end_scores"]
      out << "#{tag}: points add up to #{ends.sum + r['end_sticks'] * 1000}" if ends.sum + r["end_sticks"].to_i * 1000 != 100_000
      voided = res["kind"] == "ron_agari" && last && riichi.include?(last[0]) &&
               r["moves"].reverse.find { |x| %w[discard riichi].include?(x[1]) }&.at(1) == "riichi"
      4.times do |s|
        stick = riichi.include?(s) && !(voided && s == last[0]) ? -1000 : 0
        got = ends[s] - r["scores"][s] - res["changes"][s]
        out << "#{tag}: seat #{s} #{r['scores'][s]} + #{res['changes'][s]} #{stick} -> #{ends[s]}" unless got == stick
      end
      prev = ends
    end
    fin = rec["final"]
    if fin && prev
      left = rounds.last["end_sticks"].to_i * 1000
      want = prev.dup
      top = fin.min_by { |f| f[1] }[0]
      want[top] += left
      fin.each { |seat, _rank, score, _| out << "final score of seat #{seat}: #{score}, the record leads to #{want[seat]}" if score != want[seat] }
    end
    out << "final #{fin.inspect} / the table's #{final.inspect}" if final && fin != final
    out
  end

  # Tile names with the red fives as fives, sorted: riichi_engine's winning
  # hand may show the red five it won on in place of a plain five of the
  # hand (it takes the winning tile out by its kind).
  def plain(names)
    names.map { |x| x.sub("0", "5") }.sort
  end

  # Advances a table until the block is true (or the steps run out).
  def run_until(table, now, limit: 200_000)
    limit.times do
      return now if yield
      now += 10
      table.tick(now)
    end
    flunk "condition not reached"
  end

  # The keys a seat's view may have beyond the public view.
  SEAT_KEYS = %w[me h dt a wt uk].freeze

  # Checks one seat's view against the state: its own hand and nothing of
  # any other hand.
  def check_secrecy(table, seat, now, assist = M::Table::ASSIST_DEFAULT)
    v = table.view(seat, now, assist)
    pub = table.public_view(now)
    assert_equal [], (v.keys - pub.keys - SEAT_KEYS), "unexpected keys in a seat's view"
    assert_nil pub["h"], "a hand in the public view"
    return v unless table.status == "play"
    mine = table.state.hands[seat].tiles.map(&:to_s)
    shown = M::Tiles.unpack(v["h"])
    shown << M::Tiles.name(v["dt"]) if v["dt"] >= 0
    assert_equal mine.sort, shown.sort, "seat #{seat} sees a hand that is not its own"
    v
  end
end
