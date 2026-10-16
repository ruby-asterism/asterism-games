# frozen_string_literal: true

require_relative "test_helper"

# The othello table (README "The othello table"): the rules, the CPU, the
# seats and the owner, time, saving.
class TestOthello < Minitest::Test
  O = AsterismGames::Othello
  B = O::Board

  def board(marks)
    cells = Array.new(64, B::EMPTY)
    marks.each { |code, c| cells[B.square(code)] = c }
    B.new(cells)
  end

  def game_on(b, turn = B::BLACK)
    g = O::Match.new
    g.instance_variable_set(:@board, b)
    g.instance_variable_set(:@turn, turn)
    g
  end

  def table(**opts)
    O::Table.new("othello1", { "cpu_ms" => 0 }.merge(opts.transform_keys(&:to_s)))
  end

  # Two humans seated, started by the first. Returns [table, tokens by seat].
  def two_players(t = table, now = 0)
    a = t.join("node-a", "A", now)["token"]
    b = t.join("node-b", "B", now)["token"]
    assert_equal "ok", t.sit(a, -1, now)
    assert_equal "ok", t.sit(b, -1, now)
    assert_equal "ok", t.start(a, now)
    [t, t.seats.to_h { |s| [t.seats.index(s), s["token"]] }]
  end

  # ------------------------------------------------------------ the rules

  def test_the_start_and_the_legal_moves
    b = B.new
    assert_equal "...........................WB......BW...........................", b.to_s
    assert_equal %w[d3 c4 f5 e6], b.moves(B::BLACK).map { B.code(_1) }
    assert_equal %w[e3 f4 c5 d6], b.moves(B::WHITE).map { B.code(_1) }
    refute b.legal?(B.square("a1"), B::BLACK)
    refute b.legal?(B.square("d4"), B::BLACK), "not on a disc"
    assert_equal [19, -1, nil, nil], ["d3", "--", "i1", "a9"].map { B.square(_1) }
  end

  def test_a_move_turns_the_discs_it_closes_in_every_direction
    # d4 for black closes c3 (to b2), d3 (to d2) and e4 (to f4), not c4 (open).
    b = board("b2" => B::BLACK, "c3" => B::WHITE, "d2" => B::BLACK, "d3" => B::WHITE,
              "e4" => B::WHITE, "f4" => B::BLACK, "c4" => B::WHITE)
    assert_equal %w[c3 d3 e4], b.flips(B.square("d4"), B::BLACK).map { B.code(_1) }.sort
    b.place(B.square("d4"), B::BLACK)
    assert_equal B::BLACK, b[B.square("d4")]
    %w[c3 d3 e4].each { |c| assert_equal B::BLACK, b[B.square(c)], c }
    assert_equal B::WHITE, b[B.square("c4")], "a line not closed is not turned"
    assert_raises(ArgumentError) { b.place(B.square("a8"), B::BLACK) }
  end

  def test_a_side_that_cannot_move_passes_by_itself
    g = game_on(board("b1" => B::WHITE, "c1" => B::BLACK, "f1" => B::WHITE, "g1" => B::BLACK, "h1" => B::BLACK))
    assert g.play(B.square("a1"))
    assert_equal "a1--", g.hist, "white has no move: a pass"
    assert_equal B::BLACK, g.turn
    refute g.over?
    assert_equal ["e1"], g.moves.map { B.code(_1) }
  end

  def test_the_game_ends_when_neither_side_can_move_and_the_discs_decide
    g = game_on(board("b1" => B::WHITE, "c1" => B::BLACK))
    refute g.play(B.square("d1")), "not legal"
    assert g.play(B.square("a1"))
    assert g.over?
    assert_equal [], g.moves
    assert_equal B::BLACK, g.winner
    refute g.play(B.square("h8"))
    assert_equal B::WHITE, game_on(board("a1" => B::WHITE, "a2" => B::WHITE, "h8" => B::BLACK)).winner
    assert_equal 0, game_on(board("a1" => B::WHITE, "h8" => B::BLACK)).winner, "a draw"
  end

  def test_a_history_replays
    g = O::Match.new
    g.play(g.moves.first) until g.over?
    r = O::Match.replay(g.hist)
    assert_equal g.board.to_s, r.board.to_s
    assert r.over?
    assert_nil O::Match.replay("d3d3"), "an illegal move"
  end

  # ------------------------------------------------------------ the CPU

  def test_the_cpu_plays_only_legal_moves_to_the_end
    5.times do |k|
      g = O::Match.new
      # A few random moves first, so the games differ.
      rng = Random.new(k)
      (k * 3).times { g.play(g.moves.sample(random: rng)) unless g.over? }
      until g.over?
        sq = O::Cpu.choose(g.board, g.turn)
        assert_includes g.moves, sq
        assert g.play(sq)
      end
      assert_equal 64, g.board.count(B::BLACK) + g.board.count(B::WHITE) + g.board.count(B::EMPTY)
    end
    assert_nil O::Cpu.choose(board("a1" => B::BLACK), B::WHITE), "no move: nothing"
    assert_equal "a1", B.code(O::Cpu.choose(board("b1" => B::WHITE, "c1" => B::BLACK, "b2" => B::WHITE, "b3" => B::BLACK), B::BLACK)),
                 "a corner first"
  end

  def test_a_game_against_the_cpu_to_the_end
    t = table
    a = t.join("node-a", "A", 0)["token"]
    assert_equal "ok", t.sit(a, 1, 0)
    assert_equal "seats", t.start(a, 0)
    assert_equal "ok", t.cpu(a, -1, true)
    assert_equal "ok", t.start(a, 0)
    me = t.seats.index { |s| s["kind"] == "human" }
    now = 0
    200.times do
      break if t.status == "over"
      t.tick(now += 10)
      v = t.member_view(a, now)
      next unless v["tn"] == me
      sq = O::Cpu.choose(t.game.board, me + 1)
      assert_equal "stale", t.move(a, v["n"] - 1, B.code(sq), now) if v["n"].positive?
      assert_equal "ok", t.move(a, v["n"], B.code(sq), now)
    end
    assert_equal "over", t.status
    v = t.public_view(now)
    assert_equal "count", v["res"]["why"]
    assert_equal v["cnt"], [v["res"]["b"], v["res"]["wc"]]
    assert_equal({ "st" => "over", "members" => 1, "humans" => 1, "cpus" => 1, "away" => 0 },
                 t.summary(now).slice("st", "members", "humans", "cpus", "away"))
  end

  # ------------------------------------------------------------ seats

  def test_the_seats_the_owner_and_the_moves
    t, tok = two_players
    assert_equal "play", t.status
    v = t.public_view(0)
    assert_equal [1, 1], v["sk"]
    assert_equal 0, v["tn"], "seat 0 is black and moves first"
    assert_equal "d3c4f5e6", v["lg"]
    assert_equal "not your turn", t.move(tok[1], 0, "e3", 0)
    assert_equal "illegal", t.move(tok[0], 0, "a1", 0)
    assert_equal "illegal", t.move(tok[0], 0, "zz", 0)
    assert_equal "token", t.move("x", 0, "d3", 0)
    assert_equal "not waiting", t.sit(tok[0], 1, 0)
    assert_equal "ok", t.move(tok[0], 0, "d3", 0)
    assert_equal [1, "d3", [4, 1]], t.public_view(0).values_at("tn", "last", "cnt")
    w = t.join("node-c", "C", 0)
    assert_equal(-1, w["seat"], "a spectator")
    assert_equal "not seated", t.move(w["token"], 1, "c3", 0)
    assert_equal(-1, t.member_view(w["token"], 0)["me"])
    assert_equal "ok", t.resign(tok[1], 0)
    assert_equal({ "w" => 0, "why" => "resign", "b" => 4, "wc" => 1 }, t.public_view(0)["res"])
    # After the game: a seat change goes back to the lobby.
    assert_equal "ok", t.stand(tok[1])
    assert_equal ["wait", nil], t.public_view(0).values_at("st", "bd")
  end

  def test_the_owner_passes_on_and_a_leaving_player_gets_a_cpu
    t = table
    a = t.join("node-a", "A", 0)["token"]
    b = t.join("node-b", "B", 0)["token"]
    t.sit(a, 0, 0)
    t.sit(b, 1, 0)
    assert_equal "not owner", t.start(b, 0)
    t.leave(a)
    assert_equal 1, t.public_view(0)["ow"], "the owner's role passes on"
    assert_equal "ok", t.cpu(b, 0, true)
    assert_equal "ok", t.start(b, 0)
    t.leave(b)
    assert_equal [2, 2], t.public_view(0)["sk"], "during a game the CPU takes the seat"
  end

  def test_spectators_have_a_limit
    t = table(spectators: 1)
    assert t.join("n1", "1", 0)["token"]
    assert t.join("n2", "2", 0)["token"]
    assert t.join("n3", "3", 0)["token"], "two seats are free in the lobby"
    assert_equal({ "error" => "spectators" }, t.join("n4", "4", 0))
  end

  # ------------------------------------------------------------ time

  def test_no_time_limit_by_default
    t, = two_players
    t.tick(3_600_000)
    assert_equal 0, t.game.n
    assert_nil t.public_view(0)["dl"]
  end

  def test_when_the_time_runs_out_the_cpu_plays_the_move
    t, tok = two_players(table(turn_ms: 5000))
    assert_equal [5000, 5], t.public_view(0).values_at("dl", "ts")
    t.tick(4999)
    assert_equal 0, t.game.n
    t.tick(5000)
    assert_equal 1, t.game.n, "black's move, played by the CPU"
    assert_includes %w[d3 c4 f5 e6], t.game.last
    assert_equal 1, t.public_view(5000)["tn"], "white's turn, with its own time"
    assert_equal 5000, t.public_view(5000)["dl"]
    assert_equal "ok", t.move(tok[1], 1, t.public_view(5000)["lg"][0, 2], 6000)
    assert_equal 5000, t.public_view(6000)["dl"]
  end

  # ------------------------------------------------------------ saving

  def test_a_game_is_saved_and_resumed
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, tok = two_players(table(turn_ms: 5000).tap { _1.instance_variable_set(:@store, store) })
      t.move(tok[0], 0, "d3", 1000)
      t.save(3000)
      u = O::Table.new("othello1", { "cpu_ms" => 0, "turn_ms" => 5000 }, store: store)
      u.resume_clock(100_000)
      assert_equal ["play", 1, t.game.board.to_s], [u.status, u.game.n, u.game.board.to_s]
      assert_equal 3000, u.public_view(100_000)["dl"], "the time left when saved"
      assert_equal tok[1], u.mine(t.seats[1]["node"])["token"], "the same token"
      assert_equal "ok", u.move(tok[1], 1, u.public_view(0)["lg"][0, 2], 100_100)
      u.tick(103_000)
      assert_equal 2, u.game.n
    end
  end

  # ------------------------------------------------------------ the object

  def test_the_exposed_methods
    assert_equal({ join: 1, mine: 0, sit: 2, stand: 1, cpu: 3, start: 1, move: 3, resign: 1, view: 1, table: 0, leave: 1 },
                 O::Remote.exposes)
    t = table
    r = O::Remote.new(t, -> { 0 })
    tok = r.join("A", from: "node-a")["token"]
    assert_equal "ok", r.sit(tok, -1, from: "node-a")
    assert_equal "ok", r.cpu(tok, -1, true, from: "node-a")
    assert_equal "ok", r.start(tok, from: "node-a")
    assert_equal({ "error" => "token" }, r.view("x"))
    v = r.view(tok, from: "node-a")
    assert_includes [0, 1], v["me"]
    refute r.table.key?("me")
    assert_operator Asterism::Codec.pack({ "value" => v }).bytesize, :<, 400
  end

  def test_the_largest_view
    t = table
    toks = (0...16).map { |i| t.join("wasm-#{format('%06d', i)}", "名" * 10 + "x#{i}", 0)["token"] }
    t.sit(toks[0], 0, 0)
    t.sit(toks[1], 1, 0)
    t.start(toks[0], 0)
    worst = 0
    until t.status == "over"
      v = t.member_view(t.seats[t.game.turn - 1]["token"], 0)
      worst = [worst, Asterism::Codec.pack({ "value" => v }).bytesize + MahjongTestHelper::CALL_KEY.bytesize].max
      t.move(t.seats[t.game.turn - 1]["token"], t.game.n, B.code(t.game.moves.last), 0)
    end
    puts "\n  othello: the largest view (16 members, names of 32 bytes): #{worst} B"
    assert_operator worst, :<, 1500
  end
end
