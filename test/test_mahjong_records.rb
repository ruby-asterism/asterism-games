# frozen_string_literal: true

require_relative "test_helper"

# Game records (README "Game records"): what a game leaves when it ends,
# kept across a restart of the host, the newest RECORDS_KEPT of a table,
# the remote's records / record within one message, the last result on the
# host's @status, and the declarations a screen shows at the seat ("cl").
class TestMahjongRecords < Minitest::Test
  include MahjongTestHelper

  LIMIT = 3800

  def tonpuu_table(store: nil, **opts)
    cpu_table(store: store, "rule" => { "game_type" => "tonpuu" }, **opts)
  end

  def cpu_table(store: nil, **opts)
    M::Table.new("t", { "humans" => 0, "cpu_ms" => 0, "result_ms" => 0 }.merge(opts.transform_keys(&:to_s)), store: store)
  end

  def play_out(t, now = 0)
    until t.status == "over"
      now += 10 unless t.step(now)
    end
    now
  end

  def test_a_game_leaves_its_whole_record
    t = tonpuu_table
    assert_equal({ "records" => [], "total" => 0 }, t.records_page)
    play_out(t)
    page = t.records_page
    assert_equal 1, page["total"]
    e = page["records"].first
    assert_equal 1, e["id"]
    assert_equal "tonpuu", e["game"]
    assert_equal 4, e["names"].size
    assert_equal [1, 2, 3, 4], e["ranks"].sort
    rec = t.record_of(1)
    assert_empty record_problems(rec, t.instance_variable_get(:@final))
    assert_equal t.stats["rounds"], rec["rounds"].size
    assert_match(/\A\d{4}-\d\d-\d\d \d\d:\d\d\z/, rec["at"])
    # Every round: the deal, a draw first (the dealer), a result.
    rec["rounds"].each do |r|
      assert_equal r["dealer"], r["moves"].first[0]
      assert_equal "draw", r["moves"].first[1]
      assert r["result"]["kind"]
    end
    # The tile names of look.
    names = M::Tiles::NAMES - ["back"]
    rec["rounds"].each { |r| r["hands"].flatten.each { |x| assert_includes names, x } }
  end

  def test_the_record_goes_on_across_a_restart
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t = tonpuu_table(store: store)
      now = 0
      # Into the second round and a few moves of it, then the host stops.
      until t.stats["rounds"] >= 1 && t.status == "play" && t.state.junme >= 3
        now += 10 unless t.step(now)
      end
      t.save(now, force: true)
      before = t.instance_variable_get(:@rec)["rounds"].last["moves"].size
      assert_operator before, :>, 0
      u = tonpuu_table(store: store)
      assert_equal before, u.instance_variable_get(:@rec)["rounds"].last["moves"].size, "the moves so far come back"
      play_out(u)
      rec = u.record_of(1)
      assert_empty record_problems(rec, u.instance_variable_get(:@final))
      # Written: a third host reads it without a game.
      w = M::Table.new("t", { "humans" => 4 }, store: store)
      assert_equal rec, w.record_of(1)
      assert File.exist?(store.path("t.records")), "next to the table's own state"
    end
  end

  def test_the_twenty_newest_are_kept
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t = cpu_table(store: store, "humans" => 4)
      22.times do |i|
        t.instance_variable_set(:@rec, { "names" => %w[a b c d], "game" => "tonpuu", "rounds" => [{ "moves" => [] }] })
        t.instance_variable_set(:@final, [[0, 1, 30_000 + i, 0], [1, 2, 25_000, 0], [2, 3, 25_000, 0], [3, 4, 20_000 - i, 0]])
        t.record_game_end
      end
      page = t.records_page
      assert_equal 20, page["total"]
      assert_equal (3..22).to_a.reverse, page["records"].map { |e| e["id"] } + (page["next"] ? t.records_page(page["next"])["records"].map { |e| e["id"] } : [])
      assert_equal({ "error" => "no record" }, t.record_answer(2))
      assert_equal 22, t.record_answer(22)["id"]
      u = cpu_table(store: store, "humans" => 4)
      assert_equal 20, u.records_page["total"], "the file holds the twenty"
      t.instance_variable_set(:@rec, { "names" => %w[a b c d], "game" => "tonpuu", "rounds" => [] })
      t.record_game_end
      assert_equal 23, t.records_page["records"].first["id"], "the numbers go on"
    end
  end

  def test_without_a_database_a_closed_room_takes_its_records_with_it
    Dir.mktmpdir do |dir|
      cfg = AsterismGames::Config.new({ "state_dir" => File.join(dir, "state"),
                                        "rooms" => { "dir" => File.join(dir, "rooms"), "max" => 2 } }, {})
      FileUtils.mkdir_p(File.join(dir, "rooms", "certs"))
      File.write(File.join(dir, "rooms", "certs", "room-01.tar"), "")
      spawned = []
      rooms = AsterismGames::Rooms.new(cfg, log: ->(_m) {}, clock: -> { 1000.0 },
                                            spawn: lambda { |slot, c|
                                              spawned << [slot, c]
                                              fork { sleep 30 }
                                            })
      path = File.join(dir, "rooms", "rooms.json")
      File.write(path, JSON.generate({ "format" => 1, "slots" => { "01" => { "room" => "aaaa", "until" => 99_999, "max" => 16,
                                                                               "app" => "/app/game/mahjong/mahjong.app.rb" } } }))
      rooms.check(1000)
      d = spawned.last[1]["state_dir"]
      # The room's host keeps its tables' records in its own store.
      t = M::Table.new("mahjong1", { "humans" => 4 }, store: AsterismGames::Store.new(d))
      t.instance_variable_set(:@rec, { "names" => %w[a b c d], "game" => "tonpuu", "rounds" => [] })
      t.instance_variable_set(:@final, [[0, 1, 25_000, 0], [1, 2, 25_000, 0], [2, 3, 25_000, 0], [3, 4, 25_000, 0]])
      t.record_game_end
      assert File.exist?(File.join(d, "mahjong1.records.json"))
      File.write("#{path}.tmp", JSON.generate({ "format" => 1, "slots" => {}, "revoked" => [{ "room" => "aaaa", "until" => 99_999 }] }))
      File.rename("#{path}.tmp", path)
      tm = Time.now + 5
      File.utime(tm, tm, path)
      rooms.check(1001)
      refute File.exist?(File.join(d, "mahjong1.records.json")), "the room's records go with the room"
      rooms.stop_all
    end
  end

  def test_the_answers_fit_one_message
    t = tonpuu_table
    play_out(t)
    long = "名前名前名前名前名前ab" # 32 bytes, the longest name
    rec = t.record_of(1)
    # Twenty games of four long names: the list in pages that fit.
    19.times do
      t.instance_variable_set(:@rec, Marshal.load(Marshal.dump(rec)).merge("names" => [long] * 4))
      t.instance_variable_set(:@final, rec["final"])
      t.record_game_end
    end
    seen = []
    from = 0
    loop do
      page = t.records_page(from)
      assert_operator reply_bytes(page), :<, LIMIT
      seen.concat(page["records"].map { |e| e["id"] })
      break unless page["next"]
      from = page["next"]
    end
    assert_equal (1..20).to_a.reverse, seen
    head = t.record_answer(20)
    assert_operator reply_bytes(head), :<, LIMIT
    assert_equal rec["rounds"].size, head["rounds"].size
    assert_equal %w[id at time table game rules names kinds final reason rounds].sort, head.keys.sort
    rec["rounds"].each_index do |i|
      r = t.record_answer(20, i)
      assert_operator reply_bytes(r), :<, LIMIT
      assert_equal [i, rec["rounds"].size], [r["round"], r["of"]]
      moves = r["moves"]
      (1...r["parts"]).each { |k| moves += t.record_answer(20, i, k)["moves"] }
      assert_equal rec["rounds"][i]["moves"], moves
    end
    assert_equal({ "error" => "no round" }, t.record_answer(20, 99))
  end

  def test_a_long_round_comes_in_parts
    t = tonpuu_table
    play_out(t)
    rec = t.record_of(1)
    r = rec["rounds"].max_by { |x| x["moves"].size }
    # Pad the round's moves to three times the room of one answer.
    pad = []
    pad.concat(r["moves"]) while t.wire_size(pad) < M::Table::RECORD_BYTES * 3
    r["moves"] = pad
    i = rec["rounds"].index(r)
    first = t.record_answer(1, i)
    assert_operator first["parts"], :>=, 3
    assert first["hands"], "the first part has the deal"
    moves = []
    first["parts"].times do |k|
      part = k.zero? ? first : t.record_answer(1, i, k)
      assert_operator reply_bytes(part), :<, LIMIT
      assert_equal k, part["part"]
      assert_equal moves.size, part["move_from"]
      moves.concat(part["moves"])
    end
    assert_equal pad, moves
    assert_equal({ "error" => "no part" }, t.record_answer(1, i, first["parts"]))
  end

  def test_the_remote_reads_them
    t = tonpuu_table
    play_out(t)
    r = M::Remote.new(t, -> { 0 })
    assert_equal t.records_page, r.records(from: "node")
    assert_equal t.records_page(0), r.records(0, from: "node")
    assert_equal t.record_answer(1), r.record(1, from: "node")
    assert_equal t.record_answer(1, 0), r.record(1, 0, from: "node")
    assert_equal({ "error" => "id" }, r.record(from: "node"))
  end

  def test_the_last_result_on_the_status
    Dir.mktmpdir do |dir|
      cfg = AsterismGames::Config.new({ "state_dir" => dir, "node" => "games-host", "app" => "games",
                                        "tables" => [{ "name" => "mahjong1", "game" => "mahjong", "humans" => 0,
                                                       "cpu_ms" => 0, "result_ms" => 0,
                                                       "rule" => { "game_type" => "tonpuu" } }] }, {})
      host = AsterismGames::Host.new(cfg, log: ->(_m) {})
      g = host.games["mahjong1"]
      refute host.tables_status["mahjong1"].key?("last")
      play_out(g)
      st = host.tables_status["mahjong1"]
      last = st["last"]
      assert_equal 1, last["id"]
      assert_equal [1, 2, 3, 4], last["result"].map { |x| x[1] }
      fin = g.instance_variable_get(:@final).sort_by { |f| f[1] }
      assert_equal fin.map { |f| f[2] }, last["result"].map { |x| x[2] }
      assert_equal fin.map { |f| g.record_of(1)["names"][f[0]] }, last["result"].map { |x| x[0] }
      text = JSON.generate(st)
      refute_match(/token|node/, text)
      # The rooms' status file stays counts only.
      refute g.summary(0).key?("last")
    end
  end

  def test_the_declaration_is_in_the_view_with_its_seat
    seen = Hash.new(0)
    3.times do
      t = cpu_table
      now = 0
      last = nil
      until t.status == "over"
        now += 10 unless t.step(now)
        cl = t.public_view(now)["cl"]
        next if cl.nil? || cl == last
        last = cl
        type, sv, *seats = cl
        assert_includes [E::RIICHI, E::PON, E::CHI, E::DAIMINKAN, E::ANKAN, E::KAKAN, E::TSUMO_AGARI, E::RON,
                         E::KYUUSHU, E::SANCHAHOU], type
        assert_kind_of Integer, sv
        refute_empty seats
        seats.each { |s| assert_includes 0..3, s }
        seen[type] += 1
      end
    end
    assert_operator seen[E::RIICHI], :>, 0
    assert_operator seen[E::PON] + seen[E::CHI], :>, 0
    assert_operator seen[E::TSUMO_AGARI] + seen[E::RON], :>, 0
  end

  # ------------------------------------------------------------ SQLite (0.14.0)

  def db_table(dir, name: "t", store: nil, **opts)
    cpu_table(store: store || AsterismGames::Store.new(dir), "rule" => { "game_type" => "tonpuu" },
              "records_db" => File.join(dir, "records.sqlite3"), **opts).tap { |t| t.instance_variable_set(:@name, name) if name != "t" }
  end

  def teardown
    AsterismGames::RecordBook::Database.close_all if AsterismGames::RecordBook.sqlite?
  end

  def test_sqlite_keeps_the_records_for_the_next_host
    skip "no sqlite3" unless AsterismGames::RecordBook.sqlite?
    Dir.mktmpdir do |dir|
      t = db_table(dir)
      assert_equal "sqlite", t.book.kind
      play_out(t)
      page = t.records_page
      assert_equal 1, page["total"]
      id = page["records"][0]["id"]
      rec = t.record_of(id)
      assert_empty record_problems(rec, t.instance_variable_get(:@final))
      assert_equal %w[id at time table game rules names kinds final reason rounds].sort, t.record_answer(id).keys.sort
      refute File.exist?(File.join(dir, "t.records.json")), "no JSON next to a database"
      last = t.last_result
      AsterismGames::RecordBook::Database.close_all
      u = M::Table.new("t", { "humans" => 4, "records_db" => File.join(dir, "records.sqlite3") }, store: AsterismGames::Store.new(dir))
      assert_equal rec, u.record_of(id)
      assert_equal last, u.last_result
      assert File.exist?(File.join(dir, "records-backup.sqlite3")), "the copy for the backup"
    end
  end

  def test_sqlite_keeps_the_thousand_newest
    skip "no sqlite3" unless AsterismGames::RecordBook.sqlite?
    Dir.mktmpdir do |dir|
      t = db_table(dir, "humans" => 4)
      base = { "names" => %w[a b c d], "kinds" => %w[human human cpu cpu], "game" => "tonpuu", "rounds" => [],
               "final" => [[0, 1, 30_000, 500], [1, 2, 25_000, 100], [2, 3, 25_000, -100], [3, 4, 20_000, -500]] }
      t.book.import(1003.times.map { |i| base.merge("at" => "2026-10-18 00:00", "time" => 1_800_000_000 + i, "n" => i) })
      assert_equal 1000, t.records_page["total"]
      assert_equal 1002, t.record_of(t.records_page["records"][0]["id"])["n"]
      t.instance_variable_set(:@rec, base.dup)
      t.instance_variable_set(:@final, base["final"])
      t.record_game_end
      assert_equal 1000, t.records_page["total"]
      # The pages walk the thousand (each within one message).
      seen = 0
      from = 0
      while from
        pg = t.records_page(from)
        assert_operator reply_bytes(pg), :<, LIMIT
        seen += pg["records"].size
        from = pg["next"]
      end
      assert_equal 1000, seen
    end
  end

  def test_the_json_records_are_taken_in_once
    skip "no sqlite3" unless AsterismGames::RecordBook.sqlite?
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      j = tonpuu_table(store: store) # 0.13.0: the JSON file
      2.times do
        play_out(j)
        j.instance_variable_set(:@status, "wait")
        j.start_game(0)
      end
      old = j.records_page
      assert_equal 2, old["total"]
      olds = [2, 1].map { |i| j.record_of(i) }
      t = db_table(dir)
      page = t.records_page
      assert_equal 2, page["total"]
      assert_equal old["records"].map { |e| e.except("id") }, page["records"].map { |e| e.except("id") }
      page["records"].each_with_index do |e, i|
        assert_equal olds[i].except("id"), t.record_of(e["id"]).except("id"), "the same game"
      end
      refute File.exist?(store.path("t.records"))
      assert File.exist?("#{store.path('t.records')}.imported")
      AsterismGames::RecordBook::Database.close_all
      assert_equal 2, db_table(dir).records_page["total"], "taken in once"
    end
  end

  def test_a_closed_rooms_records_stay_for_the_stats_and_nobody_else_reads_them
    skip "no sqlite3" unless AsterismGames::RecordBook.sqlite?
    Dir.mktmpdir do |dir|
      cfg = AsterismGames::Config.new({ "state_dir" => File.join(dir, "state"),
                                        "rooms" => { "dir" => File.join(dir, "rooms"), "max" => 2 } }, {})
      FileUtils.mkdir_p(File.join(dir, "rooms", "certs"))
      %w[01 02].each { |s| File.write(File.join(dir, "rooms", "certs", "room-#{s}.tar"), "") }
      spawned = {}
      rooms = AsterismGames::Rooms.new(cfg, log: ->(_m) {}, clock: -> { 1000.0 },
                                            spawn: lambda { |slot, c|
                                              spawned[slot] = c
                                              fork { sleep 30 }
                                            })
      path = File.join(dir, "rooms", "rooms.json")
      app = "/app/game/mahjong/mahjong.app.rb"
      File.write(path, JSON.generate({ "format" => 1, "slots" => { "01" => { "room" => "aaaa", "until" => 99_999, "app" => app },
                                                                   "02" => { "room" => "bbbb", "until" => 99_999, "app" => app } } }))
      rooms.check(1000)
      c1 = spawned["01"]
      assert_equal File.join(dir, "state", "records.sqlite3"), c1["records_db"], "the supervisor's database"
      assert_equal "room", c1["records_place"]
      opts = ->(c) { { "humans" => 0, "cpu_ms" => 0, "result_ms" => 0, "rule" => { "game_type" => "tonpuu" } }.merge(c.slice("room_id", "records_db", "records_place")) }
      t1 = M::Table.new("mahjong1", opts.call(c1), store: AsterismGames::Store.new(c1["state_dir"]))
      play_out(t1)
      id = t1.records_page["records"][0]["id"]
      t2 = M::Table.new("mahjong1", opts.call(spawned["02"]), store: AsterismGames::Store.new(spawned["02"]["state_dir"]))
      perm = M::Table.new("mahjong1", { "humans" => 4, "records_db" => c1["records_db"], "records_place" => "permanent" },
                          store: AsterismGames::Store.new(File.join(dir, "state", "permanent")))
      lan = M::Table.new("mahjong1", { "humans" => 4, "records_db" => c1["records_db"] }, store: AsterismGames::Store.new(dir))
      [t2, perm, lan].each do |o|
        assert_equal 0, o.records_page["total"], "another room's or the permanent table's recent results"
        assert_equal({ "error" => "no record" }, o.record_answer(id))
        assert_nil o.last_result
      end
      # Closed: the room's directory goes, its games stay.
      File.write("#{path}.tmp", JSON.generate({ "format" => 1, "slots" => { "02" => { "room" => "bbbb", "until" => 99_999, "app" => app } },
                                                "revoked" => [{ "room" => "aaaa", "until" => 99_999 }] }))
      File.rename("#{path}.tmp", path)
      tm = Time.now + 5
      File.utime(tm, tm, path)
      rooms.check(1001)
      refute File.exist?(c1["state_dir"]), "the room's saved tables go"
      AsterismGames::RecordBook::Database.close_all
      db = SQLite3::Database.new(c1["records_db"])
      assert_equal [[id, "room", "aaaa", "mahjong1"]], db.execute("SELECT id, place, room, tbl FROM games")
      db.close
      perm = M::Table.new("mahjong1", { "humans" => 4, "records_db" => c1["records_db"], "records_place" => "permanent" },
                          store: AsterismGames::Store.new(File.join(dir, "state", "permanent")))
      assert_equal 0, perm.records_page["total"]
      # The stats count it everywhere (names and numbers), "table" only its room's.
      assert_equal 1, perm.stats_answer(0, "", "all")["games"]
      assert_equal 0, perm.stats_answer(0, "", "table")["games"]
      refute_match(/"moves"|"hands"/, JSON.generate(perm.stats_answer))
      rooms.stop_all
    end
  end

  # The stats as the records count them, counted here another way: the
  # wins from the moves (tsumo / ron, not at a sanchahou), a deal-in per
  # round from a ron move's seat, riichi from the moves.
  def expected_stats(recs)
    out = Hash.new { |h, k| h[k] = { "games" => 0, "ranks" => [0, 0, 0, 0], "rounds" => 0, "wins" => 0, "dealins" => 0, "riichi" => 0, "score" => 0, "points" => 0 } }
    recs.each do |rec|
      who = (0..3).map do |s|
        k = rec["kinds"][s] == "ai" ? rec["ais"][s] : rec["kinds"][s]
        k == "human" ? ["human", rec["names"][s]] : [k, ""]
      end
      rec["final"].each do |seat, rank, score, pt|
        e = out[who[seat]]
        e["games"] += 1
        e["ranks"][rank - 1] += 1
        e["score"] += score
        e["points"] += pt
        e["rounds"] += rec["rounds"].size
      end
      rec["rounds"].each do |r|
        next_ron_from = nil
        r["moves"].each do |m|
          out[who[m[0]]]["riichi"] += 1 if m[1] == "riichi"
          next if r["result"]["kind"] == "sanchahou"
          out[who[m[0]]]["wins"] += 1 if %w[tsumo ron].include?(m[1])
          next_ron_from = m[3] if m[1] == "ron"
        end
        out[who[next_ron_from]]["dealins"] += 1 if next_ron_from
      end
    end
    out
  end

  def test_the_stats_are_what_the_records_count
    skip "no sqlite3" unless AsterismGames::RecordBook.sqlite?
    Dir.mktmpdir do |dir|
      t = db_table(dir, "ai_turn_ms" => 0, "ai_call_ms" => 0)
      recs = []
      4.times do |g|
        seats = t.instance_variable_get(:@seats)
        seats[1]["ai"] = "claude"
        seats[2]["ai"] = g.even? ? "jev" : nil
        seats[2].delete("ai") unless g.even?
        t.send(:name_cpus)
        play_out(t)
        recs << t.record_of(t.records_page["records"][0]["id"])
        t.instance_variable_set(:@status, "wait")
        t.start_game(0)
      end
      # A person: the same name is the same person.
      recs.each { |r| r["kinds"][0] = "human" }
      AsterismGames::RecordBook::Database.close_all
      db = SQLite3::Database.new(File.join(dir, "records.sqlite3"))
      db.execute("UPDATE seats SET kind = 'human', name = 'ann' WHERE seat = 0")
      db.close
      recs.each { |r| r["names"][0] = "ann" }
      t = db_table(dir)
      want = expected_stats(recs)
      st = t.stats_answer
      assert_equal 4, st["games"]
      assert_equal "sqlite", st["store"]
      assert_equal %w[human claude cpu jev], st["rows"].map { |r| r["kind"] }.uniq.sort_by { |k| %w[human claude cpu jev].index(k) }
      st["rows"].each do |row|
        e = want[[row["kind"], row["kind"] == "human" ? row["name"] : ""]]
        %w[games ranks rounds wins dealins riichi].each { |k| assert_equal e[k], row[k], "#{row['name']} #{k}" }
        assert_equal (e["points"] / 10.0).round(1), row["points"]
        assert_equal (e["score"].to_f / e["games"]).round, row["avg_score"]
        assert_in_delta e["ranks"].each_with_index.sum { |n, i| n * (i + 1) }.to_f / e["games"], row["avg_rank"], 0.006
        assert_in_delta e["wins"].to_f / e["rounds"], row["win_rate"], 0.0006
      end
      assert_equal "ann", st["rows"][0]["name"]
      assert_equal %w[CPU Claude Jev], st["rows"].reject { |r| r["kind"] == "human" }.map { |r| r["name"] }.sort
      assert_operator reply_bytes(st), :<, LIMIT
      assert_equal 0, t.stats_answer(0, "hanchan")["games"]
      assert_equal 4, t.stats_answer(7, "tonpuu")["games"]
      # The remote's stats: the same, and its arguments optional.
      r = M::Remote.new(t, -> { 0 })
      assert_equal st, r.stats(from: "node")
      assert_equal t.stats_answer(7, "tonpuu", "table"), r.stats(7, "tonpuu", "table", from: "node")
    end
  end

  def test_the_stats_come_in_pages
    skip "no sqlite3" unless AsterismGames::RecordBook.sqlite?
    Dir.mktmpdir do |dir|
      t = db_table(dir, "humans" => 4)
      long = "名前名前名前名前名前ab"
      recs = 30.times.map do |i|
        { "names" => ["#{long[0, 8]}#{i}a", "#{long[0, 8]}#{i}b", "CPU1", "CPU2"], "kinds" => %w[human human cpu cpu],
          "game" => "tonpuu", "rounds" => [], "at" => "2026-10-18 00:00", "time" => Time.now.to_i,
          "final" => [[0, 1, 30_000, 500], [1, 2, 25_000, 100], [2, 3, 25_000, -100], [3, 4, 20_000, -500]] }
      end
      t.book.import(recs)
      rows = []
      from = 0
      while from
        pg = t.stats_answer(0, "", "all", from)
        assert_operator reply_bytes(pg), :<, LIMIT
        rows.concat(pg["rows"])
        from = pg["next"]
      end
      assert_equal 61, rows.size
      assert_equal 60, rows.count { |r| r["kind"] == "human" }
    end
  end
end
