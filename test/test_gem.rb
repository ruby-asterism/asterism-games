# frozen_string_literal: true

require_relative "test_helper"

# What the gem holds (asterism-games.gemspec; README "The gem and the
# image"): the framework, othello and the drawing board, the host and the
# terminal clients (the mahjong one too: it needs only the asterism gem);
# never the mahjong table (app/, riichi_engine), the deployment, the
# settings of a server, the tests or anything like a key.
class TestGem < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def spec
    @spec ||= Dir.chdir(ROOT) { Gem::Specification.load("asterism-games.gemspec") }
  end

  def test_the_files_are_the_framework_and_the_sample_games
    files = spec.files
    files.each do |f|
      next assert_match(%r{\Alib/asterism_games/play/mahjong(_text|_screen)?\.rb\z}, f) if f.include?("/play/mahjong")

      refute_match(%r{mahjong|riichi|\Aapp/|\Adeploy/|\Aconfig/|\Atest/|\Avar/|\Avendor/|credentials}i, f, "#{f} is not the gem's")
      refute_match(/\.(tar|pem|key|crt|p12|env)\z|\.env\b|secret|token/i, f, "#{f} looks like a key")
      assert File.file?(File.join(ROOT, f)), "#{f} is missing"
    end
    lib = Dir.glob("lib/**/*.rb", base: ROOT)
    assert_equal lib.sort, files.grep(%r{\Alib/}).sort, "every file of lib/ is in the gem"
    assert_includes files, "lib/asterism_games/othello.rb"
    assert_includes files, "lib/asterism_games/board.rb"
    assert_includes files, "VERSION", "version.rb reads it"
    assert_equal %w[asterism-games othello-tty], spec.executables.sort
    spec.executables.each { |e| assert_includes files, "bin/#{e}" }
  end

  def test_the_version_and_the_dependencies
    assert_equal AsterismGames::VERSION, spec.version.to_s
    runtime = spec.runtime_dependencies.map(&:name)
    assert_equal ["asterism"], runtime, "riichi_engine and anthropic are the Gemfile's, not the gem's"
    assert spec.runtime_dependencies.first.requirement.satisfied_by?(Gem::Version.new("0.7.1"))
  end

  def test_the_gem_alone_has_the_sample_games_and_nothing_of_mahjong
    skip "mahjong is loaded in the whole suite (rake test:gem runs this)" unless GEM_ONLY
    assert_equal %w[othello board], AsterismGames.games.keys
    assert_empty $LOADED_FEATURES.grep(/riichi|mahjong|anthropic/i).grep_v(%r{/asterism_games/play/mahjong}),
                 "the mahjong client (play/) may be loaded, the table never"
    assert_equal "othello", AsterismGames::Config.default_game
  end
end
