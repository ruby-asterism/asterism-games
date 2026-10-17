# frozen_string_literal: true

require_relative "test_helper"

# Whole games by four CPUs (MJ_GAMES hanchan, default 20, over MJ_PROCS
# processes, default 8): no exception, the points add up after every round,
# no seat ever sees another's hand, and every view fits in one message a
# board can take (4096 B with the Zenoh headers; LIMIT leaves room for them).
class TestMahjongGames < Minitest::Test
  include MahjongTestHelper

  LIMIT = 3800
  LEVELS = [1, 2, 3, 0].freeze # the help each seat's screen asks for (README "Assist")
  GAMES = Integer(ENV.fetch("MJ_GAMES", "20"))
  PROCS = [Integer(ENV.fetch("MJ_PROCS", "8")), GAMES].min

  def play_games(n)
    out = { "games" => 0, "rounds" => 0, "max_view" => 0, "max_public" => 0, "kinds" => Hash.new(0),
            "checks" => 0, "actions" => 0, "cpu_refused" => 0, "wt_views" => 0, "max_wt" => 0, "uk_views" => 0, "max_uk" => 0,
            "assist_ms" => [], "errors" => [] }
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
          level = LEVELS[seat]
          v = check_secrecy(t, seat, now, level)
          out["max_view"] = [out["max_view"], reply_bytes(v)].max
          out["checks"] += 1
          if v["wt"]
            out["wt_views"] += 1
            out["max_wt"] = [out["max_wt"], v["wt"].bytesize].max
            out["errors"] << "wt without riichi" if level == 1 && v["a"].none? { |t, _| t == E::RIICHI }
            out["errors"] << "wt without a discard" if v["a"].none? { |t, _| t == E::DAHAI }
          end
          if v["uk"]
            out["uk_views"] += 1
            out["max_uk"] = [out["max_uk"], v["uk"].bytesize].max
            out["errors"] << "uk below level 3" if level < 3
            out["errors"] << "uk with wt" if v["wt"]
          end
          out["errors"] << "help at level 0" if level.zero? && (v["wt"] || v["uk"])
        end
        out["max_public"] = [out["max_public"], reply_bytes(t.public_view(now))].max
        sv = t.view(-1, now) # a spectator: the four hands too
        out["max_spectator"] = [out["max_spectator"].to_i, reply_bytes(sv)].max
        out["errors"] << "a spectator sees offers" unless sv["a"] == []
        raise "too many steps" if steps > 2_000_000
      end
      out["games"] += 1
      # The game's record (README "Game records"): nothing missing from the
      # deal to the end, the points as played.
      rec = t.records_page["records"].first && t.record_of(t.records_page["records"].first["id"])
      if rec
        out["errors"].concat(record_problems(rec, t.instance_variable_get(:@final)))
        out["record_moves"] = out["record_moves"].to_i + rec["rounds"].sum { |r| r["moves"].size }
      else
        out["errors"] << "no record of the game"
      end
      out["assist_ms"].concat(t.assist_times)
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
      %w[games rounds actions checks cpu_refused wt_views uk_views].each { |k| a[k] += x[k] }
      a["record_moves"] += x["record_moves"].to_i
      a["max_view"] = [a["max_view"], x["max_view"]].max
      a["max_wt"] = [a["max_wt"], x["max_wt"]].max
      a["max_uk"] = [a["max_uk"], x["max_uk"]].max
      a["max_public"] = [a["max_public"], x["max_public"]].max
      a["max_spectator"] = [a["max_spectator"], x["max_spectator"].to_i].max
      x["kinds"].each { |k, v| a["kind_#{k}"] += v }
    end
    errors = results.flat_map { |x| x["errors"] }
    puts "\n  #{sum.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    ms = results.flat_map { |x| x["assist_ms"] }.sort
    unless ms.empty?
      puts "  assist: #{ms.size} computations, #{format('%.2f', ms[ms.size / 2])} / " \
           "#{format('%.2f', ms[ms.size * 95 / 100])} / #{format('%.2f', ms.last)} ms (median / 95% / max)"
    end
    assert_empty errors
    assert_equal GAMES, sum["games"]
    assert_operator sum["max_view"], :<, LIMIT
    assert_operator sum["max_spectator"], :<, LIMIT
    assert_operator sum["wt_views"], :>, 0 if GAMES >= 4
    assert_operator sum["uk_views"], :>, 0 if GAMES >= 4
  end

  HUMAN_GAMES = Integer(ENV.fetch("MJ_HUMAN_GAMES", "1"))
  AI = ::Mahjong::Cpu::Ai::NormalAi.new

  # What the engine's CPU would do with the seat's turn, as [type, bytes] (a
  # discard of the drawn tile when the CPU's choice is not offered).
  def discard_like_a_cpu(t, seat, offers)
    c = E.cpu_choice(t.state, seat, t.rule, AI)
    type = c && E::TYPE_OF[c[:type].to_sym]
    tiles = c ? (c[:tile] ? [c[:tile]] : Array(c[:tiles])) : []
    o = offers.find { |x, _| x == type }
    return [type, M::Tiles.pack(tiles).b] if o && E.match([[o[0], M::Tiles.unpack(o[1])]], type, tiles)
    d = offers.find { |x, _| x == E::DAHAI }
    [E::DAHAI, d[1].byteslice(d[1].bytesize - 1, 1)]
  end

  # Hanchan by four humans played through act (as four screens would): each
  # takes a win when offered, calls now and then, otherwise passes or
  # discards, and now and then sends something not offered (refused). After
  # every step no seat sees another's hand and every view fits.
  def test_four_human_hanchans
    rng = Random.new(7)
    sum = Hash.new(0)
    HUMAN_GAMES.times do
      t, toks = seated_table(4, "turn_ms" => 1000, "call_ms" => 1000, "over_ms" => 10**9)
      now = 0
      steps = 0
      until t.status == "over"
        acted = false
        toks.each do |seat, tok|
          v = check_secrecy(t, seat, now)
          sum["max_view"] = [sum["max_view"], reply_bytes(v)].max
          a = v["a"]
          next if a.empty?
          if rng.rand < 0.02
            assert_equal "not offered", t.act(tok, t.sv, E::RON, [], now) unless a.any? { |x, _| x == E::RON }
            sum["refused_checked"] += 1
          end
          types = a.map(&:first)
          pick = if (w = a.find { |x, _| [E::TSUMO_AGARI, E::RON, E::NEXT].include?(x) }) then [w[0], w[1]]
                 elsif types.include?(E::PON) && rng.rand < 0.4 then a.find { |x, _| x == E::PON }
                 elsif types.include?(E::CHI) && rng.rand < 0.3 then a.find { |x, _| x == E::CHI }
                 elsif types.include?(E::SKIP) then [E::SKIP, "".b]
                 elsif types.include?(E::DAHAI) then discard_like_a_cpu(t, seat, a)
                 end
          next unless pick && rng.rand < 0.8 # now and then nobody answers: the time runs out
          tiles = M::Tiles.unpack(pick[1])
          r = t.act(tok, t.sv, pick[0], tiles, now)
          assert_includes ["ok", "stale"], r, "seat #{seat} #{pick.inspect}"
          acted ||= r == "ok"
        end
        now += 50 unless acted
        t.tick(now)
        steps += 1
        raise "too many steps" if steps > 500_000
      end
      %w[rounds multi_human_calls double_ron round_sanchahou timeouts refused round_ron_agari round_tsumo_agari round_ryuukyoku].each { |k| sum[k] += t.stats[k] }
      sum["games"] += 1
      total = t.public_view(now)["fin"].sum { |f| f[2] }
      assert_operator total, :<=, 100_000
    end
    puts "\n  four humans: #{sum.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    assert_equal HUMAN_GAMES, sum["games"]
    assert_operator sum["multi_human_calls"], :>, 0
    assert_operator sum["max_view"], :<, LIMIT
  end

  # The largest view a seat can get: long names, full rivers, four kans
  # each, a long list of yaku. Built by hand on a real table.
  def test_worst_case_view_fits
    t, toks = seated_table(4)
    seat = toks.keys.first
    # sixteen members (four seated, twelve watching), 32-byte names
    12.times { |i| t.join("wasm-bbbb#{format('%02d', i)}", "名前" * 5 + "ab", 0) }
    st = t.state
    4.times do |s|
      t.instance_variable_get(:@seats)[s]["name"] = "名前" * 5 + "ab" # 32 bytes
      24.times { |i| st.kawas[s].add(Mahjong::Tiles::Tile.new(M::Tiles::NAMES[i % 37]), riichi: i == 3) }
      st.fuuros[s] = 4.times.map do |k|
        tile = Mahjong::Tiles::Tile.new("#{k + 1}z")
        Mahjong::State::Fuuro.new(type: :kakan, tiles: [tile] * 4, called_tile: tile, from_seat: (s + 1) % 4)
      end
    end
    # a triple ron (triple_ron_draw off), each with fourteen yaku
    win = { "agari" => "1z",
            "yaku" => %w[立直 一発 門前清自摸和 平和 断幺九 一盃口 三色同順 一気通貫 混全帯幺九 ドラ 裏ドラ 赤ドラ 海底摸月 嶺上開花].map { |y| "#{y} 13" },
            "yaku_han" => [13] * 14, # the han of each (README "Views": yh)
            "points" => "数え役満 48000点オール", "hand" => %w[1m 1m 1m 2m 3m 4m 5m 6m 7m 8m 9m 9m 9m],
            "pao" => [[0, "大三元"], [0, "大四喜"]] } # pao (README "Views": pa), more than a hand has
    res = { "kind" => "ron_agari", "delta" => [-99_000, 33_000, 33_000, 33_000], "round" => [1, 4, 9], "from" => 0,
            "wins" => [1, 2, 3].map { |w| win.merge("winner" => w) } }
    t.instance_variable_set(:@result, res)
    t.instance_variable_set(:@status, "result")
    t.instance_variable_set(:@final, [[0, 1, 99_999, 999], [1, 2, 99_999, 999], [2, 3, 99_999, 999], [3, 4, 99_999, 999]])
    t.instance_variable_set(:@final_reason, "all_last_oya_tenpai")
    v = t.view(seat, 0)
    bytes = reply_bytes(v)
    puts "\n  worst case view: #{bytes} B"
    assert_operator bytes, :<, LIMIT
    # A spectator's view of the same table (README "Spectators"): the four
    # hands besides, at their largest (fourteen tiles each, one drawn).
    sp = t.join("wasm-cccccc", "名前" * 5 + "ab", 0)["token"] || t.mine("wasm-bbbb00")["token"]
    4.times { |s| st.hands[s] = Mahjong::State::Hand.new(%w[1m 2m 3m 4p 5p 6p 7s 8s 9s 1z 1z 2s 3s 9m]) }
    st.phase = :dahai
    st.last_tsumo = Mahjong::Tiles::Tile.new("9m")
    sv = t.member_view(sp, 0)
    assert_equal 4, sv["sh"].size
    bytes = reply_bytes(sv)
    puts "  worst case spectator view: #{bytes} B (hands #{sv['sh'].sum(&:bytesize) + 4} B)"
    assert_operator bytes, :<, LIMIT
  end

  # The largest view while a seat may declare riichi: the same long names
  # and full rivers, the other three seats with four kans each, and the
  # riichi help (wt) at a size no hand reaches: fourteen discards with
  # thirteen waits each (a real hand has at most 14 riichi discards and 13
  # waits, kokushi; a nine-sided chuuren gives the most waits over all its
  # discards, measured below).
  def test_worst_case_riichi_view_fits
    t, toks = seated_table(4)
    seat = toks.keys.first
    12.times { |i| t.join("wasm-bbbb#{format('%02d', i)}", "名前" * 5 + "ab", 0) }
    st = t.state
    4.times do |s|
      t.instance_variable_get(:@seats)[s]["name"] = "名前" * 5 + "ab"
      24.times { |i| st.kawas[s].add(Mahjong::Tiles::Tile.new(M::Tiles::NAMES[i % 37]), riichi: i == 3) }
      next if s == seat
      st.fuuros[s] = 4.times.map do |k|
        tile = Mahjong::Tiles::Tile.new("#{k + 1}z")
        Mahjong::State::Fuuro.new(type: :kakan, tiles: [tile] * 4, called_tile: tile, from_seat: (s + 1) % 4)
      end
    end
    v = t.view(seat, 0)
    v["a"] = [[E::DAHAI, (0..13).to_a.pack("C*").b], [E::RIICHI, (0..13).to_a.pack("C*").b],
              [E::TSUMO_AGARI, "".b], [E::ANKAN, "\x01".b], [E::ANKAN, "\x02".b], [E::ANKAN, "\x03".b],
              [E::KYUUSHU, "".b]]
    v["dl"] = [15, 25_000, 20_000] # a move with a bank (README "Time")
    v["wt"] = 14.times.flat_map { |d| [d, 13] + 13.times.flat_map { |w| [w, 4] } }.pack("C*").b
    bytes = reply_bytes(v)
    puts "\n  worst case riichi view: #{bytes} B (wt #{v['wt'].bytesize} B)"
    assert_operator bytes, :<, LIMIT

    # A real hand with many waits: nine-sided chuuren and a drawn tile.
    s = st
    s.hands[seat] = Mahjong::State::Hand.new(%w[1m 1m 1m 2m 3m 4m 5m 6m 7m 8m 9m 9m 9m 5m])
    w = E.waits_after(s, seat, %w[1m 2m 3m 4m 5m 6m 7m 8m 9m])
    n = w.sum { |_d, ws| 2 + ws.size * 2 }
    puts "  chuuren: #{w.count { |_d, ws| ws.any? }} discards, #{w.sum { |_d, ws| ws.size }} waits, wt #{n} B"
    assert_operator n, :<, 14 * 28
  end
end
