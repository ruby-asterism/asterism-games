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

  def test_a_closed_room_takes_its_records_with_it
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
end
