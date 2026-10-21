# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zlib"
require "digest"
require "socket"
require "asterism_games/commentate"
require "asterism_games/commentate/mahjong"

# The sound of Family mruby's mahjong app at the commentary page (README
# "Commentary", "The sound"): which effect a step of the views calls for
# and the BGM's scene (pure functions), the files and their note (made
# with the app's APU: sounds.json says what each is), the hub's "state"
# events that carry them and the web server that serves them. In
# `rake test:gem` too.
class TestCommentateSounds < Minitest::Test
  S = AsterismGames::Commentate::MahjongSounds
  C = AsterismGames::Commentate
  ROOT = File.expand_path("..", __dir__)
  ASSETS = File.join(ROOT, "lib/asterism_games/commentate/assets")
  SOUNDS = File.join(ASSETS, "sounds")
  FIXTURE = File.join(__dir__, "fixtures/commentate_tonpuu.json.gz")

  def manifest
    @manifest ||= JSON.parse(File.read(File.join(SOUNDS, "sounds.json")))
  end

  def recorded
    @recorded ||= JSON.parse(Zlib::GzipReader.open(FIXTURE, &:read))
  end

  def seat(**kw)
    { "name" => "CPU", "kind" => "cpu", "score" => 25_000, "riichi" => false, "river" => [], "melds" => [],
      "hand_count" => 13 }.merge(kw.transform_keys(&:to_s))
  end

  def view(status: "play", number: 1, honba: 0, wall: 60, turn: 0, seats: nil, **kw)
    seats ||= Array.new(4) { seat }
    { "status" => status, "seats" => seats,
      "round" => { "wind" => "east", "number" => number, "honba" => honba, "wall_left" => wall, "turn" => turn } }
      .merge(kw.transform_keys(&:to_s))
  end

  def seats_with(i, **kw)
    Array.new(4) { |j| j == i ? seat(**kw) : seat }
  end

  def names(prev, cur) = S.effects(prev, cur).map(&:first)

  # ------------------------------------------------------------ the effects

  def test_the_first_view_sounds_nothing
    assert_empty S.effects(nil, view)
    assert_empty S.effects(view, nil)
  end

  def test_a_round_starts_with_round
    assert_equal [["round", 0]], S.effects(view(status: "wait"), view)
    assert_equal [["round", 0]], S.effects(view(status: "result"), view(number: 2)), "the next round"
    assert_equal [["round", 0]], S.effects(view(status: "result"), view(honba: 1)), "a honba is a new round"
    assert_equal [["round", 0]], S.effects(view(status: "over"), view), "the next game"
  end

  def test_a_move_discard_draw_and_the_turn
    a = view(wall: 60, turn: 0)
    b = view(wall: 59, turn: 1, seats: seats_with(0, river: ["1m"]))
    assert_equal [["discard_other", 0], ["draw", 0], ["turn", 70]], S.effects(a, b)
    assert_equal [["discard_other", 0]], S.effects(a, view(wall: 60, turn: 0, seats: seats_with(0, river: ["1m"])))
    assert_empty S.effects(a, a), "the same view put again"
  end

  def test_the_calls_and_riichi_are_their_jingles
    a = view
    { "chi" => "chi", "pon" => "pon", "open_kan" => "kan", "closed_kan" => "kan" }.each do |type, name|
      b = view(seats: seats_with(2, melds: [{ "type" => type, "tiles" => %w[1m 1m 1m] }]))
      assert_equal [name], names(a, b), type
    end
    pon = view(seats: seats_with(2, melds: [{ "type" => "pon", "tiles" => %w[1m 1m 1m] }]))
    kakan = view(seats: seats_with(2, melds: [{ "type" => "added_kan", "tiles" => %w[1m 1m 1m 1m] }]))
    assert_equal ["kan"], names(pon, kakan), "a pon turned into an added kan"
    r = view(wall: 59, turn: 2, seats: seats_with(1, riichi: true, river: ["5p"]))
    assert_equal %w[riichi discard_other draw turn], names(view(wall: 60, turn: 1), r), "the jingle first"
  end

  def test_a_win_a_draw_and_the_end
    a = view(seats: seats_with(0, riichi: true))
    ron = view(status: "result", seats: seats_with(0, riichi: true),
               result: { "kind" => "ron_agari", "wins" => [{ "seat" => 0, "points" => "8000" }] })
    assert_equal [["ron", 0], ["points", 1000]], S.effects(a, ron), "the jingle, then the points after the shout"
    tsumo = view(status: "result", result: { "kind" => "tsumo_agari", "wins" => [{ "seat" => 1 }] })
    assert_equal %w[tsumo points], names(view, tsumo)
    assert_equal %w[ryuukyoku], names(view, view(status: "result", result: { "kind" => "ryuukyoku", "tenpai" => [0] }))
    %w[suufon_renda suukaikan suucha_riichi sanchahou].each do |k|
      assert_equal %w[ryuukyoku], names(view, view(status: "result", result: { "kind" => k })), k
    end
    assert_equal %w[kyuushu], names(view, view(status: "result", result: { "kind" => "kyuushu_kyuuhai" }))
    assert_empty S.effects(ron, ron), "a result put again"
    over = view(status: "over", result: ron["result"], final: [[0, 1, 33_000, 23]])
    assert_equal [["fanfare1", 0]], S.effects(ron, over), "the end of the game: a spectator's fanfare"
    assert_equal [["ron", 0], ["fanfare1", 1000]], S.effects(a, over), "after a win's shout"
  end

  # ------------------------------------------------------------ the BGM's scene

  def test_the_scenes_are_the_apps
    assert_equal "lobby", S.scene(nil), "no table yet"
    assert_equal "lobby", S.scene(view(status: "wait"))
    assert_equal "play", S.scene(view)
    assert_equal "play", S.scene(view(wall: S::TENSE_LEFT + 1))
    assert_equal "tense", S.scene(view(wall: S::TENSE_LEFT)), "few tiles left"
    assert_equal "tense", S.scene(view(seats: seats_with(3, riichi: true))), "a riichi on the table"
    assert_equal "play", S.scene(view(status: "result", wall: 3)), "the result of a round without riichi"
    assert_equal "tense", S.scene(view(status: "result", seats: seats_with(3, riichi: true)))
    assert_equal "none", S.scene(view(status: "over")), "the fanfare plays alone"
  end

  def test_a_recorded_game_sounds_as_the_app
    prev = nil
    count = Hash.new(0)
    scenes = []
    recorded.each do |v|
      S.effects(prev, v).each do |n, ms|
        count[n] += 1
        assert_includes S::NAMES, n
        assert_includes [0, S::TURN_DELAY_MS, S::SHOUT_MS], ms
      end
      s = S.scene(v)
      scenes << s if scenes.last != s
      prev = v
    end
    rounds = recorded.map { |v| S.round_key(v) }.compact.uniq.size
    assert_equal rounds - 1, count["round"], "each round but the first view's"
    assert_equal 1, count["fanfare1"]
    assert_equal count["ron"] + count["tsumo"], count["points"]
    assert_operator count["discard_other"], :>, 100
    assert_operator count["draw"], :>, 100
    assert_operator count["riichi"], :>=, 1
    assert_equal "none", scenes.last
    assert_includes scenes, "tense"
  end

  # ------------------------------------------------------------ the files

  def test_every_sound_the_page_asks_for_is_there
    S::NAMES.each do |n|
      e = manifest["effects"][n]
      assert e, "#{n} in sounds.json"
      assert File.file?(File.join(SOUNDS, e["file"])), e["file"]
      assert_includes 1..4, e["priority"]
      refute_empty e["channels"]
    end
    assert_equal S::TENSE_LEFT, manifest["tense_left"], "the app's"
    assert_equal [0.0, 0.3, 0.55, 1.0], manifest["bgm_levels"], "the app's BGM_LEVELS"
    assert_equal %w[切 小 中 大], manifest["bgm_names"]
    assert_equal 1, manifest["bgm_default"], "low by default"
    %w[lobby play tense].each do |scene|
      t = manifest["tunes"][manifest["scenes"][scene]]
      assert t, scene
      assert File.file?(File.join(SOUNDS, t["file"])), t["file"]
      assert_equal "shiru8bit", t["author"]
      assert_equal "CC BY 3.0", t["license"]
      assert_operator t["loop_s"], :>, 30
      assert_operator t["loop_start"], :>=, t["intro_s"] + 0.5, "inside the repeating part"
      assert_operator t["loop_start"] + t["loop_s"] + 0.5, :<=, t["length_s"], "the loop's end inside the file"
    end
  end

  def test_the_files_are_those_sounds_json_lists
    listed = manifest["files"]
    on_disk = Dir.children(SOUNDS).reject { |f| f == "sounds.json" }.sort
    assert_equal listed.keys.sort, on_disk
    listed.each do |f, m|
      body = File.binread(File.join(SOUNDS, f))
      assert_equal m["bytes"], body.bytesize, f
      assert_equal m["sha256"], Digest::SHA256.hexdigest(body), "#{f} as made (fmruby-core tools/mahjong_sounds.rb)"
      if f.end_with?(".wav")
        assert body.start_with?("RIFF") && body[8, 4] == "WAVE", f
      else
        assert(body.start_with?("ID3") || (body.getbyte(0) == 0xFF && (body.getbyte(1) & 0xE0) == 0xE0), "#{f} is MP3")
      end
    end
    total = listed.values.sum { |m| m["bytes"] }
    assert_operator total, :<, 5_000_000, "a few MB at most"
  end

  def test_the_note_of_the_sounds
    note = File.read(File.join(ASSETS, "SOUNDS_LICENSE.txt"))
    assert_match(/MIT License/, note)
    assert_match(/CC BY 3\.0/, note)
    assert_match(/shiru8bit/, note)
    manifest["tunes"].each_value do |t|
      assert_includes note, t["file"]
      assert_includes note, t["title"]
    end
    manifest["effects"].each_key { |n| assert_match(/\b#{n}\b/, note, "#{n} is named under MIT") }
    page = File.read(File.join(ASSETS, "index.html"))
    assert_includes page, "BGM: shiru8bit (CC BY 3.0)", "the page credits the BGM"
  end

  # ------------------------------------------------------------ the hub and the server

  class Page
    attr_accessor :table, :hide

    def initialize(table = nil)
      @table = table
      @frames = []
    end

    def push(f) = @frames << f
    def events = @frames.map { |f| [f[/\Aevent: (\w+)/, 1], JSON.parse(f[/^data: (.*)$/, 1])] }
  end

  def test_the_hub_sends_the_scene_and_the_effects_with_each_state
    hub = C::MahjongHub.new(rng: Random.new(1), clock: -> { Time.at(0) })
    page = Page.new
    hub.subscribe(page)
    recorded.each { |v| hub.update("games", "mahjong1", v) }
    all_states = page.events.select { |k, _| k == "state" }.map(&:last)
    assert(all_states.all? { |s| %w[lobby play tense none].include?(s["bgm"]) })
    states = all_states.select { |s| s.key?("sounds") }
    assert_equal recorded.size, states.size, "each view's state has its effects"
    assert(states.all? { |s| s["sounds"].is_a?(Array) })
    assert_empty states.first["sounds"], "the first view: none"
    assert_equal "none", states.last["bgm"]
    all = states.flat_map { |s| s["sounds"].map(&:first) }
    assert_includes all, "ron"
    assert_includes all, "fanfare1"
    hello = hub.hello(Page.new)
    st = hello.find { |k, _| k == "state" }.last
    assert_equal "none", st["bgm"], "a page that opens later gets the scene"
    refute st.key?("sounds"), "and no old effects"
  end

  def free_port
    srv = TCPServer.new("127.0.0.1", 0)
    p = srv.addr[1]
    srv.close
    p
  end

  def get(port, path)
    s = TCPSocket.new("127.0.0.1", port)
    s.write("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n")
    s.close_write
    out = s.read
    s.close
    head, body = out.split("\r\n\r\n", 2)
    [head.lines.first.split[1].to_i, head, body.to_s.b]
  end

  def test_the_server_serves_the_sounds_and_nothing_else
    s = C::Server.new(C::MahjongHub.new, port: free_port).start
    code, head, body = get(s.port, "/sounds/sounds.json")
    assert_equal 200, code
    assert_match(%r{application/json}, head)
    assert_equal manifest, JSON.parse(body)
    code, head, body = get(s.port, "/sounds/ron.wav")
    assert_equal 200, code
    assert_match(%r{audio/wav}, head)
    assert_equal File.binread(File.join(SOUNDS, "ron.wav")), body
    tune = manifest["tunes"].values.first["file"]
    code, head, = get(s.port, "/sounds/#{tune}")
    assert_equal 200, code
    assert_match(%r{audio/mpeg}, head)
    code, head, = get(s.port, "/SOUNDS_LICENSE.txt")
    assert_equal 200, code
    assert_match(%r{text/plain}, head)
    assert_equal 404, get(s.port, "/sounds/nothing.wav")[0]
    assert_equal 404, get(s.port, "/sounds/../commentate.js")[0]
    assert_equal 404, get(s.port, "/sounds/%2e%2e/commentate.js")[0]
    assert_equal 404, get(s.port, "/sounds/")[0]
  ensure
    s&.stop
  end
end
