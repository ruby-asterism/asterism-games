# frozen_string_literal: true

# The framework with a game of its own (Tally) and nothing else loaded:
# run by test/test_framework.rb in a process of its own (no mahjong, no
# riichi_engine), or by hand:
#   bundle exec ruby -Ilib -Itest/framework test/framework/test_tally.rb
require "minitest/autorun"
require "tmpdir"
require "json"
require "net/http"
require "openssl"
require "rubygems/package"
require_relative "tally"

class TestTally < Minitest::Test
  APP = "/app/test/tally.app.rb"

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    @rooms&.stop_all
    FileUtils.rm_rf(@dir)
  end

  # The host's clock (its step ticks the tables with it).
  def ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)

  def config(file = {}, env = {})
    AsterismGames::Config.new({ "state_dir" => File.join(@dir, "state") }.merge(file), env).data
  end

  def test_only_the_framework_and_the_game_are_loaded
    assert_equal ["tally"], AsterismGames.games.keys
    assert_empty $LOADED_FEATURES.grep(/riichi|mahjong/i)
    refute defined?(AsterismGames::Mahjong)
  end

  def test_the_exposed_methods_and_their_arguments
    assert_equal({ press: 2, view: 1, table: 0, join: 1, mine: 0, leave: 1 }, Tally::Remote.exposes)
    assert_equal({ join: 1, mine: 0, leave: 1 }, AsterismGames::Remote.exposes)
  end

  def test_settings_come_from_the_game
    c = config({}, { "TALLY_GOAL" => "5" })
    assert_equal [{ "name" => "tally1", "game" => "tally", "goal" => 5 }, { "name" => "tally2", "game" => "tally", "goal" => 5 }],
                 c["tables"]
    c = config({ "tables" => [{ "name" => "t", "step_seconds" => 0.5, "goal" => 3 }] })
    assert_equal [{ "name" => "t", "game" => "tally", "step_ms" => 500, "goal" => 3 }], c["tables"]
    r = config({ "rooms" => { "dir" => "/r" } })["rooms"]
    assert_equal [APP], r["apps"], "the game's screens"
    assert_equal [{ "name" => "tally1", "game" => "tally" }], r["tables"], "the first table"
    assert_raises(ArgumentError) { AsterismGames::Host.new(config({ "tables" => [{ "name" => "x", "game" => "chess" }] })) }
  end

  def test_members_through_the_remote_with_from
    t = Tally::Table.new("t", { "step_ms" => 100, "goal" => 3 })
    r = Tally::Remote.new(t, -> { @now })
    @now = 0
    a = r.join("Alice", from: "node-a")
    assert_equal 32, a["token"].size
    assert_equal a, r.mine(from: "node-a")
    assert_nil r.mine(from: "node-b")
    assert_equal "token", r.press("bad", 1, from: "node-a")
    assert_equal "ok", r.press(a["token"], 2, from: "node-a")
    assert_equal({ "error" => "token" }, r.view("bad", from: "node-a"))
    assert_equal "Alice", r.view(a["token"], from: "node-a")["me"]
    @now = 100
    t.tick(@now)
    assert_equal 1, t.rounds
    assert_equal "ok", r.press(a["token"], 1, from: "node-a")
    assert_equal "over", r.press(a["token"], 1, from: "node-a")
    assert_equal "over", r.table(from: "x")["st"]
    assert r.leave(a["token"], from: "node-a")
    assert_nil r.mine(from: "node-a")
  end

  def test_a_member_is_there_while_it_calls_from_its_own_node
    t = Tally::Table.new("t", { "away_ms" => 1000 })
    r = Tally::Remote.new(t, -> { @now })
    @now = 0
    tok = r.join("A", from: "node-a")["token"]
    @now = 5000
    t.tick(@now)
    assert t.member_away?("node-a")
    r.view(tok, from: "someone-else")
    assert t.member_away?("node-a"), "a call with the token from another node is not a sign"
    r.view(tok, from: "node-a")
    refute t.member_away?("node-a")
    @now = 5000 + 6001
    t.tick(@now)
    assert_nil t.mine("node-a"), "gone for six times away_ms: forgotten"
  end

  def test_the_host_saves_and_another_host_goes_on
    c = config({ "tables" => [{ "name" => "tally1", "step_seconds" => 60 }] })
    h = AsterismGames::Host.new(c, log: ->(_m) {})
    t = h.games["tally1"]
    tok = t.join("node-a", "A", ms)["token"]
    assert_equal "ok", t.press(tok, 4, ms)
    h.step
    saved = JSON.parse(File.read(File.join(@dir, "state", "tally1.json")))
    assert_equal [1, 4], saved.values_at("format", "count")
    refute saved.dig("members", "node-a").key?("seen")
    h2 = AsterismGames::Host.new(c, log: ->(_m) {})
    t2 = h2.games["tally1"]
    assert_equal 4, t2.count
    assert_equal tok, t2.mine("node-a")["token"], "the same token after a restart"
    assert_operator t2.ver, :>, t.ver - 1
    File.write(File.join(@dir, "state", "tally1.json"), JSON.generate(saved.merge("format" => 99)))
    assert_equal 0, AsterismGames::Host.new(c, log: ->(_m) {}).games["tally1"].count, "another format is not read"
  end

  # The host's @status (README "Status"): counts only, the same keys as
  # the status file without the game's own extras, and none in a room.
  # TablesStatus with a Net that has net.status (asterism after 0.7.1) and
  # with one that does not (by hand on the session).
  def test_the_at_status_has_counts_only
    c = config({ "tables" => [{ "name" => "tally1" }] })
    h = AsterismGames::Host.new(c, log: ->(_m) {})
    tok = h.games["tally1"].join("node-secret", "Carol", ms)["token"]
    st = h.tables_status(ms)
    assert_equal({ "tally1" => { "st" => "play", "members" => 1, "humans" => 1, "cpus" => 0, "away" => 0 } }, st)
    [tok, "Carol", "node-secret"].each { |x| refute_includes JSON.generate(st), x }
    assert h.tables_status?
    refute AsterismGames::Host.new(c.merge("namespace" => "room/01"), log: ->(_m) {}).tables_status?, "not in a room"

    with_api = Struct.new(:st) do
      def status(h = nil) = h ? (self.st = h) : st
    end.new
    ts = AsterismGames::Host::TablesStatus.new(with_api, "games", "games")
    assert_equal "asterism/games/games/@status".bytesize + Asterism::Codec.pack(st).bytesize, ts.set(st)
    assert_equal st, with_api.st
    assert_nil ts.set(st), "the same counts again: nothing"

    session = Struct.new(:puts, :qa) do
      def queryable(key, &blk) = (self.qa = [key, blk])
      def put(key, bytes) = puts << [key, bytes]
    end.new([])
    by_hand = Struct.new(:session).new(session)
    ts = AsterismGames::Host::TablesStatus.new(by_hand, "games", "games")
    assert_equal "asterism/games/games/@status", session.qa[0]
    assert ts.set(st)
    assert_nil ts.set(st)
    assert_equal [["asterism/games/games/@status", Asterism::Codec.pack(st)]], session.puts
    q = Struct.new(:replies) { def reply(k, b) = replies << [k, b] }.new([])
    session.qa[1].call(q)
    assert_equal [["asterism/games/games/@status", Asterism::Codec.pack(st)]], q.replies
  end

  def test_the_status_file_has_counts_only
    c = config({ "tables" => [{ "name" => "tally1" }] }).merge("status_file" => File.join(@dir, "host.json"))
    h = AsterismGames::Host.new(c, log: ->(_m) {})
    tok = h.games["tally1"].join("node-secret", "Carol", ms)["token"]
    h.step
    s = JSON.parse(File.read(File.join(@dir, "host.json")))
    assert_equal({ "st" => "play", "members" => 1, "humans" => 1, "cpus" => 0, "away" => 0, "n" => 0 }, s["tables"]["tally1"])
    text = File.read(File.join(@dir, "host.json"))
    [tok, "Carol", "node-secret"].each { |x| refute_includes text, x }
  end

  # Over a real router (ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447): the host
  # in a child process, this process a player through the Net API. (One
  # test: the host is forked before this process uses zenoh-c.)
  def test_over_the_network
    router = ENV["ASTERISM_TEST_ROUTER"]
    skip "set ASTERISM_TEST_ROUTER to run against a router" unless router
    node = "tally-test-#{Process.pid}"
    status = File.join(@dir, "host.json")
    c = config({ "router" => router, "node" => node, "tables" => [{ "name" => "tally1", "step_seconds" => 0.2 }] })
          .merge("status_file" => status)
    pid = fork do
      h = AsterismGames::Host.new(c, log: ->(_m) {})
      trap("TERM") { h.stop! }
      h.run
      exit!(0)
    end
    states = Queue.new
    statuses = Queue.new
    Asterism.connect(router, node: "tally-player-#{Process.pid}", app: "game") do |net|
      net.session.subscribe("asterism/#{node}/games/tally1/state") { |s| states << Asterism::Codec.unpack(s.payload) }
      net.session.subscribe("asterism/#{node}/games/@status") { |s| statuses << Asterism::Codec.unpack(s.payload) }
      net.start
      t = nil
      50.times do
        t = net.each("#{node}/games/*").first
        break if t
        sleep 0.1
      end
      assert t, "the host came up"
      t = net["#{node}/games/tally1", timeout: 3.0]
      tok = t.join("Player")["token"]
      assert_equal tok, t.mine["token"], "the caller is this node (from:)"
      e = assert_raises(Asterism::RemoteError) { t.press(tok, 1, from: "someone") }
      assert_equal "arguments", e.remote_kind
      assert_equal "ok", t.press(tok, 3)
      assert_equal 3, t.view(tok)["n"]
      s = nil
      30.times do
        s = states.pop(timeout: 0.2)
        break if s && s["n"] == 3
      end
      assert_equal 3, s && s["n"], "the state put on the table's key"
      assert_equal "asterism-games", net.profile_of(node, icon: false)&.fetch("name")
      # The tables' counts on the host's @status (README "Status"): put
      # when they change, and the answer to a get.
      st = nil
      30.times do
        st = statuses.pop(timeout: 0.2)
        break if st && st.dig("tally1", "members") == 1
      end
      assert_equal({ "tally1" => { "st" => "play", "members" => 1, "humans" => 1, "cpus" => 0, "away" => 0 } }, st)
      got = net.session.get("asterism/#{node}/games/@status", timeout: 2.0).map { Asterism::Codec.unpack(_1.payload) }
      assert_equal [st], got
      assert t.leave(tok)
      # Who is there (README "Who is there"): another node joins and is
      # killed; the host hears its node leave and shows it away at once
      # (away_ms is 10 s). The node comes back without calling: back.
      other = "tally-other-#{Process.pid}"
      away = -> { JSON.parse(File.read(status)).dig("tables", "tally1", "away") rescue nil }
      kid = other_node(router, other, node, join: true)
      wait_for(10) { away.call == 0 && JSON.parse(File.read(status)).dig("tables", "tally1", "members") == 1 }
      t0 = ms
      Process.kill("KILL", kid)
      Process.wait(kid)
      kid = nil
      assert wait_for(8) { away.call == 1 }, "away"
      assert_operator ms - t0, :<, 4000, "away well before away_ms (the status file is written every 2 s)"
      kid = other_node(router, other, node, join: false)
      assert wait_for(8) { away.call == 0 }, "back when its node is there again, before any call"
    ensure
      if kid
        Process.kill("KILL", kid)
        Process.wait(kid)
      end
    end
  ensure
    if pid
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end

  # Another node in a process of its own (spawned, not forked: this
  # process has used zenoh-c): joins the tally table (join: true) or only
  # connects, then waits to be killed.
  def other_node(router, other, host, join:)
    code = <<~RUBY
      require "asterism"
      Asterism.connect(#{router.inspect}, node: #{other.inspect}, app: "game") do |net|
        net.start
        net[#{"#{host}/games/tally1".inspect}, timeout: 3.0].join("Other") if #{join}
        sleep
      end
    RUBY
    Process.spawn(RbConfig.ruby, "-e", code, out: File::NULL, err: File::NULL)
  end

  def wait_for(seconds)
    deadline = ms + seconds * 1000
    until ms > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  # ------------------------------------------------------------ rooms

  def credentials_tar(path, name)
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
        files.each { |n, body| tar.add_file_simple("#{name}/#{n}", 0o600, body.bytesize) { _1.write(body) } }
      end
    end
  end

  # The supervisor with tally rooms and permanent tables; its host
  # processes are children that run the Host's loop without a network
  # (Host#step), so the status they write is what the supervisor shows.
  def tally_rooms
    @rooms_dir = File.join(@dir, "rooms")
    FileUtils.mkdir_p(File.join(@rooms_dir, "certs"))
    File.write(File.join(@rooms_dir, "certs", "room-01.tar"), "")
    @tar = File.join(@dir, "credentials", "games.tar")
    credentials_tar(@tar, "games")
    @spawned = []
    cfg = AsterismGames::Config.new({ "state_dir" => File.join(@dir, "state"),
                                      "rooms" => { "dir" => @rooms_dir, "status_listen" => "127.0.0.1:0" },
                                      "permanent" => { "credentials" => @tar } }, {})
    @rooms = AsterismGames::Rooms.new(cfg, log: ->(_m) {}, spawn: lambda { |who, c|
      @spawned << [who, c]
      fork do
        h = AsterismGames::Host.new(c, log: ->(_m) {})
        ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        h.games.each_value { |g| g.join(who == "permanent" ? "fmruby-aaaaaa" : "wasm-0101", "P", ms) }
        loop do
          h.step
          sleep 0.05
        end
      end
    })
  end

  def write_rooms(slots, extra = {})
    path = File.join(@rooms_dir, "rooms.json")
    File.write(path, JSON.generate({ "format" => 1, "slots" => slots, "revoked" => [] }.merge(extra)))
  end

  def test_rooms_and_permanent_tables_of_the_game
    tally_rooms
    now = Time.now.to_i
    write_rooms({ "01" => { "room" => "aaaa", "until" => now + 3600, "app" => APP, "seats" => 2 },
                  "02" => { "room" => "bbbb", "until" => now + 3600, "app" => "/app/other.app.rb" } },
                { "hosts" => ["games"], "seat_node_prefix" => "wasm-" })
    @rooms.check(now)
    assert_equal %w[permanent 01], @spawned.map(&:first), "a host for the room opening the game, none for the other"
    perm = @spawned.assoc("permanent")[1]
    assert_equal [%w[tally1 tally], %w[tally2 tally]], perm["tables"].map { _1.values_at("name", "game") }
    room = @spawned.assoc("01")[1]
    assert_equal [@tar, "room/01", "aaaa", %w[wasm-0101 wasm-0102]],
                 room.values_at("credentials", "namespace", "room_id", "trusted_nodes")
    # Who joins, as the framework checks it for any game.
    t = AsterismGames::Host.new(room.merge("state_dir" => File.join(@dir, "x")), log: ->(_m) {}).games["tally1"]
    assert t.join("wasm-0102", "Seat", 0)["token"], "a seat"
    assert t.join("games-bot1", "Bot", 0)["token"], "the host's own names"
    assert_equal({ "error" => "identity" }, t.join("wasm-abcdef", "X", 0), "a page without a seat")
    # GET /status: the room's and the permanent tables' counts.
    @rooms.start_status_server
    port = @rooms.instance_variable_get(:@server).addr[1]
    s = nil
    40.times do
      s = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{port}/status")))
      break if s.dig("rooms", "01", "tables", "tally1") && s.dig("permanent", "tables", "tally2")
      sleep 0.1
    end
    assert_equal 1, s.dig("rooms", "01", "tables", "tally1", "humans")
    assert_equal 1, s.dig("permanent", "tables", "tally2", "members")
    assert s["busy"], "someone sits at a table"
    refute_includes JSON.generate(s), "wasm-0101"
    # The room closes: its host stops and its saved tables go.
    write_rooms({}, { "revoked" => [{ "room" => "aaaa", "until" => now + 3600 }] })
    File.utime(Time.now + 5, Time.now + 5, File.join(@rooms_dir, "rooms.json"))
    @rooms.check(now + 1)
    assert_nil @rooms.children["01"]
    refute File.exist?(File.join(@dir, "state", "rooms", "01"))
    assert File.exist?(File.join(@dir, "state", "permanent", "tally1.json")), "the permanent tables are kept"
  end
end
