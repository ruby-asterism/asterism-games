# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

# The framework does not depend on a game (README "Writing a game"): its
# files require nothing of mahjong or riichi_engine, loading it loads only
# its own files, and a small game of its own (test/framework/tally.rb) has
# rooms, permanent tables, saving and the status on it, in a process
# where nothing else is loaded.
class TestFramework < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)
  # The framework's files (the gem holds them, and the sample games next to them).
  FRAMEWORK = %w[asterism_games.rb asterism_games/version.rb asterism_games/game.rb asterism_games/remote.rb
                 asterism_games/store.rb asterism_games/config.rb asterism_games/host.rb
                 asterism_games/rooms.rb asterism_games/ai.rb asterism_games/ai_hub.rb
                 asterism_games/record_book.rb].freeze

  def ruby(*args)
    Open3.capture2e({ "RUBYOPT" => "-rbundler/setup" }, RbConfig.ruby, "-I#{LIB}", *args,
                    chdir: File.expand_path("..", __dir__))
  end

  def test_the_framework_files_require_only_the_framework
    FRAMEWORK.each do |f|
      text = File.read(File.join(LIB, f))
      refute_match(/riichi|mahjong/i, text.lines.grep(/^\s*require/).join, "#{f} requires a game")
      refute_match(/Mahjong|RiichiEngine|::Riichi/, text, "#{f} names a game's code")
      text.scan(/^\s*require_relative "([^"]+)"/).flatten.each do |r|
        path = File.expand_path("#{r}.rb", File.dirname(File.join(LIB, f))).delete_prefix("#{LIB}/")
        assert_includes FRAMEWORK, path, "#{f} requires #{path}, outside the framework"
      end
    end
    assert_equal FRAMEWORK.sort, (Dir.glob("asterism_games{.rb,/*.rb}", base: LIB) -
                                  ["asterism_games/othello.rb", "asterism_games/board.rb", "asterism_games/play.rb",
                                   "asterism_games/commentate.rb"]).sort,
                 "every framework file is listed"
    # The gem's games need nothing but the framework either.
    Dir.glob("asterism_games/{othello,board}{.rb,/*.rb}", base: LIB).each do |f|
      refute_match(/riichi|mahjong|anthropic/i, File.read(File.join(LIB, f)).lines.grep(/^\s*require/).join, "#{f} requires more than the framework")
    end
    # The terminal clients (asterism-games play) and the commentator
    # (asterism-games commentate): the mahjong ones too, but neither the
    # table nor riichi_engine nor the framework.
    Dir.glob("asterism_games/{play,commentate}{.rb,/*.rb}", base: LIB).each do |f|
      reqs = File.read(File.join(LIB, f)).lines.grep(/^\s*require/).join
      refute_match(/riichi|anthropic|"asterism_games"|mahjong\/(table|engine)/i, reqs, "#{f} requires more than asterism")
    end
    assert_empty Dir.glob("**/*mahjong*", base: LIB).grep_v(%r{\Aasterism_games/(play|commentate)/}),
                 "the mahjong table is the image's (app/), not the gem's"
  end

  def test_loading_the_framework_loads_no_game
    out, st = ruby("-e", <<~RUBY)
      require "json"
      before = $LOADED_FEATURES.dup
      require "asterism_games"
      mine = ($LOADED_FEATURES - before).select { _1.start_with?("#{LIB}/") }.map { _1.delete_prefix("#{LIB}/") }
      puts JSON.generate({ "mine" => mine.sort, "games" => AsterismGames.games.keys,
                           "riichi" => $LOADED_FEATURES.grep(/riichi/i).size })
    RUBY
    assert st.success?, out
    r = JSON.parse(out.lines.last)
    assert_equal FRAMEWORK.sort, r["mine"]
    assert_equal [], r["games"]
    assert_equal 0, r["riichi"]
  end

  def test_a_game_of_its_own_on_the_framework_alone
    out, st = ruby("-I#{File.expand_path('framework', __dir__)}", File.expand_path("framework/test_tally.rb", __dir__))
    assert st.success?, out
    m = out.match(/(\d+) runs, (\d+) assertions, 0 failures, 0 errors/)
    assert m, out
    assert_operator m[1].to_i, :>=, 8
    puts "\n  framework alone (tally): #{m[1]} runs, #{m[2]} assertions"
  end

  def test_the_mahjong_game_is_registered_with_its_screen_and_tables
    skip "mahjong is not in the gem (rake test:gem)" if GEM_ONLY
    t = AsterismGames.game("mahjong")
    assert_equal MahjongTestHelper::M::Table, t
    assert_equal MahjongTestHelper::M::Remote, t.remote
    assert_equal %w[mahjong1 mahjong2], t.tables
    assert_equal ["/app/game/mahjong/mahjong.app.rb"], t.screens
    # The exposed methods and their numbers of arguments, in the order of
    # before (the meta a console lists).
    assert_equal({ join: 1, mine: 0, sit: 2, stand: 1, cpu: 3, start: 1, rule: 3, view: 2, act: 4, table: 0,
                   describe: 0, look: 1, choose: 3, points: 1, records: -1, record: -1, stats: -1, leave: 1 },
                 t.remote.exposes)
    # Every method is described (names as many as its arguments).
    t.remote.exposes.each do |m, n|
      d = t.remote.docs[m]
      assert d, "#{m} has no doc"
      # Any number (-1): the names are the leading ones (README "Game records").
      assert_equal n, d[0].size, "#{m}: argument names" unless n.negative?
      assert_operator d[1].bytesize, :<=, 2048
    end
    assert_equal t.remote.exposes, MahjongTestHelper::M::Remote::METHODS
  end
end
