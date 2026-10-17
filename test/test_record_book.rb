# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The games' records (README "Game records"): the book of a table, in
# SQLite (one database for every host process: the newest kept of a table,
# a room's games kept after the room and given out only in it, several
# processes ending games at once, the copy for the backup) and in JSON
# (without the sqlite3 gem: rake test:gem runs this file that way).
class TestRecordBook < Minitest::Test
  RB = AsterismGames::RecordBook

  SUMMARY = lambda do |rec|
    { "variant" => rec["v"], "reason" => "end", "rounds" => 1,
      "seats" => rec["p"].each_with_index.map do |(name, kind, rank), i|
        { "seat" => i, "name" => name, "kind" => kind, "rank" => rank, "score" => 25_000 + (10 * rank),
          "points" => 10 * (3 - rank), "counts" => { "rounds" => 1, "wins" => rank == 1 ? 1 : 0 } }
      end }
  end

  def game(n, v = "tonpuu", names = %w[ann bob])
    { "n" => n, "v" => v, "p" => [[names[0], "human", 1], [names[1], "human", 2], ["CPU1", "cpu", 3], ["Claude", "claude", 4]] }
  end

  def book(dir, table: "t", place: "lan", room: nil, kept: 5, db: nil)
    RB.open(db: db || File.join(dir, RB::DB_NAME), game: "g", table: table, place: place, room: room,
            store: AsterismGames::Store.new(File.join(dir, place, room.to_s)), kept: kept, json_kept: 3,
            summarize: SUMMARY)
  end

  def teardown
    RB::Database.close_all if RB.sqlite?
  end

  def test_the_json_form_keeps_the_newest_in_the_store
    Dir.mktmpdir do |dir|
      b = book(dir, db: "json")
      assert_equal "json", b.kind
      5.times { |i| b.add(game(i)) }
      assert_equal 3, b.size
      assert_equal [4, 3, 2], b.list(0, 10).map { |r, _| r["n"] }
      assert_equal 5, b.list(0, 1)[0][0]["id"]
      assert_nil b.get(1)
      c = book(dir, db: "json")
      assert_equal 3, c.size, "read back from the store"
      assert File.exist?(File.join(dir, "lan", "t.records.json"))
      rows = c.stat_rows
      assert_equal 12, rows.size
      st = RB.aggregate(rows)
      assert_equal [%w[human ann], %w[human bob], %w[claude], %w[cpu]], st.map { |e| [e["kind"], e["name"]].reject(&:empty?) }
      assert_equal [3, 0, 0, 0], st[0]["ranks"]
      assert_equal 3, st[0]["counts"]["wins"]
    end
  end

  def test_without_sqlite3_the_records_are_json
    lib = File.expand_path("../lib", __dir__)
    out, st = Open3.capture2e({ "RUBYOPT" => "-rbundler/setup" }, RbConfig.ruby, "-I#{File.expand_path('no_sqlite3', __dir__)}",
                              "-I#{lib}", "-e", <<~RUBY, chdir: File.expand_path("..", __dir__))
                                require "asterism_games"
                                require "tmpdir"
                                Dir.mktmpdir do |d|
                                  b = AsterismGames::RecordBook.open(db: File.join(d, "records.sqlite3"), game: "g", table: "t",
                                    place: "lan", room: nil, store: AsterismGames::Store.new(d), kept: 1000, json_kept: 20,
                                    summarize: ->(_r) { { "seats" => [] } })
                                  b.add({ "x" => 1 })
                                  puts [AsterismGames::RecordBook.sqlite?, b.kind, File.exist?(File.join(d, "records.sqlite3")),
                                        File.exist?(File.join(d, "t.records.json"))].inspect
                                end
                              RUBY
    assert st.success?, out
    assert_equal "[false, \"json\", false, true]", out.lines.last.strip
  end

  def test_sqlite_keeps_the_newest_of_a_table
    skip "no sqlite3 (rake test:gem)" unless RB.sqlite?
    Dir.mktmpdir do |dir|
      b = book(dir)
      assert_equal "sqlite", b.kind
      ids = 7.times.map { |i| b.add(game(i)) }
      assert_equal 5, b.size
      assert_equal [6, 5, 4, 3, 2], b.list(0, 10).map { |r, _| r["n"] }
      assert_equal [4, 3], b.list(2, 2).map { |r, _| r["n"] }
      assert_nil b.get(ids[0]), "the oldest went"
      assert_equal 6, b.get(ids[-1])["n"]
      assert_equal ids[-1], b.get(ids[-1])["id"]
      assert_match(/\A\d{4}-\d\d-\d\d \d\d:\d\d\z/, b.get(ids[-1])["at"])
      # Another table of the same place has its own.
      o = book(dir, table: "u")
      assert_equal 0, o.size
      o.add(game(9))
      assert_equal 5, b.size
      # The seats went with their games.
      n = b.db.read { |d| d.get_first_value("SELECT COUNT(*) FROM seats") }
      assert_equal 6 * 4, n
      # A new id after a trim never repeats one.
      assert_operator b.add(game(10)), :>, ids.max
    end
  end

  def test_a_rooms_games_stay_and_only_the_room_gives_them_out
    skip "no sqlite3 (rake test:gem)" unless RB.sqlite?
    Dir.mktmpdir do |dir|
      a = book(dir, place: "room", room: "aaaa", kept: 3)
      b = book(dir, place: "room", room: "bbbb", kept: 3)
      lan = book(dir, place: "permanent")
      id = a.add(game(1))
      assert_equal 1, a.size
      assert_equal 0, b.size
      assert_equal 0, lan.size
      assert_nil b.get(id)
      assert_nil lan.get(id)
      assert_equal 1, a.get(id)["n"]
      # The stats: the room's own, or everything (names and numbers).
      assert_equal 4, a.stat_rows.size
      assert_equal 0, b.stat_rows.size
      assert_equal 4, lan.stat_rows(everything: true).size
      # The rooms' table counts together for the newest kept.
      3.times { |i| b.add(game(10 + i)) }
      assert_equal 0, a.size, "the rooms' t keeps 3 in all"
      assert_equal 3, b.size
      # A room's book opened again (the room closed; another one) finds them.
      RB::Database.close_all
      assert_equal 3, book(dir, place: "room", room: "bbbb").size
    end
  end

  def test_the_stats_filter_by_time_and_variant
    skip "no sqlite3 (rake test:gem)" unless RB.sqlite?
    Dir.mktmpdir do |dir|
      b = book(dir, kept: 100)
      old = game(1, "hanchan").merge("time" => Time.now.to_i - (40 * 86_400), "at" => "2026-01-01 00:00")
      b.import([old])
      b.add(game(2, "tonpuu"))
      b.add(game(3, "tonpuu", %w[ann cy]))
      assert_equal 12, b.stat_rows.size
      assert_equal 8, b.stat_rows(since: Time.now.to_i - (30 * 86_400)).size
      assert_equal 4, b.stat_rows(variant: "hanchan").size
      st = RB.aggregate(b.stat_rows)
      ann = st.find { |e| e["name"] == "ann" }
      assert_equal 3, ann["games"]
      assert_equal 3 * (25_000 + 10), ann["score"]
      assert_equal %w[ann bob cy], st.select { |e| e["kind"] == "human" }.map { |e| e["name"] }
    end
  end

  def test_processes_ending_games_at_once_lose_none
    skip "no sqlite3 (rake test:gem)" unless RB.sqlite?
    Dir.mktmpdir do |dir|
      book(dir, kept: 1000) # the schema, made once
      RB::Database.close_all
      pids = 4.times.map do |k|
        fork do
          b = book(dir, table: "t", place: k.even? ? "lan" : "room", room: k.even? ? nil : "r#{k}", kept: 1000)
          25.times { |i| b.add(game((k * 100) + i)) }
          exit!(0)
        end
      end
      assert(pids.map { |p| Process.wait2(p)[1] }.all?(&:success?))
      b = book(dir, kept: 1000)
      d = b.db
      assert_equal 100, d.read { |x| x.get_first_value("SELECT COUNT(*) FROM games") }
      assert_equal 400, d.read { |x| x.get_first_value("SELECT COUNT(*) FROM seats") }
      assert_equal 100, d.read { |x| x.get_first_value("SELECT COUNT(DISTINCT id) FROM games") }
      assert_equal "ok", d.read { |x| x.get_first_value("PRAGMA integrity_check") }
      assert_equal 50, b.size
      # The copy for the backup is whole too.
      copy = File.join(dir, RB::COPY_NAME)
      assert File.exist?(copy)
      assert_empty Dir.glob(File.join(dir, "*.tmp"))
    end
  end

  def test_a_restore_puts_the_copy_back
    skip "no sqlite3 (rake test:gem)" unless RB.sqlite?
    Dir.mktmpdir do |dir|
      b = book(dir)
      3.times { |i| b.add(game(i)) }
      RB::Database.close_all
      # What docs/install.md's restore does: the copy without the database.
      Dir.glob(File.join(dir, "records.sqlite3*")).each { |f| File.delete(f) }
      c = book(dir)
      assert_equal 3, c.size
      assert_equal [2, 1, 0], c.list(0, 5).map { |r, _| r["n"] }
      c.add(game(3))
      RB::Database.close_all
      # Every host process of the volume starts at once after a restore:
      # one puts the copy in place, all of them read and write it.
      Dir.glob(File.join(dir, "records.sqlite3*")).each { |f| File.delete(f) }
      pids = 4.times.map do |k|
        fork do
          b = book(dir, table: "p#{k}")
          b.add(game(10 + k))
          exit!(b.size == 1 && book(dir).size == 4 ? 0 : 1)
        end
      end
      assert(pids.map { |p| Process.wait2(p)[1] }.all?(&:success?))
      d = book(dir)
      assert_equal 4, d.size
      assert_equal 8, d.db.read { |x| x.get_first_value("SELECT COUNT(*) FROM games") }
      assert_empty Dir.glob(File.join(dir, "*.tmp"))
    end
  end
end
