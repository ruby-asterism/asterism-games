# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

# Who is there by the table app (README "Who is there"), through a real
# Zenoh router (skipped without one):
#   ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 rake test
# A player's node runs its table app ("game") and another application;
# when the table app closes, the host makes the member away at once
# although the node stays on the network.
class TestAppPresence < Minitest::Test
  include MahjongTestHelper

  ROUTER = ENV["ASTERISM_TEST_ROUTER"]

  # A child: node, app; joins the table and sits when its app is "game".
  CHILD = <<~'RUBY'
    require "asterism"
    router, node, app, host = ARGV
    Asterism.connect(router, node: node, app: app)
    if app == "game"
      t = Asterism["#{host}/games/mahjong1", timeout: 3.0]
      tok = t.join("P")["token"]
      t.sit(tok, -1)
    end
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll
      r, = IO.select([STDIN], nil, nil, 0.005)
      break if r && STDIN.read_nonblock(1, exception: false).nil?
    end
    Asterism.close
  RUBY

  def setup
    skip "set ASTERISM_TEST_ROUTER to run against a router" unless ROUTER
    @dir = Dir.mktmpdir
    @node = "games-app-#{Process.pid}"
    # The host in a process of its own (spawned, not forked: a fork after
    # zenoh-c was used in this process would hang).
    host = <<~RUBY
      require "asterism_games"
      require "asterism_games/mahjong"
      cfg = AsterismGames::Config.new({ "router" => #{ROUTER.inspect}, "node" => #{@node.inspect},
                                        "state_dir" => #{@dir.inspect},
                                        "tables" => [{ "name" => "mahjong1", "game" => "mahjong" }] }, {})
      host = AsterismGames::Host.new(cfg, log: ->(_m) {})
      trap("TERM") { host.stop! }
      host.run
    RUBY
    inc = $LOAD_PATH.select { |p| File.exist?(File.join(p, "asterism.rb")) || File.exist?(File.join(p, "asterism/zenoh.rb")) }
    lib = File.expand_path("../lib", __dir__)
    app = File.expand_path("../app", __dir__)
    @pid = Process.spawn(RbConfig.ruby, "-I", lib, "-I", app, *inc.flat_map { ["-I", _1] }, "-e", host, out: File::NULL)
    @children = []
  end

  def teardown
    return unless ROUTER
    @children.each do |c|
      c.close_write rescue nil
      c.close rescue nil
    end
    if @pid
      Process.kill("TERM", @pid)
      Process.wait(@pid)
    end
    FileUtils.rm_rf(@dir) if @dir
  end

  def child(node, app)
    inc = $LOAD_PATH.select { |p| File.exist?(File.join(p, "asterism.rb")) || File.exist?(File.join(p, "asterism/zenoh.rb")) }
    c = IO.popen([RbConfig.ruby, *inc.flat_map { ["-I", _1] }, "-e", CHILD, ROUTER, node, app, @node], "r+")
    assert_equal "ready", c.gets&.strip
    @children << c
    c
  end

  # The watcher: calls the table and times the member's away flag after
  # the table app closed. In a process of its own too, so that this
  # process never uses zenoh-c (TestNetwork forks its host and would hang
  # in a fork made after that).
  WATCH = <<~'RUBY'
    require "asterism"
    router, host, player = ARGV
    Asterism.connect(router, node: "app-watch-#{Process.pid}", app: "watch")
    t = nil
    100.times do
      Asterism.poll
      break if (t = Asterism.each("#{host}/games/mahjong1").first)
      sleep 0.05
    end
    abort "the host did not come up" unless t
    t = Asterism["#{host}/games/mahjong1", timeout: 3.0]
    away = -> { (t.table["mb"] || []).find { _1[0] == "P" }&.dig(2).to_i & 1 == 1 }
    STDOUT.puts "watching #{away.call ? 'away' : 'there'}"
    STDOUT.flush
    STDIN.gets # the table app closes now
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    until away.call
      abort "not away after 5 s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 > 5
      sleep 0.002
    end
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    STDOUT.puts "away #{ms} #{Asterism.nodes.include?(player)}"
    STDOUT.flush
    Asterism.close
  RUBY

  def test_the_table_app_closing_makes_the_member_away
    player = "player-#{Process.pid}"
    other = child(player, "other")
    game = child(player, "game")
    inc = $LOAD_PATH.select { |p| File.exist?(File.join(p, "asterism.rb")) || File.exist?(File.join(p, "asterism/zenoh.rb")) }
    w = IO.popen([RbConfig.ruby, *inc.flat_map { ["-I", _1] }, "-e", WATCH, ROUTER, @node, player], "r+")
    @children << w
    assert_equal "watching there", w.gets&.strip, "seated and there"
    game.close_write
    w.puts "go"
    w.flush
    game.read
    game.close
    @children.delete(game)
    r = w.gets.to_s.split
    assert_equal "away", r[0], r.inspect
    ms = r[1].to_i
    assert_equal "true", r[2], "the node stays (its other application)"
    puts "\n  the table app closed: away after #{ms} ms (the node stays with its other application)"
    assert_operator ms, :<, 3000
    other.close_write
  end
end
