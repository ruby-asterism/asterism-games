# frozen_string_literal: true

require "rake/testtask"

# rake test           every test: the gem's files and the image's games
#                     (mahjong: 20 CPU hanchan in 8 processes, a few minutes)
# MJ_GAMES=4 rake test   fewer hanchan
# rake test:gem       what the gem holds only (lib/: the framework, othello,
#                     the drawing board), with mahjong never loaded
Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib" << "app"
  t.test_files = FileList["test/test_*.rb"]
  t.warning = false
end

GEM_TESTS = %w[test/test_framework.rb test/test_othello.rb test/test_board.rb test/test_gem.rb].freeze

Rake::TestTask.new("test:gem_files") do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList[*GEM_TESTS]
  t.warning = false
end

desc "Run the tests of what the gem holds (no mahjong)"
task "test:gem" do
  ENV["ASTERISM_GAMES_TEST_GEM"] = "1"
  Rake::Task["test:gem_files"].invoke
end

task default: :test
