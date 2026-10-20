# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zlib"
require "open3"
require "socket"
require "asterism_games/commentate"
require "asterism_games/commentate/mahjong"

# `asterism-games commentate mahjong` (README "Commentary"): the events
# between two spectate views and their words (pure functions, fed with a
# recorded game and with views made by hand), the hands kept out when
# they are hidden, the hub that tells the pages, the web server (the page,
# the tile sheets, the events; 127.0.0.1 only) and the options. In
# `rake test:gem` too: none of it needs the mahjong table. With the table
# there (rake test), a CPU round played here goes through the hub.
class TestCommentate < Minitest::Test
  E = AsterismGames::Commentate::MahjongEvents
  P = AsterismGames::Commentate::MahjongPhrases
  C = AsterismGames::Commentate
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin/asterism-games")
  FIXTURE = File.join(__dir__, "fixtures/commentate_tonpuu.json.gz")

  # A tonpuu of four CPUs as the host put its spectate views (one per
  # change), recorded from a table of this repository.
  def recorded
    @recorded ||= JSON.parse(Zlib::GzipReader.open(FIXTURE, &:read))
  end

  # Every event and line of a run of views: [[event, line, view], ...].
  def run_views(views, seed: 1)
    rng = Random.new(seed)
    memo = {}
    prev = nil
    out = []
    views.each do |v|
      evs, memo = E.diff(prev, v, memo)
      evs.each { |e| out << [e, P.line(e, v, rng), v] }
      prev = v
    end
    out
  end

  # ------------------------------------------------------------ the hands

  def test_waits
    assert_equal %w[4s 7s], E.waits(%w[1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 5s 6s])
    assert_equal %w[1m 4m 7m], E.waits(%w[2m 3m 4m 5m 6m 1p 2p 3p 7s 8s 9s 5z 5z]).sort
    assert_equal %w[3z], E.waits(%w[1m 1m 2p 2p 3s 3s 4s 4s 6m 6m 7z 7z 3z]), "seven pairs"
    assert_equal 13, E.waits(%w[1m 9m 1p 9p 1s 9s 1z 2z 3z 4z 5z 6z 7z]).size, "thirteen orphans, thirteen waits"
    assert_equal %w[1p 4p], E.waits(%w[1m 1m 2p 3p]), "with melds outside the hand"
    assert_equal %w[5p], E.waits(%w[0p]), "a red five is a five"
    assert_empty E.waits(%w[1m 3m 5m 7m 9m 2p 4p 6p 8p 1s 3s 5s 7s])
    assert_nil E.waits_of({ "hand" => %w[1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 5s 6s], "drawn" => "3s" }), "not between two discards"
    assert_nil E.waits_of({ "hand_count" => 13 }), "no hand in the view"
  end

  def test_dora_of_an_indicator
    assert_equal "2m", E.dora_of("1m")
    assert_equal "1m", E.dora_of("9m")
    assert_equal "6p", E.dora_of("0p")
    assert_equal "1z", E.dora_of("4z"), "north -> east"
    assert_equal "5z", E.dora_of("7z"), "red -> white"
    assert_equal "6z", E.dora_of("5z")
  end

  # ------------------------------------------------------------ events by hand

  def seat(name, score, **kw)
    { "name" => name, "kind" => "cpu", "score" => score, "wind" => "east", "riichi" => false, "river" => [],
      "melds" => [], "hand_count" => 13, "hand" => %w[1m 3m 5m 7m 9m 2p 4p 6p 8p 1s 3s 5s 7s], "drawn" => nil }
      .merge(kw.transform_keys(&:to_s))
  end

  def view(status: "play", wind: "east", number: 1, honba: 0, wall: 60, seats: nil, game: "hanchan", **kw)
    seats ||= [seat("Ann", 25_000), seat("Bob", 25_000), seat("Cat", 25_000), seat("Dan", 25_000)]
    { "table" => "mahjong1", "status" => status, "seats" => seats,
      "round" => { "wind" => wind, "number" => number, "honba" => honba, "riichi_sticks" => 0, "dealer" => (number - 1) % 4,
                   "wall_left" => wall, "turn" => 0, "phase" => "discard" },
      "dora_indicators" => ["1m"], "rules" => { "game" => game }, "delay_s" => 0 }.merge(kw.transform_keys(&:to_s))
  end

  def types(evs) = evs.map { |e| e["type"] }

  def test_the_first_view_says_where_the_table_is_and_nothing_else
    evs, memo = E.diff(nil, view)
    assert_equal %w[hello], types(evs)
    assert_equal ["east", 1, 0], memo["round"]
    l = P.line(evs[0], view, Random.new(1))
    assert_match(/観戦を始めます。東1局/, l["text"])
    assert_match(/トン1局/, l["speech"])
  end

  def test_a_round_starts
    lobby = view(status: "wait")
    evs, = E.diff(lobby, view, {})
    assert_equal %w[round_start], types(evs)
    assert evs[0]["game_start"]
    assert_equal ["2m"], evs[0]["dora"]
    l = P.line(evs[0], view, Random.new(0))
    assert_match(/東1局/, l["text"])
    assert_match(/2萬/, l["text"])
    assert_match(/リャンマン/, l["speech"])
    evs, = E.diff(view(status: "result"), view(number: 2, honba: 1), { "round" => ["east", 1, 0] })
    assert_equal %w[round_start], types(evs)
    refute evs[0]["game_start"]
    assert_match(/東2局 1本場/, P.line(evs[0], view(number: 2, honba: 1), Random.new(0))["text"])
  end

  def test_oorasu
    v = view(wind: "south", number: 4)
    evs, memo = E.diff(view(status: "result", wind: "south", number: 3), v, { "round" => ["south", 3, 0] })
    assert evs[0]["oorasu"]
    assert_equal 3, evs[0]["prio"], "a big moment"
    assert_match(/オーラス/, P.line(evs[0], v, Random.new(0))["text"])
    v2 = view(wind: "south", number: 4, honba: 1)
    evs, = E.diff(view(status: "result", wind: "south", number: 4), v2, memo)
    assert evs[0]["again"]
    assert_match(/オーラス続行|まだ終わらない/, P.line(evs[0], v2, Random.new(0))["text"])
    t = view(number: 4, game: "tonpuu")
    evs, = E.diff(view(status: "result", number: 3, game: "tonpuu"), t, {})
    assert evs[0]["oorasu"], "east 4 of a tonpuu"
    evs, = E.diff(view(status: "result", number: 3), view(number: 4), {})
    refute evs[0]["oorasu"], "east 4 of a hanchan is not the last"
  end

  def test_riichi_calls_discards_the_wall_and_a_new_dora
    a = view
    memo = E.diff(nil, a)[1]
    # Ann discards the dora (2m) and a red five and declares riichi (her
    # hand tenpai); Bob pons; the wall goes under 10; a kan turns a dora.
    tenpai = %w[1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 5s 6s]
    s0 = seat("Ann", 24_000, river: %w[2m 0p 9s], riichi: true, riichi_index: 2, hand: tenpai)
    s1 = seat("Bob", 25_000, melds: [{ "type" => "pon", "tiles" => %w[7z 7z 7z], "from" => 0 }], hand_count: 10,
                             hand: %w[1m 9m 1p 9p 1s 9s 1z 2z 3z 4z])
    b = view(seats: [s0, s1, a["seats"][2], a["seats"][3]], wall: 9, dora_indicators: %w[1m 3p])
    evs, memo = E.diff(a, b, memo)
    t = types(evs)
    assert_equal 2, t.count("dora_discard"), "the dora and the red five"
    assert_includes t, "riichi"
    assert_includes t, "call"
    assert_includes t, "wall"
    assert_includes t, "new_dora"
    refute_includes t, "tenpai", "riichi says it"
    ri = evs.find { |e| e["type"] == "riichi" }
    assert_equal %w[4s 7s], ri["waits"]
    l = P.line(ri, b, Random.new(0))
    assert_match(/リーチ/, l["text"])
    assert_match(/4索/, l["text"])
    refute_match(/4索|7索|待ち/, l["ptext"], "the hands hidden: the riichi without its waits")
    call = evs.find { |e| e["type"] == "call" }
    assert_equal "pon", call["call"]
    assert_equal 1, call["seat"]
    assert_match(/ポン/, P.line(call, b, Random.new(0))["text"])
    nd = evs.find { |e| e["type"] == "new_dora" }
    assert_equal "4p", nd["dora"]
    # A pon turned into an added kan.
    s1k = s1.merge("melds" => [{ "type" => "added_kan", "tiles" => %w[7z 7z 7z 7z], "from" => 0 }])
    c = b.merge("seats" => [s0, s1k, b["seats"][2], b["seats"][3]])
    evs, = E.diff(b, c, memo)
    k = evs.find { |e| e["type"] == "call" }
    assert_equal "added_kan", k["call"]
    assert_match(/加槓/, P.line(k, c, Random.new(1))["text"].to_s + P.line(k, c, Random.new(0))["text"].to_s)
  end

  def test_a_tenpai_is_said_once_a_round_and_only_with_the_hands
    a = view
    memo = E.diff(nil, a)[1]
    tenpai = %w[1m 2m 3m 4m 5m 6m 7m 8m 9m 1p 1p 5s 6s]
    b = view(seats: [seat("Ann", 25_000, hand: tenpai, river: %w[9p])] + a["seats"][1..])
    evs, memo = E.diff(a, b, memo)
    assert_equal %w[tenpai], types(evs)
    assert evs[0]["hands"]
    l = P.line(evs[0], b, Random.new(0))
    assert_match(/テンパイ/, l["text"])
    assert_nil l["ptext"], "nothing said with the hands hidden"
    assert_nil l["pspeech"]
    c = view(seats: [seat("Ann", 25_000, hand: tenpai, river: %w[9p 1z])] + a["seats"][1..])
    evs, = E.diff(b, c, memo)
    assert_empty evs, "once a round"
  end

  def test_a_big_win_and_the_lead_changing_hands
    a = view(seats: [seat("Ann", 30_000), seat("Bob", 25_000), seat("Cat", 25_000), seat("Dan", 20_000)])
    memo = E.diff(nil, a)[1]
    assert_equal 0, memo["leader"]
    res = { "kind" => "ron_agari", "from" => 0, "changes" => [-12_000, 12_000, 0, 0],
            "wins" => [{ "seat" => 1, "yaku" => ["立直", "一発", "ドラ 3"], "han" => 6, "fu" => 30,
                         "points" => "6翻 跳満 12000点", "tile" => "5m" }] }
    b = a.merge("status" => "result", "result" => res)
    evs, = E.diff(a, b, memo)
    win = evs.find { |e| e["type"] == "win" }
    assert_equal 3, win["prio"]
    assert_equal "跳満", win["level"]
    lc = evs.find { |e| e["type"] == "lead_change" }
    assert_equal 1, lc["seat"], "the scores before plus the changes"
    assert_equal 37_000, lc["score"]
    lines = 6.times.map { |i| P.line(win, b, Random.new(i))["text"] }
    assert lines.all? { |t| t.include?("跳満") && t.include?("Bob") }
    assert lines.all? { |t| t.scan("跳満").size == 1 }, "the level said once: #{lines.inspect}"
    assert lines.any? { |t| t.include?("Annから") }, "the discarder of a ron"
    sp = P.line(win, b, Random.new(0))["speech"]
    assert_match(/ハネマン/, sp)
    assert_match(/リーチ/, sp)
    assert_match(/逆転|入れ替わ/, P.line(lc, b, Random.new(0))["text"])
    small = res.merge("wins" => [res["wins"][0].merge("points" => "30符 1翻 1000点", "han" => 1)])
    evs, = E.diff(a, a.merge("status" => "result", "result" => small), E.diff(nil, a)[1])
    assert_equal 2, evs.find { |e| e["type"] == "win" }["prio"]
  end

  def test_a_draw_an_abortive_draw_and_the_end
    a = view
    memo = E.diff(nil, a)[1]
    evs, = E.diff(a, a.merge("status" => "result", "result" => { "kind" => "ryuukyoku", "changes" => [1500, 1500, -1500, -1500], "tenpai" => [0, 1] }), memo)
    d = evs.find { |e| e["type"] == "draw" }
    assert_match(/流局。テンパイはAnn、Bob/, P.line(d, a, Random.new(0))["text"])
    evs, = E.diff(a, a.merge("status" => "result", "result" => { "kind" => "kyuushu_kyuuhai", "changes" => [0, 0, 0, 0] }), memo)
    assert_match(/九種九牌/, P.line(evs[0], a, Random.new(0))["text"])
    fin = [[2, 1, 41_000, 51], [0, 2, 30_000, 10], [1, 3, 19_000, -21], [3, 4, 10_000, -40]]
    over = a.merge("status" => "over", "result" => { "kind" => "ryuukyoku", "changes" => [0, 0, 0, 0], "tenpai" => [] }, "final" => fin)
    evs, = E.diff(a.merge("status" => "result", "result" => over["result"]), over, memo)
    go = evs.find { |e| e["type"] == "game_over" }
    assert go
    assert_match(/Cat/, P.line(go, over, Random.new(0))["text"])
    assert_match(/41000/, P.line(go, over, Random.new(0))["text"])
  end

  def test_the_words_read_as_a_player_says_them
    assert_equal %w[3萬 サンマン], P.tile_words("3m")
    assert_equal %w[赤5筒 アカウーピン], P.tile_words("0p")
    assert_equal %w[中 チュン], P.tile_words("7z")
    assert_equal ["立直・自風 東・役牌 白・ドラ 2", "リーチ、ジカゼ トン、ハク、ドラ2"], P.yaku_words(["立直", "自風 東", "役牌 白", "ドラ 2"])
    assert_equal ["30符 2翻 2000/3900点", "30フ 2ハン 2000、3900点"], P.points_words("30符 2翻 2000/3900点")
    assert_equal ["南4局 2本場", "ナン4局 2本場"], P.round_words({ "wind" => "south", "number" => 4, "honba" => 2 })
  end

  def test_phrasings_vary_by_the_random_source
    ev = { "type" => "riichi", "prio" => 2, "seat" => 0, "turn" => 7, "waits" => %w[3m 6m] }
    texts = 20.times.map { |i| P.line(ev, view, Random.new(i))["text"] }.uniq
    assert_operator texts.size, :>=, 2
    assert_equal P.line(ev, view, Random.new(5)), P.line(ev, view, Random.new(5)), "the same source, the same line"
  end

  # ------------------------------------------------------------ a recorded game

  def test_a_recorded_game_gives_the_events_and_their_words
    out = run_views(recorded)
    t = out.map { |e, _, _| e["type"] }.tally
    %w[hello round_start riichi call win dora_discard tenpai game_over].each { |k| assert t[k], "#{k} in #{t.inspect}" }
    assert_equal 1, t["hello"]
    assert_equal 1, t["game_over"]
    out.each do |e, l, _|
      assert_kind_of String, l["text"]
      refute_empty l["text"], e.inspect
      refute_match(/%\{|nil|\?/, l["text"], "every value filled: #{l['text']}")
      refute_match(/[0-9][mpsz](?![a-z])/, l["speech"], "the tiles read as words: #{l['speech']}")
      assert_includes 0..3, l["prio"]
    end
    # The rounds of a tonpuu: four or more, the last one the oorasu.
    rs = out.select { |e, _, _| e["type"] == "round_start" }
    assert rs.any? { |e, _, _| e["oorasu"] }
  end

  # With the hands hidden nothing tells a hand: no tenpai, no waits, and
  # no tile of a hand in a line that is not a discard, a call, a dora or
  # a win (those are on the table for everybody).
  def test_the_hands_hidden_tell_nothing_of_the_hands
    out = run_views(recorded)
    shown = %w[dora_discard call new_dora win round_start hello]
    out.each do |e, l, v|
      next assert_nil(l["ptext"], "#{e['type']} says nothing hidden") if e["hands"]
      refute_nil l["ptext"], e.inspect
      refute_match(/待ち|テンパイ(?!は)/, l["ptext"], "#{e['type']}: #{l['ptext']}") unless e["type"] == "draw"
      next if shown.include?(e["type"])
      # A riichi, the wall, a lead, a draw: no tile name at all.
      refute_match(/[1-9](萬|筒|索)/, l["ptext"], "#{e['type']}: #{l['ptext']}") unless e["type"] == "draw"
      v # the view the line came from
    end
    assert out.any? { |e, _, _| e["hands"] }, "the recorded game has a tenpai to hide"
  end

  # ------------------------------------------------------------ the hub

  class Page
    attr_accessor :table
    attr_reader :frames

    def initialize(table = nil)
      @table = table
      @frames = []
    end

    def push(f) = @frames << f
    def events = @frames.map { |f| [f[/\Aevent: (\w+)/, 1], JSON.parse(f[/^data: (.*)$/, 1])] }
  end

  def test_the_hub_tells_the_pages_and_hides_the_hands_with_public
    [false, true].each do |pub|
      json = StringIO.new
      hub = C::MahjongHub.new(public: pub, json: json, rng: Random.new(3), clock: -> { Time.at(0) })
      page = Page.new
      hub.subscribe(page)
      recorded.each { |v| hub.update("games", "mahjong1", v) }
      evs = page.events
      states = evs.select { |k, _| k == "state" }.map(&:last)
      lines = evs.select { |k, _| k == "line" }.map(&:last)
      refute_empty states
      refute_empty lines
      assert_equal "games/mahjong1", page.table, "the first table"
      assert evs.any? { |k, d| k == "status" && d["tables"].map { |x| x["id"] } == ["games/mahjong1"] }
      hands = states.any? { |s| s["view"]["seats"].any? { |x| x.key?("hand") } }
      if pub
        refute hands, "no hand leaves with --public"
        refute lines.any? { |l| l["type"] == "tenpai" }
        refute lines.any? { |l| l.key?("ptext") }
        assert lines.all? { |l| l["text"] && l["speech"] }
      else
        assert hands
        assert lines.any? { |l| l["type"] == "tenpai" && l["ptext"].nil? }, "the page hides it itself (H)"
      end
      # --json: a line each.
      js = json.string.lines.map { |x| JSON.parse(x) }
      assert_equal lines.size, js.size
      assert js.all? { |x| x["text"] && x["table"] == "games/mahjong1" }
      # A page that opens later gets the last state and the lines so far.
      late = Page.new
      hello = hub.hello(late)
      assert_equal %w[status state], hello.first(2).map(&:first)
      assert hello.drop(2).all? { |k, d| k == "line" && d["old"] }
    end
  end

  def test_the_hub_goes_on_when_the_host_leaves_and_comes_back
    t = Time.at(0)
    hub = C::MahjongHub.new(clock: -> { t })
    page = Page.new
    hub.subscribe(page)
    hub.update("games", "mahjong1", recorded[0])
    hub.host_left("games")
    assert hub.status["tables"][0]["gone"]
    hub.host_back("games")
    refute hub.status["tables"][0]["gone"]
    t += 30
    hub.check_stale(15)
    assert hub.status["tables"][0]["gone"], "not heard from: gone"
    hub.update("games", "mahjong1", recorded[1])
    refute hub.status["tables"][0]["gone"], "back with the next put"
    hub.update("games", "mahjong2", recorded[0])
    assert_equal %w[games/mahjong1 games/mahjong2], hub.status["tables"].map { |x| x["id"] }
    other = Page.new("games/mahjong2")
    hub.subscribe(other)
    hub.update("games", "mahjong1", recorded[2])
    assert(other.events.none? { |k, d| k == "state" && d["table"] == "games/mahjong1" }, "a page gets its own table")
  end

  # ------------------------------------------------------------ the server

  def with_server(hub = C::MahjongHub.new)
    s = C::Server.new(hub, port: free_port).start
    yield s
  ensure
    s&.stop
  end

  def free_port
    srv = TCPServer.new("127.0.0.1", 0)
    p = srv.addr[1]
    srv.close
    p
  end

  def http(port, req)
    s = TCPSocket.new("127.0.0.1", port)
    s.write(req)
    s.close_write
    out = s.read
    s.close
    head, body = out.split("\r\n\r\n", 2)
    [head.lines.first.split[1].to_i, head, body.to_s.b]
  end

  def get(port, path, host: "127.0.0.1:#{port}")
    http(port, "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
  end

  def test_the_server_serves_the_page_and_the_sheets_on_127_0_0_1_only
    with_server do |s|
      assert_equal "127.0.0.1", s.address, "listening on this machine only"
      code, head, body = get(s.port, "/")
      assert_equal 200, code
      assert_match(%r{text/html}, head)
      assert_match(/commentate\.js/, body.force_encoding("UTF-8"))
      %w[/commentate.js /commentate.css /TILES_LICENSE.txt].each { |p| assert_equal 200, get(s.port, p)[0], p }
      %w[tiles_hand.bmp tiles_river.bmp].each do |f|
        code, head, body = get(s.port, "/#{f}")
        assert_equal 200, code
        assert_match(%r{image/bmp}, head)
        assert_equal File.binread(File.join(ROOT, "lib/asterism_games/commentate/assets", f)), body, "#{f} as it is"
      end
      assert_equal 404, get(s.port, "/../README.md")[0]
      assert_equal 404, get(s.port, "/assets/tiles_hand.bmp")[0]
      assert_equal 403, get(s.port, "/", host: "evil.example:#{s.port}")[0], "a name that only points here"
      assert_equal 200, get(s.port, "/", host: "localhost:#{s.port}")[0]
      code, = http(s.port, "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n")
      assert_equal 405, code
      code, head, body = http(s.port, "HEAD /tiles_hand.bmp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      assert_equal 200, code
      assert_empty body
      assert_match(/Content-Length: #{File.size(File.join(ROOT, 'lib/asterism_games/commentate/assets/tiles_hand.bmp'))}/, head)
    end
  end

  def test_the_server_streams_the_table_and_the_lines
    hub = C::MahjongHub.new(rng: Random.new(1))
    with_server(hub) do |s|
      hub.update("games", "mahjong1", recorded[0])
      sock = TCPSocket.new("127.0.0.1", s.port)
      sock.write("GET /events HTTP/1.1\r\nHost: 127.0.0.1:#{s.port}\r\nAccept: text/event-stream\r\n\r\n")
      got = +""
      deadline = Time.now + 5
      fed = false
      until got.include?("event: line\ndata:") && got.scan("event: state").size >= 2 || Time.now > deadline
        unless fed || !got.include?("event: state")
          recorded[1..40].each { |v| hub.update("games", "mahjong1", v) }
          fed = true
        end
        got << sock.readpartial(65_536) if sock.wait_readable(0.5)
      end
      sock.close
      assert_match(%r{\AHTTP/1.1 200 OK\r\nContent-Type: text/event-stream}, got)
      assert_match(/^event: status\ndata: \{.*"games\/mahjong1"/, got)
      assert_operator got.scan("event: state").size, :>=, 2, "the first state and the next"
      assert_match(/^event: line\ndata: \{.*"text":/, got)
    end
  end

  def test_a_taken_port_moves_to_the_next
    first = TCPServer.new("127.0.0.1", 0)
    port = first.addr[1]
    s = C::Server.new(C::MahjongHub.new, port: port)
    refute_equal port, s.port
    assert_operator s.port, :>, port
  ensure
    s&.stop
    first&.close
  end

  # ------------------------------------------------------------ options

  def test_options
    o = C.parse(%w[--router tcp/192.0.2.1:7447 --table h/spectate/mahjong1 --port 8123 --public --no-open --json], env: {})
    assert_equal "tcp/192.0.2.1:7447", o[:locator]
    assert_equal 8123, o[:port]
    assert o[:public]
    refute o[:open]
    assert o[:json]
    o = C.parse([], env: { "ASTERISM_CREDENTIALS" => "/x/viewer.tar" })
    assert_equal "/x/viewer.tar", o[:credentials]
    assert_equal C::DEFAULT_PORT, o[:port]
    assert o[:open]
    assert_equal "tcp/127.0.0.1:7447", C.parse([], env: {})[:locator]
    assert_raises(ArgumentError) { C.parse(%w[--port 0], env: {}) }
    assert_raises(ArgumentError) { C.parse(%w[--port x], env: {}) }
    assert_raises(ArgumentError) { C.parse(%w[--sit], env: {}) }
  end

  def test_which_tables
    r = C::MahjongRunner
    assert r.wanted?("games", "mahjong1", nil, nil)
    assert r.wanted?("games", "mahjong1", "mahjong1", nil)
    assert r.wanted?("games", "mahjong1", "games/mahjong1", nil)
    assert r.wanted?("games", "mahjong1", "games/spectate/mahjong1", nil)
    assert r.wanted?("games", "mahjong1", "games/games/mahjong1", nil), "the play's path"
    refute r.wanted?("other", "mahjong1", "games/mahjong1", nil)
    refute r.wanted?("games", "mahjong2", "mahjong1", nil)
    pre = r.room_prefix("room/01")
    assert_equal "room01-", pre
    assert r.wanted?("games", "room01-mahjong1", nil, pre)
    refute r.wanted?("games", "mahjong1", nil, pre), "a room's tables only"
    assert r.wanted?("games", "room01-mahjong1", "mahjong1", pre)
    assert_equal "games/mahjong1", r.table_filter({ table: "games/spectate/mahjong1" })
  end

  def test_help_prints_and_starts_nothing
    out, st = Open3.capture2e(RbConfig.ruby, BIN, "commentate", "--help")
    assert st.success?, out
    assert_match(/asterism-games commentate <game>/, out)
    assert_match(/--public/, out)
    out, st = Open3.capture2e(RbConfig.ruby, BIN, "commentate", "mahjong", "--help")
    assert st.success?, out
    assert_match(/Space/, out)
    out, st = Open3.capture2e(RbConfig.ruby, BIN, "commentate", "othello")
    refute st.success?
    assert_match(/no game/, out)
    out, = Open3.capture2e(RbConfig.ruby, BIN, "help")
    assert_match(/commentate <game>/, out)
  end

  # ------------------------------------------------------------ a live table

  unless GEM_ONLY
    include MahjongTestHelper

    # A round of four CPUs played here, its spectate views into the hub as
    # the host would put them: the commentary of a real table.
    def test_a_cpu_round_through_the_hub
      t = M::Table.new("mahjong1", { "humans" => 0, "cpu_ms" => 300, "result_ms" => 2000, "deal_pause_ms" => 0 })
      hub = C::MahjongHub.new(rng: Random.new(2))
      pub = C::MahjongHub.new(public: true, rng: Random.new(2))
      page = Page.new
      pub.subscribe(page)
      lines = []
      now = 0
      last = nil
      seen_result = false
      200_000.times do
        now += 10
        t.tick(now)
        v = t.spectate_view(now)
        next if last && v["sv"] == last["sv"] && v["status"] == last["status"]
        last = v
        lines.concat(hub.update("games", "mahjong1", v))
        pub.update("games", "mahjong1", v)
        seen_result ||= v["status"] == "result"
        break if seen_result && v["status"] == "play"
      end
      assert seen_result
      ty = lines.map { |l| l["type"] }
      assert_includes ty, "hello"
      assert(ty.any? { |x| %w[win draw abort].include?(x) }, ty.inspect)
      assert_includes ty, "round_start", "the next round"
      refute(page.events.any? { |k, d| k == "state" && d["view"]["seats"].any? { |s| s.key?("hand") } })
    end
  end
end
