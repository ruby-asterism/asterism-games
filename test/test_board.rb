# frozen_string_literal: true

require_relative "test_helper"

# The drawing board (README "The drawing board"): strokes, taking back,
# clearing (the owner only), what goes out on the strokes key, the limits,
# the picture in pages, saving and the host's puts.
class TestBoard < Minitest::Test
  B = AsterismGames::Board
  T = B::Table
  KEY = "asterism/games-host-aaaaaa/games/board1/strokes"

  def board(store: nil)
    T.new("board1", {}, store: store)
  end

  def pts(n, x0 = 0, y0 = 0)
    (0...n).flat_map { |i| [(x0 + i) % T::WIDTH, (y0 + i) % T::HEIGHT] }
  end

  def joined(t = board, n = 2)
    toks = (0...n).map { |i| t.join("node-#{i}", "P#{i}", 0)["token"] }
    t.take_told
    [t, *toks]
  end

  def bytes(msg)
    KEY.bytesize + Asterism::Codec.pack(msg).bytesize
  end

  def test_registered_with_its_screen_tables_and_described_methods
    g = AsterismGames.game("board")
    assert_equal T, g
    assert_equal B::Remote, g.remote
    assert_equal ["board1"], g.tables
    assert_equal ["/app/game/board/board.app.rb"], g.screens
    g.remote.exposes.each do |m, n|
      d = g.remote.docs[m]
      assert d, "#{m} has no doc"
      assert_equal n, d[0].size, "#{m}: argument names"
      assert_operator d[1].bytesize, :<=, 2048
    end
    assert_equal ["/app/game/board/board.app.rb"],
                 AsterismGames::Config.tables_for_app([{ "name" => "board1", "game" => "board" },
                                                       { "name" => "othello1", "game" => "othello" }],
                                                      "/app/game/board/board.app.rb").map { g.screens.first }
  end

  def test_a_stroke_and_more_points_go_out_on_the_strokes_key
    t, a, = joined
    r = t.line(a, 3, 1, [10, 20, 11, 21])
    assert_equal({ "id" => 1 }, r)
    assert_equal "ok", t.more(a, 1, [12, 22, 13, 23])
    told = t.take_told
    assert_equal 2, told.size
    assert(told.all? { |sub, _| sub == "strokes" })
    first, cont = told.map(&:last)
    assert_equal({ "o" => "a", "id" => 1, "c" => 3, "w" => 1, "p" => [10, 20, 11, 21], "k" => 0 }, first.except("v"))
    assert_equal [11, 21, 12, 22, 13, 23], cont["p"], "a part goes on from the stroke's last point"
    assert_equal 1, cont["k"]
    assert_operator cont["v"], :>, first["v"]
    assert_equal [10, 20, 11, 21, 12, 22, 13, 23], t.strokes[0]["p"]
    assert_equal 4, t.points
    v = t.member_view(a, 0)
    assert_equal [1, 4, 1, 1, true], v.values_at("n", "np", "last", "mine", "own")
  end

  def test_what_is_refused
    t, a, b = joined
    assert_equal "token", t.line("nope", 0, 0, [1, 1])
    assert_equal "colour", t.line(a, 16, 0, [1, 1])
    assert_equal "colour", t.line(a, "1", 0, [1, 1])
    assert_equal "width", t.line(a, 0, 4, [1, 1])
    assert_equal "points", t.line(a, 0, 0, [])
    assert_equal "points", t.line(a, 0, 0, [1])
    assert_equal "points", t.line(a, 0, 0, [640, 0])
    assert_equal "points", t.line(a, 0, 0, [0, 360])
    assert_equal "points", t.line(a, 0, 0, [-1, 0])
    assert_equal "points", t.line(a, 0, 0, [1.5, 0])
    assert_equal "points", t.line(a, 0, 0, pts(T::PART_POINTS + 1))
    assert_equal({ "id" => 1 }, t.line(a, 0, 0, pts(T::PART_POINTS)))
    assert_equal "not yours", t.more(b, 1, [1, 1]), "another member's stroke"
    t.line(a, 0, 0, [5, 5])
    assert_equal "not yours", t.more(a, 1, [1, 1]), "only the newest stroke goes on"
    assert_equal [], t.take_told.select { |_, m| m["o"] != "a" }
  end

  def test_a_stroke_has_at_most_line_points
    t, a, = joined
    id = t.line(a, 0, 0, pts(T::PART_POINTS))["id"]
    (T::LINE_POINTS / T::PART_POINTS - 1).times { assert_equal "ok", t.more(a, id, pts(T::PART_POINTS)) }
    assert_equal T::LINE_POINTS, t.strokes[0]["p"].size / 2
    assert_equal "long", t.more(a, id, [1, 1])
  end

  def test_undo_takes_back_the_callers_own_last_stroke
    t, a, b = joined
    t.line(a, 1, 0, [1, 1])
    t.line(b, 2, 0, [2, 2])
    t.line(a, 3, 0, [3, 3])
    t.take_told
    assert_equal "ok", t.undo(b)
    assert_equal [1, 3], t.strokes.map { _1["id"] }
    assert_equal [["strokes", { "o" => "u", "id" => 2 }]], t.take_told.map { |s, m| [s, m.except("v")] }
    assert_equal "nothing", t.undo(b)
    assert_equal "ok", t.undo(a)
    assert_equal [1], t.strokes.map { _1["id"] }
    assert_equal 1, t.points
  end

  def test_only_the_owner_clears_and_the_owner_passes_on
    t, a, b = joined
    t.line(a, 1, 0, [1, 1])
    t.line(b, 1, 0, [2, 2])
    t.take_told
    assert t.member_view(a, 0)["own"]
    refute t.member_view(b, 0)["own"]
    assert_equal "not owner", t.clear(b)
    assert_equal 2, t.strokes.size
    assert_equal "ok", t.clear(a)
    assert_equal [], t.strokes
    assert_equal 0, t.points
    assert_equal [{ "o" => "c" }], t.take_told.map { _2.except("v") }
    assert t.leave(a)
    assert_equal "node-1", t.owner, "the next one in the order of joining"
    assert_equal "ok", t.clear(b)
    c = t.join("node-9", "Late", 0)
    refute c["owner"]
    assert t.join("node-1", "P1", 0)["owner"]
  end

  def test_the_oldest_strokes_go_past_the_limits
    t, a, = joined
    (T::MAX_STROKES + 5).times { |i| t.line(a, 0, 0, [i % T::WIDTH, 0]) }
    assert_equal T::MAX_STROKES, t.strokes.size
    assert_equal 6, t.strokes[0]["id"], "the oldest five dropped"
    t2, b, = joined
    id = nil
    n = 0
    while n <= T::MAX_POINTS + T::LINE_POINTS
      id = t2.line(b, 0, 0, pts(T::PART_POINTS))["id"]
      3.times { t2.more(b, id, pts(T::PART_POINTS)) }
      n += T::LINE_POINTS
    end
    assert_operator t2.points, :<=, T::MAX_POINTS
    assert_equal id, t2.strokes[-1]["id"], "the newest stays"
    puts "\n  board: #{t2.strokes.size} strokes of #{T::LINE_POINTS} points at the point limit (#{t2.points})"
  end

  # A message is under the 4096 bytes a board takes (key and Zenoh header
  # in it): the largest part, colour and width the largest, points of
  # 3-byte coordinates, the largest id and version.
  def test_the_largest_message
    t, a, = joined
    big = (0...T::PART_POINTS).flat_map { |i| [T::WIDTH - 1 - (i % 2), T::HEIGHT - 1 - (i % 2)] }
    t.instance_variable_set(:@next_id, 2**31)
    t.instance_variable_set(:@ver, 2**31)
    id = t.line(a, T::COLORS - 1, T::WIDTHS - 1, big)["id"]
    t.more(a, id, big)
    msgs = t.take_told.map(&:last)
    worst = msgs.map { bytes(_1) }.max
    assert_operator worst, :<, 2048, "a part: #{worst} B"
    page = t.picture(0, 0)
    pb = KEY.bytesize + Asterism::Codec.pack({ "value" => page }).bytesize
    assert_operator pb, :<, 3072, "a page of the picture: #{pb} B"
    puts "\n  board: the largest strokes message #{worst} B, a page of the picture #{pb} B"
  end

  def test_the_picture_in_pages_gives_every_point_once
    t, a, b = joined
    want = []
    7.times do |i|
      tok = i.even? ? a : b
      id = t.line(tok, i, i % 4, pts(T::PART_POINTS, i * 3, i))["id"]
      p = pts(T::PART_POINTS, i * 3, i)
      (i % 4).times do |j|
        more = pts(100 + j, i * 5, j)
        t.more(tok, id, more)
        p += more
      end
      want << [id, i, i % 4, p]
    end
    got = {}
    cur = [0, 0]
    pages = 0
    while cur
      pg = t.picture(*cur)
      pages += 1
      assert_operator pg["p"].sum { _1[3].size / 2 }, :<=, T::PAGE_POINTS + pg["p"].size
      pg["p"].each do |id, c, w, p, k|
        if k == 1
          assert got[id], "a stroke goes on from a page before"
          assert_equal got[id][2][-2, 2], p[0, 2], "the point before at"
          got[id][2].concat(p.drop(2))
        else
          got[id] = [c, w, p.dup]
        end
      end
      cur = pg["nx"]
    end
    assert_equal want, got.map { |id, (c, w, p)| [id, c, w, p] }
    assert_operator pages, :>, 3
    t.undo(b)
    ids = t.strokes.map { _1["id"] }
    assert_equal ids[ids.index(6) + 1..], t.picture(6, 3)["p"].map(&:first) - [6] if ids.include?(6)
    assert_equal [], t.picture(10_000, 0)["p"]
    assert_nil t.picture(10_000, 0)["nx"]
    assert_equal ids.first, t.picture("x", nil)["p"][0][0], "bad arguments read from the start"
  end

  def test_saved_and_resumed_with_its_owner_and_ids
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, a, b = joined(board(store: store))
      t.line(a, 1, 2, [1, 2, 3, 4])
      id = t.line(b, 5, 0, [9, 9])["id"]
      t.more(b, id, [10, 10])
      t.save(0, force: true)
      t2 = board(store: store)
      assert_equal t.strokes, t2.strokes
      assert_equal 4, t2.points
      assert_equal "node-0", t2.owner
      assert_equal({ "id" => 3 }, t2.line(a, 0, 0, [0, 0]), "ids go on")
      assert_equal "ok", t2.undo(b), "members keep their tokens"
      assert_equal "ok", t2.clear(a)
    end
  end

  def test_writes_are_held_to_one_a_second
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, a, = joined(board(store: store))
      t.save(0)
      t.line(a, 0, 0, [1, 1])
      t.save(100)
      assert t.unsaved?, "held"
      assert_equal 0, store.read("board1")["strokes"].size
      t.save(1000)
      refute t.unsaved?
      assert_equal 1, store.read("board1")["strokes"].size
      t.line(a, 0, 0, [2, 2])
      t.save(1001, force: true)
      assert_equal 2, store.read("board1")["strokes"].size
    end
  end

  def test_the_host_puts_the_strokes_before_the_state_and_counts_them_in_the_status
    Dir.mktmpdir do |dir|
      cfg = AsterismGames::Config.new({ "state_dir" => dir, "node" => "games", "tables" => [{ "name" => "board1", "game" => "board" }] }, {}).data
      host = AsterismGames::Host.new(cfg, log: ->(_m) {})
      session = Struct.new(:puts) { def put(key, bytes) = puts << [key, Asterism::Codec.unpack(bytes)] }.new([])
      host.instance_variable_set(:@net, Struct.new(:session).new(session))
      g = host.games["board1"]
      tok = host.instance_variable_get(:@remotes)["board1"].join("Ann", from: "node-a")["token"]
      host.step
      session.puts.clear
      r = host.instance_variable_get(:@remotes)["board1"].line(tok, 2, 1, [5, 5, 6, 6], from: "node-a")
      assert_equal 1, r["id"]
      host.step
      keys = session.puts.map(&:first)
      assert_equal ["asterism/games/games/board1/strokes", "asterism/games/games/board1/state"], keys
      assert_equal [5, 5, 6, 6], session.puts[0][1]["p"]
      assert_equal 1, session.puts[1][1]["n"]
      assert_equal 1, host.tables_status["board1"]["strokes"]
      assert_equal %w[st members humans cpus away strokes].sort, host.tables_status["board1"].keys.sort
    end
  end

  # The host restarted: the picture comes back (Host#save_all writes what
  # a held write had not).
  def test_a_host_started_again_has_the_picture
    Dir.mktmpdir do |dir|
      cfg = AsterismGames::Config.new({ "state_dir" => dir, "tables" => [{ "name" => "board1", "game" => "board" }] }, {}).data
      host = AsterismGames::Host.new(cfg, log: ->(_m) {})
      g = host.games["board1"]
      tok = g.join("node-a", "Ann", host.instance_variable_get(:@clock).call)["token"]
      g.line(tok, 1, 1, [1, 1])
      host.step
      g.line(tok, 1, 1, [2, 2])
      host.step
      host.send(:save_all)
      h2 = AsterismGames::Host.new(cfg, log: ->(_m) {})
      assert_equal [[1, 1], [2, 2]], h2.games["board1"].strokes.map { _1["p"] }
    end
  end
end
