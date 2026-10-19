# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "yaml"
require "asterism_games/play"
require "asterism_games/play/mahjong_screen"

# `asterism-games play` (README "Playing in a terminal"): the options, the
# tiles as text, the widths and the rows that keep their columns, reading
# what the player types, the screen; and, through a real router
# (ASTERISM_TEST_ROUTER, as test_network.rb), a tonpuu game against CPUs
# played to the end by the terminal client from scripted input.
class TestPlay < Minitest::Test
  T = AsterismGames::Play::MahjongText
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin/asterism-games")

  # ------------------------------------------------------------ options

  def test_options_and_the_environment
    o = AsterismGames::Play.parse(%w[--router tcp/192.0.2.1:7447 --table h/games/mahjong1 --name A --tiles mpsz], "mahjong", env: {})
    assert_equal "tcp/192.0.2.1:7447", o[:locator]
    assert_equal "mpsz", o[:tiles]
    assert_equal "h/games/mahjong1", o[:table]
    # Nothing on the line: the environment, all or nothing.
    env = { "ASTERISM_ROUTER" => "tcp/192.0.2.2:7447", "ASTERISM_CREDENTIALS" => "/x/me.tar" }
    o = AsterismGames::Play.parse([], "mahjong", env: env)
    assert_equal "/x/me.tar", o[:credentials]
    assert_equal "tcp/192.0.2.2:7447", o[:locator]
    o = AsterismGames::Play.parse(%w[--router tcp/192.0.2.3:7447], "mahjong", env: env)
    assert_nil o[:credentials], "a router on the line never meets a .tar from the environment"
    o = AsterismGames::Play.parse(%w[--credentials a.tar], "mahjong", env: env)
    assert_nil o[:locator], "a .tar alone: its router"
    o = AsterismGames::Play.parse([], "othello", env: {})
    assert_equal "tcp/127.0.0.1:7447", o[:locator], "nothing at all: a zenohd on this machine"
    assert_raises(ArgumentError) { AsterismGames::Play.parse(%w[--tiles ascii], "mahjong", env: {}) }
    assert_raises(ArgumentError) { AsterismGames::Play.parse(%w[--tiles mpsz], "othello", env: {}) }
    assert_raises(ArgumentError) { AsterismGames::Play.parse(%w[--bogus], "mahjong", env: {}) }
  end

  def test_help_prints_and_starts_nothing
    %w[--help -h help].each do |w|
      out, st = Open3.capture2e(RbConfig.ruby, BIN, w)
      assert st.success?, out
      assert_match(/asterism-games play <game>/, out)
      refute_match(/games: .* up/, out, "the host did not start")
    end
    out, st = Open3.capture2e(RbConfig.ruby, BIN, "--config", "/nonexistent.yml", "--help")
    assert st.success?, out
    assert_match(/Usage:/, out)
    out, st = Open3.capture2e(RbConfig.ruby, BIN, "play", "--help")
    assert st.success?
    assert_match(/mahjong .*othello|othello .*\n.*mahjong/m, out)
    assert_match(/--tiles emoji\|mpsz/, out)
    out, st = Open3.capture2e(RbConfig.ruby, BIN, "play", "mahjong", "--help")
    assert st.success?
    assert_match(/riichi \[e\|6s\]/, out)
    out, st = Open3.capture2e(RbConfig.ruby, BIN, "play", "chess")
    assert_equal 2, st.exitstatus
    assert_match(/no game "chess"/, out)
    out, st = Open3.capture2e(RbConfig.ruby, File.join(ROOT, "bin/othello-tty"), "--help")
    assert st.success?
    assert_match(/Othello commands/, out)
  end

  # ------------------------------------------------------------ tiles

  def test_tiles_as_emoji_and_mpsz
    assert_equal "🀇", T.tile(0, "emoji")      # 1m
    assert_equal "🀏", T.tile(8, "emoji")      # 9m
    assert_equal "🀋", T.tile(9, "emoji"), "the red five shows as the five"
    assert_equal "🀙", T.tile(10, "emoji")     # 1p
    assert_equal "🀐", T.tile(20, "emoji")     # 1s
    assert_equal %w[🀀 🀁 🀂 🀃 🀆 🀅 🀄], (30..36).map { |c| T.tile(c, "emoji") }
    assert_equal "🀫", T.tile(37, "emoji")
    assert_equal %w[1m 9m 0m 1p 0p 1s 0s], [0, 8, 9, 10, 19, 20, 29].map { |c| T.tile(c, "mpsz") }
    assert_equal %w[東 南 西 北 白 發 中], (30..36).map { |c| T.tile(c, "mpsz") }
    assert_equal %w[1z 7z], [T.mpsz(30), T.mpsz(36)]
    (0..36).each do |c|
      assert_equal c, T.parse_tile(T.mpsz(c)), T.mpsz(c)
      assert_equal c, T.parse_tile(T.tile(c, "mpsz"))
      assert_equal(T.red?(c) ? c - 5 : c, T.parse_tile(T.tile(c, "emoji")), "an emoji names the plain tile")
    end
    assert_equal 25, T.parse_tile("6s")
    assert_equal 19, T.parse_tile("0p")
    assert_equal 35, T.parse_tile("発")
    assert_nil T.parse_tile("8z")
    assert_nil T.parse_tile("x")
    assert_equal [2, 3], T.parse_tiles("34m")
    assert_equal [2, 3], T.parse_tiles("3m4m")
    assert_equal [2, 13], T.parse_tiles("3m 4p")
    assert_equal [30, 30], T.parse_tiles("東東")
    assert_nil T.parse_tiles("3q")
  end

  # ------------------------------------------------------------ widths

  def test_widths
    assert_equal 1, T.width("🀇")
    assert_equal 2, T.width("🀄"), "the red dragon is wide by default"
    assert_equal 2, T.width("東")
    assert_equal 4, T.width("自分")
    assert_equal 3, T.width("a\e[31mb\e[0mc"), "escapes take no column"
    assert_equal 0, T.width("️")
    assert_equal "自分  ", T.fit("自分", 6)
    assert_equal "ab", T.fit("abc", 2)
    assert_equal "自 ", T.fit("自分", 3), "a wide character that does not fit is left out"
  end

  # Without a terminal: every part padded to its columns by width, so a
  # wide 🀄 takes its whole slot and the letters stay under their tiles.
  def test_a_row_keeps_its_columns_without_a_terminal
    tiles = T::Row.new
    letters = T::Row.new
    [0, 36, 10, 36, 36, 20].each_with_index do |c, i|
      tiles.cell(T.tile(c, "emoji"), 2)
      letters.cell(T::LETTERS[i], 2)
    end
    assert_equal "🀇 🀄🀙 🀄🀄🀐 ", tiles.to_s
    assert_equal "a b c d e f ", letters.to_s
    starts = lambda do |row|
      col = 0
      row.to_s.each_char.filter_map do |ch|
        at = col
        col += T.char_width(ch)
        at unless ch == " "
      end
    end
    assert_equal starts.call(letters), starts.call(tiles), "each tile starts at its letter's column"
  end

  # On a terminal: each part after the first is put at its column (CHA),
  # whatever the terminal makes of the tile before it.
  def test_a_row_on_a_terminal_puts_each_part_at_its_column
    r = T::Row.new(cursor: true)
    r.text("東 ").cell("🀇", 2).cell("🀄", 2).cell("🀙", 2)
    assert_equal "東 \e[4G🀇\e[6G🀄\e[8G🀙", r.to_s
    assert_equal 9, r.col
    r = T::Row.new(cursor: true)
    r.text("ab").to(10).cell("x", 2)
    assert_equal "ab\e[11G\e[11Gx", r.to_s
  end

  # ------------------------------------------------------------ input

  # A turn: the hand 1m 2m 3m 0p 5p ... with the drawn tile 6s; riichi
  # offered on two discards, a closed kan, tsumo.
  def turn_view
    hand = [0, 1, 2, 19, 14, 15, 16, 30, 30, 30, 36, 36, 33]
    { "st" => "play", "sv" => 7, "me" => 0, "h" => hand.pack("C*").b, "dt" => 25,
      "a" => [[T::DAHAI, (hand + [25]).uniq.pack("C*").b], [T::RIICHI, [33, 25].pack("C*").b],
              [T::ANKAN, [30].pack("C*").b], [T::TSUMO, "".b]] }
  end

  def test_reading_a_discard
    v = turn_view
    assert_equal [:act, T::DAHAI, [0]], T.parse("a", v)
    assert_equal [:act, T::DAHAI, [25]], T.parse("n", v), "the drawn tile is the last letter"
    assert_equal [:act, T::DAHAI, [25]], T.parse("6s", v)
    assert_equal [:act, T::DAHAI, [19]], T.parse("0p", v)
    assert_equal [:act, T::DAHAI, [14]], T.parse("5p", v), "5p is the plain five when the hand has one"
    assert_equal [:act, T::DAHAI, [36]], T.parse("中", v)
    assert_equal [:act, T::DAHAI, [33]], T.parse("4z", v)
    assert_equal [:act, T::DAHAI, [30]], T.parse("🀀", v)
    assert_equal :error, T.parse("9m", v)[0]
    assert_equal :error, T.parse("xyz", v)[0]
    assert_equal [:none], T.parse("   ", v)
    v2 = v.merge("h" => [0, 1, 2, 19].pack("C*").b, "dt" => -1, "a" => [[T::DAHAI, [0, 1, 2, 19].pack("C*").b]])
    assert_equal [:act, T::DAHAI, [19]], T.parse("5p", v2), "5p takes the red five when it is the only five"
    assert_equal :error, T.parse("e", v2)[0], "no letter past the hand"
  end

  def test_reading_the_declarations
    v = turn_view
    assert_equal [:act, T::TSUMO, []], T.parse("tsumo", v)
    assert_equal [:act, T::ANKAN, [30]], T.parse("kan", v)
    r = T.parse("riichi", v)
    assert_equal :choose, r[0], "two discards declare it: choose"
    assert_equal [T::RIICHI, [[T::RIICHI, [33]], [T::RIICHI, [25]]]], r[1, 2]
    assert_equal [:act, T::RIICHI, [25]], T.parse("n", v, r[1, 2]), "the next line chooses by letter"
    assert_equal [:act, T::RIICHI, [33]], T.parse("4z", v, r[1, 2])
    assert_equal [:act, T::RIICHI, [33]], T.parse("1", v, r[1, 2])
    assert_equal [:act, T::RIICHI, [25]], T.parse("riichi 6s", v)
    assert_equal [:act, T::RIICHI, [33]], T.parse("riichi m", v)
    assert_equal :error, T.parse("riichi a", v)[0]
    assert_equal :error, T.parse("ron", v)[0]
    assert_equal :error, T.parse("ok", v)[0]
    %w[sit stand cpu start tonpuu auto quit help].each { |w| assert_equal :cmd, T.parse(w, v)[0] }
    assert_equal [:cmd, "cpu", ["2"]], T.parse("cpu 2", v)
  end

  def test_reading_a_call
    calls = { "st" => "play", "sv" => 9, "me" => 1, "h" => [11, 12, 13, 14, 15].pack("C*").b, "dt" => -1,
              "a" => [[T::RON, "".b], [T::PON, [13, 13].pack("C*").b], [T::CHI, [11, 12].pack("C*").b],
                      [T::CHI, [14, 15].pack("C*").b], [T::SKIP, "".b]] }
    assert_equal [:act, T::RON, []], T.parse("ron", calls)
    assert_equal [:act, T::SKIP, []], T.parse("pass", calls)
    assert_equal [:act, T::PON, [13, 13]], T.parse("pon", calls)
    r = T.parse("chi", calls)
    assert_equal :choose, r[0]
    assert_equal [:act, T::CHI, [14, 15]], T.parse("2", calls, r[1, 2])
    assert_equal [:act, T::CHI, [11, 12]], T.parse("chi 1", calls)
    assert_equal [:act, T::CHI, [14, 15]], T.parse("chi 5p6p", calls)
    assert_equal [:act, T::CHI, [11, 12]], T.parse("chi 23p", calls)
    assert_equal [:act, T::CHI, [14, 15]], T.parse("chi d e", calls), "or the letters of the hand"
    assert_equal :error, T.parse("chi 7p8p", calls)[0]
    assert_equal :error, T.parse("kan", calls)[0]
    assert_equal :error, T.parse("a", calls)[0], "no discard while calling"
    red = calls.merge("a" => [[T::PON, [14, 19].pack("C*").b], [T::PON, [14, 14].pack("C*").b]])
    assert_equal [:act, T::PON, [14, 19]], T.parse("pon 0p5p", red)
    assert_equal [:act, T::PON, [14, 14]], T.parse("pon 55p", red)
    ok = { "st" => "result", "me" => 0, "a" => [[T::NEXT, "".b]] }
    assert_equal [:act, T::NEXT, []], T.parse("ok", ok)
  end

  # ------------------------------------------------------------ the screen

  def round_view(**over)
    { "st" => "play", "v" => 3, "sv" => 3, "t" => "mahjong1", "me" => 0,
      "nm" => %w[Alice Jev CPU2 Claude], "sk" => [1, 2, 2, 2], "aw" => 0b0100,
      "r" => [0, 1, 0, 0, 0, 62, 0, 1], "sc" => [26_000, 25_000, 25_000, 24_000], "ri" => 0b1000,
      "dora" => [35].pack("C*").b,
      "kw" => [[36, 10 + 8].pack("C*").b, [33, 8, 18, 31].pack("C*").b, [35, 18, 25].pack("C*").b,
               [30, 1, 23 | 0x40].pack("C*").b],
      "fu" => ["".b, [2, 2, 3, 12, 12, 12].pack("C*").b, "".b, "".b],
      "h" => [0, 1, 2, 13, 14, 15, 21, 22, 23, 30, 30, 35, 35].pack("C*").b, "dt" => 24,
      "a" => [[T::DAHAI, [0, 1, 2, 13, 14, 15, 21, 22, 23, 30, 35, 24].pack("C*").b], [T::TSUMO, "".b]],
      "dl" => [1, 25_000, 20_000] }.merge(over.transform_keys(&:to_s))
  end

  def test_the_round_screen
    lines = AsterismGames::Play::MahjongScreen.new(style: "emoji").lines(round_view)
    text = lines.join("\n")
    assert_equal "東1局 0本場  供託0  残り62  ドラ 🀅", lines[0]
    assert_match(/^南 Jev\s+25000  🀃 🀏 🀡 🀁$/, text, "the next seat first, its river")
    assert_match(/^西 CPU2\s+25000  🀅 🀡 🀕  \(途切れ\)$/, text)
    assert_match(/^北 Claude\s+24000\* 🀀 🀈 \[🀓 \]$/, text, "riichi: * and the tile in [ ] (with room for a wide glyph)")
    assert_match(/^東 自分\s+26000  🀄🀡$/, text, "this seat last; 🀄 takes its two columns")
    assert_match(/鳴き\s+🀛 🀛 🀛/, text)
    i = lines.index { |l| l.start_with?("🀇") }
    assert_equal "🀇 🀈 🀉 🀜 🀝 🀞 🀑 🀒 🀓 🀀 🀀 🀅 🀅   🀔", lines[i]
    assert_equal "a b c d e f g h i j k l m   n", lines[i + 1]
    assert_equal "自分の番: 打つ牌 (文字か 6s)、tsumo  あと 5+20秒", lines.last
    late = AsterismGames::Play::MahjongScreen.new(style: "emoji").lines(round_view(dl: [1, 12_000, 15_000]))
    assert_match(/あと 0\+12秒\z/, late.last, "the move's time used up: the bank that is left")
    mp = AsterismGames::Play::MahjongScreen.new(style: "mpsz").lines(round_view)
    assert_equal "東1局 0本場  供託0  残り62  ドラ 發", mp[0]
    i = mp.index { |l| l.start_with?("1m") }
    assert_equal "1m 2m 3m 4p 5p 6p 2s 3s 4s 東 東 發 發    5s", mp[i]
    assert_equal "a  b  c  d  e  f  g  h  i  j  k  l  m     n", mp[i + 1]
    assert_match(/^北 Claude\s+24000\* 東 2m \[4s\]$/, mp.join("\n"))
  end

  def test_the_other_screens
    s = AsterismGames::Play::MahjongScreen.new(style: "mpsz")
    lobby = s.lines({ "st" => "wait", "t" => "mahjong1", "hv" => "0.17.0", "me" => 0, "ow" => 0,
                      "nm" => ["Alice", "CPU1", "", ""], "sk" => [1, 2, 0, 0], "aw" => 0,
                      "ru" => [1, 1, 3, 1, 0, 1, 1, 0, 1, 1, 5], "tb" => 20, "mb" => [["Alice", 0, 2], ["Bob", -1, 0]] })
    assert_includes lobby, "  席1  Alice (卓の主, 自分)"
    assert_includes lobby, "  席3  空き"
    assert_includes lobby, "  ルール: 東風 喰いタンあり 赤3 持ち時間 5+20秒"
    assert_includes lobby, "  観戦: Bob"
    assert_match(/start/, lobby.last)
    res = { "k" => "ron_agari", "rd" => [0, 2, 1], "d" => [-3900, 3900, 0, 0], "f" => 0,
            "wn" => [{ "w" => 1, "y" => ["立直", "ドラ 2"], "yh" => [1, 2], "pt" => "30符 3翻 3900点",
                       "h" => [0, 1, 2].pack("C*").b, "ag" => 3 }] }
    v = round_view(st: "result", res: res, sc: [22_100, 28_900, 25_000, 24_000], ok: [0, 1, 9000],
                   a: [[T::NEXT, "".b]], r: [0, 2, 1, 0, 1, 40, 1, 3])
    text = s.lines(v).join("\n")
    assert_match(/東2局 1本場  東 Jev ロン \(北 自分 から\)/, text)
    assert_match(/^  1m 2m 3m    4m    3p 3p 3p$/, text, "the winning hand, the winning tile, the melds")
    assert_match(/^  立直 1翻$/, text)
    assert_match(/^  ドラ 2翻$/, text, "the dora's count goes to the han")
    assert_match(/^  30符 3翻 3900点$/, text)
    assert_match(/北 自分\s+26000 →  22100  -3900/, text)
    assert_match(/OK を待っています \(0\/1\)  あと 9 秒/, text)
    assert_match(/ok で次へ\z/, text)
    over = round_view(st: "over", res: res, fin: [[1, 1, 28_900, 389], [0, 4, 22_100, -279]], fr: "normal_end", a: [])
    text = s.lines(over).join("\n")
    assert_match(/終局 \(最後の局まで\)/, text)
    assert_match(/1位 Jev\s+28900 \(\+38\.9\)/, text)
    assert_match(/4位 自分\s+22100 \(-27\.9\)/, text)
    calls = round_view(a: [[T::PON, [13, 13].pack("C*").b], [T::SKIP, "".b]], ls: [3, 13], dl: [1, 8000], "dt" => -1)
    assert_equal "鳴ける (北 Claude の 4p): pon、pass  あと 8秒", s.lines(calls).last
    watch = round_view(me: -1, a: [], sh: [[0, 1].pack("C*").b, "".b, "".b, "".b], sd: [5, -1, -1, -1])
    text = s.lines(watch).join("\n")
    assert_match(/手牌\s+1m 2m    6m/, text, "a spectator sees the hands")
    assert_match(/観戦中/, text)
  end

  # ------------------------------------------------------------ through a router

  ROUTER = ENV["ASTERISM_TEST_ROUTER"]

  # Two clients at once (emoji at mahjong1, mpsz at mahjong2), each from
  # scripted input: sit, CPUs, tonpuu, start, then an answer to every
  # screen (a letter, an MPSZ tile, a win, a call or a pass, the OKs) until
  # the game is over.
  def test_a_tonpuu_game_to_the_end_from_scripted_input
    skip "set ASTERISM_TEST_ROUTER to run against a router" unless ROUTER
    Dir.mktmpdir do |dir|
      node = "games-play-#{Process.pid}"
      cfg = { "router" => ROUTER, "node" => node, "state_dir" => dir,
              "tables" => %w[mahjong1 mahjong2].map do |n|
                { "name" => n, "game" => "mahjong", "cpu_ms" => 0, "deal_pause_seconds" => 1 }
              end }
      File.write(File.join(dir, "host.yml"), cfg.to_yaml)
      env = { "ANTHROPIC_API_KEY" => nil, "TYPESAFE_API_KEY" => nil, "ASTERISM_GAMES_AI_FAKE" => nil }
      host = Process.spawn(env, RbConfig.ruby, BIN, "--config", File.join(dir, "host.yml"),
                           out: File.join(dir, "host.log"), err: %i[child out])
      begin
        log = File.join(dir, "host.log")
        100.times do
          break if File.exist?(log) && File.read(log).include?(" up ")
          sleep 0.1
        end
        results = { "emoji" => "mahjong1", "mpsz" => "mahjong2" }.map do |style, table|
          Thread.new { [style, play_scripted("#{node}/games/#{table}", style)] }
        end.map(&:value)
        results.each do |style, (screens, sent)|
          keep_transcript(style, screens)
          last = screens.last.to_s
          assert_match(/終局/, last, "#{style}: the game is over")
          assert_match(/1位/, last)
          assert screens.any? { |s| s.include?("東1局 0本場 が始まります") }, "#{style}: the round's name showed"
          assert screens.any? { |s| s.include?("点数:") }, "#{style}: a result showed"
          # The east round to its end (or an end before it: tobi).
          assert(screens.any? { |s| s.include?("東4局") } || last.include?("トビ"), "#{style}: the game was played out")
          assert sent.any? { |w| w =~ /\A[a-n]\z/ }, "#{style}: a letter was typed"
          assert sent.any? { |w| T.parse_tile(w) }, "#{style}: a tile was typed"
          assert sent.any? { |w| ["ok", ""].include?(w) }, "#{style}: a result was OKed"
          refute screens.any? { |s| s =~ /Error|undefined method/ }, "#{style}: no exception on the screen"
        end
      ensure
        Process.kill("TERM", host)
        Process.wait(host)
      end
    end
  end

  def keep_transcript(style, screens)
    dir = ENV["PLAY_TRANSCRIPT_DIR"] or return
    File.write(File.join(dir, "mahjong_#{style}.txt"), screens.join("> \n"))
  end

  # Runs the client with a pipe for its input and answers each screen;
  # returns [screens, the lines sent].
  def play_scripted(table, style)
    screens = []
    sent = []
    cmd = [RbConfig.ruby, BIN, "play", "mahjong", "--router", ROUTER, "--table", table, "--name", "Tester",
           "--tiles", style, "--until-over", "--commands", "sit,cpu,tonpuu,start"]
    Open3.popen2e(*cmd) do |stdin, out, wait|
      buf = []
      turn = 0
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        break unless out.wait_readable(5) || wait.alive?
        line = out.gets or break
        warn line if ENV["PLAY_DEBUG"]
        line = line.force_encoding(Encoding::UTF_8).chomp
        next buf << line unless line == "> "
        screens << (buf.join("\n") + "\n")
        screen = buf
        buf = []
        # Only the newest screen is answered.
        next if out.wait_readable(0.05)
        answer = answer_for(screen, style, turn += 1)
        next unless answer
        sent << answer
        stdin.puts(answer)
      end
      stdin.close rescue nil
      begin
        Process.kill("TERM", wait.pid) if wait.alive?
      rescue Errno::ESRCH
        nil
      end
    end
    [screens, sent]
  end

  def answer_for(screen, style, n)
    hint = screen.last.to_s
    if (c = screen.find { |l| l.start_with?("リーチ: 切る牌を選ぶ") })
      return c[/: ([a-n]) /, 1] || "1"
    end
    return "1" if screen.any? { |l| l.start_with?("どれにする") }
    return (n.even? ? "ok" : "") if hint.start_with?("ok で次へ")
    return nil unless hint =~ /\A(自分の番|鳴ける)/
    return "tsumo" if hint =~ /tsumo/ && hint.start_with?("自分の番")
    return "ron" if hint =~ /\bron\b/
    if hint.start_with?("鳴ける")
      return "pon" if hint =~ /\bpon\b/ && (n % 3).zero?
      return "chi" if hint =~ /\bchi\b/ && (n % 5).zero?
      return "pass"
    end
    return "riichi" if hint =~ /riichi/ && (n % 2).zero?
    letters = screen.find { |l| l =~ /\Aa( +[b-n])+\z/ } or return nil
    last = letters.split.last
    if (n % 3).zero?
      # The drawn (or last) tile typed as a tile: the last cell of the row
      # above the letters.
      row = screen[screen.index(letters) - 1]
      code = T.parse_tile(row.split.last)
      return code ? T.mpsz(code) : last
    end
    last
  end
end
