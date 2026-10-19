# frozen_string_literal: true

require "json"
require "time"

module AsterismGames
  # AI players (README "AI players"): a table's owner puts one in an empty
  # seat as it puts a CPU there. The host asks it for each decision through
  # one connection shape (a "decider"), outside the game's lock, and hands
  # the answer back to the table; a decision that does not come in time, or
  # fails, is played by the CPU. What it costs is counted per day, with a
  # limit.
  #
  # A decider takes a request and returns a Decision:
  #
  #   request = { "game" => "mahjong", "table" => "mahjong1", "seat" => 2,
  #               "instructions" => "how the game is played (a long text)",
  #               "view" => { ... the seat's look, with "moves" numbered ... } }
  #   decider.decide(request, timeout:) # => Decision.new(n: 3, tokens: {...})
  #
  # n is the number of one of the view's moves. A decider raises AI::Error
  # when it has no answer (the reason is a short text without the key).
  module AI
    class Error < StandardError; end

    # tokens: {"in", "out", "cache_write", "cache_read"} as the API counted them.
    Decision = Struct.new(:n, :tokens, :ms, keyword_init: true)

    LABELS = { "claude" => "Claude", "jev" => "Jev" }.freeze

    # The kinds each game may seat (README "AI players"): the one place
    # that decides it. Othello offers Jev only (games 0.17.0), whatever
    # other keys the host has; a game not named here offers none.
    GAME_KINDS = { "mahjong" => %w[claude jev], "othello" => %w[jev] }.freeze

    # The kinds a table of game may offer, of those the host can offer
    # now (in the host's order).
    def self.kinds_for(game, kinds)
      allowed = GAME_KINDS[game.to_s] || []
      Array(kinds).map(&:to_s).select { |k| allowed.include?(k) }
    end

    # The settings, from the environment (README "AI players").
    class Settings
      attr_reader :env

      def initialize(env = ENV)
        @env = env
      end

      def daily_usd = num("ASTERISM_GAMES_AI_DAILY_USD", 3.0)

      # The kinds' own daily limits, ASTERISM_GAMES_AI_DAILY_USD_<KIND>
      # (CLAUDE, JEV): {kind => USD}, only the kinds that have one. A kind
      # without one follows daily_usd (the day's total of every kind). A
      # value that is not a number, or is negative, is left out (said in
      # the log when log is given).
      def kind_daily_usd(log: nil)
        LABELS.keys.each_with_object({}) do |kind, out|
          k = "ASTERISM_GAMES_AI_DAILY_USD_#{kind.upcase}"
          v = @env[k].to_s.strip
          next if v.empty?
          f = Float(v, exception: false)
          if f.nil? || !f.finite? || f.negative?
            log&.call("games: AI players: #{k} is not a number of dollars (0 or more); ignored, " \
                      "#{kind} follows ASTERISM_GAMES_AI_DAILY_USD")
            next
          end
          out[kind] = f
        end
      end
      def calls_per_game = num("ASTERISM_GAMES_AI_CALLS_PER_GAME", 400).to_i
      def threads = [num("ASTERISM_GAMES_AI_THREADS", 4).to_i, 1].max
      def fake? = %w[1 true yes].include?(@env["ASTERISM_GAMES_AI_FAKE"].to_s.downcase)

      def claude_model = str("ASTERISM_GAMES_CLAUDE_MODEL", "claude-sonnet-5-5")
      def claude_effort = str("ASTERISM_GAMES_CLAUDE_EFFORT", "low")
      def jev_model = str("ASTERISM_GAMES_JEV_MODEL", "jev-latest")

      # USD per million tokens. The defaults are the published prices:
      # Claude Sonnet 5.5 $2 input, $10 output, $2.50 a 5-minute cache
      # write, $0.10 a cache hit (checked 2026-10-17); Jev (TypeSafe's API)
      # $0.042 input, output free (checked 2026-10-18).
      def prices(kind)
        case kind
        when "claude"
          { "in" => num("ASTERISM_GAMES_CLAUDE_USD_IN", 2.0), "out" => num("ASTERISM_GAMES_CLAUDE_USD_OUT", 10.0),
            "cache_write" => num("ASTERISM_GAMES_CLAUDE_USD_CACHE_WRITE", 2.5),
            "cache_read" => num("ASTERISM_GAMES_CLAUDE_USD_CACHE_READ", 0.10) }
        when "jev"
          { "in" => num("ASTERISM_GAMES_JEV_USD_IN", 0.042), "out" => num("ASTERISM_GAMES_JEV_USD_OUT", 0.0),
            "cache_write" => 0.0, "cache_read" => 0.0 }
        else { "in" => 0.0, "out" => 0.0, "cache_write" => 0.0, "cache_read" => 0.0 }
        end
      end

      # The deciders there are keys (or fakes) for: {kind => decider}.
      # Without a key a kind is not offered at all.
      def deciders(log: nil)
        if fake?
          opts = { delay_ms: num("ASTERISM_GAMES_AI_FAKE_DELAY_MS", 300).to_i,
                   slow_every: num("ASTERISM_GAMES_AI_FAKE_SLOW_EVERY", 0).to_i,
                   fail_every: num("ASTERISM_GAMES_AI_FAKE_FAIL_EVERY", 0).to_i }
          log&.call("games: AI players are fakes (ASTERISM_GAMES_AI_FAKE): no API is called")
          return { "claude" => Fake.new(**opts), "jev" => Fake.new(**opts) }
        end
        out = {}
        key = @env["ANTHROPIC_API_KEY"].to_s
        unless key.empty?
          begin
            out["claude"] = Claude.new(key, model: claude_model, effort: claude_effort)
          rescue LoadError
            log&.call("games: ANTHROPIC_API_KEY is set but the anthropic gem is missing: no Claude players")
          end
        end
        tok = @env["TYPESAFE_API_KEY"].to_s
        out["jev"] = Jev.new(tok, model: jev_model) unless tok.empty?
        out
      end

      private

      def num(k, default)
        v = @env[k].to_s
        v.empty? ? default : Float(v)
      rescue ArgumentError
        default
      end

      def str(k, default)
        v = @env[k].to_s
        v.empty? ? default : v
      end
    end

    # What the AI players cost, per day (the host's local date), kept in a
    # JSON file every host process shares (the rooms' hosts, the permanent
    # tables): {"days" => {"2026-10-17" => {kind => {"calls", "in", "out",
    # "cache_write", "cache_read", "usd"}}}}. Counts and money only: no
    # key, no table, no player.
    #
    # The limits: daily_usd for the day's total of every kind, and
    # kind_usd ({kind => USD}) for the kinds that have their own. A kind
    # with its own stops when its own money of the day reaches it; the
    # others when the day's total reaches daily_usd.
    class Budget
      KEEP_DAYS = 31

      attr_reader :path, :daily_usd, :kind_usd

      def initialize(path, daily_usd:, prices:, kind_usd: {}, clock: -> { Time.now })
        @path = path
        @daily_usd = daily_usd.to_f
        @kind_usd = kind_usd.to_h { |k, v| [k.to_s, v.to_f] }.freeze
        @prices = prices
        @clock = clock
        @lock = Mutex.new
        @cache = nil
        @cache_at = 0
      end

      def today
        @clock.call.strftime("%Y-%m-%d")
      end

      # Adds one decision's tokens; returns its cost (USD).
      def record(kind, tokens)
        p = @prices.call(kind)
        usd = %w[in out cache_write cache_read].sum { |k| tokens[k].to_i * p[k].to_f } / 1_000_000.0
        update do |days|
          d = (days[today] ||= {})
          e = (d[kind] ||= { "calls" => 0, "in" => 0, "out" => 0, "cache_write" => 0, "cache_read" => 0, "usd" => 0.0 })
          e["calls"] += 1
          %w[in out cache_write cache_read].each { |k| e[k] += tokens[k].to_i }
          e["usd"] = (e["usd"].to_f + usd).round(6)
        end
        usd
      end

      # A decision that failed before any token was counted.
      def record_failure(kind)
        update do |days|
          d = (days[today] ||= {})
          e = (d[kind] ||= { "calls" => 0, "in" => 0, "out" => 0, "cache_write" => 0, "cache_read" => 0, "usd" => 0.0 })
          e["failed"] = e["failed"].to_i + 1
        end
      end

      # Today's counts: {kind => {...}} (read again at most once a second).
      def day(date = today)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @cache.nil? || now - @cache_at > 1.0
          @cache = read
          @cache_at = now
        end
        (@cache["days"] || {})[date] || {}
      end

      # Today's money: every kind's (kind nil), or one kind's.
      def usd_today(kind = nil)
        return day.values.sum { |e| e["usd"].to_f } if kind.nil?
        (day[kind.to_s] || {})["usd"].to_f
      end

      # Whether the kind has a limit of its own.
      def own_limit?(kind) = @kind_usd.key?(kind.to_s)

      # The limit the kind stops at: its own, else the total's (kind nil:
      # the total's).
      def limit_usd(kind = nil) = (kind && @kind_usd[kind.to_s]) || @daily_usd

      # Whether the kind stops for today: its own money against its own
      # limit, else the day's total against daily_usd (kind nil: the total).
      def over?(kind = nil)
        return usd_today(kind) >= @kind_usd[kind.to_s] if kind && own_limit?(kind)
        usd_today >= @daily_usd
      end

      # The totals of today, for the status: {"date", "calls", "tokens_in",
      # "tokens_out", "usd", "limit_usd"} (and per kind with kinds: true),
      # and "kind_limit_usd" ({kind => USD}) when some kind has its own
      # limit.
      def summary(kinds: false)
        d = day
        out = { "date" => today, "calls" => d.values.sum { |e| e["calls"].to_i },
                "tokens_in" => d.values.sum { |e| e["in"].to_i + e["cache_write"].to_i + e["cache_read"].to_i },
                "tokens_out" => d.values.sum { |e| e["out"].to_i },
                "usd" => d.values.sum { |e| e["usd"].to_f }.round(4), "limit_usd" => @daily_usd }
        out["kind_limit_usd"] = @kind_usd.dup unless @kind_usd.empty?
        out["kinds"] = d if kinds
        out
      end

      private

      def read
        JSON.parse(File.read(@path))
      rescue Errno::ENOENT, JSON::ParserError
        { "days" => {} }
      end

      # Read, change and write the file under an exclusive lock (several
      # host processes share it).
      def update
        @lock.synchronize do
          File.open(@path, File::RDWR | File::CREAT, 0o600) do |f|
            f.flock(File::LOCK_EX)
            data = begin
              JSON.parse(f.read)
            rescue JSON::ParserError
              {}
            end
            data = {} unless data.is_a?(Hash)
            days = (data["days"] ||= {})
            yield days
            days.keys.sort[0...-KEEP_DAYS].each { |k| days.delete(k) } if days.size > KEEP_DAYS
            f.rewind
            f.truncate(0)
            f.write(JSON.generate(data))
            f.flush
            @cache = data
            @cache_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
      end
    end

    # A decider for tests and for the LAN without keys
    # (ASTERISM_GAMES_AI_FAKE): picks a move after delay_ms (the first
    # discard of the help's tenpai list, else the drawn tile, else the
    # first move); every slow_every-th decision sleeps past its time limit,
    # every fail_every-th fails. Counts 100 tokens in, 1 out.
    class Fake
      attr_reader :count

      def initialize(delay_ms: 0, slow_every: 0, fail_every: 0, choose: nil)
        @delay_ms = delay_ms
        @slow_every = slow_every
        @fail_every = fail_every
        @choose = choose
        @count = 0
        @lock = Mutex.new
      end

      def decide(request, timeout: 30)
        i = @lock.synchronize { @count += 1 }
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @slow_every.positive? && (i % @slow_every).zero?
          sleep(timeout + 1)
        else
          sleep(@delay_ms / 1000.0) if @delay_ms.positive?
        end
        raise Error, "fake: failing on purpose (#{i})" if @fail_every.positive? && (i % @fail_every).zero?
        n = @choose ? @choose.call(request) : pick(request["view"])
        Decision.new(n: n, tokens: { "in" => 100, "out" => 1 },
                     ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round)
      end

      private

      def pick(view)
        moves = view["moves"] || []
        tenpai = view.dig("help", "tenpai")
        if tenpai && !tenpai.empty?
          m = moves.find { |x| x["type"] == "discard" && x["tile"] == tenpai[0]["discard"] }
          return m["n"] if m
        end
        win = moves.find { |x| %w[tsumo ron].include?(x["type"]) }
        return win["n"] if win
        drawn = moves.find { |x| x["type"] == "discard" && x["tile"] == view["drawn"] }
        return drawn["n"] if drawn
        pass = moves.find { |x| x["type"] == "pass" }
        return pass["n"] if pass
        moves.first ? moves.first["n"] : 0
      end
    end

    # The answer both real deciders ask for, and its check.
    def self.move_number(n, view)
      n = Integer(n, exception: false) if n.is_a?(String)
      raise Error, "no move number in the answer" unless n.is_a?(Integer)
      raise Error, "move #{n} is not offered" unless (view["moves"] || []).any? { |m| m["n"] == n }
      n
    end

    # Claude through the Messages API (the anthropic gem): the
    # instructions as the system prompt (cached), the view as JSON, and a
    # structured answer {"n": <move number>}.
    class Claude
      SCHEMA = { type: "object", properties: { n: { type: "integer" } }, required: ["n"],
                 additionalProperties: false }.freeze

      def initialize(key, model:, effort: "low")
        require "anthropic"
        @client = ::Anthropic::Client.new(api_key: key, max_retries: 0)
        @model = model
        @effort = effort
      end

      def decide(request, timeout: 30)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        view = request["view"]
        msg = @client.messages.create(
          model: @model.to_sym,
          max_tokens: 4096,
          system_: [{ type: "text", text: Claude.system_text(request), cache_control: { type: "ephemeral" } }],
          output_config: { effort: @effort.to_sym, format_: { type: :json_schema, schema: SCHEMA } },
          messages: [{ role: "user", content: Claude.user_text(request) }],
          request_options: { timeout: timeout }
        )
        u = msg.usage
        tokens = { "in" => u.input_tokens.to_i, "out" => u.output_tokens.to_i,
                   "cache_write" => u.cache_creation_input_tokens.to_i, "cache_read" => u.cache_read_input_tokens.to_i }
        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
        if msg.stop_reason == :refusal
          raise TokenError.new("claude: refused", tokens)
        end
        text = msg.content.select { |b| b.type == :text }.map(&:text).join
        n = begin
          AI.move_number(JSON.parse(text)["n"], view)
        rescue JSON::ParserError, NoMethodError, Error => e
          raise TokenError.new("claude: #{e.is_a?(Error) ? e.message : 'no JSON answer'}", tokens)
        end
        Decision.new(n: n, tokens: tokens, ms: ms)
      rescue ::Anthropic::Errors::APIStatusError => e
        raise Error, "claude: HTTP #{e.status} #{e.class.name.split('::').last}"
      rescue ::Anthropic::Errors::APIConnectionError => e
        raise Error, "claude: #{e.class.name.split('::').last}"
      end

      def self.system_text(request)
        "You play #{request['game']} at a table of an Asterism game host, as seat #{request['seat']}. " \
          "Each message is the table as your seat sees it (JSON). Choose one of its \"moves\" and answer " \
          "{\"n\": <its number>}. Play to win the game: score points, avoid dealing in to riichi and tenpai " \
          "hands.\n\n#{request['instructions']}"
      end

      def self.user_text(request)
        JSON.generate(request["view"])
      end
    end

    # A failure after the API counted tokens (they still cost).
    class TokenError < Error
      attr_reader :tokens

      def initialize(msg, tokens)
        super(msg)
        @tokens = tokens
      end
    end

    # Jev (TypeSafe) through its own API, POST /v1/systemone: a decision
    # model that picks one of a set of answers. The view is the state, the
    # moves are one choice question's criteria (their numbers as the keys,
    # their texts as the descriptions); the answer's "choice" is the key it
    # picked, "usage" the tokens it counted (input only is paid).
    class Jev
      BASE = "https://api.typesafe.ai"
      PATH = "/v1/systemone"

      def initialize(key, model: "jev-latest", base: BASE)
        require "net/http"
        require "openssl"
        @key = key
        @model = model
        @uri = URI(base.to_s.chomp("/") + PATH)
      end

      # The request body (without the key).
      def body(request)
        view = request["view"]
        state = view.merge("moves" => nil).compact
        criteria = (view["moves"] || []).to_h { |m| [m["n"].to_s, m["text"]] }
        { "state" => state, "model" => @model,
          "questions" => { "move" => { "type" => "choice", "instructions" => Jev.instructions(request),
                                       "criteria" => criteria } } }
      end

      def decide(request, timeout: 30)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        view = request["view"]
        res = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https",
                                                    open_timeout: [timeout, 5].min, read_timeout: timeout,
                                                    write_timeout: timeout) do |h|
          req = Net::HTTP::Post.new(@uri)
          req["Authorization"] = "Bearer #{@key}"
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body(request))
          h.request(req)
        end
        raise Error, "jev: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
        data = JSON.parse(res.body)
        raise Error, "jev: not an object" unless data.is_a?(Hash)
        u = data["usage"].is_a?(Hash) ? data["usage"] : {}
        tokens = { "in" => u["input_tokens"].to_i, "out" => u["output_tokens"].to_i }
        choice = data.dig("answers", "move", "choice")
        begin
          n = AI.move_number(choice, view)
        rescue Error => e
          raise TokenError.new("jev: #{e.message}", tokens)
        end
        Decision.new(n: n, tokens: tokens, ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round)
      rescue JSON::ParserError
        raise Error, "jev: not JSON"
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, IOError, SocketError, SystemCallError,
             OpenSSL::SSL::SSLError => e
        raise Error, "jev: #{e.class.name}"
      end

      def self.instructions(request)
        "You are seat #{request['seat']} at a #{request['game']} table; the state is the table as that seat sees " \
          "it. Which move should the seat play to win the game? #{request['instructions']}"
      end
    end
  end
end
