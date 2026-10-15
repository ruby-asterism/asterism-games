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

  def write_rooms(slots, revoked = [])
    path = File.join(@rooms_dir, "rooms.json")
    File.write("#{path}.tmp", JSON.generate({ "format" => 1, "slots" => slots, "revoked" => revoked }))
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
end
