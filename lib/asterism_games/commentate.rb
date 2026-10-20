# frozen_string_literal: true

require_relative "version"
require_relative "play"
require_relative "commentate/voicevox"
require_relative "commentate/voice"
require_relative "commentate/ai_comment"

module AsterismGames
  # `asterism-games commentate <game>` (README "Commentary"): watches a
  # table from outside (its spectate key, README "Spectate"), draws it in
  # a browser and comments on it in captions and a voice (VOICEVOX's, on
  # this machine, else the browser's). It
  # only reads: it never joins or calls a table. CRuby and the asterism gem
  # only; the page is served from this process on 127.0.0.1.
  module Commentate
    GAMES = {
      "mahjong" => "a mahjong table: the four hands drawn with Family mruby's tiles, the commentary as captions and voice"
    }.freeze
    DEFAULT_PORT = 7470
    DEFAULT_SPEAKER = "ずんだもん"
    DEFAULT_STYLE = "ノーマル"

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
        --voicevox URL        the VOICEVOX engine (default VOICEVOX_URL, else
                              http://127.0.0.1:50021); not there: the browser's voice
        --speaker NAME        the VOICEVOX character (default %<speaker>s)
        --style NAME          its style (default %<style>s)
        --ai on|off           the AI's one-liners (default on; they need
                              ANTHROPIC_API_KEY and the anthropic gem)
        --ai-model MODEL      the model (default %<ai_model>s)
        --ai-daily-usd USD    what they may cost a day (default %<ai_usd>.2f); then the
                              fixed commentary alone
        -h, --help            this text

      The page: Space pauses, M turns the voice off and on, H hides the hands.
      The browser speaks once the page has been clicked (its autoplay rule).

      The voice: VOICEVOX's character says the fixed phrases (リーチ, ポン,
      ロン, the rounds ...) from WAV files made on this machine at the first
      start, and the rest of each line as it comes. The page shows the credit
      (VOICEVOX:<character>); put it in a stream's description too.

      The AI's one-liners: at the big moments (a riichi, a win, a draw, the
      lead changing hands, the last round, the end) and after a quiet
      minute, Claude says a short line after the fixed commentary (at most
      one call every 20 s, 8 s for a bigger scene than the last, such as a
      win after a riichi; only while a page is open). With the hands hidden
      (--public, H) it is not told the hands. What it costs is counted in
      $XDG_STATE_HOME/asterism-games/commentary_ai_usage.json
      (~/.local/state/... by default); the page shows today's money.

      Usage: asterism-games commentate voices --list [--voicevox URL]
             asterism-games commentate voices --make [--voicevox URL] [--speaker NAME] [--style NAME]
        --list   the engine's characters and their styles
        --make   make the fixed phrases' WAV files now (the commentary makes
                 the missing ones at its start too), in
                 $XDG_CACHE_HOME/asterism-games/voices/<speaker>-<style>/
                 (~/.cache/... by default; delete it at any time)

      With neither --router nor --credentials, ASTERISM_ROUTER and
      ASTERISM_CREDENTIALS from the environment are used (all or nothing).
    TEXT

    module_function

    def usage
      format(USAGE, games: GAMES.map { |n, text| format("  %-9s %s", n, text) }.join("\n"), port: DEFAULT_PORT,
                    speaker: DEFAULT_SPEAKER, style: DEFAULT_STYLE, ai_model: AIComment::DEFAULT_MODEL,
                    ai_usd: AIComment::DEFAULT_DAILY_USD)
    end

    def main(argv, out: $stdout, err: $stderr)
      game = argv.first
      if game.nil? || %w[-h --help help].include?(game)
        out.puts usage
        return 0
      end
      return voices(argv.drop(1), out: out, err: err) if game == "voices"
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
    rescue Voicevox::NotFound => e
      err.puts "asterism-games commentate #{game}: #{e.message} (voices --list)"
      2
    rescue ArgumentError => e
      err.puts "asterism-games commentate #{game}: #{e.message} (--help)"
      2
    end

    def parse(args, env: ENV)
      opts = { router: nil, credentials: nil, namespace: nil, table: nil, node: nil, port: DEFAULT_PORT,
               public: false, open: true, json: false, help: false,
               voicevox: env["VOICEVOX_URL"].to_s.empty? ? Voicevox::DEFAULT_URL : env["VOICEVOX_URL"],
               speaker: DEFAULT_SPEAKER, style: DEFAULT_STYLE,
               ai: true, ai_model: AIComment::DEFAULT_MODEL, ai_daily_usd: AIComment::DEFAULT_DAILY_USD }
      args = args.dup
      until args.empty?
        k = args.shift
        need = lambda do
          v = args.shift
          raise ArgumentError, "#{k} takes a value" if v.nil? || v.start_with?("--")
          v
        end
        case k
        when "--ai"
          v = need.call
          raise ArgumentError, "--ai takes on or off" unless %w[on off].include?(v)
          opts[:ai] = v == "on"
        when "--ai-model" then opts[:ai_model] = need.call
        when "--ai-daily-usd"
          v = Float(need.call, exception: false)
          raise ArgumentError, "--ai-daily-usd takes a number of dollars (0 or more)" unless v&.finite? && v >= 0
          opts[:ai_daily_usd] = v
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
        when "--voicevox" then opts[:voicevox] = need.call
        when "--speaker" then opts[:speaker] = need.call
        when "--style" then opts[:style] = need.call
        when "-h", "--help" then opts[:help] = true
        else raise ArgumentError, "unknown option #{k}"
        end
      end
      Play.network!(opts, env)
      opts
    end

    # `commentate voices --list | --make`: the engine's characters, or the
    # fixed phrases' files made now.
    def voices(args, out: $stdout, err: $stderr, env: ENV, root: nil)
      opts = { voicevox: env["VOICEVOX_URL"].to_s.empty? ? Voicevox::DEFAULT_URL : env["VOICEVOX_URL"],
               speaker: DEFAULT_SPEAKER, style: DEFAULT_STYLE, list: false, make: false }
      args = args.dup
      until args.empty?
        k = args.shift
        need = lambda do
          v = args.shift
          raise ArgumentError, "#{k} takes a value" if v.nil? || v.start_with?("--")
          v
        end
        case k
        when "--list" then opts[:list] = true
        when "--make" then opts[:make] = true
        when "--voicevox" then opts[:voicevox] = need.call
        when "--speaker" then opts[:speaker] = need.call
        when "--style" then opts[:style] = need.call
        when "-h", "--help" then return out.puts(usage) || 0
        else raise ArgumentError, "unknown option #{k}"
        end
      end
      raise ArgumentError, "--list or --make" unless opts[:list] || opts[:make]
      vv = Voicevox.new(opts[:voicevox])
      begin
        ver = vv.version
      rescue Voicevox::Error => e
        err.puts "asterism-games commentate voices: no VOICEVOX at #{vv.url} (#{e.message}); " \
                 "start the VOICEVOX app or its engine (README \"Commentary\", \"The voice\")"
        return 1
      end
      list = vv.speakers
      if opts[:list]
        out.puts "VOICEVOX #{ver} at #{vv.url}: #{list.size} character(s) (--speaker NAME --style NAME)"
        list.each { |s| out.puts "  #{s['name']}: #{s['styles'].map { |st| "#{st['name']} (#{st['id']})" }.join(', ')}" }
      end
      if opts[:make]
        id = vv.style_id(opts[:speaker], opts[:style], list)
        voice = Voice.new(vv, opts[:speaker], opts[:style], id, version: ver, root: root || ClipBank.cache_root)
        out.puts "voices: #{opts[:speaker]} (#{opts[:style]}, #{id}) into #{voice.bank.dir}"
        made, had = voice.bank.make!(log: ->(m) { out.puts "  #{m}" })
        out.puts "voices: #{made} made, #{had} already there. Credit: #{voice.credit}"
      end
      0
    rescue Voicevox::Error => e
      err.puts "asterism-games commentate voices: #{e.message}"
      1
    rescue ArgumentError => e
      err.puts "asterism-games commentate voices: #{e.message} (--help)"
      2
    end
  end
end
