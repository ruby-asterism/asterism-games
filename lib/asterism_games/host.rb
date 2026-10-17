# frozen_string_literal: true

require "asterism"
require "json"
require_relative "version"
require_relative "game"
require_relative "config"
require_relative "store"

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
  # node leaves the network and comes back (net.on_leave / on_join, on the
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
      @put_at = {}
      @stats = Hash.new(0)
      config["tables"].each do |t|
        klass = AsterismGames.game(t["game"]) or raise ArgumentError, "unknown game #{t['game'].inspect}"
        # A room's tables check who joins against the room's ID, and trust
        # the callers the router binds to their names (README "Who joins").
        if config["room_id"]
          t = t.merge(config.slice("room_id", "trusted_nodes", "trusted_prefix", "seat_reuse_ms").compact)
        end
        name = t["name"]
        g = klass.new(name, t.reject { |k, _| %w[name game].include?(k) }, store: @store, log: @log)
        g.resume_clock(@clock.call)
        @games[name] = g
        @remotes[name] = SizeWatch.new(klass.remote.new(g, @clock), self, name)
        @methods[name] = klass.remote.exposes
      end
      @stop = false
    end

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
      @log.call("games: largest message #{@stats['max_bytes']} B (#{@stats['max_what']})")
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
      net.on_leave { |n| node_left(n) }
      net.on_join { |n| node_joined(n) }
      @games.each_key do |name|
        net.expose(name, @remotes[name], methods: @methods[name], caller: :from)
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
        ::Asterism::LOCK.synchronize { step }
        sleep LOOP_S
      end
    end

    # A node left the network: its members are away at every table.
    # (Called on the receiving thread, which holds Asterism::LOCK.)
    def node_left(n, now = @clock.call)
      @stats["left"] += 1 if @games.values.map { |g| g.node_left(n, now) }.any?
    end

    # A node is on the network again: its members are back.
    def node_joined(n, now = @clock.call)
      @stats["back"] += 1 if @games.values.map { |g| g.node_joined(n, now) }.any?
    end

    def down
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
        "tables" => @games.transform_values { |g| g.summary(now) } }
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
      @games.each do |name, g|
        g.tick(now)
        if g.dirty?
          changed = true
          g.save(now)
          put_state(name, g, now)
        elsif g.unsaved?
          # A change only one member's own view shows: saved, not put.
          g.save(now)
        elsif now - @put_at.fetch(name, 0) >= PUT_EVERY_MS
          put_state(name, g, now)
        end
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
    TABLES_STATUS_KEYS = %w[st members humans cpus away].freeze

    # Whether this host tells its tables' counts on
    # asterism/<node>/<app>/@status (docs/protocol.md 8 of asterism): on a
    # LAN and for the permanent tables, not in a room (the console's room
    # rules let a room's host write only its own keys, and the verbatim
    # chunk @status is not among them; nobody could read it there either).
    def tables_status?
      !@config["namespace"]
    end

    # {table => {"st", "members", "humans", "cpus", "away"}}.
    def tables_status(now = @clock.call)
      @games.transform_values { |g| g.summary(now).slice(*TABLES_STATUS_KEYS) }
    end

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

    # The largest message seen so far, key and payload together.
    def note_size(what, bytes)
      return unless bytes > @stats["max_bytes"]
      @stats["max_bytes"] = bytes
      @stats["max_what"] = what
      @log.call("games: largest message so far: #{bytes} B (#{what})") if bytes > 1024
    end

    def save_all
      now = @clock.call
      @games.each_value { |g| g.save(now) }
    end

    # The host's status: Asterism's (net.status, asterism after 0.7.1),
    # which puts it when it changes and answers who asks. The asterism gem
    # this host is pinned to (0.7.1) has no status yet: then the same
    # thing by hand on the connection's session (a queryable on the key
    # and a put when the counts change).
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
