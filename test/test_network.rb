# frozen_string_literal: true

require_relative "test_helper"

# The host through a real Zenoh router (skipped without one):
#   ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 rake test
# A host runs in a child process; this process calls it as a player would.
class TestNetwork < Minitest::Test
  include MahjongTestHelper

  ROUTER = ENV["ASTERISM_TEST_ROUTER"]

  def setup
    skip "set ASTERISM_TEST_ROUTER to run against a router" unless ROUTER
    @dir = Dir.mktmpdir
    @node = "games-test-#{Process.pid}"
    cfg = AsterismGames::Config.new({ "router" => ROUTER, "node" => @node, "state_dir" => @dir,
                                      "tables" => [{ "name" => "mahjong1", "game" => "mahjong", "cpu_ms" => 0 }] }, {})
    @pid = fork do
      host = AsterismGames::Host.new(cfg, log: ->(_m) {})
      trap("TERM") { host.stop! }
      host.run
      exit!(0)
    end
    Asterism.connect(ROUTER, node: "test-client-#{Process.pid}", app: "game")
    @t = nil
    50.times do
      Asterism.poll
      @t = Asterism.each("#{@node}/games/*").first
      break if @t
      sleep 0.1
    end
    flunk "the host did not come up" unless @t
    @t = Asterism["#{@node}/games/mahjong1", timeout: 3.0]
  end

  def teardown
    return unless ROUTER
    Asterism.close
    if @pid
      Process.kill("TERM", @pid)
      Process.wait(@pid)
    end
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_tokens_and_refusals_over_the_network
    assert_nil @t.mine, "not a member yet"
    r = @t.join("Tester")
    token = r["token"]
    assert_equal 32, token.size
    assert_equal r, @t.mine
    assert_equal "ok", @t.sit(token, -1)
    assert_equal "ok", @t.cpu(token, -1, true)
    assert_equal "ok", @t.start(token)
    assert_equal({ "error" => "token" }, @t.view("wrong"))
    assert_equal({ "error" => "token" }, @t.view(""))
    assert_equal "token", @t.act("wrong", 0, E::DAHAI, "\x00".b)
    v = nil
    40.times do
      v = @t.view(token)
      break if v["a"].any? { |a| a[0] == E::DAHAI }
      sleep 0.05
    end
    assert v["h"], "the seat's view has its hand"
    pub = @t.table
    assert_nil pub["h"], "the public view has no hand"
    assert_equal "not offered", @t.act(token, v["sv"], E::RON, "".b)
    assert_equal "stale", @t.act(token, v["sv"] - 1, E::DAHAI, [v["dt"]].pack("C"))
    tile = v["dt"] >= 0 ? v["dt"] : v["h"].getbyte(0)
    assert_equal "ok", @t.act(token, v["sv"], E::DAHAI, [tile].pack("C"))
    assert_operator reply_bytes(@t.view(token)), :<, 3800
  end
end
