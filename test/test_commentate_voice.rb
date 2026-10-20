# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zlib"
require "socket"
require "stringio"
require "asterism_games/commentate"
require "asterism_games/commentate/mahjong"

# The commentary's voice (README "Commentary", "The voice"): VOICEVOX's
# HTTP against a small engine of our own started here (the characters by
# name, the synthesis), the fixed phrases' files (made, kept, made again
# when the list changes), the lines synthesised once and kept, the
# browser's voice when there is no engine, the characters' tones
# (ずんだもん's 〜なのだ), the hub and the web server with the sound. In
# `rake test:gem` too.
class TestCommentateVoice < Minitest::Test
  C = AsterismGames::Commentate
  P = C::MahjongPhrases
  E = C::MahjongEvents
  FIXTURE = File.join(__dir__, "fixtures/commentate_tonpuu.json.gz")

  # A VOICEVOX engine of a few lines: /version, /speakers, /audio_query
  # (the text back in the query) and /synthesis (a "WAV" with the text in
  # it). It counts the syntheses.
  class FakeEngine
    SPEAKERS = [
      { "name" => "四国めたん", "styles" => [{ "name" => "ノーマル", "id" => 2 }] },
      { "name" => "ずんだもん", "styles" => [{ "name" => "あまあま", "id" => 1 }, { "name" => "ノーマル", "id" => 3 }] }
    ].freeze

    attr_reader :texts, :port

    def initialize(delay: 0)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @texts = Thread::Queue.new
      @delay = delay
      @thread = Thread.new do
        loop do
          s = @server.accept
          Thread.new(s) { |c| serve(c) }
        rescue IOError, Errno::EBADF
          break
        end
      end
    end

    def url = "http://127.0.0.1:#{@port}"
    def count = @texts.size

    def stop
      @server.close
      @thread.join(1)
    end

    def serve(c)
      line = c.gets.to_s
      method, target, = line.split(" ")
      len = 0
      while (h = c.gets) && h != "\r\n"
        len = h.split(":", 2)[1].to_i if h.downcase.start_with?("content-length:")
      end
      body = len.positive? ? c.read(len) : ""
      path, query = target.to_s.split("?", 2)
      q = URI.decode_www_form(query.to_s).to_h
      code, type, out = case [method, path]
                        when %w[GET /version] then [200, "application/json", JSON.generate("0.99.0")]
                        when %w[GET /speakers] then [200, "application/json", JSON.generate(SPEAKERS)]
                        when %w[POST /audio_query]
                          [200, "application/json", JSON.generate({ "kana" => q["text"], "speaker" => q["speaker"].to_i })]
                        when %w[POST /synthesis]
                          t = JSON.parse(body)["kana"]
                          sleep @delay if @delay.positive?
                          @texts << t
                          [200, "audio/wav", "RIFF....WAVE#{q['speaker']}:#{t}".b]
                        else [404, "text/plain", "no"]
                        end
      c.write("HTTP/1.1 #{code} X\r\nContent-Type: #{type}\r\nContent-Length: #{out.bytesize}\r\nConnection: close\r\n\r\n")
      c.write(out)
    rescue IOError, SystemCallError
      nil
    ensure
      c.close
    end
  end

  def setup
    @engine = FakeEngine.new
    @dir = Dir.mktmpdir("voices")
  end

  def teardown
    @engine&.stop
    FileUtils.rm_rf(@dir) if @dir
  end

  def texts(engine = @engine)
    out = []
    out << engine.texts.pop until engine.texts.empty?
    out
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    s.addr[1]
  ensure
    s&.close
  end

  # ------------------------------------------------------------ the engine

  def test_the_style_is_looked_up_by_name
    vv = C::Voicevox.new(@engine.url)
    assert_equal "0.99.0", vv.version
    assert_equal 3, vv.style_id("ずんだもん", "ノーマル")
    assert_equal 1, vv.style_id("ずんだもん", "あまあま")
    assert_equal 2, vv.style_id("四国めたん", "ノーマル")
    e = assert_raises(C::Voicevox::NotFound) { vv.style_id("ずんだもんX", "ノーマル") }
    assert_equal %w[四国めたん ずんだもん], e.candidates
    assert_match(/there are: 四国めたん, ずんだもん/, e.message)
    e = assert_raises(C::Voicevox::NotFound) { vv.style_id("ずんだもん", "ふつう") }
    assert_equal %w[あまあま ノーマル], e.candidates
  end

  def test_synthesis
    vv = C::Voicevox.new(@engine.url)
    wav = vv.synthesize("リーチなのだ！", 3)
    assert wav.start_with?("RIFF")
    assert_equal "3:リーチなのだ！", wav.b.split("WAVE", 2)[1].force_encoding("UTF-8")
  end

  def test_no_engine
    url = "http://127.0.0.1:#{free_port}"
    assert_raises(C::Voicevox::Error) { C::Voicevox.new(url, open_timeout: 1).version }
    assert_nil C::Voice.connect(url: url, speaker: "ずんだもん", style: "ノーマル", root: @dir)
    info = StringIO.new
    voice, note = C::MahjongRunner.start_voice({ voicevox: url }, info, root: @dir)
    assert_nil voice
    assert_equal "missing", note
    assert_match(/no VOICEVOX at #{Regexp.escape(url)}: the browser's voice reads/, info.string)
    hub = C::MahjongHub.new(voice: nil, voice_note: note)
    assert_equal({ "engine" => "browser", "note" => "missing" }, hub.status["voice"])
    line = hub.update("games", "mahjong1", recorded[0]).first
    refute line.key?("voice"), "the browser reads the speech"
    assert_empty Dir.children(@dir), "nothing made"
  end

  def test_a_character_that_is_not_there_lists_the_others
    assert_raises(C::Voicevox::NotFound) { C::Voice.connect(url: @engine.url, speaker: "誰か", style: "ノーマル", root: @dir) }
    err = StringIO.new
    rc = C.voices(%w[--make --speaker 誰か], out: StringIO.new, err: err, env: { "VOICEVOX_URL" => @engine.url }, root: @dir)
    assert_equal 1, rc
    assert_match(/no character "誰か" \(there are: 四国めたん, ずんだもん\)/, err.string)
  end

  # ------------------------------------------------------------ the fixed phrases

  LIST = {
    "riichi" => { "word" => "リーチ", "plain" => ["リーチ！"], "zundamon" => ["リーチなのだ！", "リーチしたのだ！"] },
    "ron" => { "word" => "ロン", "plain" => ["ロン！"], "zundamon" => ["ロンなのだ！"] },
    "mangan" => { "plain" => ["満貫！"] }
  }.freeze

  def bank(list = LIST, tone: "zundamon")
    vv = C::Voicevox.new(@engine.url)
    C::ClipBank.new(File.join(@dir, "ずんだもん-ノーマル"), tone: tone, list: list, client: vv, id: 3, credit: "VOICEVOX:ずんだもん")
  end

  def test_the_fixed_phrases_are_made_once_and_named_by_their_digest
    b = bank
    refute b.ready?("riichi")
    assert_equal [4, 0], b.make!
    assert_equal ["リーチなのだ！", "リーチしたのだ！", "ロンなのだ！", "マンガン！"].sort, texts.sort,
                 "a tone without its own phrasing uses plain's, read as the speech is (満貫 マンガン)"
    files = Dir.children(b.dir).grep(/\.wav\z/).sort
    assert_equal ["リーチなのだ！", "リーチしたのだ！", "ロンなのだ！", "マンガン！"].map { |t| C::ClipBank.file_name(t) }.sort, files
    assert_match(/VOICEVOX:ずんだもん/, File.read(File.join(b.dir, "CREDITS.txt")))
    assert b.ready?("riichi")
    assert_includes %w[リーチなのだ！ リーチしたのだ！].map { |t| C::ClipBank.file_name(t) }, b.pick("riichi", Random.new(1))
    assert_equal [0, 4], b.make!, "nothing again"
    assert_empty texts
    assert_nil b.read("../CREDITS.txt")
    assert_nil b.read("0123456789abcdef.wav"), "only the files of the list"
    assert b.read(C::ClipBank.file_name("ロンなのだ！")).start_with?("RIFF")
  end

  def test_a_changed_list_is_made_again
    bank.make!
    texts
    changed = LIST.merge("ron" => { "word" => "ロン", "plain" => ["ロン！"], "zundamon" => ["ロンなのだ！！"] })
    b = bank(changed)
    assert_equal [C::ClipBank.file_name("ロンなのだ！！")], b.missing
    assert_equal [1, 3], b.make!
    assert_equal ["ロンなのだ！！"], texts
    refute File.exist?(File.join(b.dir, C::ClipBank.file_name("ロンなのだ！"))), "the old phrasing's file is gone"
    assert File.exist?(File.join(b.dir, "CREDITS.txt"))
  end

  def test_the_cache_directory
    assert_equal "/x/cache/asterism-games/voices", C::ClipBank.cache_root({ "XDG_CACHE_HOME" => "/x/cache" })
    assert_equal File.join(Dir.home, ".cache/asterism-games/voices"), C::ClipBank.cache_root({})
    assert_equal File.join(Dir.home, ".cache/asterism-games/voices"), C::ClipBank.cache_root({ "XDG_CACHE_HOME" => "rel" })
    assert_equal "/r/ずんだもん-ノーマル", C::ClipBank.dir_for("ずんだもん", "ノーマル", root: "/r")
    assert_equal "/r/a_b-__x", C::ClipBank.dir_for("a/b", "../x", root: "/r"), "nothing that leaves the root"
  end

  def test_the_gems_list_has_every_clip_the_lines_ask_for_in_both_tones
    list = C::ClipBank.load_list
    asked = %w[start] + run_lines.flat_map { |l| l["clips"] }.uniq
    %w[east south west].product((1..4).to_a).each { |w, n| asked << "round_#{w}#{n}" }
    asked += %w[chi pon kan ron tsumo mangan haneman baiman sanbaiman yakuman ryuukyoku abort game_start oorasu]
    asked.uniq.each do |k|
      assert list.key?(k), "#{k} in mahjong_voice.yml"
      refute_empty Array(list[k]["plain"]), k
      refute_empty Array(list[k]["zundamon"]), k
      list[k]["zundamon"].each { |t| assert_match(/のだ/, t, "#{k}: ずんだもん's tone") }
    end
  end

  # ------------------------------------------------------------ the lines

  def test_a_line_is_synthesised_once_and_kept
    live = C::LiveVoice.new(C::Voicevox.new(@engine.url), 3, max_entries: 2)
    d = live.register("CPU1、テンパイなのだ。", prio: 1)
    assert_equal d, live.register("CPU1、テンパイなのだ。", prio: 1), "the same text, the same digest"
    wav = live.fetch(d)
    assert wav.start_with?("RIFF")
    assert_equal live.fetch(d), wav
    assert_equal ["CPU1、テンパイなのだ。"], texts, "synthesised once"
    # Kept: two at most; the least recently used goes and is made again.
    a = live.register("あ", prio: 1)
    live.fetch(a)
    b = live.register("い", prio: 1)
    live.fetch(b)
    texts
    assert live.fetch(b)
    assert_empty texts, "still kept"
    assert live.fetch(d)
    assert_equal ["CPU1、テンパイなのだ。"], texts, "dropped as the oldest, made again when asked"
    # Not queued: made only when asked.
    q = live.register("隠したほう", queue: false)
    sleep 0.2
    assert_empty texts
    assert live.fetch(q)
    assert_equal ["隠したほう"], texts
    assert_nil live.fetch("0" * 32), "a text never registered is not synthesised"
    assert_nil live.fetch("../x")
  ensure
    live&.stop
  end

  def test_a_failing_engine_is_a_nil_and_the_line_goes_on
    url = "http://127.0.0.1:#{free_port}"
    live = C::LiveVoice.new(C::Voicevox.new(url, open_timeout: 1), 3, log: ->(_) {})
    d = live.register("ロン")
    assert_nil live.fetch(d, wait_s: 5)
  ensure
    live&.stop
  end

  def test_the_words_said_by_the_fixed_phrases_are_left_out
    assert_equal "CPU1、タンヤオ。30フ 2ハン 2900点。", C::Voice.after("ロン CPU1、タンヤオ。30フ 2ハン 2900点。", ["ロン"])
    assert_equal "CPU1、マンガンなのだ", C::Voice.after("ロンなのだ CPU1、マンガンなのだ", ["ロン", nil])
    assert_equal "1本場、親はCPU2。", C::Voice.after("トン1局 1本場、親はCPU2。", ["トン1局"])
    assert_equal "CPU1、リーチ", C::Voice.after("CPU1、リーチ", ["リーチ"]), "only at the start"
    assert_equal "", C::Voice.after("流局。", ["流局"])
  end

  # ------------------------------------------------------------ the tone

  def recorded
    @recorded ||= JSON.parse(Zlib::GzipReader.open(FIXTURE, &:read))
  end

  def run_lines(tone: "plain", seed: 1)
    rng = Random.new(seed)
    memo = {}
    prev = nil
    out = []
    recorded.each do |v|
      evs, memo = E.diff(prev, v, memo)
      evs.each { |e| out << P.line(e, v, rng, tone: tone) }
      prev = v
    end
    out
  end

  def test_zundamon_speaks_in_her_tone
    assert_equal "zundamon", P.tone_for("ずんだもん")
    assert_equal "plain", P.tone_for("四国めたん")
    assert_equal "plain", P.tone_for(nil)
    P::PHRASES.each do |k, list|
      z = P::ZUNDAMON_PHRASES.fetch(k)
      assert_equal list.size, z.size, "#{k}: as many phrasings"
      z.each { |t| assert_match(/のだ|%\{status_line\}/, t, k) }
    end
    assert_match(/のだ/, P::TONES["zundamon"]["prompt"])
    plain = run_lines
    zun = run_lines(tone: "zundamon")
    assert_equal plain.map { |l| l["type"] }, zun.map { |l| l["type"] }, "the same events"
    zun.each do |l|
      assert_match(/のだ/, l["text"], l["text"])
      assert_match(/のだ/, l["ptext"], l["ptext"]) if l["ptext"]
    end
    refute(plain.any? { |l| l["text"].include?("のだ") }, "the plain tone never")
    riichi = { "type" => "riichi", "prio" => 2, "seat" => 0, "turn" => 6 }
    l = P.line(riichi, { "seats" => [{ "name" => "CPU1" }] }, Random.new(1), tone: "zundamon")
    assert_match(/リーチなのだ！|リーチが入ったのだ/, l["text"])
    win = { "type" => "win", "prio" => 3, "by" => "ron", "seat" => 0, "from" => 1, "yaku" => ["断么九"],
            "points" => "満貫 8000点", "level" => "満貫" }
    l = P.line(win, { "seats" => [{ "name" => "CPU1" }, { "name" => "CPU2" }] }, Random.new(1), tone: "zundamon")
    assert_match(/なのだ！\z/, l["text"])
    assert_equal %w[ron mangan], l["clips"]
  end

  def test_the_clips_of_the_events_tell_no_hand
    lines = run_lines
    tenpai = lines.select { |l| l["type"] == "tenpai" }
    refute_empty tenpai
    tenpai.each { |l| assert_empty l["clips"] }
    assert(lines.any? { |l| l["clips"].include?("riichi") })
    assert(lines.any? { |l| l["clips"].any? { |c| c.start_with?("round_") || c == "game_start" } })
  end

  # ------------------------------------------------------------ the hub and the pages

  def voice
    v = C::Voice.connect(url: @engine.url, speaker: "ずんだもん", style: "ノーマル", root: @dir, log: ->(_) {})
    v.bank.make!
    texts
    v
  end

  def test_the_hub_gives_each_line_its_sound
    v = voice
    assert_equal "zundamon", v.tone
    assert_equal "VOICEVOX:ずんだもん", v.credit
    hub = C::MahjongHub.new(voice: v, rng: Random.new(3))
    st = hub.status["voice"]
    assert_equal "voicevox", st["engine"]
    assert_equal "VOICEVOX:ずんだもん", st["credit"]
    assert_match(%r{\A/clip/[0-9a-f]{16}\.wav\z}, st["start"])
    lines = recorded.flat_map { |view| hub.update("games", "mahjong1", view) }
    lines.each do |l|
      assert l["voice"], l["text"]
      assert_match(/のだ/, l["text"])
      l["voice"]["clips"].each { |c| assert_match(%r{\A/clip/[0-9a-f]{16}\.wav\z}, c) }
      assert_match(%r{\A/voice/[0-9a-f]{32}\.wav\z}, l["voice"]["live"]) if l["voice"]["live"]
    end
    tenpai = lines.find { |l| l["type"] == "tenpai" }
    assert_nil tenpai["voice"]["plive"], "hidden: nothing said"
    wins = lines.select { |l| l["type"] == "win" }
    refute_empty wins
    win = wins.find { |l| l["speech"].match?(/\A(ロン|ツモ)/) }
    if win
      d = win["voice"]["live"][%r{/voice/(\h+)\.wav}, 1]
      wav = v.wav("#{d}.wav")
      said = wav.b.split("WAVE", 2)[1].force_encoding("UTF-8")
      refute_match(/\A3:(ロン|ツモ)/, said, "the fixed phrase said it: the line goes on from the name")
    end
  ensure
    v&.stop
  end

  def test_the_server_serves_the_sound
    v = voice
    hub = C::MahjongHub.new(voice: v, rng: Random.new(3))
    lines = recorded.first(60).flat_map { |view| hub.update("games", "mahjong1", view) }
    l = lines.find { |x| x["voice"]["live"] && !x["voice"]["clips"].empty? }
    s = C::Server.new(hub, port: free_port).start
    get = lambda do |path|
      sock = TCPSocket.new("127.0.0.1", s.port)
      sock.write("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{s.port}\r\nConnection: close\r\n\r\n")
      out = sock.read.b
      sock.close
      head, body = out.split("\r\n\r\n", 2)
      [head.lines.first.split[1].to_i, head, body]
    end
    code, head, body = get.call(l["voice"]["clips"].first)
    assert_equal 200, code
    assert_match(%r{audio/wav}, head)
    assert body.start_with?("RIFF")
    code, _, body = get.call(l["voice"]["live"])
    assert_equal 200, code
    assert body.start_with?("RIFF")
    assert_equal 404, get.call("/voice/#{'0' * 32}.wav")[0], "never a text the hub did not register"
    assert_equal 404, get.call("/clip/0123456789abcdef.wav")[0]
    assert_equal 404, get.call("/clip/../CREDITS.txt")[0]
    plain = C::Server.new(C::MahjongHub.new, port: free_port).start
    sock = TCPSocket.new("127.0.0.1", plain.port)
    sock.write("GET #{l['voice']['live']} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    assert_match(/\AHTTP\/1.1 404/, sock.read)
    sock.close
  ensure
    s&.stop
    plain&.stop
    v&.stop
  end

  def test_the_start_makes_the_missing_phrases
    info = StringIO.new
    v, note = C::MahjongRunner.start_voice({ voicevox: @engine.url, speaker: "ずんだもん", style: "ノーマル" }, info, root: @dir)
    assert_nil note
    assert_match(/VOICEVOX 0\.99\.0 .*ずんだもん \(ノーマル, 3\).*credit: VOICEVOX:ずんだもん/, info.string)
    deadline = Time.now + 20
    sleep 0.1 until v.bank.missing.empty? || Time.now > deadline
    assert_empty v.bank.missing
    assert_equal C::ClipBank.load_list.sum { |_, e| Array(e["zundamon"] || e["plain"]).size }, texts.size
  ensure
    v&.stop
  end

  # ------------------------------------------------------------ what the engine reads

  # Words VOICEVOX reads wrongly (三萬 サンヨロズ, 流局 ナガレキョク, 起家
  # オコリカ, 跳満 トベミツル): never in a text sent to the engine, which is
  # always the speech (サンマン, 30フ 2ハン), never the caption.
  MISREAD = /[萬筒索]|流局|起家|跳満|三倍満|東\d局|立直|一発|裏ドラ|[符翻]/

  def test_the_engine_gets_the_speech_never_the_caption
    %w[ずんだもん 四国めたん].each do |speaker|
      v = C::Voice.connect(url: @engine.url, speaker: speaker, style: "ノーマル", root: @dir, log: ->(_) {})
      v.bank.make!
      hub = C::MahjongHub.new(voice: v, rng: Random.new(5))
      lines = recorded.flat_map { |view| hub.update("games", "mahjong1", view) }
      assert(lines.any? { |l| l["text"].match?(/[萬筒索]/) }, "the captions do name tiles")
      lines.each do |l|
        [l["voice"]["live"], l["voice"]["plive"]].compact.uniq.each { |u| assert v.wav(u.delete_prefix("/voice/")), u }
      end
      v.stop
    end
    sent = texts
    assert_operator sent.size, :>, 50
    sent.each { |t| refute_match(MISREAD, t, t) }
  end

  def test_the_yaku_the_points_and_the_tiles_are_read
    yaku = P::YAKU_READ.keys + ["役牌 白", "自風 東", "場風 南", "ドラ 2", "赤ドラ 1", "裏ドラ 3"]
    win = { "type" => "win", "prio" => 2, "by" => "ron", "seat" => 0, "from" => 1, "yaku" => yaku, "points" => "30符 2翻 2000点" }
    seats = { "seats" => [{ "name" => "CPU1" }, { "name" => "CPU2" }] }
    %w[plain zundamon].each do |tone|
      3.times do |i|
        l = P.line(win, seats, Random.new(i), tone: tone)
        assert_match(/[立直]/, l["text"], "the caption keeps the kanji")
        refute_match(MISREAD, l["speech"], l["speech"])
        P::YAKU_READ.each_key { |y| refute_includes l["speech"], y }
      end
      draw = P.line({ "type" => "draw", "prio" => 2, "tenpai" => [] }, seats, Random.new(0), tone: tone)
      refute_match(MISREAD, draw["speech"])
      game = P.line({ "type" => "round_start", "prio" => 1, "game_start" => true,
                      "round" => { "wind" => "east", "number" => 1, "honba" => 0, "dealer" => 0 }, "dora" => %w[3m] },
                    seats, Random.new(0), tone: tone)
      refute_match(MISREAD, game["speech"], game["speech"])
      assert_match(/サンマン/, game["speech"])
    end
    assert_equal "ここでリューキョク。チーチャ。サンマン、アカウーピン、アカウーソー。30フ 2ハン",
                 P.reading("ここで流局。起家。3萬、赤5筒、0索。30符 2翻")
    C::ClipBank.load_list.each_value do |e|
      (Array(e["plain"]) + Array(e["zundamon"])).each { |t| refute_match(MISREAD, P.reading(t), t) }
    end
  end

  # ------------------------------------------------------------ the commands

  def test_options_and_the_voices_command
    o = C.parse(%w[--voicevox http://192.0.2.5:50021 --speaker 四国めたん --style あまあま], env: {})
    assert_equal ["http://192.0.2.5:50021", "四国めたん", "あまあま"], o.values_at(:voicevox, :speaker, :style)
    o = C.parse([], env: { "VOICEVOX_URL" => "http://192.0.2.6:50021" })
    assert_equal ["http://192.0.2.6:50021", "ずんだもん", "ノーマル"], o.values_at(:voicevox, :speaker, :style)
    assert_equal "http://127.0.0.1:50021", C.parse([], env: {})[:voicevox]
    out = StringIO.new
    assert_equal 0, C.voices(["--list", "--voicevox", @engine.url], out: out, err: StringIO.new, env: {})
    assert_match(/ずんだもん: あまあま \(1\), ノーマル \(3\)/, out.string)
    out = StringIO.new
    assert_equal 0, C.voices(["--make"], out: out, err: StringIO.new, env: { "VOICEVOX_URL" => @engine.url }, root: @dir)
    assert_match(/made, 0 already there\. Credit: VOICEVOX:ずんだもん/, out.string)
    assert Dir.exist?(File.join(@dir, "ずんだもん-ノーマル"))
    assert_equal 2, C.voices([], out: StringIO.new, err: StringIO.new, env: {})
    err = StringIO.new
    assert_equal 1, C.voices(["--list", "--voicevox", "http://127.0.0.1:#{free_port}"], out: StringIO.new, err: err, env: {})
    assert_match(/no VOICEVOX at/, err.string)
    out = StringIO.new
    C.main(%w[--help], out: out)
    assert_match(/--speaker NAME/, out.string)
    assert_match(/voices --list/, out.string)
  end
end
