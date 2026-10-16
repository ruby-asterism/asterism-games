# frozen_string_literal: true

require_relative "test_helper"

# The local rules the owner chooses in the lobby, the spectators (no hand,
# the delay, how many) and the result's han per yaku (README "Local rules",
# "Spectators").
class TestMahjongLocalRules < Minitest::Test
  include MahjongTestHelper

  T = M::Table
  GAME = 0
  KUITAN = 1
  AKA = 2
  EXTRA = 9
  TURN = 10
  ABORTIVE = 11
  NAGASHI = 12
  DOUBLE_YAKUMAN = 13
  TENPAI_YAME = 14
  CPU = 15
  DELAY = 16
  AI = ::Mahjong::Cpu::Ai::NormalAi.new

  # A lobby with n members seated (the first is the owner): [table, tokens].
  def lobby(n = 1, store: nil, **opts)
    t = human_table(store: store, **opts)
    toks = (0...n).map do |i|
      tok = t.join("wasm-aaaaa#{i}", "P#{i}", 0)["token"]
      assert_equal "ok", t.sit(tok, -1, 0)
      tok
    end
    [t, toks]
  end

  def start(t, toks)
    t.cpu(toks[0], -1, true) if toks.size < 4
    assert_equal "ok", t.start(toks[0], 0)
    toks.to_h { |tok| [t.seat_of(tok), tok] }
  end

  def give(state, seat, names)
    state.hands[seat] = Mahjong::State::Hand.new(names)
  end

  # ------------------------------------------------------------ the rules

  def test_the_defaults_are_the_hosts
    t, = lobby
    assert_equal [0, 1, 3, 1, 0, 1, 1, 0, 1, 1, 1], t.public_view(0)["ru"],
                 "hanchan, kuitan, three red fives, double ron, no sanchahou, multiple yakuman, kazoe, " \
                 "no kiriage, tobi, west round, the setting's time (1 s in the test table)"
    assert_equal [1, 1, 1, 1], t.public_view(0)["rx"],
                 "the abortive draws, nagashi mangan, double yakuman, tenpai-yame"
    assert_equal [1, 0], t.public_view(0)["ry"], "the setting's CPUs (normal), no spectator delay"
    assert_equal T::RULE_ITEMS.size, %w[ru rx ry].sum { |k| t.public_view(0)[k].size }
    assert_equal 11, t.public_view(0)["ru"].size, "the items a table app of MJ3b knows"
    assert_equal 4, t.public_view(0)["rx"].size, "and the four a table app of MJ-E2 knows besides"
    assert_equal [0, 60, 180, 300], t.public_view(0)["dc"]
    assert_equal [20_005, 5, 30, 60, 600, 1], t.rule_choices(TURN),
                 "5+20, 5+0, 30 s, 60 s, 600 s and the setting's own time (1 s, no bank)"
    assert_equal 0, t.public_view(0)["tb"], "no bank"
    assert_equal t.rule_choices(TURN), t.public_view(0)["tc"]
    assert_equal [0, 3, 4], t.rule_choices(AKA)
  end

  def test_only_the_owner_in_the_lobby_with_values_offered
    t, toks = lobby(2)
    assert_equal "not owner", t.set_rule(toks[1], GAME, 1)
    assert_equal "token", t.set_rule("x" * 32, GAME, 1)
    assert_equal "no rule", t.set_rule(toks[0], 99, 1)
    assert_equal "value", t.set_rule(toks[0], AKA, 2)
    assert_equal "value", t.set_rule(toks[0], TURN, 15)
    assert_equal "no change", t.set_rule(toks[0], KUITAN, 1)
    v0 = t.public_view(0)["v"]
    assert_equal "ok", t.set_rule(toks[0], GAME, 1)
    assert_operator t.public_view(0)["v"], :>, v0, "everybody sees the change"
    assert_equal "ok", t.set_rule(toks[0], KUITAN, 0)
    assert_equal "ok", t.set_rule(toks[0], AKA, 4)
    assert_equal "ok", t.set_rule(toks[0], TURN, 30)
    assert_equal "tonpuu", t.rule.game_type
    refute t.rule.kuitan?
    assert_equal({ "m" => 1, "p" => 2, "s" => 1 }, t.rule.aka_dora_config)
    assert_equal 30_000, t.turn_ms
    assert_equal [1, 0, 4, 1, 0, 1, 1, 0, 1, 1, 30], t.public_view(0)["ru"]
    # back to the host's value: no choice is kept for it
    assert_equal "ok", t.set_rule(toks[0], AKA, 3)
    refute t.instance_variable_get(:@choice).key?("aka_dora")
    start(t, toks)
    assert_equal "not waiting", t.set_rule(toks[0], GAME, 0), "fixed once the game has started"
    assert_equal [1, 0, 3, 1, 0, 1, 1, 0, 1, 1, 30], t.view(0, 0)["ru"], "the rules are in every view"
  end

  def test_every_engine_item_reaches_the_engine
    t, toks = lobby
    { 3 => :double_ron?, 4 => :triple_ron_draw?, 5 => :multiple_yakuman?, 6 => :kazoe_yakuman?,
      7 => :kiriage_mangan?, 8 => :tobi? }.each do |item, m|
      was = t.rule.public_send(m)
      assert_equal "ok", t.set_rule(toks[0], item, was ? 0 : 1)
      assert_equal !was, t.rule.public_send(m), "item #{item}"
    end
  end

  # Item 9, the extra round, sets both keys: the west round of a hanchan
  # (nishi_iri) and the south round of a tonpuu game (nan_iri). Its value is
  # the one of the game chosen.
  def test_the_extra_round_item_sets_both_keys
    t, toks = lobby
    assert t.rule.nishi_iri? && t.rule.nan_iri?
    assert_equal "ok", t.set_rule(toks[0], EXTRA, 0)
    refute t.rule.nishi_iri?
    refute t.rule.nan_iri?
    assert_equal 0, t.public_view(0)["ru"][EXTRA]
    assert_equal "ok", t.set_rule(toks[0], GAME, 1)
    assert_equal 0, t.public_view(0)["ru"][EXTRA], "a tonpuu game shows nan_iri"
    assert_equal "ok", t.set_rule(toks[0], EXTRA, 1)
    assert t.rule.nishi_iri? && t.rule.nan_iri?
    assert_equal({ "game_type" => "tonpuu" }, t.instance_variable_get(:@choice), "back to the host's values")
    # a setting with only the west round: a tonpuu game shows 0, a hanchan 1
    u, utoks = lobby(1, "rule" => { "nan_iri" => false })
    assert_equal 1, u.public_view(0)["ru"][EXTRA]
    assert_equal "ok", u.set_rule(utoks[0], GAME, 1)
    assert_equal 0, u.public_view(0)["ru"][EXTRA]
    assert_equal "ok", u.set_rule(utoks[0], EXTRA, 1)
    assert u.rule.nan_iri?
    assert_equal "ok", u.set_rule(utoks[0], EXTRA, 0)
    refute u.rule.nan_iri?
    refute u.rule.nishi_iri?
    assert_equal "ok", u.set_rule(utoks[0], EXTRA, 1)
    assert_equal({ "game_type" => "tonpuu", "nan_iri" => true }, u.instance_variable_get(:@choice))
  end

  def test_the_new_items_reach_the_engine
    t, toks = lobby
    abortive = %i[suufon_renda? suukaikan? suucha_riichi?]
    assert(abortive.all? { |m| t.rule.public_send(m) })
    assert_equal "ok", t.set_rule(toks[0], ABORTIVE, 0)
    assert(abortive.none? { |m| t.rule.public_send(m) }, "one item, the three keys")
    assert_equal 0, t.public_view(0)["rx"][0]
    assert_equal "ok", t.set_rule(toks[0], ABORTIVE, 1)
    assert(abortive.all? { |m| t.rule.public_send(m) })
    assert_empty t.instance_variable_get(:@choice), "back to the host's values"
    { NAGASHI => :nagashi_mangan?, DOUBLE_YAKUMAN => :double_yakuman?, TENPAI_YAME => :tenpai_yame? }.each do |item, m|
      was = t.rule.public_send(m)
      assert_equal "ok", t.set_rule(toks[0], item, was ? 0 : 1)
      assert_equal !was, t.rule.public_send(m), "item #{item}"
    end
    assert_equal [1, 0, 0, 0], t.public_view(0)["rx"]
    assert_equal "value", t.set_rule(toks[0], NAGASHI, 2)
  end

  # A table whose setting has only some of the abortive draws shows the
  # item as off; choosing it sets all three, choosing off again goes back
  # to the setting's.
  def test_the_abortive_draws_item_over_a_mixed_setting
    t, toks = lobby(1, "rule" => { "suukaikan" => false })
    assert_equal 0, t.public_view(0)["rx"][0]
    assert_equal "ok", t.set_rule(toks[0], ABORTIVE, 1)
    assert t.rule.suukaikan?
    assert_equal "ok", t.set_rule(toks[0], ABORTIVE, 0)
    refute t.rule.suukaikan?
    assert t.rule.suufon_renda?
    assert_empty t.instance_variable_get(:@choice)
  end

  def test_the_time_to_discard_is_the_chosen_one
    t, toks = lobby(1, "turn_ms" => 20_000)
    assert_equal "ok", t.set_rule(toks[0], TURN, 30)
    seats = start(t, toks)
    seat = seats.keys.first
    now = run_until(t, 0) { t.state.phase == :dahai && t.state.current_seat == seat }
    assert_equal [1 << seat, 30_000], t.public_view(now)["dl"]
  end

  # Item 15: the owner's CPU level reaches the table's CPUs (in "ry", not
  # in "ru" or "rx"); the setting's level is the start and choosing it
  # again drops the choice.
  def test_the_cpu_level_reaches_the_cpus
    t, toks = lobby
    assert_instance_of ::Mahjong::Cpu::Ai::NormalAi, t.instance_variable_get(:@ai)
    assert_equal [0, 1, 2], t.rule_choices(CPU)
    assert_equal "ok", t.set_rule(toks[0], CPU, 2)
    assert_instance_of ::Mahjong::Cpu::Ai::HardAi, t.instance_variable_get(:@ai)
    assert_equal 2, t.public_view(0)["ry"][0]
    assert_equal 11, t.public_view(0)["ru"].size
    assert_equal 4, t.public_view(0)["rx"].size
    assert_equal "ok", t.set_rule(toks[0], CPU, 0)
    assert_instance_of ::Mahjong::Cpu::Ai::EasyAi, t.instance_variable_get(:@ai)
    assert_equal "value", t.set_rule(toks[0], CPU, 3)
    assert_equal "ok", t.set_rule(toks[0], CPU, 1)
    assert_nil t.to_saved(0)["rules"]["cpu"], "the setting's level again: no choice kept"
    h, = lobby(1, "cpu_level" => "hard")
    assert_equal 2, h.public_view(0)["ry"][0], "the setting's level"
    assert_instance_of ::Mahjong::Cpu::Ai::HardAi, h.instance_variable_get(:@ai)
  end

  # The CPUs of a game play at the level chosen in the lobby: a game started
  # with easy CPUs asks the easy AI.
  def test_the_chosen_level_plays
    t, toks = lobby
    assert_equal "ok", t.set_rule(toks[0], CPU, 0)
    start(t, toks)
    asked = 0
    ai = t.instance_variable_get(:@ai)
    ai.define_singleton_method(:think) { |**kw| asked += 1; super(**kw) }
    run_until(t, 0) { asked >= 3 }
    assert_instance_of ::Mahjong::Cpu::Ai::EasyAi, ai
  end

  # Item 16: the spectators' delay (seconds; none, 1, 3, 5 minutes and the
  # setting's own), in "ry"; it is what the spectators see.
  def test_the_spectator_delay_item
    t, toks = lobby(1, "spectator_delay_ms" => 45_000)
    assert_equal [0, 45, 60, 180, 300], t.rule_choices(DELAY)
    assert_equal 45, t.public_view(0)["ry"][1]
    assert_equal [0, 45, 60, 180, 300], t.public_view(0)["dc"]
    assert_equal "value", t.set_rule(toks[0], DELAY, 30)
    assert_equal "ok", t.set_rule(toks[0], DELAY, 180)
    assert_equal 180_000, t.spectator_delay_ms
    assert_equal "ok", t.set_rule(toks[0], DELAY, 0)
    assert_equal 0, t.spectator_delay_ms
    sp = t.join("wasm-cccc01", "W", 0)["token"]
    start(t, toks)
    now = run_until(t, 0) { t.sv > 5 }
    assert_equal t.sv, t.member_view(sp, now)["sv"], "no delay chosen: now"
  end

  def test_a_delay_chosen_holds_the_spectators_back
    t, toks = lobby(1, "cpu_ms" => 300)
    assert_equal "ok", t.set_rule(toks[0], DELAY, 60)
    sp = t.join("wasm-cccc01", "W", 0)["token"]
    start(t, toks)
    first = t.sv
    now = run_until(t, 0) { t.sv > first + 5 }
    assert_operator t.member_view(sp, now)["sv"], :<=, first + 1, "a minute behind"
  end

  def test_the_cpu_level_and_the_delay_are_saved
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, toks = lobby(1, store: store)
      t.set_rule(toks[0], CPU, 2)
      t.set_rule(toks[0], DELAY, 300)
      t.save(0)
      u = human_table(store: store)
      assert_equal [2, 300], u.public_view(0)["ry"]
      assert_instance_of ::Mahjong::Cpu::Ai::HardAi, u.instance_variable_get(:@ai)
      assert_equal 300_000, u.spectator_delay_ms
    end
  end

  def test_the_spectator_delay_setting_in_minutes
    c = AsterismGames::Config.new({ "tables" => [{ "name" => "m", "spectator_delay_minutes" => 3 }] }, {})
    assert_equal 180_000, c["tables"][0]["spectator_delay_ms"]
    c = AsterismGames::Config.new({ "tables" => [{ "name" => "m" }] }, { "MAHJONG_SPECTATOR_DELAY_MINUTES" => "1" })
    assert_equal 60_000, c["tables"][0]["spectator_delay_ms"]
    c = AsterismGames::Config.new({ "tables" => [{ "name" => "m", "spectator_delay_seconds" => 20 }] }, {})
    assert_equal 20_000, c["tables"][0]["spectator_delay_ms"], "the seconds as before"
  end

  def test_the_rules_are_saved_and_stay_for_the_next_game
    Dir.mktmpdir do |dir|
      store = AsterismGames::Store.new(dir)
      t, toks = lobby(1, store: store)
      t.set_rule(toks[0], GAME, 1)
      t.set_rule(toks[0], KUITAN, 0)
      t.set_rule(toks[0], TURN, 60)
      start(t, toks)
      t.save(0)
      u = human_table(store: store)
      u.resume_clock(0)
      assert_equal t.public_view(0)["ru"], u.public_view(0)["ru"]
      assert_equal "tonpuu", u.rule.game_type
      refute u.rule.kuitan?
      assert_equal 60_000, u.turn_ms
      u.instance_variable_set(:@flow, { "end" => true })
      u.next_round(0)
      assert_equal "ok", u.act(toks[0], u.sv, E::NEXT, [], 0)
      assert_equal "wait", u.status
      assert_equal t.public_view(0)["ru"], u.public_view(0)["ru"], "back in the lobby, the same rules"
    end
  end

  # One human (played as the engine's CPU would) and three CPUs, a tonpuu
  # game chosen in the lobby: it ends in the east round, or in the south
  # round when nobody had 30,000 after east 4 (nan_iri).
  def test_a_tonpuu_game_chosen_in_the_lobby_ends_in_the_east
    t, toks = lobby(1, "over_ms" => 10**9)
    assert_equal "ok", t.set_rule(toks[0], GAME, 1)
    seat, tok = start(t, toks).first
    now = 0
    winds = {}
    steps = 0
    until t.status == "over"
      g = t.instance_variable_get(:@game)
      winds[g["bakaze"]] = true if g
      a = t.view(seat, now)["a"]
      pick = if (w = a.find { |x, _| [E::TSUMO_AGARI, E::RON, E::NEXT].include?(x) }) then [w[0], []]
             elsif a.any? { |x, _| x == E::SKIP } then [E::SKIP, []]
             elsif a.any? { |x, _| x == E::DAHAI }
               c = E.cpu_choice(t.state, seat, t.rule, AI)
               d = a.find { |x, _| x == E::DAHAI }
               names = M::Tiles.unpack(d[1])
               c && c[:type].to_sym == :dahai && names.include?(c[:tile]) ? [E::DAHAI, [c[:tile]]] : [E::DAHAI, [names.last]]
             end
      if pick
        t.act(tok, t.sv, pick[0], pick[1], now)
      else
        now += 10
      end
      t.tick(now)
      steps += 1
      flunk "too many steps" if steps > 400_000
    end
    puts "\n  tonpuu: #{t.stats['rounds']} rounds, winds #{winds.keys.inspect}"
    assert_operator t.stats["rounds"], :>=, 4
    assert_includes [["ton"], %w[ton nan]], winds.keys, "every round in the east, or the south round after it"
    assert_includes %w[normal_end tobi all_last_oya_agari all_last_oya_tenpai sudden_death], t.public_view(now)["fr"]
    assert_equal 4, t.public_view(now)["fin"].size
  end

  # A tanyao-only open hand (a pon of 2p): with kuitan off the engine offers
  # no ron on its wait, with kuitan on it does.
  def open_tanyao_table(kuitan)
    t, toks = lobby(4, "result_ms" => 60_000)
    assert_equal "ok", t.set_rule(toks[0], KUITAN, 0) unless kuitan
    seats = start(t, toks)
    st = t.state
    E.apply(st, { type: :tsumo }, t.rule) while st.phase == :tsumo
    4.times { |i| st.first_turn_flags[i] = false }
    4.times { |i| give(st, i, %w[1z 1z 2z 2z 3z 3z 4z 4z 5z 5z 6z 6z 7z]) }
    give(st, 1, %w[2m 3m 4m 5p 6p 7p 4s 4s 6s 7s])
    p2 = Mahjong::Tiles::Tile.new("2p")
    st.fuuros[1] = [Mahjong::State::Fuuro.new(type: :pon, tiles: [p2] * 3, called_tile: p2, from_seat: 0)]
    st.menzen_flags[1] = false
    give(st, 2, %w[8s 1z 1z 2z 2z 3z 3z 4z 4z 5z 5z 6z 6z 7z])
    st.current_seat = 2
    st.phase = :dahai
    st.last_tsumo = Mahjong::Tiles::Tile.new("8s")
    st.dora_hyouji = [Mahjong::Tiles::Tile.new("1z")]
    assert_equal "ok", t.act(seats[2], t.sv, E::DAHAI, ["8s"], 0)
    t
  end

  def test_no_kuitan_no_ron_on_an_open_tanyao
    on = open_tanyao_table(true)
    assert(on.view(1, 0)["a"].any? { |x, _| x == E::RON }, "kuitan on: the ron is offered")
    off = open_tanyao_table(false)
    refute(off.view(1, 0)["a"].any? { |x, _| x == E::RON }, "kuitan off: no ron")
    refute off.rule.kuitan?
  end

  def test_red_fives_by_the_lobby
    [[0, 0], [3, 3], [4, 4]].each do |value, reds|
      t, toks = lobby
      t.set_rule(toks[0], AKA, value) unless value == 3
      start(t, toks)
      # the wall is built from this (riichi_engine RoundFlow: Wall.build(aka_config:))
      all = Mahjong::Tiles::Tile.all_tiles(t.rule.aka_dora_config).map(&:to_s).select { |n| n.start_with?("0") }
      assert_equal reds, all.size, "aka #{value}"
    end
  end

  # ------------------------------------------------------------ spectators

  def spectator(t, i = 0)
    t.join("wasm-cccc#{format('%02d', i)}", "W#{i}", 0)["token"]
  end

  # Over a whole tonpuu game (one human played through act), a spectator's
  # own view has the four hands ("sh", "sd") and no offer, no help and no
  # sign of who may call; the put and table carry no hand (except the
  # winners' at a win), and no seat's view has the four hands.
  def test_spectators_see_the_four_hands_and_nothing_else
    t, toks = lobby(1, "over_ms" => 10**9)
    t.set_rule(toks[0], GAME, 1)
    sp = spectator(t)
    seat, tok = start(t, toks).first
    now = 0
    checks = 0
    until t.status == "over"
      v = t.member_view(sp, now, 3)
      %w[h dt wt uk].each { |k| refute v.key?(k), "a spectator's view has #{k}" }
      assert_equal [], v["a"]
      assert_equal(-1, v["me"])
      if t.status == "wait"
        refute v.key?("sh")
      else
        hands = (0..3).map { |s| t.hand_of(s) }
        assert_equal hands.map(&:first), v["sh"], "the four hands"
        assert_equal hands.map(&:last), v["sd"], "the drawn tiles"
      end
      assert_nil v["dl"], "no sign of who may call" if t.state&.phase == :naki_wait
      [t.spectator_view(now), t.public_view(now), t.view(seat, now, 3)].each do |x|
        %w[sh sd].each { |k| refute x.key?(k), "#{k} outside a spectator's own view" }
      end
      %w[h dt wt uk].each { |k| refute t.spectator_view(now).key?(k), "the put has #{k}" }
      checks += 1
      a = t.view(seat, now)["a"]
      o = a.find { |x, _| [E::TSUMO_AGARI, E::RON, E::NEXT, E::SKIP].include?(x) } || a.find { |x, _| x == E::DAHAI }
      if o
        tiles = o[0] == E::DAHAI ? [M::Tiles.unpack(o[1]).last] : []
        t.act(tok, t.sv, o[0], tiles, now)
      else
        now += 10
      end
      t.tick(now)
      flunk "too many steps" if checks > 400_000
    end
    assert_operator checks, :>, 20 # a tonpuu game may end in four short rounds
  end

  def test_spectators_see_the_game_as_it_was_the_delay_ago
    t, toks = lobby(1, "spectator_delay_ms" => 5000, "cpu_ms" => 300)
    sp = spectator(t)
    seat, = start(t, toks).first
    seen = {} # time => state version
    hands = {} # state version => the four hands
    now = 0
    while now < 30_000 && t.status == "play"
      t.act(toks[0], t.sv, E::DAHAI, [M::Tiles.unpack(t.view(seat, now)["a"].find { |x, _| x == E::DAHAI }[1]).last], now) if
        t.view(seat, now)["a"].any? { |x, _| x == E::DAHAI }
      seen[now] = t.sv # after what happened at now
      hands[t.sv] ||= (0..3).map { |s| t.hand_of(s).first } if t.status == "play"
      now += 10
      t.tick(now)
      next if now < 5000
      want = seen[now - 5000]
      v = t.member_view(sp, now)
      assert_equal hands[v["sv"]], v["sh"], "the hands are as old as the rest" if hands[v["sv"]]
      refute t.spectator_view(now).key?("sh"), "never in the put"
      assert_operator v["sv"], :<=, want, "at #{now} ms a spectator is no later than 5 s ago"
      assert_operator v["sv"], :>=, seen[now - 5020], "and not earlier" if seen[now - 5020]
      assert_equal t.spectator_view(now)["sv"], v["sv"], "the put and table are as late"
      assert_nil v["dl"], "no deadline in a delayed view"
      assert_equal t.sv, t.view(seat, now)["sv"], "a seated player is not delayed"
      assert_equal t.public_view(now)["v"], v["v"], "the version is now's (the screens ask when it moves)"
    end
    assert_operator now, :>=, 5000
    assert_operator t.member_view(sp, now)["sv"], :<, t.sv
  end

  def test_no_delay_by_default
    t, toks = lobby
    sp = spectator(t)
    start(t, toks)
    now = run_until(t, 0) { t.sv > 5 }
    assert_equal t.sv, t.member_view(sp, now)["sv"]
    assert_equal 0, T::DEFAULTS["spectator_delay_ms"]
  end

  def test_how_many_spectators
    t, toks = lobby(1, "spectators" => 2)
    # In the lobby the seats still free count too: 2 + 3.
    5.times { |i| refute t.join("wasm-dddd#{i}", "D", 0)["error"], "joiner #{i}" }
    assert_equal({ "error" => "spectators" }, t.join("wasm-ddddx", "D", 0))
    assert_equal "ok", t.sit(t.mine("wasm-dddd0")["token"], -1, 0)
    t.leave(t.mine("wasm-dddd1")["token"])
    t.leave(t.mine("wasm-dddd2")["token"])
    start(t, toks)
    assert_equal({ "error" => "spectators" }, t.join("wasm-ddddy", "D", 0), "in a game: two at most")
    refute t.join("wasm-dddd3", "D", 0)["error"], "a member gets its place back"
    assert_equal 12, T::DEFAULTS["spectators"]
  end

  # ------------------------------------------------------------ the result

  def test_the_han_of_each_yaku_is_in_the_result
    t = open_tanyao_table(true)
    tok1 = t.instance_variable_get(:@seats)[1]["token"]
    assert_equal "ok", t.act(tok1, t.sv, E::RON, [], 10)
    w = t.public_view(10)["res"]["wn"][0]
    assert_equal w["y"].size, w["yh"].size
    assert_equal ["断么九"], w["y"]
    assert_equal [1], w["yh"]
    assert_operator reply_bytes(t.view(1, 10)), :<, 3800
  end
end
