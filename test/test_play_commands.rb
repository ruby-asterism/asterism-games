# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "asterism_games/play"
require "asterism_games/play/mahjong"

# `asterism-games play mahjong --commands "sit,cpu,start"` (README
# "Playing in a terminal"): the client against a mahjong table in this
# process (no network: the table's calls through a small stand-in for the
# Asterism object). The commands wait for the moment the table can take
# them: a client that joins while a game is still going on (or its end is
# still shown) sits, fills the seats and starts once the table is back in
# its lobby, instead of sending them at once and losing them.
class TestPlayCommands < Minitest::Test
  include MahjongTestHelper

  # The table's methods as the exposed object has them, with a clock.
  class Remote
    attr_accessor :now

    def initialize(table, node)
      @t = table
      @node = node
      @now = 0
    end

    def join(name) = @t.join(@node, name, @now)
    def view(token, assist) = @t.member_view(token, @now, assist) || { "error" => "token" }
    def sit(token, seat) = @t.sit(token, seat, @now)
    def stand(token) = @t.stand(token)
    def cpu(token, seat, on) = @t.cpu(token, seat, on)
    def start(token) = @t.start(token, @now)
    def rule(token, item, value) = @t.set_rule(token, item, value)
    def leave(token) = @t.leave(token)

    def act(token, sv, type, tiles)
      @t.act(token, sv, type, AsterismGames::Mahjong::Tiles.unpack(tiles), @now)
    end
  end

  # What the client asks of its Net: the object, and a subscription.
  class Net
    def initialize(remote) = @remote = remote
    def [](_path, timeout: nil) = @remote
    def session = self
    def subscribe(*) = nil
  end

  # A started client without its ticker (the test refreshes it).
  def client(remote, out = StringIO.new)
    c = AsterismGames::Play::Mahjong.new(Net.new(remote), "games/games/t", "Alice", style: "mpsz", out: out)
    c.start
    c.instance_variable_get(:@ticker)&.kill
    c
  end

  # The case of the user's try: a game going on at the table (another
  # member's, who then leaves) when the client joins with its commands.
  def test_the_commands_wait_for_the_lobby_and_the_seats
    t = human_table
    bob = Remote.new(t, "wasm-bbbbbb")
    btok = bob.join("Bob")["token"]
    assert_equal "ok", bob.sit(btok, -1)
    assert_equal "ok", bob.cpu(btok, -1, true)
    assert_equal "ok", bob.start(btok)
    assert_equal "play", t.public_view(0)["st"]

    alice = Remote.new(t, "wasm-aaaaaa")
    out = StringIO.new
    c = client(alice, out)
    c.queue_commands(%w[sit cpu start])
    assert_equal(-1, c.view["me"], "Alice watches the game")
    assert_equal "play", c.view["st"]
    assert_match(/--commands: sit \(待ち合わせを待っています\)/, out.string, "the screen says what it waits for")

    # Bob leaves: his seat goes to a CPU, nobody is left, the game is
    # abandoned and the table is back in its lobby (four CPUs).
    bob.leave(btok)
    alice.now = 1000
    t.tick(1000)
    assert_equal "wait", t.public_view(1000)["st"]
    c.refresh
    v = c.view
    assert_equal "play", v["st"], "sat, filled the seats and started"
    assert v["me"] >= 0, "Alice is seated"
    assert_equal v["me"], v["ow"], "and the owner"
  ensure
    c&.stop
  end

  # A fresh lobby: all three at once, in order.
  def test_the_commands_in_a_fresh_lobby
    t = human_table
    alice = Remote.new(t, "wasm-aaaaaa")
    c = client(alice)
    c.queue_commands(%w[sit cpu tonpuu start])
    v = c.view
    assert_equal "play", v["st"]
    assert v["me"] >= 0, "seated (the seats are drawn at the start)"
    assert_equal 1, t.public_view(0)["ru"][0], "tonpuu"
  ensure
    c&.stop
  end

  # Not the owner: the owner's commands wait (the seat is taken at once).
  def test_an_owners_command_waits_for_the_owner
    t = human_table
    bob = Remote.new(t, "wasm-bbbbbb")
    btok = bob.join("Bob")["token"]
    bob.sit(btok, -1)
    alice = Remote.new(t, "wasm-aaaaaa")
    out = StringIO.new
    c = client(alice, out)
    c.queue_commands(%w[sit cpu start])
    assert c.view["me"] >= 0, "seated"
    assert_equal "wait", c.view["st"]
    assert_match(/--commands: cpu \(卓の主ではありません。卓の主の役が回ってくるのを待っています\)/, out.string)
    bob.stand(btok) # the role passes to Alice
    c.refresh
    assert_equal "play", c.view["st"]
  ensure
    c&.stop
  end

  # Unseated and not the owner (games 0.20.0): watch waits for the role,
  # and the message does not ask for a seat.
  def test_watch_waits_for_the_role_without_asking_for_a_seat
    t = human_table
    bob = Remote.new(t, "wasm-bbbbbb")
    bob.join("Bob")
    alice = Remote.new(t, "wasm-aaaaaa")
    out = StringIO.new
    c = client(alice, out)
    c.queue_commands(%w[watch])
    assert_match(/--commands: watch \(卓の主ではありません。/, out.string)
    refute_match(/席に着く/, out.string)
  ensure
    c&.stop
  end
end
