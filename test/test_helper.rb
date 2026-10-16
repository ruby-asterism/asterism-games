# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "tmpdir"
require "asterism"
require "asterism_games"
require "asterism_games/mahjong"
require "asterism_games/othello"

module MahjongTestHelper
  M = AsterismGames::Mahjong
  E = M::Engine

  # The bytes a view takes as the answer of a call: the reply payload
  # {"value" => view} and a call key with long names.
  CALL_KEY = "asterism/games-host-aaaaaa/games/mahjong1/call/wasm-aaaaaa"

  def reply_bytes(v)
    Asterism::Codec.pack({ "value" => v }).bytesize + CALL_KEY.bytesize
  end

  def cpu_table(**opts)
    M::Table.new("t", { "humans" => 0, "cpu_ms" => 0, "result_ms" => 0 }.merge(opts.transform_keys(&:to_s)))
  end

  # A table with humans; a fixed time per move (no bank) unless bank_ms is
  # given.
  def human_table(store: nil, **opts)
    M::Table.new("t", { "cpu_ms" => 0, "result_ms" => 0, "turn_ms" => 1000, "bank_ms" => 0,
                        "call_ms" => 1000 }.merge(opts.transform_keys(&:to_s)), store: store)
  end

  # A game with n human members seated (nodes "wasm-aaaaa0".. ), the other
  # seats CPUs, started by the first. Returns [table, {seat => token}].
  def seated_table(n = 1, store: nil, now: 0, **opts)
    t = human_table(store: store, **opts)
    tokens = (0...n).map do |i|
      tok = t.join("wasm-aaaaa#{i}", "P#{i}", now)["token"]
      assert_equal "ok", t.sit(tok, -1, now)
      tok
    end
    t.cpu(tokens[0], -1, true) if n < 4
    assert_equal "ok", t.start(tokens[0], now)
    [t, tokens.to_h { |tok| [t.seat_of(tok), tok] }]
  end
  # Advances a table until the block is true (or the steps run out).
  def run_until(table, now, limit: 200_000)
    limit.times do
      return now if yield
      now += 10
      table.tick(now)
    end
    flunk "condition not reached"
  end

  # The keys a seat's view may have beyond the public view.
  SEAT_KEYS = %w[me h dt a wt uk].freeze

  # Checks one seat's view against the state: its own hand and nothing of
  # any other hand.
  def check_secrecy(table, seat, now, assist = M::Table::ASSIST_DEFAULT)
    v = table.view(seat, now, assist)
    pub = table.public_view(now)
    assert_equal [], (v.keys - pub.keys - SEAT_KEYS), "unexpected keys in a seat's view"
    assert_nil pub["h"], "a hand in the public view"
    return v unless table.status == "play"
    mine = table.state.hands[seat].tiles.map(&:to_s)
    shown = M::Tiles.unpack(v["h"])
    shown << M::Tiles.name(v["dt"]) if v["dt"] >= 0
    assert_equal mine.sort, shown.sort, "seat #{seat} sees a hand that is not its own"
    v
  end
end
