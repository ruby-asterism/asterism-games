# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "asterism_games/play"
require "asterism_games/play/keys"
require "asterism_games/play/mahjong_screen"
require "asterism_games/play/othello"

# `asterism-games play` with keys (README "Keys"): the bytes of a terminal
# as key names (the arrows, ESC alone after a short wait), each key as a
# command (mahjong: the table app's keys in every part of the game;
# othello: the cursor and its edges), the screens with the cursor and the
# keys, and the line mode kept when the input is not a terminal.
class TestPlayKeys < Minitest::Test
  K = AsterismGames::Play::Keys
  T = AsterismGames::Play::MahjongText
  O = AsterismGames::Play::OthelloTty

  # ------------------------------------------------------------ decoding

  def test_decoding_the_bytes
    assert_equal [[:up, :down, :right, :left], ""], K.decode("\e[A\e[B\e[C\e[D")
    assert_equal [[:up, :left], ""], K.decode("\eOA\eOD"), "the application mode's arrows"
    assert_equal [[:right], ""], K.decode("\e[1;5C"), "a modifier is dropped"
    assert_equal [[:delete, :home, :end], ""], K.decode("\e[3~\e[H\e[4~")
    assert_equal [[:enter, :enter, :space, :tab, :backspace], ""], K.decode("\r\n \t\x7f")
    assert_equal [[:ctrl_c, :ctrl_q, :ctrl_d], ""], K.decode("\x03\x11\x04")
    assert_equal [["R", "t", ":", "1"], ""], K.decode("Rt:1")
    assert_equal [["東"], ""], K.decode("東")
  end

  def test_esc_alone_and_sequences_cut_short
    assert_equal [[], "\e"], K.decode("\e"), "ESC alone: more may come"
    assert_equal [[:esc], ""], K.decode("\e", final: true), "nothing came: ESC"
    assert_equal [["p"], "\e["], K.decode("p\e[")
    assert_equal [[], "\e[1;5"], K.decode("\e[1;5")
    assert_equal [[:esc], ""], K.decode("\e[", final: true).then { |k, r| [k.take(1), r] }
    assert_equal [[:esc, :up], ""], K.decode("\e\e[A"), "ESC, then an arrow"
    assert_equal [[:esc, "x"], ""], K.decode("\ex"), "ESC then a key (Alt+x)"
    part = "東".b
    assert_equal [[], part.byteslice(0, 2)], K.decode(part.byteslice(0, 2)), "a part of a character waits"
  end

  # A terminal's input in a pipe: the reader waits ESC_WAIT_S for the rest
  # of a sequence, else ESC alone.
  def test_the_reader_waits_a_little_after_esc
    r, w = IO.pipe
    reader = K::Reader.new(r)
    w.write("\e")
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal :esc, reader.read(1)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :>=, K::ESC_WAIT_S * 0.9
    w.write("\e[")
    Thread.new do
      sleep 0.01
      w.write("D")
    end
    assert_equal :left, reader.read(1), "the rest within the wait: the arrow"
    w.write("ab")
    assert_equal "a", reader.read(1)
    assert_equal "b", reader.read(0)
    assert_nil reader.read(0.01)
    w.close
    assert_equal :eof, reader.read(1)
  ensure
    r&.close
  end

  def test_crlf_out
    io = StringIO.new
    o = K::CrlfOut.new(io)
    o.puts(%w[a b])
    o.print("c\nd")
    o.puts
    assert_equal "a\r\nb\r\nc\r\nd\r\n", io.string
  end

  # ------------------------------------------------------------ mahjong keys

  def turn_view(**over)
    hand = [0, 1, 2, 13, 14, 15, 19, 21, 22, 23, 33, 33, 36]
    { "st" => "play", "sv" => 7, "me" => 0, "h" => hand.pack("C*").b, "dt" => 25,
      "a" => [[T::DAHAI, (hand + [25]).uniq.pack("C*").b], [T::RIICHI, [33, 25].pack("C*").b],
              [T::ANKAN, [30].pack("C*").b], [T::ANKAN, [33].pack("C*").b], [T::TSUMO, "".b],
              [T::KYUUSHU, "".b]] }.merge(over.transform_keys(&:to_s))
  end

  def calls_view
    { "st" => "play", "sv" => 9, "me" => 1, "h" => [11, 12, 13, 14, 15].pack("C*").b, "dt" => -1,
      "a" => [[T::RON, "".b], [T::PON, [13, 13].pack("C*").b], [T::CHI, [11, 12].pack("C*").b],
              [T::CHI, [14, 15].pack("C*").b], [T::CHI, [15, 16].pack("C*").b], [T::DAIMINKAN, [13, 13, 13].pack("C*").b],
              [T::SKIP, "".b]] }
  end

  def test_choosing_and_discarding_a_tile
    v = turn_view
    assert_equal [:act, T::DAHAI, [25]], T.key_command(:enter, v), "nothing chosen: the drawn tile"
    assert_equal [:act, T::DAHAI, [25]], T.key_command(:space, v), "Space as Enter"
    assert_equal [:select, 12], T.key_command(:left, v), "from the drawn tile"
    assert_equal [:select, 0], T.key_command(:right, v), "round to the first"
    assert_equal [:select, 13], T.key_command(:left, v, sel: 0), "round to the last"
    assert_equal [:act, T::DAHAI, [0]], T.key_command(:enter, v, sel: 0)
    assert_equal [:act, T::DAHAI, [19]], T.key_command(:enter, v, sel: 6), "the red five"
    only = turn_view(a: [[T::DAHAI, [25].pack("C*").b]])
    assert_equal [:error, "その牌は打てない"], T.key_command(:enter, only, sel: 0)
    assert_equal [:none], T.key_command("x", v)
    assert_equal [:none], T.key_command("a", v), "the letters of the hand are not keys"
  end

  def test_the_declarations_by_one_key
    v = turn_view
    assert_equal [:act, T::TSUMO, []], T.key_command("t", v)
    assert_equal [:act, T::TSUMO, []], T.key_command("T", v), "either case"
    assert_equal [:act, T::KYUUSHU, []], T.key_command("n", v)
    assert_equal [:act, T::ANKAN, [30]], T.key_command("k", v), "K the first kan"
    assert_equal [:act, T::ANKAN, [33]], T.key_command("l", v), "L the second"
    assert_equal [:error, "今はできない"], T.key_command("j", v), "no third"
    assert_equal [:error, "今はできない"], T.key_command("p", v)
    # Riichi: R chooses the tile with the arrows, Enter discards it.
    assert_equal [:pick, true], T.key_command("r", v)
    assert_equal [:pick, false], T.key_command("r", v, pick: true), "R again: off"
    assert_equal [:act, T::RIICHI, [25]], T.key_command(:enter, v, pick: true)
    assert_equal [:act, T::RIICHI, [33]], T.key_command(:enter, v, sel: 10, pick: true)
    assert_equal [:act, T::RIICHI, [33]], T.key_command(:enter, v, sel: 0, pick: true),
                 "a tile that does not declare it: the first that does (as the table app)"
    assert_equal [:pick, false], T.key_command(:esc, v, pick: true), "Esc: no riichi"
    assert_equal [:none], T.key_command(:esc, v), "Esc with nothing to pass"
  end

  def test_the_calls_by_one_key
    v = calls_view
    assert_equal [:act, T::RON, []], T.key_command("t", v), "T: ron as well"
    assert_equal [:act, T::PON, [13, 13]], T.key_command("p", v)
    assert_equal [:act, T::CHI, [11, 12]], T.key_command("c", v)
    assert_equal [:act, T::CHI, [14, 15]], T.key_command("v", v)
    assert_equal [:act, T::CHI, [15, 16]], T.key_command("b", v)
    assert_equal [:act, T::DAIMINKAN, [13, 13, 13]], T.key_command("k", v)
    assert_equal [:act, T::SKIP, []], T.key_command(:esc, v)
    assert_equal [:none], T.key_command(:left, v), "no tile is chosen while calling"
    assert_equal [:none], T.key_command(:enter, v), "nor discarded"
    assert_equal "V", T.offer_key_name(T.options(v), T::CHI, [14, 15])
    assert_equal "K", T.offer_key_name(T.options(v), T::DAIMINKAN, [13, 13, 13])
  end

  def test_the_result_the_lobby_and_the_rest
    ok = { "st" => "result", "me" => 0, "a" => [[T::NEXT, "".b]] }
    assert_equal [:act, T::NEXT, []], T.key_command(:enter, ok)
    over = { "st" => "over", "me" => 0, "a" => [[T::NEXT, "".b]] }
    assert_equal [:act, T::NEXT, []], T.key_command(:enter, over), "the owner: back to the lobby"
    assert_equal [:none], T.key_command(:enter, { "st" => "result", "me" => 0, "a" => [] })
    lobby = { "st" => "wait", "me" => 0, "ow" => 0, "sk" => [1, 0, 0, 0] }
    assert_equal [:cmd, "sit", ["3"]], T.key_command("3", lobby)
    assert_equal [:cmd, "stand", []], T.key_command("s", lobby)
    assert_equal [:cmd, "cpu", []], T.key_command("c", lobby)
    assert_equal [:cmd, "start", []], T.key_command(:enter, lobby)
    guest = lobby.merge("me" => 1)
    assert_equal [:error, "卓の主だけができる"], T.key_command("c", guest)
    assert_equal [:none], T.key_command(:enter, guest)
    watcher = lobby.merge("me" => -1)
    assert_equal [:cmd, "sit", ["2"]], T.key_command("2", watcher)
    assert_equal [:none], T.key_command("s", watcher)
    [:ctrl_c, :ctrl_q, "q", "Q"].each { |k| assert_equal [:quit], T.key_command(k, turn_view) }
    [":", "/"].each { |k| assert_equal [:line], T.key_command(k, turn_view) }
    assert_equal [:none], T.key_command(:enter, turn_view(me: -1)), "a spectator plays nothing"
    assert_equal [:quit], T.key_command("q", nil), "quit before any view"
  end

  # ------------------------------------------------------------ mahjong screen

  def round_view(**over)
    { "st" => "play", "v" => 3, "sv" => 3, "t" => "mahjong1", "me" => 0,
      "nm" => %w[Alice Jev CPU2 Claude], "sk" => [1, 2, 2, 2], "aw" => 0,
      "r" => [0, 1, 0, 0, 0, 62, 0, 1], "sc" => [25_000] * 4, "ri" => 0,
      "dora" => [35].pack("C*").b, "kw" => ["".b] * 4, "fu" => ["".b] * 4,
      "h" => [0, 1, 2, 13, 19, 15, 21, 22, 23, 30, 30, 35, 35].pack("C*").b, "dt" => 24,
      "a" => [[T::DAHAI, [0, 1, 2, 13, 19, 15, 21, 22, 23, 30, 35, 24].pack("C*").b],
              [T::RIICHI, [30, 24].pack("C*").b], [T::TSUMO, "".b]],
      "dl" => [1, 25_000, 20_000] }.merge(over.transform_keys(&:to_s))
  end

  def test_the_screen_with_keys
    s = AsterismGames::Play::MahjongScreen.new(style: "mpsz")
    lines = s.lines(round_view, keys: { sel: -1, pick: false })
    i = lines.index { |l| l.start_with?("1m") }
    assert_equal "1m 2m 3m 4p 0p 6p 2s 3s 4s 東 東 發 發    5s", lines[i]
    assert_equal "                                          ^^", lines[i + 1], "the drawn tile chosen"
    refute(lines.any? { |l| l.start_with?("赤:") }, "no letters to name")
    assert_equal "自分の番: [←][→]選ぶ [Enter]打つ [R]リーチ [T]ツモ  あと 5+20秒  [:]打ち込む [Q]閉じる", lines.last
    lines = s.lines(round_view, keys: { sel: 1, pick: false })
    assert_equal "   ^^", lines[i + 1]
    pick = s.lines(round_view, keys: { sel: 9, pick: true })
    assert_includes pick, "リーチ: 切る牌を選ぶ (東 5s)"
    assert_equal "リーチ: [←][→]選ぶ [Enter]切ってリーチ [Esc]やめる  あと 5+20秒  [:]打ち込む [Q]閉じる", pick.last
    calls = round_view(a: [[T::PON, [13, 13].pack("C*").b], [T::CHI, [11, 12].pack("C*").b],
                           [T::CHI, [14, 15].pack("C*").b], [T::SKIP, "".b]], ls: [3, 13], dl: [1, 8000], dt: -1)
    text = s.lines(calls, keys: { sel: -1, pick: false })
    assert_equal "鳴ける (北 Claude の 4p): [P]ポン [C]チー 2p3p [V]チー 5p6p [Esc]パス  あと 8秒  [:]打ち込む [Q]閉じる",
                 text.last
    refute(text.any? { |l| l.include?("^^") }, "no cursor while calling")
    ok = round_view(st: "result", res: { "k" => "ryuukyoku", "d" => [0, 0, 0, 0], "tp" => [] }, a: [[T::NEXT, "".b]])
    assert_equal "[Enter]OK  [:]打ち込む [Q]閉じる", s.lines(ok, keys: {}).last
    lobby = { "st" => "wait", "t" => "mahjong1", "me" => 0, "ow" => 0, "nm" => ["Alice", "CPU1", "", ""],
              "sk" => [1, 2, 0, 0], "aw" => 0 }
    assert_equal "[2][3][4]座る [S]立つ [C]CPU で埋める [:]打ち込む [Q]閉じる", s.lines(lobby, keys: {}).last
    full = lobby.merge("sk" => [1, 2, 2, 2])
    assert_equal "[2][3][4]座る [S]立つ [Enter]始める [:]打ち込む [Q]閉じる", s.lines(full, keys: {}).last
    assert_equal "観戦中: [2][3][4]座る [:]打ち込む [Q]閉じる", s.lines(full.merge("me" => -1), keys: {}).last
    # Without keys (a pipe, or a line being typed): the letters and words.
    typed = s.lines(round_view)
    assert_equal "a  b  c  d  e  f  g  h  i  j  k  l  m     n", typed[i + 1]
    assert_match(/\A自分の番: 打つ牌 \(文字か 6s\)、riichi、tsumo/, typed.last)
  end

  # The client: a key moves the cursor and draws; a hand that changes has
  # the drawn tile chosen again; no prompt with keys, one while typing.
  def test_the_client_with_keys
    require "asterism_games/play/mahjong"
    net = Struct.new(:x) { def [](*, **) = nil }.new
    out = StringIO.new
    c = AsterismGames::Play::Mahjong.new(net, "games/games/mahjong1", "Alice", style: "mpsz", out: out, keys: true)
    c.instance_variable_set(:@view, round_view)
    assert_equal true, c.key(:left)
    assert_equal 12, c.instance_variable_get(:@sel)
    assert_includes out.string, "^^"
    assert_equal :line, c.key(":")
    assert_equal false, c.key("q")
    c.send(:took_keys, round_view(dt: 5), round_view)
    assert_equal(-1, c.instance_variable_get(:@sel), "a new tile: the drawn one chosen")
    c.instance_variable_set(:@pick, true)
    c.send(:took_keys, round_view(a: [[T::DAHAI, [24].pack("C*").b]]), round_view)
    assert_equal false, c.instance_variable_get(:@pick), "riichi no longer offered"
  end

  # ------------------------------------------------------------ othello

  def othello_view(**over)
    { "st" => "play", "me" => 0, "tn" => 0, "n" => 0, "ow" => 0, "sk" => [1, 2], "nm" => %w[A CPU],
      "bd" => "...........................WB......BW...........................",
      "lg" => "d3c4f5e6", "cnt" => [2, 2] }.merge(over.transform_keys(&:to_s))
  end

  def test_othello_cursor_and_edges
    assert_equal [3, 2], O.place_cursor(othello_view, nil), "a legal square first (d3)"
    assert_equal [0, 0], O.place_cursor(othello_view, [0, 0]), "one already there stays"
    assert_nil O.place_cursor(othello_view(st: "wait"), [1, 1]), "none outside a game"
    assert_nil O.place_cursor(othello_view(me: -1), nil), "none for a spectator"
    assert_nil O.place_cursor(othello_view(tn: 1), nil), "not yet: the other side moves"
    assert_equal [:cursor, [3, 1]], O.key_command(:up, othello_view, [3, 2])
    assert_equal [:cursor, [0, 0]], O.key_command(:up, othello_view, [0, 0]), "stops at the top"
    assert_equal [:cursor, [0, 0]], O.key_command(:left, othello_view, [0, 0]), "and at the left"
    assert_equal [:cursor, [7, 7]], O.key_command(:right, othello_view, [7, 7])
    assert_equal [:cursor, [7, 7]], O.key_command(:down, othello_view, [7, 7])
    assert_equal [:cursor, [3, 4]], O.key_command(:down, othello_view, nil), "from the middle"
    assert_equal [:cmd, "d3"], O.key_command(:enter, othello_view, [3, 2])
    assert_equal [:cmd, "c4"], O.key_command(:space, othello_view, [2, 3])
    assert_equal [:note, "a1: not a legal square"], O.key_command(:enter, othello_view, [0, 0])
    assert_equal :note, O.key_command(:enter, othello_view(tn: 1), [3, 2])[0]
    assert_equal [:none], O.key_command(:up, othello_view(me: -1), nil)
    lobby = othello_view(st: "wait", sk: [1, 0])
    assert_equal [:cmd, "stand"], O.key_command("s", lobby, nil)
    assert_equal [:cmd, "sit"], O.key_command("S", lobby.merge("me" => -1), nil)
    assert_equal [:cmd, "cpu"], O.key_command("c", lobby, nil)
    assert_equal [:cmd, "start"], O.key_command(:enter, lobby, nil)
    assert_equal [:none], O.key_command(:enter, lobby.merge("me" => 1), nil)
    assert_equal [:quit], O.key_command("q", lobby, nil)
    assert_equal [:line], O.key_command(":", lobby, nil)
  end

  # Esc during this member's own game: "resign? [Y/N]" (as the othello
  # app); Y resigns, N or Esc cancels, other keys wait; not for a spectator
  # nor outside a game.
  def test_othello_resign_asks_first
    v = othello_view
    assert_equal [:confirm, true], O.key_command(:esc, v, [3, 2])
    assert_equal [:confirm, true], O.key_command(:esc, othello_view(tn: 1), nil), "on the other's move too"
    assert_equal [:cmd, "resign"], O.key_command("y", v, [3, 2], confirm: true)
    assert_equal [:cmd, "resign"], O.key_command("Y", v, [3, 2], confirm: true)
    assert_equal [:confirm, false], O.key_command("n", v, [3, 2], confirm: true)
    assert_equal [:confirm, false], O.key_command(:esc, v, [3, 2], confirm: true)
    assert_equal [:none], O.key_command(:enter, v, [3, 2], confirm: true), "Enter does not play meanwhile"
    assert_equal [:none], O.key_command(:up, v, [3, 2], confirm: true)
    assert_equal [:quit], O.key_command("q", v, [3, 2], confirm: true)
    assert_equal [:none], O.key_command(:esc, othello_view(me: -1), nil), "a spectator has nothing to resign"
    assert_equal [:none], O.key_command(:esc, othello_view(st: "wait"), nil)
    assert_equal [:none], O.key_command("y", othello_view(st: "over"), nil, confirm: true), "the game ended meanwhile"
    # The client: the question on the last line, cancelled, then answered.
    out = StringIO.new
    sent = []
    table = Object.new
    table.define_singleton_method(:resign) { |token| sent << token; "ok" }
    table.define_singleton_method(:view) { |_t| v }
    tty = O.allocate
    { out: out, path: "games/games/othello1", note: "", keys: true, typing: false, view: v, cursor: [3, 2],
      confirm: false, lock: Mutex.new, table: table, token: "tk", auto: false, played: true }.each do |k, x|
      tty.instance_variable_set(:"@#{k}", x)
    end
    tty.key(:esc)
    assert_equal true, tty.instance_variable_get(:@confirm)
    assert_match(/resign\? \[Y\] yes \[N\] no$/, out.string)
    tty.key("n")
    assert_equal false, tty.instance_variable_get(:@confirm)
    assert_empty sent, "N: nothing sent"
    tty.key(:esc)
    tty.key("y")
    assert_equal ["tk"], sent, "Y: resigned"
    assert_equal false, tty.instance_variable_get(:@confirm)
    tty.instance_variable_set(:@confirm, true)
    tty.instance_variable_set(:@view, nil)
    table.define_singleton_method(:view) { |_t| v.merge("st" => "over") }
    tty.refresh
    assert_equal false, tty.instance_variable_get(:@confirm), "the question goes when the game is over"
  end

  def test_othello_board_with_the_cursor
    assert_equal " . . . . . . . .", O.board_row(%w[. . . . . . . .], nil)
    assert_equal "[.]. . . . . . .", O.board_row(%w[. . . . . . . .], 0)
    assert_equal " . . .[*]. . . .", O.board_row(%w[. . . * . . . .], 3)
    assert_equal " . . . . . . .[.]", O.board_row(%w[. . . . . . . .], 7)
    out = StringIO.new
    tty = O.allocate
    tty.instance_variable_set(:@out, out)
    tty.instance_variable_set(:@path, "games/games/othello1")
    tty.instance_variable_set(:@note, "")
    tty.instance_variable_set(:@keys, true)
    tty.instance_variable_set(:@typing, false)
    tty.instance_variable_set(:@view, othello_view)
    tty.instance_variable_set(:@cursor, [3, 2])
    tty.draw
    assert_includes out.string, "  3 . . .[*]. . . ."
    assert_match(/your move: \[arrows\] move \[Enter\] play .* \[Q\] quit$/, out.string)
  end

  # ------------------------------------------------------------ not a terminal

  # A pipe (or a file, or the tests): lines as before, no raw mode.
  def test_lines_when_not_a_terminal
    r, w = IO.pipe
    refute AsterismGames::Play.keys?(r)
    refute AsterismGames::Play.keys?(StringIO.new)
    out = StringIO.new
    assert_same out, AsterismGames::Play.key_out(r, out)
    client = Class.new do
      attr_reader :lines

      def initialize = @lines = []
      def key(_k) = raise("no keys from a pipe")
      def finished? = false

      def command(line)
        @lines << line.strip
        line.strip != "quit"
      end
    end.new
    w.puts "sit"
    w.puts "quit"
    w.close
    AsterismGames::Play.read_loop(client, { commands: ["cpu"], until_over: false }, input: r, out: out)
    assert_equal %w[cpu sit quit], client.lines
  ensure
    r&.close
  end
end
