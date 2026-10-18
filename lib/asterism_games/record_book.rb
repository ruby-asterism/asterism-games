# frozen_string_literal: true

require "json"
require "fileutils"

module AsterismGames
  # Where a game keeps the games its tables played to the end (README
  # "Game records"): a book per table, in one of two forms.
  #
  # - SQLite (the image, a checkout with the Gemfile): every table of every
  #   host process that shares the state volume writes into one database,
  #   state_dir/records.sqlite3 (the rooms' and the permanent tables' hosts
  #   are given the supervisor's), in WAL mode, once per game at its end.
  #   The newest `kept` games of a table are kept (a room's tables count
  #   together, by table name: the rooms' mahjong1). A room's games stay
  #   when the room closes; only that room's host gives them out (its book
  #   is scoped to the room's ID), the others count them in their stats.
  #   A room made from a console's invite link has the link's group
  #   (rooms.json "group", games 0.16.0), kept with each of its games: a
  #   room of the same group gives out those games too (its list and
  #   record, not its stats nor its last result).
  #   After every game a consistent copy is made with VACUUM INTO next to
  #   the database (records-backup.sqlite3, through a *.tmp name), which a
  #   backup takes; a host that finds no database but the copy starts from
  #   the copy (the way a restore puts it back).
  # - JSON (no sqlite3 gem: the gem alone, or records_db "json"): the
  #   newest `json_kept` games of a table in the table's store, next to its
  #   saved state (<table>.records.json), as before 0.14.0; a room's go
  #   with the room.
  #
  # A game gives each record (a Hash, its own form, with "id", "at" and
  # "time" filled in here) and a summary of it (summarize: rec ->
  # {"variant", "reason", "rounds", "seats" => [{"seat", "name", "kind",
  # "rank", "score", "points", "counts" => {name => n}}]}), from which the
  # lists and the stats are read without the record itself.
  module RecordBook
    DB_NAME = "records.sqlite3"
    COPY_NAME = "records-backup.sqlite3"
    BUSY_MS = 10_000

    # Whether the sqlite3 gem is there (loaded on the first ask).
    def self.sqlite?
      return @sqlite unless @sqlite.nil?
      @sqlite = begin
        require "sqlite3"
        true
      rescue LoadError
        false
      end
    end

    # The book of one table. db: the database's path ("json" or nil: the
    # JSON form); game: the game's name; place: "lan" / "permanent" /
    # "room"; room: the room's ID in a room; group: in a room, the group
    # of the invite link it was made from (nil: none; the JSON form has no
    # use for it, a room's records go with the room).
    def self.open(db:, game:, table:, place:, room:, store:, kept:, json_kept:, summarize:, log: nil, group: nil)
      if db && db != "json" && sqlite?
        SQLiteBook.new(Database.shared(db, log: log), game: game, table: table, place: place, room: room, kept: kept,
                                                       summarize: summarize, log: log, group: group)
      else
        JSONBook.new(store, "#{table}.records", kept: json_kept, summarize: summarize, log: log)
      end
    end

    # The stats of the rows (stat_rows: [kind, name, rank, score, points,
    # counts]): one entry per player, a person by name ("human"), every
    # other kind as one: {"kind", "name", "games", "ranks" => [n of 1st,
    # 2nd, ...], "score" (the sum), "points" (the sum, as stored),
    # "counts" => {name => sum}}. Humans first, by games; then the kinds.
    def self.aggregate(rows, seats: 4)
      by = {}
      rows.each do |kind, name, rank, score, points, counts|
        key = kind == "human" ? ["human", name.to_s] : [kind.to_s, ""]
        e = by[key] ||= { "kind" => key[0], "name" => key[1], "games" => 0, "ranks" => [0] * seats, "score" => 0,
                          "points" => 0, "counts" => Hash.new(0) }
        e["games"] += 1
        r = rank.to_i
        e["ranks"][r - 1] += 1 if r.between?(1, seats)
        e["score"] += score.to_i
        e["points"] += points.to_i
        counts.to_h.each { |k, v| e["counts"][k] += v.to_i }
      end
      by.values.each { |e| e["counts"] = e["counts"].to_h }
      by.values.sort_by { |e| [e["kind"] == "human" ? 0 : 1, -e["games"], e["kind"], e["name"]] }
    end

    # The JSON form (README "Game records", before 0.14.0): the newest kept
    # games in the table's store ({"format", "seq", "games"}), in memory
    # without a store (tests).
    class JSONBook
      FORMAT = 1

      def initialize(store, name, kept:, summarize:, log: nil)
        @store = store
        @name = name
        @kept = kept
        @summarize = summarize
        @log = log
        @games = []
        @seq = 0
        load
      end

      def kind = "json"

      def load
        d = @store&.read(@name)
        return unless d.is_a?(Hash) && d["format"] == FORMAT
        @games = Array(d["games"])
        @seq = d["seq"].to_i
      rescue JSON::ParserError, SystemCallError => e
        @log&.call("records: #{@name}: #{e.class}: #{e.message}")
      end

      def add(rec, now = Time.now)
        rec["id"] = (@seq += 1)
        rec["at"] = now.strftime("%Y-%m-%d %H:%M")
        rec["time"] = now.to_i
        @games << rec
        @games.shift while @games.size > @kept
        @store&.write(@name, { "format" => FORMAT, "seq" => @seq, "games" => @games })
        rec["id"]
      end

      def size = @games.size

      # [rec, summary] newest first, from the from-th, at most limit.
      def list(from, limit)
        @games.reverse[from, limit].to_a.map { |r| [r, @summarize.call(r)] }
      end

      def get(id)
        @games.find { |r| r["id"] == id.to_i }
      end

      def last
        r = @games.last
        r && [r, @summarize.call(r)]
      end

      # The rows of this table's games (the JSON form knows no others):
      # since (Unix s, nil: all), variant (nil: all).
      def stat_rows(since: nil, variant: nil, everything: false)
        @games.flat_map do |r|
          next [] if since && r["time"].to_i < since
          s = @summarize.call(r)
          next [] if variant && s["variant"] != variant
          s["seats"].map { |x| [x["kind"], x["name"], x["rank"], x["score"], x["points"], x["counts"]] }
        end
      end
    end

    # One database file, shared by the books of a process (one connection;
    # the host's loop and its calls take Asterism::LOCK, the mutex is for
    # anything else). Never carried over a fork: a process opens its own.
    class Database
      VERSION = 1
      @open = {}
      @lock = Mutex.new

      def self.shared(path, log: nil)
        @lock.synchronize do
          d = @open[path]
          return d if d && d.pid == Process.pid
          @open[path] = new(path, log: log)
        end
      end

      # Closes every database of this process (tests).
      def self.close_all
        @lock.synchronize do
          @open.each_value { |d| d.close if d.pid == Process.pid }
          @open.clear
        end
      end

      attr_reader :path, :pid, :db

      def initialize(path, log: nil)
        @path = path
        @log = log
        @pid = Process.pid
        @mutex = Mutex.new
        FileUtils.mkdir_p(File.dirname(path))
        restore_from_copy
        @db = SQLite3::Database.new(path)
        @db.busy_timeout = BUSY_MS
        pragma("PRAGMA journal_mode=WAL")
        pragma("PRAGMA synchronous=NORMAL")
        pragma("PRAGMA foreign_keys=ON")
        schema
      end

      def close
        @db&.close
        @db = nil
      end

      def copy_path = File.join(File.dirname(@path), COPY_NAME)

      # A restore puts the copy back without the database (docs/install.md,
      # "Backups and restoring"): it becomes the database. Every host process
      # of the state volume starts at once; the copy is put in place with a
      # hard link, which only one of them makes (a rename would put a new
      # file under one that another process has opened already).
      def restore_from_copy
        return if File.exist?(@path) || !File.file?(copy_path)
        tmp = "#{@path}.restore-#{Process.pid}.tmp"
        FileUtils.cp(copy_path, tmp)
        begin
          File.link(tmp, @path)
          @log&.call("records: #{@path} made from #{COPY_NAME}")
        rescue Errno::EEXIST
          nil # another process put it there first
        ensure
          FileUtils.rm_f(tmp)
        end
      end

      # Turning a new database to WAL takes it for a moment: several
      # processes opening it at once wait for each other.
      def pragma(sql, tries = 50)
        @db.execute(sql)
      rescue SQLite3::BusyException
        raise if (tries -= 1) <= 0
        sleep 0.1
        retry
      end

      # Format 1, and the column grp added to it (games 0.16.0: the group
      # of a room's invite link, NULL for every other game and for the games
      # before it). The column is added in place and the format stays 1, so
      # a host before 0.16.0 put back reads and writes the same database
      # (it names its columns, and leaves grp NULL).
      def schema
        transaction do
          v = @db.get_first_value("PRAGMA user_version").to_i
          raise "records: #{@path} has format #{v}, this host reads #{VERSION}" if v > VERSION
          create_tables if v < VERSION
          add_group_column
        end
      end

      def add_group_column
        cols = @db.execute("PRAGMA table_info(games)").map { |r| r[1] }
        return if cols.include?("grp")
        @db.execute("ALTER TABLE games ADD COLUMN grp TEXT")
        @db.execute("CREATE INDEX IF NOT EXISTS games_grp ON games (grp, tbl, id)")
      end

      def create_tables
        @db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS games (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            game TEXT NOT NULL,
            place TEXT NOT NULL,
            room TEXT,
            tbl TEXT NOT NULL,
            time INTEGER NOT NULL,
            at TEXT NOT NULL,
            variant TEXT,
            reason TEXT,
            rounds INTEGER,
            body TEXT NOT NULL
          );
          CREATE INDEX IF NOT EXISTS games_place ON games (game, place, tbl, id);
          CREATE INDEX IF NOT EXISTS games_room ON games (room, tbl, id);
          CREATE INDEX IF NOT EXISTS games_time ON games (game, time);
          CREATE TABLE IF NOT EXISTS seats (
            game_id INTEGER NOT NULL REFERENCES games (id) ON DELETE CASCADE,
            seat INTEGER NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            rank INTEGER,
            score INTEGER,
            points INTEGER,
            counts TEXT,
            PRIMARY KEY (game_id, seat)
          );
          CREATE INDEX IF NOT EXISTS seats_who ON seats (kind, name);
          PRAGMA user_version = #{VERSION};
        SQL
      end

      # A write transaction (BEGIN IMMEDIATE: the lock is taken first, so
      # two processes ending a game at once wait for each other within the
      # busy timeout instead of failing at the commit).
      def transaction(&blk)
        @mutex.synchronize do
          @db.transaction(:immediate) { blk.call(@db) }
        end
      end

      def read(&blk)
        @mutex.synchronize { blk.call(@db) }
      end

      # The consistent copy a backup takes (VACUUM INTO a *.tmp name, then
      # renamed over the last one). Returns its size.
      def write_copy
        tmp = "#{copy_path}.#{Process.pid}.tmp"
        FileUtils.rm_f(tmp)
        @mutex.synchronize { @db.execute("VACUUM INTO ?", [tmp]) }
        File.rename(tmp, copy_path)
        File.size(copy_path)
      rescue SQLite3::Exception, SystemCallError => e
        FileUtils.rm_f(tmp) if tmp
        @log&.call("records: the copy for the backup: #{e.class}: #{e.message}")
        nil
      end
    end

    # The SQLite form: a table's view of the shared database (its game,
    # place, table and, in a room, the room's ID and its invite link's
    # group).
    class SQLiteBook
      # What a group may look like (the console writes a random hex string);
      # anything else is taken as none.
      GROUP = /\A[A-Za-z0-9_-]{8,64}\z/

      attr_reader :db, :group

      def initialize(db, game:, table:, place:, room:, kept:, summarize:, log: nil, group: nil)
        @db = db
        @game = game
        @table = table
        @place = place.to_s
        @room = place.to_s == "room" ? room.to_s : nil
        @group = @room && group.is_a?(String) && group.match?(GROUP) ? group : nil
        @kept = kept
        @summarize = summarize
        @log = log
      end

      def kind = "sqlite"

      # The games this table gives out (list, record): in a room the room's
      # and those of the rooms of the same group, else the table's of its
      # place.
      def scope_sql(t = "")
        return own_sql(t) unless @group
        ["#{t}game = ? AND #{t}place = 'room' AND #{t}tbl = ? AND (#{t}room = ? OR #{t}grp = ?)",
         [@game, @table, @room, @group]]
      end

      # The games this table played itself: in a room the room's, else the
      # table's of its place (the stats of "table", the last result).
      def own_sql(t = "")
        if @room
          ["#{t}game = ? AND #{t}place = 'room' AND #{t}room = ? AND #{t}tbl = ?", [@game, @room, @table]]
        else
          ["#{t}game = ? AND #{t}place = ? AND #{t}room IS NULL AND #{t}tbl = ?", [@game, @place, @table]]
        end
      end

      def add(rec, now = Time.now, copy: true)
        rec["at"] ||= now.strftime("%Y-%m-%d %H:%M")
        rec["time"] ||= now.to_i
        id = nil
        @db.transaction do |d|
          id = insert(d, rec)
          trim(d)
        end
        @db.write_copy if copy
        id
      end

      # The game's row and its seats' (the record's id is the row's); group:
      # the group kept with it (the games taken in from the JSON form, of
      # before 0.16.0, keep none).
      def insert(d, rec, group = @group)
        s = @summarize.call(rec)
        rec.delete("id")
        d.execute("INSERT INTO games (game, place, room, grp, tbl, time, at, variant, reason, rounds, body) " \
                  "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '')",
                  [@game, @place, @room, group, @table, rec["time"].to_i, rec["at"].to_s, s["variant"], s["reason"],
                   s["rounds"]])
        id = d.last_insert_row_id
        rec["id"] = id
        d.execute("UPDATE games SET body = ? WHERE id = ?", [JSON.generate(rec), id])
        s["seats"].each do |x|
          d.execute("INSERT INTO seats (game_id, seat, name, kind, rank, score, points, counts) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    [id, x["seat"], x["name"].to_s, x["kind"].to_s, x["rank"], x["score"], x["points"],
                     JSON.generate(x["counts"] || {})])
        end
        id
      end

      # The newest kept of the table: a room's tables count together (the
      # rooms' table of that name), the others by their place.
      def trim(d)
        where, args = @room ? ["game = ? AND place = 'room' AND tbl = ?", [@game, @table]] : own_sql
        d.execute("DELETE FROM games WHERE id IN (SELECT id FROM games WHERE #{where} ORDER BY id DESC LIMIT -1 OFFSET ?)",
                  args + [@kept])
      end

      # The games of the JSON form (a host before 0.14.0): added in their
      # order, with their own times; returns how many.
      def import(recs)
        n = 0
        @db.transaction do |d|
          recs.each do |r|
            r = r.dup
            insert(d, r, nil)
            n += 1
          end
          trim(d)
        end
        @db.write_copy
        n
      end

      def size
        where, args = scope_sql
        @db.read { |d| d.get_first_value("SELECT COUNT(*) FROM games WHERE #{where}", args).to_i }
      end

      def list(from, limit)
        where, args = scope_sql
        rows = @db.read do |d|
          d.execute("SELECT body FROM games WHERE #{where} ORDER BY id DESC LIMIT ? OFFSET ?", args + [limit, from])
        end
        rows.map do |(body)|
          r = JSON.parse(body)
          [r, @summarize.call(r)]
        end
      end

      def get(id)
        where, args = scope_sql
        body = @db.read { |d| d.get_first_value("SELECT body FROM games WHERE id = ? AND #{where}", [id.to_i] + args) }
        body && JSON.parse(body)
      end

      # The newest game this table played itself (a room's own, not its
      # group's).
      def last
        where, args = own_sql
        body = @db.read { |d| d.get_first_value("SELECT body FROM games WHERE #{where} ORDER BY id DESC LIMIT 1", args) }
        return nil unless body
        r = JSON.parse(body)
        [r, @summarize.call(r)]
      end

      # The rows of the stats: this table's games (everything: false; in a
      # room the room's own, not its group's) or every game of this game in
      # the database (everything: true: every table, place and room, closed
      # rooms too).
      def stat_rows(since: nil, variant: nil, everything: false)
        where, args = everything ? ["g.game = ?", [@game]] : own_sql("g.")
        if since
          where += " AND g.time >= ?"
          args += [since]
        end
        if variant
          where += " AND g.variant = ?"
          args += [variant]
        end
        rows = @db.read do |d|
          d.execute("SELECT s.kind, s.name, s.rank, s.score, s.points, s.counts FROM seats s JOIN games g ON g.id = s.game_id " \
                    "WHERE #{where}", args)
        end
        rows.map { |k, n, r, sc, pt, c| [k, n, r, sc, pt, c ? JSON.parse(c) : {}] }
      end
    end
  end
end
