version = File.read(File.expand_path("VERSION", __dir__)).strip

# The gem (README "The gem and the image"): the framework and the two
# sample games that need nothing else (othello, the drawing board), with
# the host and the terminal clients (asterism-games play: othello, and the
# mahjong client, which needs nothing else). Not in it: the mahjong table (app/, which needs
# the riichi_engine fork from git), bin/mahjong-bots, deploy/, config/,
# the tests. The image (deploy/vps/Dockerfile) holds all of it, with the
# gems of the Gemfile.
Gem::Specification.new do |s|
  s.name = "asterism-games"
  s.version = version
  s.summary = "Game hosts on Asterism: write the rules of a game, get tables people play over Zenoh"
  s.description = "A framework for the server side of a game on an Asterism network: the host " \
                  "(tables exposed as Asterism objects, the state put and saved, who is there, time), " \
                  "the rooms of an Asterism console and the permanent tables next to them. " \
                  "A game subclasses AsterismGames::Game and AsterismGames::Remote and writes only its " \
                  "rules and the methods it exposes. Comes with othello and a shared drawing board as samples, " \
                  "and terminal clients for othello and mahjong (asterism-games play)."
  s.authors = ["Katsuhiko Kageyama"]
  s.homepage = "https://github.com/ruby-asterism/asterism-games"
  s.metadata = {
    "homepage_uri" => s.homepage,
    "source_code_uri" => "https://github.com/ruby-asterism/asterism-games",
    "changelog_uri" => "https://github.com/ruby-asterism/asterism-games/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/ruby-asterism/asterism-games/issues",
    "rubygems_mfa_required" => "true"
  }
  s.license = "MIT"
  s.required_ruby_version = ">= 3.2"
  # Listed by name and pattern, never from git: nothing else in the
  # checkout (app/, deploy/, credentials, var/) can slip in.
  s.files = Dir["lib/asterism_games.rb", "lib/asterism_games/**/*.rb"] +
            ["bin/asterism-games", "VERSION", "README.md", "CHANGELOG.md", "LICENSE"]
  s.require_paths = ["lib"]
  s.bindir = "bin"
  s.executables = ["asterism-games"]
  # 0.7.1 is enough: what came after it (the methods' texts in the meta,
  # @status, on_app_join) is used when the asterism gem has it.
  # The AI players' Claude needs the anthropic gem, which is not a
  # dependency (install it to offer Claude; README "AI players").
  s.add_dependency "asterism", "~> 0.7", ">= 0.7.1"
end
