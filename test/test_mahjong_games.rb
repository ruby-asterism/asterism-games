# frozen_string_literal: true

require_relative "test_helper"

# Whole games by four CPUs (MJ_GAMES hanchan, default 20, over MJ_PROCS
# processes, default 8): no exception, the points add up after every round,
# no seat ever sees another's hand, and every view fits in one message a
# board can take (4096 B with the Zenoh headers; LIMIT leaves room for them).
class TestMahjongGames < Minitest::Test
  include MahjongTestHelper

  LIMIT = 3800
  GAMES = Integer(ENV.fetch("MJ_GAMES", "20"))
  PROCS = [Integer(ENV.fetch("MJ_PROCS", "8")), GAMES].min

  def play_games(n)
    out = { "games" => 0, "rounds" => 0, "max_view" => 0, "max_public" => 0, "kinds" => Hash.new(0),
            "checks" => 0, "actions" => 0, "cpu_refused" => 0, "errors" => [] }
    n.times do
      t = cpu_table
      now = 0
      steps = 0
      until t.status == "over"
        now += 10 unless t.step(now)
        steps += 1
        if t.status == "result" && t.instance_variable_get(:@result) != @last_result
          @last_result = t.instance_variable_get(:@result)
          total = @last_result && t.public_view(now)["sc"].sum + t.public_view(now)["r"][3] * 1000
          out["errors"] << "points add up to #{total}" if total != 100_000
          out["kinds"][@last_result["kind"]] += 1
        end
        4.times do |seat|
          v = check_secrecy(t, seat, now)
          out["max_view"] = [out["max_view"], reply_bytes(v)].max
          out["checks"] += 1
        end
        out["max_public"] = [out["max_public"], reply_bytes(t.public_view(now))].max
        raise "too many steps" if steps > 2_000_000
      end
      out["games"] += 1
      out["rounds"] += t.stats["rounds"]
      out["actions"] += t.stats["actions"]
      out["cpu_refused"] += t.stats["cpu_refused"]
    end
    out
  rescue Minitest::Assertion, StandardError => e
    out["errors"] << "#{e.class}: #{e.message} #{e.backtrace&.first(3)&.join(' | ')}"
    out
  end

  def test_cpu_hanchans
    per = Array.new(PROCS) { |i| GAMES / PROCS + (i < GAMES % PROCS ? 1 : 0) }
    readers = per.map do |n|
      r, w = IO.pipe
      pid = fork do
        r.close
        w.write(Marshal.dump(play_games(n)))
        w.close
        exit!(0)
      end
      w.close
      [pid, r]
    end
    results = readers.map do |pid, r|
      data = r.read
      Process.wait(pid)
      Marshal.load(data)
    end
    sum = results.each_with_object(Hash.new(0)) do |x, a|
      %w[games rounds actions checks cpu_refused].each { |k| a[k] += x[k] }
      a["max_view"] = [a["max_view"], x["max_view"]].max
      a["max_public"] = [a["max_public"], x["max_public"]].max
      x["kinds"].each { |k, v| a["kind_#{k}"] += v }
    end
    errors = results.flat_map { |x| x["errors"] }
    puts "\n  #{sum.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    assert_empty errors
    assert_equal GAMES, sum["games"]
    assert_operator sum["max_view"], :<, LIMIT
  end

  # The largest view a seat can get: long names, full rivers, four kans
  # each, a long list of yaku. Built by hand on a real table.
  def test_worst_case_view_fits
    t = human_table
    seat = t.sit("wasm-aaaaaa", "名" * 20, 0)["seat"]
    st = t.state
    4.times do |s|
      t.instance_variable_get(:@seats)[s]["name"] = "名前" * 5 + "ab" # 32 bytes
      24.times { |i| st.kawas[s].add(Mahjong::Tiles::Tile.new(M::Tiles::NAMES[i % 37]), riichi: i == 3) }
      st.fuuros[s] = 4.times.map do |k|
        tile = Mahjong::Tiles::Tile.new("#{k + 1}z")
        Mahjong::State::Fuuro.new(type: :kakan, tiles: [tile] * 4, called_tile: tile, from_seat: (s + 1) % 4)
      end
    end
    res = { "kind" => "tsumo_agari", "delta" => [-16_000, 48_000, -16_000, -16_000], "round" => [1, 4, 9],
            "winner" => 1, "from" => nil, "agari" => "1z",
            "yaku" => %w[立直 一発 門前清自摸和 平和 断幺九 一盃口 三色同順 一気通貫 混全帯幺九 ドラ 裏ドラ 赤ドラ 海底摸月 嶺上開花] .map { |y| "#{y} 13" },
            "points" => "数え役満 48000点オール", "hand" => %w[1m 1m 1m 2m 3m 4m 5m 6m 7m 8m 9m 9m 9m 1z] }
    t.instance_variable_set(:@result, res)
    t.instance_variable_set(:@status, "result")
    t.instance_variable_set(:@final, [[0, 1, 99_999, 999], [1, 2, 99_999, 999], [2, 3, 99_999, 999], [3, 4, 99_999, 999]])
    v = t.view(seat, 0)
    bytes = reply_bytes(v)
    puts "\n  worst case view: #{bytes} B"
    assert_operator bytes, :<, LIMIT
  end
end
