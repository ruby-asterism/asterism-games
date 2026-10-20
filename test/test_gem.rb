# frozen_string_literal: true

require_relative "test_helper"
require "digest"

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
      next assert_match(%r{\Alib/asterism_games/commentate/(mahjong(_events|_phrases)?\.rb|assets/[a-z_]+\.(html|js|css)|assets/tiles_(hand|river)\.bmp|assets/TILES_LICENSE\.txt)\z}, f) if f.include?("/commentate/") && f.match?(/mahjong|tiles|assets/i)

      refute_match(%r{mahjong|riichi|\Aapp/|\Adeploy/|\Aconfig/|\Atest/|\Avar/|\Avendor/|credentials}i, f, "#{f} is not the gem's")
      refute_match(/\.(tar|pem|key|crt|p12|env)\z|\.env\b|secret|token/i, f, "#{f} looks like a key")
      assert File.file?(File.join(ROOT, f)), "#{f} is missing"
    end
    lib = Dir.glob("lib/**/*.rb", base: ROOT)
    assert_equal lib.sort, files.grep(%r{\Alib/.*\.rb\z}).sort, "every file of lib/ is in the gem"
    assets = Dir.glob("lib/asterism_games/commentate/assets/*", base: ROOT)
    assert_equal assets.sort, files.grep(%r{\Alib/asterism_games/commentate/assets/}).sort, "every file of the page is in the gem"
    assert_includes files, "lib/asterism_games/othello.rb"
    assert_includes files, "lib/asterism_games/board.rb"
    assert_includes files, "VERSION", "version.rb reads it"
    assert_equal %w[asterism-games], spec.executables.sort
    spec.executables.each { |e| assert_includes files, "bin/#{e}" }
  end

  # The commentary's page and the tile sheets of Family mruby's mahjong
  # app (README "Commentary"): in the gem, the sheets byte for byte as
  # drawn (these digests are the sheets of fmruby-core's
  # flash/app/game/mahjong/), with their note.
  SHEETS = {
    "tiles_hand.bmp" => "45c8a037ffd178623ab49ae03124600cdb16125d1412f2c95b9043cd86c8aa85",
    "tiles_river.bmp" => "9c0b28d634465deae0342fa568a16faab87a9293f70c402afb9ef258c0b9c513"
  }.freeze

  def test_the_commentary_page_and_the_tile_sheets_are_in_the_gem
    files = spec.files
    %w[index.html commentate.js commentate.css TILES_LICENSE.txt].each do |f|
      assert_includes files, "lib/asterism_games/commentate/assets/#{f}"
    end
    SHEETS.each do |name, sha|
      path = "lib/asterism_games/commentate/assets/#{name}"
      assert_includes files, path
      assert_equal sha, Digest::SHA256.file(File.join(ROOT, path)).hexdigest, "#{name} is the hand-drawn sheet as it is"
    end
    note = File.read(File.join(ROOT, "lib/asterism_games/commentate/assets/TILES_LICENSE.txt"))
    assert_match(/MIT License/, note)
    assert_match(/Family mruby/, note)
    page = %w[index.html commentate.js commentate.css].map { |f| File.read(File.join(ROOT, "lib/asterism_games/commentate/assets", f)) }.join
    refute_match(%r{https?://}, page, "the page loads nothing from elsewhere (no CDN)")
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
    assert_empty $LOADED_FEATURES.grep(/riichi|mahjong|anthropic/i).grep_v(%r{/asterism_games/(play|commentate)/mahjong}),
                 "the mahjong client (play/) and commentator (commentate/) may be loaded, the table never"
    assert_equal "othello", AsterismGames::Config.default_game
  end
end
