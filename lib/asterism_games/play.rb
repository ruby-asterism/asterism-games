# frozen_string_literal: true

require_relative "version"

module AsterismGames
  # `asterism-games play <game>` (README "Playing in a terminal"): the
  # terminal clients of the tables, CRuby and the asterism gem only. The
  # connection options are the same for every game; each game has a class
  # with `run(opts)` (play/othello.rb, play/mahjong.rb), loaded only when
  # it is played (neither needs the framework or riichi_engine).
  module Play
    GAMES = {
      "othello" => ["othello", "an othello table: the board as text, play by typing squares (d3)"],
      "mahjong" => ["mahjong", "a mahjong table: the tiles as kanji, emoji or 123m text, play by letters or 6s"]
    }.freeze

    USAGE = <<~TEXT
      Usage: asterism-games play <game> [options]

      Games:
      %<games>s

      Options (every game):
        --router LOCATOR      the Zenoh router (tcp/127.0.0.1:7447 when nothing says otherwise)
        --credentials FILE    a console's .tar for a router over mutual TLS (the router and
                              the node ID come from it)
        --namespace PREFIX    inside a room's key space (room/01)
        --table PATH          the table (<host>/games/<table>); without it the first one found
        --name NAME           the name at the table (default: the node ID)
        --node NODE           the node ID (default: tty-<host>-<pid>, or the .tar's name)
        --commands LIST       commands to run first, comma separated ("sit,cpu,start")
        --until-over          quit when a game it saw played is over
        -h, --help            this text (and the game's own: play <game> --help)
      mahjong only:
        --tiles kanji|emoji|mpsz
                              how tiles show: kanji (default: 一萬 ４筒 ３索 東, the hand in
                              two rows like the table app), emoji (🀇🀈🀉; the font draws
                              them, 🀄 often in colour) or text (1m 4p 3s 東)

      With neither --router nor --credentials, ASTERISM_ROUTER and
      ASTERISM_CREDENTIALS from the environment are used (as the asterism
      command line does: all or nothing).
    TEXT

    module_function

    def usage
      format(USAGE, games: GAMES.map { |n, (_, text)| format("  %-9s %s", n, text) }.join("\n"))
    end

    # The entry (bin/asterism-games play ...); returns the exit status.
    def main(argv, out: $stdout, err: $stderr)
      game = argv.first
      if game.nil? || %w[-h --help help].include?(game)
        out.puts usage
        return 0
      end
      unless GAMES.key?(game)
        err.puts "asterism-games play: no game #{game.inspect} (#{GAMES.keys.join(', ')})"
        return 2
      end
      opts = parse(argv.drop(1), game)
      if opts[:help]
        out.puts game_help(game)
        return 0
      end
      run(game, opts)
      0
    rescue ArgumentError => e
      err.puts "asterism-games play #{game}: #{e.message} (--help)"
      2
    end

    def run(game, opts)
      require_relative "play/#{GAMES.fetch(game)[0]}"
      { "othello" => -> { OthelloTty.run(opts) }, "mahjong" => -> { Mahjong.run(opts) } }.fetch(game).call
    end

    def game_help(game)
      require_relative "play/#{GAMES.fetch(game)[0]}"
      "#{usage}\n#{(game == 'othello' ? OthelloTty : Mahjong)::HELP}"
    end

    # The options of every game (and --tiles); raises ArgumentError.
    def parse(args, game = nil, env: ENV)
      opts = { router: nil, table: nil, name: nil, node: nil, credentials: nil, namespace: nil,
               commands: [], until_over: false, tiles: "kanji", help: false }
      args = args.dup
      until args.empty?
        k = args.shift
        need = lambda do
          v = args.shift
          raise ArgumentError, "#{k} takes a value" if v.nil? || v.start_with?("--")
          v
        end
        case k
        when "--router" then opts[:router] = need.call
        when "--table" then opts[:table] = need.call
        when "--name" then opts[:name] = need.call
        when "--node" then opts[:node] = need.call
        when "--credentials" then opts[:credentials] = need.call
        when "--namespace" then opts[:namespace] = need.call
        when "--commands" then opts[:commands] = need.call.split(",").map(&:strip).reject(&:empty?)
        when "--until-over" then opts[:until_over] = true
        when "--tiles"
          raise ArgumentError, "--tiles is mahjong's" unless game.nil? || game == "mahjong"
          opts[:tiles] = need.call
          raise ArgumentError, "--tiles kanji, emoji or mpsz" unless %w[kanji emoji mpsz].include?(opts[:tiles])
        when "-h", "--help" then opts[:help] = true
        else raise ArgumentError, "unknown option #{k}"
        end
      end
      network!(opts, env)
      opts
    end

    # The router and the credentials: the line's; with neither on the
    # line, ASTERISM_ROUTER and ASTERISM_CREDENTIALS (all or nothing, so a
    # router on the line never meets a .tar from the environment); with
    # nothing at all, a zenohd on this machine. opts[:locator] is what
    # Asterism.connect takes (nil: the .tar's router).
    def network!(opts, env = ENV)
      if opts[:router].nil? && opts[:credentials].nil?
        r = env["ASTERISM_ROUTER"].to_s
        c = env["ASTERISM_CREDENTIALS"].to_s
        opts[:router] = r unless r.empty?
        opts[:credentials] = c unless c.empty?
      end
      opts[:router] = "tcp/127.0.0.1:7447" if opts[:router].nil? && opts[:credentials].nil?
      opts[:locator] = opts[:router]
      opts
    end

    # Asterism.connect with the options; yields the Net (started, with
    # on_join / on_leave passed to the given handlers).
    def connect(opts, app: "game", on_join: nil, on_leave: nil, label: "play")
      require "asterism"
      require "socket"
      node = opts[:node] || (opts[:credentials] ? nil : "tty-#{Socket.gethostname[/\A[A-Za-z0-9_-]+/]}-#{Process.pid}")
      kw = { app: app }
      kw[:node] = node if node
      kw[:credentials] = opts[:credentials] if opts[:credentials]
      kw[:config] = { "namespace" => opts[:namespace] } if opts[:namespace]
      Asterism.connect(opts[:locator], **kw) do |net|
        net.on_error { |e, where| warn "#{label}: #{where}: #{e.class}: #{e.message}" }
        net.on_join { |n| on_join&.call(n) }
        net.on_leave { |n| on_leave&.call(n) }
        net.start
        yield net
      end
    end

    # The first table whose name starts with prefix (looking again whenever
    # a node joins, for wait seconds); nil when none.
    def find_tables(net, prefix, joined, wait: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      loop do
        found = net.each("*/games/*").map(&:asterism_path).sort.select { |p| p.split("/")[2].to_s.start_with?(prefix) }
        return found unless found.empty?
        return [] if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        # A node that joins may be a host: look again then (its objects
        # follow its application within moments, so also a little later).
        joined.pop(timeout: 0.5)
      end
    end

    # Reads stdin lines into the client (command(line) false: quit) and
    # waits; returns when the client quits, stdin ends on a terminal, or
    # (until_over) the game it saw is over. The end of a pipe or a file
    # keeps it running (auto plays on) until Ctrl-C.
    def read_loop(client, opts, input: $stdin)
      # A client that can wait for the right moment takes them as a queue.
      if client.respond_to?(:queue_commands)
        client.queue_commands(opts[:commands])
      else
        opts[:commands].each { |c| client.command(c) }
      end
      reader = Thread.new do
        quit = false
        while (line = input.gets)
          break quit = true unless client.command(line)
        end
        sleep unless quit || input.tty?
      end
      sleep 0.2 while reader.alive? && !(opts[:until_over] && client.finished?)
    ensure
      reader&.kill
    end
  end
end
