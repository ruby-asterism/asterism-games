# frozen_string_literal: true

require "rake/testtask"

# rake test           every test (20 CPU hanchan in 8 processes: a few minutes)
# MJ_GAMES=4 rake test   fewer hanchan
Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/test_*.rb"]
  t.warning = false
end

task default: :test
