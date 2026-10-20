# frozen_string_literal: true

require_relative "version"
require_relative "play"

module AsterismGames
  # `asterism-games commentate <game>` (README "Commentary"): watches a
  # table from outside (its spectate key, README "Spectate"), draws it in
  # a browser and comments on it in captions and the browser's voice. It
  # only reads: it never joins or calls a table. CRuby and the asterism gem
  # only; the page is served from this process on 127.0.0.1.
  module Commentate
    GAMES = {
      "mahjong" => "a mahjong table: the four hands drawn with Family mruby's tiles, the commentary as captions and voice"
    }.freeze
    DEFAULT_PORT = 7470

    USAGE = <<~TEXT
      Usage: asterism-games commentate <game> [options]

      Games:
      %<games>s

      Options:
        --router LOCATOR      the Zenoh router (tcp/127.0.0.1:7447 when nothing says otherwise)
        --credentials FILE    a console's .tar (a viewer's or a spectator's role reads the
                              spectate keys; the router and the node ID come from it)
        --namespace PREFIX    a room's tables (room/01: their spectate keys room01-<table>,
                              outside the room; the connection itself has no namespace)
        --table TABLE         the table to show first (<table>, <host>/<table>, or
                              <host>/spectate/<table>); without it every table that puts
                              its spectate key is listed and the first one shown
        --node NODE           the node ID (default: commentate-<host>-<pid>, or the .tar's name)
        --port N              the page's port on 127.0.0.1 (default %<port>d; taken: the next free)
        --public              hide the hands: the page never gets them and the commentary
                              never tells them (for a stream; H on the page does the same
                              for that page only)
        --no-open             do not open the browser
        --json                every commentary line as a JSON line on standard output
        -h, --help            this text

      The page: Space pauses, M turns the voice off and on, H hides the hands.
      The browser speaks once the page has been clicked (its autoplay rule).

      With neither --router nor --credentials, ASTERISM_ROUTER and
      ASTERISM_CREDENTIALS from the environment are used (all or nothing).
    TEXT

    module_function

    def usage
      format(USAGE, games: GAMES.map { |n, text| format("  %-9s %s", n, text) }.join("\n"), port: DEFAULT_PORT)
    end

    def main(argv, out: $stdout, err: $stderr)
      game = argv.first
      if game.nil? || %w[-h --help help].include?(game)
        out.puts usage
        return 0
      end
      unless GAMES.key?(game)
        err.puts "asterism-games commentate: no game #{game.inspect} (#{GAMES.keys.join(', ')})"
        return 2
      end
      opts = parse(argv.drop(1))
      if opts[:help]
        out.puts usage
        return 0
      end
      require_relative "commentate/mahjong"
      MahjongRunner.run(opts, out: out, err: err)
      0
    rescue ArgumentError => e
      err.puts "asterism-games commentate #{game}: #{e.message} (--help)"
      2
    end

    def parse(args, env: ENV)
      opts = { router: nil, credentials: nil, namespace: nil, table: nil, node: nil, port: DEFAULT_PORT,
               public: false, open: true, json: false, help: false }
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
        when "--credentials" then opts[:credentials] = need.call
        when "--namespace" then opts[:namespace] = need.call
        when "--table" then opts[:table] = need.call
        when "--node" then opts[:node] = need.call
        when "--port"
          v = need.call
          raise ArgumentError, "--port takes a number (1-65535)" unless v.match?(/\A\d+\z/) && v.to_i.between?(1, 65_535)
          opts[:port] = v.to_i
        when "--public" then opts[:public] = true
        when "--no-open" then opts[:open] = false
        when "--json" then opts[:json] = true
        when "-h", "--help" then opts[:help] = true
        else raise ArgumentError, "unknown option #{k}"
        end
      end
      Play.network!(opts, env)
      opts
    end
  end
end
