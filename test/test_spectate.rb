# frozen_string_literal: true

require "test_helper"
require "json"

# What the host puts for those who watch from outside the table (README
# "Spectate"): Game#spectate_view (nil by default: nothing), the mahjong
# table's (the four hands, nothing nobody knows yet), held for the table's
# spectator delay, on asterism/<node>/spectate/<table>/state, a room's
# table as room<slot>-<table> on a connection without the room's namespace.
class SpectateTest < Minitest::Test
  # Records the puts (key, unpacked value) like a session.
  class Session
    attr_reader :puts

    def initialize
      @puts = []
    end

    def put(key, bytes)
      @puts << [key, Asterism::Codec.unpack(bytes)]
    end

    def reconnecting? = false

    def keys = @puts.map(&:first)
    def spectate = @puts.select { |k, _| k.include?("/spectate/") }
  end

  def host(dir, tables, **cfg)
    c = { "state_dir" => dir, "node" => "games", "app" => "games", "tables" => tables }.merge(cfg.transform_keys(&:to_s))
    h = AsterismGames::Host.new(c, log: ->(_m) {})
    s = Session.new
    h.instance_variable_set(:@net, Struct.new(:session).new(s))
    [h, s]
  end

  def clock(h, now)
    h.instance_variable_set(:@clock, -> { now })
  end

  def test_a_game_puts_nothing_by_default
    g = AsterismGames::Game.new("t")
    assert_nil g.spectate_view(0)
    assert_equal 0, g.spectate_delay_ms
    Dir.mktmpdir do |dir|
      h, s = host(dir, [{ "name" => "othello1", "game" => "othello" }, { "name" => "board1", "game" => "board" }])
      3.times { |i| clock(h, 1000 + i * 6000) && h.step }
      assert_includes s.keys, "asterism/games/games/othello1/state"
      assert_empty s.spectate, "othello and the board have nothing to hide: no spectate key"
      assert_empty h.instance_variable_get(:@spec)
    end
  end

  def test_the_keys_of_the_permanent_tables_and_of_a_room
    Dir.mktmpdir do |dir|
      h, = host(dir, [{ "name" => "othello1", "game" => "othello" }])
      assert_equal "asterism/games/spectate/othello1/state", h.spectate_key("othello1")
      r, = host(dir, [{ "name" => "othello1", "game" => "othello" }], namespace: "room/03", spectate_label: "room03")
      assert_equal "asterism/games/spectate/room03-othello1/state", r.spectate_key("othello1")
      r, = host(dir, [{ "name" => "othello1", "game" => "othello" }], namespace: "room/04")
      assert_equal "asterism/games/spectate/room04-othello1/state", r.spectate_key("othello1"), "from the namespace"
      # Each part a name (asterism docs/protocol.md 2.1).
      r.spectate_key("othello1").split("/").each { |p| refute_match(%r{[*$?#/]|\A@|\A\z}, p) }
    end
  end

  def test_the_rooms_give_their_hosts_the_label_and_whether_they_may_put_outside
    Dir.mktmpdir do |dir|
      cfg = AsterismGames::Config.new({ "state_dir" => dir, "rooms" => { "dir" => dir, "node" => "games" } }, {}).data
      rooms = AsterismGames::Rooms.new(cfg, log: ->(_m) {}, spawn: ->(_s, _c) { 1 })
      own = rooms.child_config("02", "games.tar", dir, "r", { "own" => true, "seats" => [], "prefix" => "games" }, nil)
      assert_equal "room02", own["spectate_label"]
      assert_equal "room/02", own["namespace"]
      assert own["spectate_outside"], "the host's own certificate: its own keys outside"
      slot = rooms.child_config("02", "room-02.tar", dir, "r", { "own" => false, "seats" => [], "prefix" => nil }, nil)
      refute slot["spectate_outside"], "the slot's certificate is the room's: nothing outside"
    end
  end

  unless GEM_ONLY
    M = AsterismGames::Mahjong

    def mahjong(**opts)
      { "name" => "mahjong1", "game" => "mahjong", "humans" => 0, "cpu_ms" => 50, "result_ms" => 100,
        "deal_pause_ms" => 0 }.merge(opts.transform_keys(&:to_s))
    end

    # Every key of a value, nested.
    def keys_of(v, out = [])
      case v
      when Hash then v.each { |k, x| out << k.to_s; keys_of(x, out) }
      when Array then v.each { |x| keys_of(x, out) }
      end
      out
    end

    FORBIDDEN = %w[token tokens node nodes wall yama ura uradora ura_indicators uradora_hyouji seed haipai rinshan
                   dead_wall live_wall].freeze

    def test_the_mahjong_view_has_the_four_hands_and_nothing_nobody_knows
      t = M::Table.new("mahjong1", { "humans" => 1, "cpu_ms" => 0, "result_ms" => 0, "deal_pause_ms" => 0 })
      tok = t.join("wasm-aaaaa0", "Ann", 0)["token"]
      assert_equal "ok", t.sit(tok, -1, 0)
      sp = t.join("wasm-cccc01", "Watcher", 0)["token"]
      v = t.spectate_view(0)
      assert_equal "wait", v["status"]
      refute v["seats"].any? { |s| s.key?("hand") }, "no hands in the lobby"
      t.cpu(tok, -1, true)
      assert_equal "ok", t.start(tok, 0)
      t.tick(10)
      v = t.spectate_view(10)
      assert_equal "play", v["status"]
      assert_equal 4, v["seats"].size
      v["seats"].each_with_index do |s, i|
        h, d = t.hand_of(i)
        assert_equal M::Tiles.unpack(h), s["hand"], "seat #{i}'s hand"
        d >= 0 ? assert_equal(M::Tiles.name(d), s["drawn"]) : assert_nil(s["drawn"])
        assert_equal s["hand_count"], s["hand"].size + (s["drawn"] ? 1 : 0)
      end
      sv = t.member_view(sp, 10)
      assert_equal sv["sh"].map { |b| M::Tiles.unpack(b) }, v["seats"].map { |s| s["hand"] },
                   "the same hands as a spectator member's view"
      st = t.state
      assert_equal st.dora_hyouji.map(&:to_s), v["round"] && v["dora_indicators"], "the turned indicators only"
      text = JSON.generate(v)
      [tok, sp, "wasm-aaaaa0", "wasm-cccc01"].each { |x| refute_includes text, x }
      assert_empty keys_of(v) & FORBIDDEN, "no token, node, wall or ura dora"
      refute v.key?("moves"), "nobody's moves"
      assert_equal 0, v["delay_s"]
    end

    # A CPU game played through on a host: every spectate put has no
    # secret, and the keys are the permanent table's.
    def test_a_cpu_game_on_the_host_puts_the_spectate_key
      Dir.mktmpdir do |dir|
        h, s = host(dir, [mahjong])
        g = h.games["mahjong1"]
        now = 0
        statuses = []
        until now > 600_000 || statuses.include?("result")
          now += 20
          clock(h, now)
          h.step
          statuses << g.status
        end
        sp = s.spectate
        refute_empty sp
        assert sp.all? { |k, _| k == "asterism/games/spectate/mahjong1/state" }
        assert sp.any? { |_k, v| v["status"] == "play" && v["seats"].all? { |x| x["hand"].is_a?(Array) } }
        sp.each { |_k, v| assert_empty keys_of(v) & FORBIDDEN }
        st = s.puts.reject { |k, _| k.include?("/spectate/") }.map(&:last)
        st.each { |v| refute v.key?("sh"), "the players' state has no hand" }
      end
    end

    # Delay 0: at once. Delay N: nothing before N, then each in order, as
    # it was N ago, also across a round's end.
    def test_the_delay
      Dir.mktmpdir do |dir|
        h, s = host(dir, [mahjong])
        g = h.games["mahjong1"]
        clock(h, 0)
        h.step
        assert_equal 1, s.spectate.size, "no delay: at once"
        assert_equal g.sv, s.spectate.last[1]["sv"]
      end
      Dir.mktmpdir do |dir|
        delay = 3000
        h, s = host(dir, [mahjong("spectator_delay_ms" => delay, "cpu_ms" => 150)])
        g = h.games["mahjong1"]
        assert_equal delay, g.spectate_delay_ms
        taken = {} # sv => the time it was first there
        now = 0
        puts_at = []
        while now < 60_000
          clock(h, now)
          n = s.spectate.size
          h.step
          taken[g.sv] ||= now
          s.spectate[n..].each { |_k, v| puts_at << [now, v] }
          now += 10
        end
        refute_empty puts_at
        assert_operator puts_at.first[0], :>=, delay, "nothing before the delay"
        ends = 0
        puts_at.each do |at, v|
          first = taken[v["sv"]]
          assert first, "a version the table had"
          assert_operator at - first, :>=, delay, "sv #{v['sv']} shown #{at - first} ms after it was there"
          ends += 1 if v["status"] == "result"
        end
        svs = puts_at.map { |_at, v| v["sv"] }
        assert_equal svs, svs.sort, "in order"
        assert_operator ends, :>=, 1, "a round's end went through the delay too"
        assert_operator g.sv, :>, svs.max, "behind the table"
        assert_equal delay / 1000, puts_at.last[1]["delay_s"]
      end
    end

    # A room's table: the state in the room (the namespaced connection),
    # the spectate key outside it on the connection of its own; with the
    # slot's certificate nowhere.
    def test_a_rooms_table_puts_its_spectate_key_outside_the_room
      Dir.mktmpdir do |dir|
        h, inside = host(dir, [mahjong], namespace: "room/01", spectate_label: "room01", spectate_outside: true,
                                          credentials: "games.tar")
        outside = Session.new
        h.instance_variable_set(:@spectate_conn, outside)
        clock(h, 0)
        h.step
        assert_equal ["asterism/games/games/mahjong1/state"], inside.keys.uniq, "in the room: the state only"
        assert_equal ["asterism/games/spectate/room01-mahjong1/state"], outside.keys.uniq
        assert_empty outside.puts.reject { |k, _| k.include?("/spectate/") }

        h2, inside2 = host(dir, [mahjong], namespace: "room/02", spectate_label: "room02", spectate_outside: false)
        clock(h2, 0)
        h2.open_spectate(0)
        assert_nil h2.instance_variable_get(:@spectate_conn), "no connection opened"
        h2.step
        assert_empty inside2.spectate, "never into the room"
      end
    end

    def test_the_last_spectate_put_is_put_again
      Dir.mktmpdir do |dir|
        h, s = host(dir, [mahjong("humans" => 4)]) # nobody sits: the lobby stays as it is
        clock(h, 0)
        h.step
        clock(h, 2000)
        h.step
        assert_equal 1, s.spectate.size
        clock(h, AsterismGames::Host::PUT_EVERY_MS + 1)
        h.step
        assert_equal 2, s.spectate.size
        assert_equal s.spectate[0][1], s.spectate[1][1]
      end
    end
  end
end
