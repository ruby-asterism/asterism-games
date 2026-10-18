# frozen_string_literal: true

require_relative "test_helper"

# The rooms' supervisor (README "Rooms") without a network: rooms.json is
# written by the test, the host processes are stand-ins (sleeping children).
class TestRooms < Minitest::Test
  APP = "/app/game/mahjong/mahjong.app.rb"
  R = AsterismGames::Rooms

  def setup
    @dir = Dir.mktmpdir
    @rooms_dir = File.join(@dir, "rooms")
    FileUtils.mkdir_p(File.join(@rooms_dir, "certs"))
    %w[01 02 03].each { |s| File.write(File.join(@rooms_dir, "certs", "room-#{s}.tar"), "") }
    @now = 1_000_000
    @spawned = []
    @logs = []
    cfg = AsterismGames::Config.new({ "state_dir" => File.join(@dir, "state"), "rooms" => { "dir" => @rooms_dir, "max" => 2 } }, {})
    @rooms = R.new(cfg, log: ->(m) { @logs << m }, clock: -> { @now.to_f },
                        spawn: lambda { |slot, c|
                          @spawned << [slot, c]
                          fork { sleep 30 }
                        })
  end

  def teardown
    @rooms&.stop_all
    FileUtils.rm_rf(@dir)
  end

  def write_rooms(slots, revoked = [], extra = {})
    path = File.join(@rooms_dir, "rooms.json")
    File.write("#{path}.tmp", JSON.generate({ "format" => 1, "slots" => slots, "revoked" => revoked }.merge(extra)))
    File.rename("#{path}.tmp", path)
    # a new mtime even within the same second
    t = Time.now + @spawned.size + rand
    File.utime(t, t, path)
  end

  def room(uid, app = APP, until_s = @now + 3600) = { "room" => uid, "until" => until_s, "max" => 16, "app" => app }

  def test_wanted_takes_the_rooms_that_open_the_table
    data = { "slots" => { "01" => room("a"), "02" => room("b", "/app/test/othello.app.rb"),
                          "03" => room("c", APP, @now - 1), "04" => room("d") },
             "revoked" => [{ "room" => "d", "until" => @now + 60 }] }
    assert_equal ["01"], R.wanted(data, [APP], @now).keys
    assert_nil R.wanted(nil, [APP], @now)
    assert_equal({}, R.wanted({ "slots" => {} }, [APP], @now))
  end

  def test_wanted_reads_the_invite_links_group
    data = { "slots" => { "01" => room("a").merge("group" => "0123456789abcdef"), "02" => room("b"),
                          "03" => room("c").merge("group" => "../x y"), "04" => room("d").merge("group" => 12) } }
    w = R.wanted(data, [APP], @now)
    assert_equal({ "01" => "0123456789abcdef", "02" => nil, "03" => nil, "04" => nil }, w.transform_values { _1["group"] })
  end

  def test_the_room_host_is_given_its_group
    write_rooms({ "01" => room("aaaa").merge("group" => "0123456789abcdef"), "02" => room("bbbb") })
    @rooms.check(@now)
    c = @spawned.to_h
    assert_equal "0123456789abcdef", c["01"]["records_group"]
    assert_nil c["02"]["records_group"], "a room without one (an admin's, a console before 0.3.8)"
    # The host gives it to a room's tables, and nothing outside a room.
    t = AsterismGames::Host.new(c["01"].merge("ai_hub" => Object.new), log: ->(_m) {})
    assert_equal "0123456789abcdef", t.games["mahjong1"].instance_variable_get(:@opts)["records_group"]
    lan = AsterismGames::Host.new({ "state_dir" => File.join(@dir, "lan"), "tables" => [{ "name" => "mahjong1", "game" => "mahjong" }],
                                    "records_group" => "0123456789abcdef", "ai_hub" => Object.new }, log: ->(_m) {})
    assert_nil lan.games["mahjong1"].instance_variable_get(:@opts)["records_group"]
  ensure
    AsterismGames::RecordBook::Database.close_all if AsterismGames::RecordBook.sqlite?
  end

  # ------------------------------------------------- which tables a room gets

  OTHELLO = "/app/game/othello/othello.app.rb"
  BOARD = "/app/game/board/board.app.rb"

  def test_by_default_every_games_screen_and_each_games_first_table
    r = AsterismGames::Config.new({ "rooms" => { "dir" => "/r" } }, {})["rooms"]
    assert_equal [APP, OTHELLO, BOARD], r["apps"]
    assert_equal [%w[mahjong1 mahjong], %w[othello1 othello], %w[board1 board]],
                 r["tables"].map { _1.values_at("name", "game") }
  end

  def test_a_room_gets_the_tables_of_the_game_its_link_opens
    write_rooms({ "01" => room("aaaa"), "02" => room("bbbb", OTHELLO),
                  "03" => room("cccc", "/app/test/othello.app.rb") })
    @rooms.check(@now)
    assert_equal %w[01 02], @spawned.map(&:first).sort, "none for an app that is not a game's"
    assert_equal ["mahjong1"], @spawned.assoc("01")[1]["tables"].map { _1["name"] }, "mahjong only"
    assert_equal ["othello1"], @spawned.assoc("02")[1]["tables"].map { _1["name"] }, "othello only"
    host = AsterismGames::Host.new(@spawned.assoc("02")[1].merge("state_dir" => File.join(@dir, "h")), log: ->(_m) {})
    assert_instance_of AsterismGames::Othello::Table, host.games["othello1"]
    assert_equal ["othello1"], host.games.keys
    assert_equal [APP, OTHELLO, BOARD], @rooms.instance_variable_get(:@serving)
    write_rooms({ "01" => room("aaaa"), "02" => room("eeee", BOARD) })
    @rooms.check(@now + 1)
    assert_equal ["board1"], @spawned.select { _1[0] == "02" }.last[1]["tables"].map { _1["name"] }, "the board only"
  end

  def test_the_tables_given_are_split_by_game
    tables = [{ "name" => "mahjong1", "game" => "mahjong" }, { "name" => "mahjong2", "game" => "mahjong" },
              { "name" => "othello1", "game" => "othello" }, { "name" => "othello2", "game" => "othello" }]
    cfg = AsterismGames::Config.new({ "state_dir" => File.join(@dir, "s2"),
                                      "rooms" => { "dir" => @rooms_dir, "apps" => [APP, OTHELLO], "tables" => tables } }, {})
    assert_equal %w[othello1 othello2], AsterismGames::Config.tables_for_app(cfg["rooms"]["tables"], OTHELLO).map { _1["name"] }
    only = AsterismGames::Config.new({ "rooms" => { "dir" => "/r", "apps" => [APP, OTHELLO],
                                                    "tables" => [tables[0]] } }, {})
    rooms = R.new(only.data.merge("state_dir" => File.join(@dir, "s3")), log: ->(m) { @logs << m }, spawn: ->(*) { 0 })
    assert_equal [APP], rooms.instance_variable_get(:@serving), "no othello table: rooms opening othello get nothing"
  end

  def test_table_names_in_the_environment_find_their_game
    p = AsterismGames::Config.new({ "rooms" => { "dir" => "/r" }, "permanent" => { "credentials" => "/c.tar" } },
                                  { "ASTERISM_GAMES_PERMANENT_TABLES" => "mahjong1,othello1,o2:othello,x" })["permanent"]
    assert_equal [%w[mahjong1 mahjong], %w[othello1 othello], %w[o2 othello], %w[x mahjong]],
                 p["tables"].map { _1.values_at("name", "game") }
  end

  def test_over_when_the_slot_holds_another_room_or_it_is_closed_or_ended
    saved = { "room" => "a", "until" => @now + 100, "slot" => "01" }
    refute R.over?(saved, { "slots" => { "01" => room("a") } }, @now)
    assert R.over?(saved, { "slots" => { "01" => room("b") } }, @now)
    assert R.over?(saved, { "slots" => {}, "revoked" => [{ "room" => "a" }] }, @now)
    assert R.over?(saved.merge("until" => @now - 1), { "slots" => {} }, @now)
    refute R.over?(saved, nil, @now), "no readable file: nothing is over"
  end

  def test_a_host_per_table_room_and_the_child_settings
    write_rooms({ "01" => room("aaaa"), "02" => room("bbbb", "/app/test/othello.app.rb") })
    @rooms.check(@now)
    assert_equal ["01"], @spawned.map(&:first)
    c = @spawned.first[1]
    assert_equal "room/01", c["namespace"]
    assert_equal File.join(@rooms_dir, "certs", "room-01.tar"), c["credentials"]
    assert_equal "games", c["node"]
    assert_equal ["mahjong1"], c["tables"].map { _1["name"] }
    assert_equal "aaaa", JSON.parse(File.read(File.join(c["state_dir"], "room.json")))["room"]
    assert_equal "aaaa", c["room_id"], "the room's ID, for who joins (README \"Who joins\")"
    @rooms.check(@now + 1)
    assert_equal 1, @spawned.size, "one host per room"
  end

  def test_a_new_room_on_the_slot_starts_from_nothing
    write_rooms({ "01" => room("aaaa") })
    @rooms.check(@now)
    d = @spawned.last[1]["state_dir"]
    File.write(File.join(d, "mahjong1.json"), "{}") # the old room's table
    pid = @rooms.children["01"]["pid"]
    write_rooms({}, [{ "room" => "aaaa", "until" => @now + 3600 }])
    @rooms.check(@now + 1)
    assert_nil @rooms.children["01"], "the host of a closed room stops"
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    refute File.exist?(d), "the closed room's tables are removed"
    write_rooms({ "01" => room("cccc") }, [{ "room" => "aaaa", "until" => @now + 3600 }])
    @rooms.check(@now + 2)
    assert_equal 2, @spawned.size
    refute File.exist?(File.join(d, "mahjong1.json"))
    assert_equal "cccc", JSON.parse(File.read(File.join(d, "room.json")))["room"]
  end

  def test_the_slot_moving_to_another_room_while_the_supervisor_was_down
    d = File.join(@dir, "state", "rooms", "01")
    FileUtils.mkdir_p(d)
    File.write(File.join(d, "room.json"), JSON.generate({ "room" => "old", "until" => @now + 3600, "slot" => "01" }))
    File.write(File.join(d, "mahjong1.json"), "{}")
    write_rooms({ "01" => room("new1") })
    @rooms.check(@now)
    refute File.exist?(File.join(d, "mahjong1.json"))
    assert_equal "new1", JSON.parse(File.read(File.join(d, "room.json")))["room"]
  end

  def test_the_same_room_keeps_its_tables_across_a_restart
    d = File.join(@dir, "state", "rooms", "01")
    FileUtils.mkdir_p(d)
    File.write(File.join(d, "room.json"), JSON.generate({ "room" => "aaaa", "until" => @now + 3600, "slot" => "01" }))
    File.write(File.join(d, "mahjong1.json"), "{}")
    write_rooms({ "01" => room("aaaa") })
    @rooms.check(@now)
    assert File.exist?(File.join(d, "mahjong1.json"))
  end

  def test_no_readable_file_changes_nothing
    write_rooms({ "01" => room("aaaa") })
    @rooms.check(@now)
    File.write(File.join(@rooms_dir, "rooms.json"), "{not json")
    @rooms.check(@now + 1)
    assert @rooms.children["01"]["pid"], "the host keeps running"
    assert File.exist?(@spawned.last[1]["state_dir"])
  end

  def test_at_most_max_rooms_and_a_stopped_host_starts_again
    write_rooms({ "01" => room("a"), "02" => room("b"), "03" => room("c") })
    @rooms.check(@now)
    assert_equal %w[01 02], @spawned.map(&:first)
    assert_equal ["03"], @rooms.status["without_table"]
    pid = @rooms.children["01"]["pid"]
    Process.kill("KILL", pid)
    sleep 0.2
    @rooms.check(@now + 0.5)
    assert_nil @rooms.children["01"]["pid"]
    assert_equal 1, @rooms.children["01"]["restarts"]
    @rooms.check(@now + 2)
    assert @rooms.children["01"]["pid"], "started again after the wait"
    assert_equal %w[01 02 01], @spawned.map(&:first)
  end

  def test_status_counts_from_the_hosts
    write_rooms({ "01" => room("aaaa") })
    @rooms.check(@now)
    c = @rooms.children["01"]
    File.write(File.join(@spawned.last[1]["state_dir"], "host.json"),
               JSON.generate({ "pid" => c["pid"], "at" => @now, "connected" => true,
                               "tables" => { "mahjong1" => { "st" => "play", "humans" => 2, "cpus" => 2, "members" => 3 } } }))
    s = @rooms.status
    assert_equal "up", s["rooms"]["01"]["state"]
    assert_equal 2, s["rooms"]["01"]["tables"]["mahjong1"]["humans"]
    assert s["busy"]
    refute JSON.generate(s).include?("token"), "counts only"
    # both seated players away: nobody is there, an update need not wait
    File.write(File.join(@spawned.last[1]["state_dir"], "host.json"),
               JSON.generate({ "pid" => c["pid"], "at" => @now, "connected" => true,
                               "tables" => { "mahjong1" => { "st" => "play", "humans" => 2, "away" => 2, "cpus" => 2, "members" => 3 } } }))
    refute @rooms.status["busy"], "away seats do not keep it busy"
  end

  def test_config_from_the_environment
    cfg = AsterismGames::Config.new({}, { "ASTERISM_GAMES_ROOMS_DIR" => "/rooms", "ASTERISM_GAMES_ROOM_MAX" => "2",
                                          "ASTERISM_GAMES_ROOM_APPS" => "/a.rb, /b.rb", "MAHJONG_TURN_SECONDS" => "15" })
    assert_equal "/rooms", cfg["rooms"]["dir"]
    assert_equal 2, cfg["rooms"]["max"]
    assert_equal ["/a.rb", "/b.rb"], cfg["rooms"]["apps"]
    assert_equal 15_000, cfg["rooms"]["tables"][0]["turn_ms"]
    assert_nil AsterismGames::Config.new({}, {})["rooms"], "no rooms unless a directory is given"
  end

  def test_a_room_host_writes_its_status_counts_only
    dir = File.join(@dir, "host")
    cfg = AsterismGames::Config.new({ "state_dir" => dir, "tables" => [{ "name" => "mahjong1", "game" => "mahjong" }] }, {}).data
    cfg = cfg.merge("status_file" => File.join(dir, "host.json"), "namespace" => "room/01")
    host = AsterismGames::Host.new(cfg, log: ->(_m) {})
    t = host.games["mahjong1"]
    tok = t.join("wasm-aaaaa0", "Alice", 0)["token"]
    t.sit(tok, -1, 0)
    host.step
    h = JSON.parse(File.read(File.join(dir, "host.json")))
    assert_equal false, h["connected"]
    assert_equal({ "st" => "wait", "members" => 1, "humans" => 1, "cpus" => 0 }, h["tables"]["mahjong1"].slice("st", "members", "humans", "cpus"))
    text = File.read(File.join(dir, "host.json"))
    refute_includes text, tok
    refute_includes text, "Alice"
    refute_includes text, "wasm-aaaaa0"
  end

  # ------------------------------------------------------- permanent tables

  def permanent_rooms(extra = {})
    @tar = File.join(@dir, "credentials", "games.tar")
    cfg = AsterismGames::Config.new({ "state_dir" => File.join(@dir, "state"),
                                      "rooms" => { "dir" => @rooms_dir, "max" => 2 },
                                      "permanent" => { "credentials" => @tar, "router" => "tls/zenohd:7448" }.merge(extra) }, {})
    @rooms.stop_all
    @rooms = R.new(cfg, log: ->(m) { @logs << m }, clock: -> { @now.to_f },
                        spawn: lambda { |who, c|
                          @spawned << [who, c]
                          fork { sleep 30 }
                        })
  end

  def put_tar
    FileUtils.mkdir_p(File.dirname(@tar))
    File.write(@tar, "")
  end

  def test_permanent_config_from_the_file_and_the_environment
    rooms = { "dir" => "/rooms" }
    assert_nil AsterismGames::Config.new({ "rooms" => rooms }, {})["permanent"], "none without a certificate"
    assert_nil AsterismGames::Config.new({}, { "ASTERISM_GAMES_PERMANENT_CREDENTIALS" => "/c/games.tar" })["permanent"],
               "none without rooms (the host itself takes credentials and tables then)"
    p = AsterismGames::Config.new({ "rooms" => rooms, "permanent" => { "router" => "tls/zenohd:7448" } },
                                  { "ASTERISM_GAMES_PERMANENT_CREDENTIALS" => "/c/games.tar",
                                    "ASTERISM_GAMES_PERMANENT_TABLES" => "mahjong1, mahjong3",
                                    "MAHJONG_TURN_SECONDS" => "15" })["permanent"]
    assert_equal "/c/games.tar", p["credentials"]
    assert_equal "tls/zenohd:7448", p["router"]
    assert_nil p["node"], "the certificate's name"
    assert_equal %w[mahjong1 mahjong3], p["tables"].map { _1["name"] }
    assert_equal 15_000, p["tables"][0]["turn_ms"]
    p = AsterismGames::Config.new({ "rooms" => rooms }, { "ASTERISM_GAMES_PERMANENT_CREDENTIALS" => "/c/games.tar" })["permanent"]
    assert_equal %w[mahjong1 mahjong2], p["tables"].map { _1["name"] }, "two tables unless said"
  end

  def test_permanent_tables_wait_for_their_certificate_then_start
    permanent_rooms
    @rooms.check(@now)
    @rooms.check(@now + 1)
    assert_empty @spawned
    assert_equal 1, @logs.count { _1.include?("no readable") }, "said once"
    assert_equal "no certificate", @rooms.status["permanent"]["state"]
    put_tar
    @rooms.check(@now + 2)
    assert_equal ["permanent"], @spawned.map(&:first)
    c = @spawned.first[1]
    assert_equal @tar, c["credentials"]
    assert_equal "tls/zenohd:7448", c["credentials_router"]
    assert_nil c["namespace"], "outside every room"
    assert_nil c["node"], "the certificate's name"
    assert_equal File.join(@dir, "state", "permanent"), c["state_dir"]
    assert_equal %w[mahjong1 mahjong2], c["tables"].map { _1["name"] }
    assert_equal "permanent tables", c["profile_name"], "apart from the rooms' hosts of the same node ID"
    @rooms.check(@now + 3)
    assert_equal 1, @spawned.size, "one host for the permanent tables"
  end

  # Records what Host#up asks of the Net.
  class ProfileNet
    attr_reader :profiles, :joined, :left, :statuses

    def initialize
      @profiles = []
      @statuses = []
    end

    def profile(**fields) = @profiles << fields
    def status(h = nil) = h ? @statuses << h : @statuses.last
    def on_error(&) = nil
    def on_join(&blk) = @joined = blk
    def on_leave(&blk) = @left = blk
    def on_app_join(&blk) = @joined = blk
    def on_app_leave(&blk) = @left = blk
    def expose(*, **) = nil
    def start = nil
  end

  def test_the_profile_name_of_each_kind_of_host
    base = AsterismGames::Config.new({ "state_dir" => File.join(@dir, "p"),
                                       "tables" => [{ "name" => "mahjong1", "game" => "mahjong" }] }, {}).data
    permanent_rooms
    put_tar
    @rooms.check(@now)
    perm = @spawned.assoc("permanent")[1]
    { perm.merge("state_dir" => File.join(@dir, "p1"), "node" => "games") => "permanent tables",
      base => "asterism-games",
      base.merge("namespace" => "room/01") => nil }.each do |cfg, name|
      host = AsterismGames::Host.new(cfg, log: ->(_m) {})
      name ? assert_equal(name, host.profile_name) : assert_nil(host.profile_name)
      net = ProfileNet.new
      host.up(net)
      assert_equal(name ? [{ name: name }] : [], net.profiles, "the profile #{cfg['namespace'] ? 'in a room' : name}")
      # The tables' counts (README "Status"): outside the rooms only.
      host.tell_tables(0, changed: true)
      st = host.games.keys.to_h { [_1, { "st" => "wait", "members" => 0, "humans" => 0, "cpus" => 0, "ais" => 0, "away" => 0 }] }
      assert_equal(cfg["namespace"] ? [] : [st], net.statuses, "the status #{cfg['namespace'] ? 'in a room' : name}")
      # Who is there: every kind of host hears the players' table apps
      # (the application "game") leave and come back; another application
      # of the node is nobody's table.
      t = host.games["mahjong1"]
      t.join("node-a", "A", 0)
      net.left.call("node-a", "other")
      refute t.member_away?("node-a")
      net.left.call("node-a", "game")
      assert t.member_away?("node-a")
      net.joined.call("node-a", "game")
      refute t.member_away?("node-a")
    end
  end

  def test_permanent_tables_next_to_the_rooms_and_never_cleaned_with_them
    permanent_rooms
    put_tar
    write_rooms({ "01" => room("aaaa") })
    @rooms.check(@now)
    assert_equal %w[01 permanent], @spawned.map(&:first).sort
    pd = @spawned.find { _1[0] == "permanent" }[1]["state_dir"]
    File.write(File.join(pd, "mahjong1.json"), "{}")
    write_rooms({}, [{ "room" => "aaaa", "until" => @now + 3600 }])
    @rooms.check(@now + 1)
    assert_nil @rooms.children["01"]
    assert @rooms.perm["pid"], "the permanent host keeps running when a room closes"
    assert File.exist?(File.join(pd, "mahjong1.json")), "and its tables stay"
    write_rooms({ "01" => room("bbbb"), "02" => room("cccc"), "03" => room("dddd") })
    @rooms.check(@now + 2)
    assert_equal ["03"], @rooms.status["without_table"], "the permanent host is not one of rooms.max"
  end

  def test_permanent_host_starts_again_and_its_status
    permanent_rooms
    put_tar
    @rooms.check(@now)
    pid = @rooms.perm["pid"]
    File.write(File.join(@dir, "state", "permanent", "host.json"),
               JSON.generate({ "pid" => pid, "at" => @now, "node" => "games", "connected" => true,
                               "tables" => { "mahjong1" => { "st" => "play", "humans" => 1, "cpus" => 3, "members" => 2 },
                                             "mahjong2" => { "st" => "wait", "humans" => 0, "cpus" => 0, "members" => 0 } } }))
    s = @rooms.status
    assert_equal "up", s["permanent"]["state"]
    assert_equal "games", s["permanent"]["node"]
    assert_equal 1, s["permanent"]["tables"]["mahjong1"]["humans"]
    assert s["busy"], "someone sits at a permanent table"
    assert_empty s["rooms"]
    Process.kill("KILL", pid)
    sleep 0.2
    @rooms.check(@now + 0.5)
    assert_nil @rooms.perm["pid"]
    assert_equal "restarting", @rooms.status["permanent"]["state"]
    refute @rooms.status["busy"], "the old counts are not taken"
    @rooms.check(@now + 2)
    assert @rooms.perm["pid"], "started again after the wait"
    assert_equal %w[permanent permanent], @spawned.map(&:first)
    again = @rooms.perm["pid"]
    @rooms.stop_all
    assert_nil @rooms.perm["pid"]
    assert_raises(Errno::ESRCH) { Process.kill(0, again) }
  end

  def test_no_permanent_tables_without_the_setting
    write_rooms({ "01" => room("aaaa") })
    @rooms.check(@now)
    assert_nil @rooms.status["permanent"]
    assert_equal ["01"], @spawned.map(&:first)
  end

  # A .tar as the console makes it (the key, the certificate, the CA,
  # asterism.json), for the host's node ID.
  def credentials_tar(path, name)
    require "openssl"
    require "rubygems/package"
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{name}")
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 86_400
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    files = { "#{name}.key" => key.private_to_pem, "#{name}.pem" => cert.to_pem, "ca.pem" => cert.to_pem,
              "asterism.json" => JSON.generate({ "name" => name, "router" => "tls/router.example.org:7448" }) }
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "wb", 0o600) do |f|
      Gem::Package::TarWriter.new(f) do |tar|
        files.each { |n, body| tar.add_file_simple("#{name}/#{n}", n.end_with?(".key") ? 0o600 : 0o644, body.bytesize) { _1.write(body) } }
      end
    end
  end

  def test_the_permanent_host_is_the_certificates_name
    tar = File.join(@dir, "credentials", "games.tar")
    credentials_tar(tar, "games")
    cfg = AsterismGames::Config.new({ "state_dir" => File.join(@dir, "p"), "tables" => [{ "name" => "mahjong1" }] }, {}).data
    host = AsterismGames::Host.new(cfg.merge("node" => nil, "credentials" => tar), log: ->(_m) {})
    assert_equal "games", host.node
    host = AsterismGames::Host.new(cfg.merge("node" => "games2", "credentials" => tar), log: ->(_m) {})
    assert_equal "games2", host.node, "the setting wins"
  end

  # ------------------------------------------------- seats (console 0.3.0)

  def test_before_the_seats_nothing_is_trusted
    write_rooms({ "01" => room("aaaa") })
    @rooms.check(@now)
    c = @spawned.first[1]
    assert_equal [[], nil], c.values_at("trusted_nodes", "trusted_prefix")
    refute c.key?("secret_ids")
  end

  def test_with_hosts_and_seats_the_host_joins_with_its_own_certificate_and_trusts_the_seats
    permanent_rooms
    put_tar
    write_rooms({ "01" => room("aaaa").merge("seats" => 3) }, [], { "seat_node_prefix" => "wasm-", "hosts" => ["games"] })
    @rooms.check(@now)
    who, c = @spawned.find { |w, _| w == "01" }
    assert_equal "01", who
    assert_equal @tar, c["credentials"], "the host's own certificate, the permanent tables' one"
    assert_equal "tls/zenohd:7448", c["credentials_router"], "the permanent tables' router"
    assert_equal "room/01", c["namespace"]
    assert_equal %w[wasm-0101 wasm-0102 wasm-0103], c["trusted_nodes"]
    assert_equal "games", c["trusted_prefix"]
    assert_equal 1_800_000, c["seat_reuse_ms"]
    host = AsterismGames::Host.new(c.merge("state_dir" => File.join(@dir, "h")), log: ->(_m) {})
    assert_equal %w[wasm-0101 wasm-0102 wasm-0103], host.games["mahjong1"].opts["trusted_nodes"]
  end

  def test_a_room_whose_seats_change_gets_its_host_again
    write_rooms({ "01" => room("aaaa") })
    @rooms.check(@now)
    assert_equal 1, @spawned.count { |w, _| w == "01" }
    write_rooms({ "01" => room("aaaa").merge("seats" => 2) }, [], { "seat_node_prefix" => "wasm-" })
    @rooms.check(@now + 1)
    @rooms.check(@now + 2)
    assert_equal 2, @spawned.count { |w, _| w == "01" }
    assert_equal %w[wasm-0101 wasm-0102], @spawned.last[1]["trusted_nodes"]
    assert(@logs.any? { _1.include?("seats or hosts changed") })
  end

  def test_listed_as_a_host_without_a_certificate_says_so
    write_rooms({ "01" => room("aaaa") }, [], { "hosts" => ["games"] })
    @rooms.check(@now)
    c = @spawned.first[1]
    assert_equal File.join(@rooms_dir, "certs", "room-01.tar"), c["credentials"]
    assert(@logs.any? { _1.include?("no rooms.credentials") })
  end

  def test_room_settings_from_the_environment
    env = { "ASTERISM_GAMES_ROOMS_DIR" => "/r",
            "ASTERISM_GAMES_ROOM_SEAT_REUSE_SECONDS" => "60", "ASTERISM_GAMES_ROOM_CREDENTIALS" => "/c/own.tar" }
    r = AsterismGames::Config.new({}, env)["rooms"]
    assert_equal [60, "/c/own.tar"], r.values_at("seat_reuse_seconds", "credentials")
    refute r.key?("secret_ids")
    r = AsterismGames::Config.new({ "permanent" => { "credentials" => "/c/games.tar" } }, { "ASTERISM_GAMES_ROOMS_DIR" => "/r" })["rooms"]
    assert_equal "/c/games.tar", r["credentials"], "the permanent tables' certificate"
  end
end
