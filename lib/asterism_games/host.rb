# frozen_string_literal: true

require "asterism"
require "json"
require_relative "version"
require_relative "game"
require_relative "config"
require_relative "store"
require_relative "ai_hub"

module AsterismGames
  # The game host: one Asterism node that exposes a game object for every
  # table in the settings, moves the games on, saves them after every change
  # and puts their public state on asterism/<node>/<app>/<table>/state.
  #
  # One process is one Asterism application (the gem keeps one connection a
  # process), so every game lives under the same app, each as an object of
  # its own name. The games come from the registry (AsterismGames.games):
  # a table's "game" names one.
  #
  # The connection is Asterism's block API (Asterism.connect { |net| }):
  # the tables are exposed with caller: :from, and the calls are answered
  # on the Net's receiving thread. The games move on in this host's own
  # loop (step: timeouts, CPU turns, the puts), which takes Asterism::LOCK,
  # the lock every tick of the receiving thread holds, so a call and a step
  # never meet inside a game.
  #
  # Who is there (README "Who is there"): Asterism tells the host when a
  # player's table app (the application "game" of its node) leaves the
  # network and comes back (net.on_app_leave / on_app_join, on the
  # receiving thread, inside that lock); the host passes it to every table,
  # where a member on that node is away at once and back at once. A router
  # whose rules do not show the host the players' presence tells it
  # nothing, and the tables fall back on the members' calls (away_ms).
  class Host
    RECONNECT_S = 3
    PUT_EVERY_MS = 5000
    LOOP_S = 0.01
    # The profile's name (outside the rooms): a host of its own on a LAN.
    # The permanent tables' host is named by Rooms (config "profile_name").
    PROFILE_NAME = "asterism-games"

    attr_reader :games, :stats

    def initialize(config, log: ->(m) { warn m })
      @config = config
      @log = log
      @clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) }
      @store = Store.new(config["state_dir"])
      @games = {}
      @remotes = {}
      @methods = {}
      @docs = {}
      @put_at = {}
      @spec = {} # table => {"q" => [[ms, bytes], ...], "bytes", "last", "out", "at"} (README "Spectate")
      @stats = Hash.new(0)
      config["tables"].each do |t|
        klass = AsterismGames.game(t["game"]) or raise ArgumentError, "unknown game #{t['game'].inspect}"
        # A room's tables check who joins against the room's ID, and trust
        # the callers the router binds to their names (README "Who joins").
        if config["room_id"]
          t = t.merge(config.slice("room_id", "trusted_nodes", "trusted_prefix", "seat_reuse_ms").compact)
        end
        # Where the games' records go (README "Game records"): the one
        # database of the state volume, and which tables these are; in a
        # room made from an invite link, the link's group (games 0.16.0).
        t = t.merge("records_db" => records_db, "records_place" => records_place)
        t = t.merge("records_group" => config["records_group"]) if config["room_id"] && config["records_group"]
        name = t["name"]
        g = klass.new(name, t.reject { |k, _| %w[name game].include?(k) }, store: @store, log: @log)
        g.resume_clock(@clock.call)
        @games[name] = g
        @remotes[name] = SizeWatch.new(klass.remote.new(g, @clock), self, name)
        @methods[name] = klass.remote.expose_methods(META_DOCS)
        @docs[name] = klass.remote.object_doc
      end
      @ai = ai_hub
      @stop = false
    end

    # The records' database: the setting ("json": the JSON files), else
    # state_dir/records.sqlite3 (the rooms' and the permanent tables' hosts
    # are given the supervisor's).
    def records_db
      @config["records_db"] || File.join(@config["state_dir"], RecordBook::DB_NAME)
    end

    # lan (a host of its own), permanent, room.
    def records_place
      @config["records_place"] || (@config["room_id"] ? "room" : "lan")
    end

    # Whether the asterism gem tells the methods' names and texts in the
    # meta (after 0.7.1; docs/protocol.md 5 of asterism).
    META_DOCS = defined?(::Asterism::DOC_MAX) ? true : false

    # The AI players (README "AI players"): the deciders there are keys for
    # (the environment), what they cost counted in ai_usage_file (shared
    # by the rooms' hosts), or the hub given (tests).
    def ai_hub
      return @config["ai_hub"] if @config["ai_hub"]
      settings = AI::Settings.new
      deciders = settings.deciders(log: @log)
      path = @config["ai_usage_file"] || File.join(@config["state_dir"], "ai_usage.json")
      own = deciders.empty? ? settings.kind_daily_usd : settings.kind_daily_usd(log: @log)
      budget = AI::Budget.new(path, daily_usd: settings.daily_usd, kind_usd: own,
                                    prices: ->(k) { settings.prices(k) })
      unless deciders.empty?
        @log.call("games: AI players: #{deciders.keys.join(', ')} (#{AI::Hub.limits_text(deciders.keys, budget)}, " \
                  "#{settings.calls_per_game} decisions a game)")
      end
      AI::Hub.new(deciders, budget, calls_per_game: settings.calls_per_game, threads: settings.threads, log: @log)
    end

    attr_reader :ai

    def stop!
      @stop = true
    end

    def run
      until @stop
        begin
          ::Asterism.connect(locator, **connect_options) do |net|
            up(net)
            serve(net)
          end
        rescue ::Asterism::Error => e
          @log.call("games: #{e.class}: #{e.message}; again in #{RECONNECT_S} s")
        end
        down
        sleep RECONNECT_S unless @stop
      end
      save_all
      @ai&.stop
      @log.call("games: largest message #{@stats['max_bytes']} B (#{@stats['max_what']})" \
                "#{"; spectate #{@stats['spectate']} puts, at most #{@stats['spectate_max_bytes']} B" if @stats['spectate'].positive?}")
      if @ai&.any?
        n, avg, max = @ai.times
        @log.call("games: AI players: #{@ai.stats.to_h.inspect}; #{n} decisions, #{avg} ms on average, #{max} ms at most; " \
                  "today #{@ai.budget.summary.inspect}")
      end
    end

    # This host's node ID: the setting, else the certificate's name (the
    # permanent tables, README "Permanent tables": the router's ACL knows
    # the host by that name).
    def node
      @node ||= @config["node"] || (@config["credentials"] && ::Asterism::Credentials.load(@config["credentials"], warn: false).name)
    end

    def locator
      @config["credentials"] ? @config["credentials_router"] : @config["router"]
    end

    def connect_options
      opts = { node: node, app: @config["app"] }
      opts[:credentials] = @config["credentials"] if @config["credentials"]
      # A room's host (Rooms): its own certificate (or the slot's) and the
      # room's key space, so every key is the room's (room/<slot>/asterism/...).
      opts[:config] = { "namespace" => @config["namespace"] } if @config["namespace"]
      opts
    end

    # The name its profile gives, or nil in a room (no name there: the
    # console does not read the profiles in a room, and labels a room's
    # host by its node ID and the room).
    def profile_name
      return nil if @config["namespace"]
      @config["profile_name"] || PROFILE_NAME
    end

    # Connected: the profile, the tables, the receiving thread.
    def up(net)
      net.profile(name: profile_name) if profile_name
      net.on_error { |e, where| @log.call("games: #{where}: #{e.class}: #{e.message}") }
      follow_players(net)
      @games.each_key do |name|
        extra = META_DOCS && @docs[name] ? { doc: @docs[name] } : {}
        net.expose(name, @remotes[name], methods: @methods[name], caller: :from, **extra)
      end
      @net = net
      @connected = true
      @tables_status = TablesStatus.new(net, node, @config["app"]) if tables_status?
      write_status
      @log.call("games: #{node}/#{@config['app']} up (#{@games.keys.join(', ')}) via " \
                "#{locator || 'credentials'}#{" in #{@config['namespace']}" if @config['namespace']}")
      net.start
    end

    # The host's own loop, until it stops or the connection is lost (the
    # receiving thread ends; a client of a router that only reconnects
    # stays, reconnecting?).
    def serve(net)
      until @stop
        unless net.running?
          @log.call("games: connection lost: #{net.lost_reason}")
          return
        end
        open_spectate
        ::Asterism::LOCK.synchronize { step }
        sleep LOOP_S
      end
    end

    # The application a player's table app runs as (README "Who is there"):
    # the host follows asterism/<node>/game, not the node, so a node that
    # runs other applications too is away as soon as its table app closes.
    PLAYER_APP = "game"

    # Who is there: Asterism's on_app_join / on_app_leave (asterism after
    # 0.7.1), else a liveliness watch of asterism/*/game on the session.
    def follow_players(net)
      app = @config["player_app"] || PLAYER_APP
      if net.respond_to?(:on_app_join)
        net.on_app_join { |n, a| node_joined(n) if a == app }
        net.on_app_leave { |n, a| node_left(n) if a == app }
      else
        own = "asterism/#{node}/"
        net.session.liveliness_watch("asterism/*/#{app}") do |key, alive|
          next if key.start_with?(own)
          n = key.split("/")[1]
          alive ? node_joined(n) : node_left(n)
        end
      end
    end

    # A node's table app left the network: its members are away at every
    # table. (Called on the receiving thread, which holds Asterism::LOCK.)
    def node_left(n, now = @clock.call)
      @stats["left"] += 1 if @games.values.map { |g| g.node_left(n, now) }.any?
    end

    # A node is on the network again: its members are back.
    def node_joined(n, now = @clock.call)
      @stats["back"] += 1 if @games.values.map { |g| g.node_joined(n, now) }.any?
    end

    def down
      close_spectate
      @net = nil
      @tables_status = nil
      @connected = false
      write_status
    end

    STATUS_EVERY_MS = 2000

    # What the room supervisor shows (Rooms#status): written to
    # config["status_file"] every STATUS_EVERY_MS. Counts only, no names,
    # no nodes, no tokens (the host's own node ID only, once known).
    def status_now(now = @clock.call)
      { "pid" => Process.pid, "at" => Time.now.to_i, "node" => @node, "connected" => @connected ? true : false,
        "reconnecting" => (@connected && ::Asterism.reconnecting?) ? true : false,
        "tables" => @games.transform_values { |g| g.summary(now) } }.tap do |h|
        h["ai"] = @ai.budget.summary if @ai&.any?
      end
    rescue StandardError
      { "pid" => Process.pid, "at" => Time.now.to_i, "connected" => false, "tables" => {} }
    end

    def write_status(now = @clock.call)
      path = @config["status_file"] or return
      @status_at = now
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.generate(status_now(now)))
      File.rename(tmp, path)
    rescue SystemCallError => e
      @log.call("games: status file: #{e.message}")
    end

    # One pass over the games (also used by the tests without a network).
    def step
      now = @clock.call
      changed = false
      @ai&.step(@games, now)
      @games.each do |name, g|
        g.tick(now)
        g.take_told.each { |sub, value| put_told(name, sub, value) }
        if g.dirty?
          changed = true
          g.save(now)
          put_state(name, g, now)
          take_spectate(name, g, now)
        elsif g.unsaved?
          # A change only one member's own view shows: saved, not put.
          g.save(now)
        elsif now - @put_at.fetch(name, 0) >= PUT_EVERY_MS
          put_state(name, g, now)
          take_spectate(name, g, now)
        end
        put_spectate(name, g, now)
      end
      write_status(now) if @config["status_file"] && now - @status_at.to_i >= STATUS_EVERY_MS
      tell_tables(now, changed: changed)
    end

    # ------------------------------------------------------------ @status

    # How often the tables' counts are looked at for the status when no
    # table changed (an away seat changes them with time alone).
    TABLES_STATUS_EVERY_MS = 1000
    # The counts the status gives of each table: those of Rooms#status,
    # nothing that names a member (README "Status").
    TABLES_STATUS_KEYS = %w[st members humans cpus ais away strokes].freeze

    # Whether this host tells its tables' counts on
    # asterism/<node>/<app>/@status (docs/protocol.md 8 of asterism): on a
    # LAN and for the permanent tables, not in a room (the console's room
    # rules let a room's host write only its own keys, and the verbatim
    # chunk @status is not among them; nobody could read it there either).
    def tables_status?
      !@config["namespace"]
    end

    # {table => {"st", "members", "humans", "cpus", "away"}} and what a
    # game adds (Game#status_extra: the mahjong tables' last result).
    def tables_status(now = @clock.call)
      st = @games.transform_values { |g| g.summary(now).slice(*TABLES_STATUS_KEYS).merge(g.status_extra(now)) }
      # The AI players' totals of today (README "AI players"): money and
      # counts only.
      if @ai&.any?
        b = @ai.budget
        u = b.summary
        st[AI_STATUS_KEY] = { "calls" => u["calls"], "usd" => u["usd"].round(2), "limit_usd" => u["limit_usd"] }
        # Per kind (0.15.0), when some kind has a limit of its own: its
        # money, the limit it stops at, whether that is its own, whether
        # it has stopped for today.
        unless b.kind_usd.empty?
          st[AI_STATUS_KEY]["kinds"] = @ai.deciders.keys.to_h do |k|
            [k, { "usd" => b.usd_today(k).round(4), "limit_usd" => b.limit_usd(k), "own" => b.own_limit?(k),
                  "over" => b.over?(k) }]
          end
        end
      end
      st
    end

    AI_STATUS_KEY = "ai_today"

    # Hands the counts to the status after a change, and once a second;
    # Asterism puts them only when they differ from the last put.
    def tell_tables(now, changed: false)
      ts = @tables_status
      return unless ts && @net && !::Asterism.reconnecting?
      return unless changed || now - @tables_at.to_i >= TABLES_STATUS_EVERY_MS
      @tables_at = now
      bytes = ts.set(tables_status(now))
      note_size("put @status", bytes) if bytes
    rescue ::Asterism::Error, ArgumentError => e
      @log.call("games: status: #{e.message}")
    end

    def put_state(name, game, now)
      @put_at[name] = now
      return unless @net && !::Asterism.reconnecting?
      key = "asterism/#{node}/#{@config['app']}/#{name}/state"
      # What everybody may see, as a spectator sees it (README "Spectators").
      payload = ::Asterism::Codec.pack(game.state_view(now))
      note_size("put #{name}/state", key.bytesize + payload.bytesize)
      @net.session.put(key, payload)
    rescue ::Asterism::Error => e
      @log.call("games: put #{name}: #{e.message}")
    end

    # What a game told (Game#tell): put on asterism/<node>/<app>/<table>/<sub>.
    def put_told(name, sub, value)
      return unless @net && !::Asterism.reconnecting?
      key = "asterism/#{node}/#{@config['app']}/#{name}/#{sub}"
      payload = ::Asterism::Codec.pack(value)
      note_size("put #{name}/#{sub}", key.bytesize + payload.bytesize)
      @stats["told"] += 1
      @net.session.put(key, payload)
    rescue ::Asterism::Error => e
      @log.call("games: put #{name}/#{sub}: #{e.message}")
    end

    # ------------------------------------------------------------ spectate
    #
    # What a game gives for those who watch from outside the table
    # (Game#spectate_view, README "Spectate"): taken when the state is put
    # (a change, and every PUT_EVERY_MS), kept in order and put once it is
    # Game#spectate_delay_ms old, each in turn, on spectate_key. Nothing is
    # put sooner than the delay asks, whatever happens between (a round
    # ends, the delay is chosen again); a host started again starts with
    # nothing kept. The last one put is put again every PUT_EVERY_MS, so a
    # new subscriber has it within that.

    # The application chunk of the spectate keys: not the host's app (the
    # players' role reads asterism/*/<app>/**), and outside every room.
    SPECTATE_APP = "spectate"
    # What one table keeps for its delay at most (bytes); the oldest goes
    # first (it is then never shown, rather than shown early).
    SPECTATE_KEEP_BYTES = 8 * 1024 * 1024
    # How often a room's host tries again to open its connection outside
    # the room (ms).
    SPECTATE_RETRY_MS = 30_000

    # asterism/<node>/spectate/<table>/state; a room's table is
    # room<slot>-<table> there, so the rooms' tables and the permanent ones
    # never meet.
    def spectate_key(name)
      table = @config["namespace"] ? "#{spectate_label}-#{name}" : name
      "asterism/#{node}/#{SPECTATE_APP}/#{table}/state"
    end

    # A room's part of its tables' spectate names: the setting (Rooms gives
    # room<slot>), else the namespace without its slashes.
    def spectate_label
      @config["spectate_label"] || @config["namespace"].to_s.delete("/")
    end

    # Takes what the game gives now (nothing when it gives nil, or the same
    # as last time).
    def take_spectate(name, game, now)
      v = game.spectate_view(now)
      return if v.nil?
      bytes = ::Asterism::Codec.pack(v)
      s = (@spec[name] ||= { "q" => [], "bytes" => 0 })
      return if bytes == s["last"]
      s["last"] = bytes
      s["q"] << [now, bytes]
      s["bytes"] += bytes.bytesize
      while s["bytes"] > SPECTATE_KEEP_BYTES && s["q"].size > 1
        s["bytes"] -= s["q"].shift[1].bytesize
        @stats["spectate_dropped"] += 1
      end
    end

    # Puts what is old enough now, in order; or the last one again.
    def put_spectate(name, game, now)
      s = @spec[name] or return
      q = s["q"]
      unless q.empty?
        delay = game.spectate_delay_ms.to_i
        while q.first && q.first[0] <= now - delay
          bytes = q.shift[1]
          s["bytes"] -= bytes.bytesize
          s["out"] = bytes
          send_spectate(name, bytes, now)
          @stats["spectate"] += 1
        end
      end
      send_spectate(name, s["out"], now) if s["out"] && now - s["at"].to_i >= PUT_EVERY_MS
    end

    def send_spectate(name, bytes, now)
      @spec[name]["at"] = now
      sess = spectate_session or return
      spectate_token(sess)
      key = spectate_key(name)
      # Counted apart from the players' messages (the hands make it larger).
      @stats["spectate_max_bytes"] = [@stats["spectate_max_bytes"], key.bytesize + bytes.bytesize].max
      sess.put(key, bytes)
    rescue ::Asterism::Error => e
      @log.call("games: put spectate #{name}: #{e.message}")
    end

    # The application asterism/<node>/spectate on the network (a liveliness
    # token on the connection that puts), so that the command line and the
    # MCP bridge take its keys for the values of an application that is
    # there. Once per connection.
    def spectate_token(sess)
      return if @spectate_token_on.equal?(sess) || !sess.respond_to?(:liveliness)
      @spectate_token_on = sess
      @spectate_token = sess.liveliness("asterism/#{node}/#{SPECTATE_APP}")
    rescue ::Asterism::Error => e
      @log.call("games: spectate: token: #{e.message}")
    end

    # Where the spectate keys are put: the host's own connection outside
    # the rooms; in a room a connection of its own without the room's
    # namespace (open_spectate), when the host joins with its own
    # certificate (spectate_outside), else nowhere.
    def spectate_session
      return nil unless @net && !::Asterism.reconnecting?
      return @net.session unless @config["namespace"]
      c = @spectate_conn
      c && !c.reconnecting? ? c : nil
    end

    # A room's host opens its connection outside the room (the host's own
    # certificate, no namespace) once connected, and again after a failure
    # every SPECTATE_RETRY_MS. Outside the lock: opening waits for the router.
    def open_spectate(now = @clock.call)
      return unless @config["namespace"] && @config["spectate_outside"] && @config["credentials"]
      return if @spectate_conn || now < @spectate_retry_at.to_i
      return unless @games.values.any? { |g| g.respond_to?(:spectate_view) && g.method(:spectate_view).owner != Game }
      @spectate_retry_at = now + SPECTATE_RETRY_MS
      @spectate_conn = ::Asterism::Zenoh.open(locator, credentials: @config["credentials"])
      @log.call("games: spectate: #{node}/#{SPECTATE_APP} outside #{@config['namespace']} " \
                "(#{@games.keys.map { |n| spectate_key(n).split('/')[3] }.join(', ')})")
    rescue ::Asterism::Error, SystemCallError => e
      @spectate_conn = nil
      @log.call("games: spectate: cannot connect outside #{@config['namespace']}: #{e.message}; " \
                "again in #{SPECTATE_RETRY_MS / 1000} s")
    end

    def close_spectate
      @spectate_token = nil # withdrawn with its connection
      @spectate_token_on = nil
      @spectate_retry_at = nil # a new connection tries at once
      c = @spectate_conn
      @spectate_conn = nil
      c&.close
    rescue ::Asterism::Error
      nil
    end

    # The largest message seen so far, key and payload together.
    def note_size(what, bytes)
      return unless bytes > @stats["max_bytes"]
      @stats["max_bytes"] = bytes
      @stats["max_what"] = what
      @log.call("games: largest message so far: #{bytes} B (#{what})") if bytes > 1024
    end

    def save_all
      now = @clock.call
      @games.each_value { |g| g.save(now, force: true) }
    end

    # The host's status: Asterism's (net.status, asterism 0.8.0, the
    # version the Gemfile pins), which puts it when it changes and answers
    # who asks. An asterism 0.7.1 (the gem's lowest) has no status: then
    # the same thing by hand on the connection's session (a queryable on
    # the key and a put when the counts change).
    class TablesStatus
      def initialize(net, node, app)
        @net = net
        @key = "asterism/#{node}/#{app}/@status"
        return if @net.respond_to?(:status)
        @bytes = nil
        @qa = net.session.queryable(@key) { |q| q.reply(@key, @bytes) if @bytes }
      end

      # Sets the status; returns the size of the put (key and payload) when
      # it changed, nil when it did not.
      def set(st)
        bytes = ::Asterism::Codec.pack(st)
        if @net.respond_to?(:status)
          return nil if @net.status == st
          @net.status(st)
        else
          return nil if bytes == @bytes
          @bytes = bytes
          @net.session.put(@key, bytes)
        end
        @key.bytesize + bytes.bytesize
      end
    end

    # Measures every answer an exposed object gives (as the reply payload
    # {"value" => ...} plus the call key, whose last chunk is the caller).
    class SizeWatch
      def initialize(obj, host, name)
        @obj = obj
        @host = host
        @name = name
      end

      def respond_to_missing?(name, priv = false)
        @obj.respond_to?(name, priv) || super
      end

      def method_missing(name, *args, **kw, &blk)
        return super unless @obj.respond_to?(name)
        v = @obj.public_send(name, *args, **kw, &blk)
        key = "asterism/x/x/#{@name}/call/#{kw[:from]}"
        @host.note_size("#{name} reply", ::Asterism::Codec.pack({ "value" => v }).bytesize + key.bytesize)
        v
      end
    end
  end
end
