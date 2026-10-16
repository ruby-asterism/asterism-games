# frozen_string_literal: true

require "yaml"
require_relative "game"

module AsterismGames
  # Settings: a YAML file (ASTERISM_GAMES_CONFIG or --config), then the
  # environment over it. See README "Settings".
  #
  # The games come from the registry (AsterismGames.games): a table's
  # "game" defaults to the first game registered, the tables the settings
  # do not name are that game's (Game.tables), a room opens the tables
  # when its link opens one of the games' screens (Game.screens), and each
  # game says which table keys the file and the environment may set
  # (Game.settings).
  class Config
    DEFAULTS = {
      "router" => "tcp/127.0.0.1:7447",
      "node" => "games",
      "app" => "games",
      "credentials" => nil,
      "state_dir" => "var/state",
      "tables" => nil,                                        # nil: the first game's tables
      "rooms" => nil,
      "permanent" => nil
    }.freeze

    # The rooms of a console (README "Rooms"): given (a "rooms" section or
    # ASTERISM_GAMES_ROOMS_DIR), the host serves tables in rooms instead of
    # the tables above.
    ROOM_DEFAULTS = {
      "dir" => nil,                                          # the console's rooms volume (rooms.json, certs/)
      "apps" => nil,                                         # a room opening one of these gets the tables (nil: the games' screens)
      "max" => 3,                                            # rooms with tables at once
      "node" => "games",                                     # the host's node ID in a room
      "router" => nil,                                       # over the slot certificate's router
      "status_listen" => nil,                                # host:port for GET /status
      "tables" => nil,                                       # nil: the first game's first table
      # The host's own certificate in the rooms (README "Rooms", console
      # 0.3.0 lists the host in rooms.json "hosts"): its .tar, else the
      # permanent tables' one; the slot's certificate only when the console
      # does not list the host.
      "credentials" => nil,
      # Callers whose node ID comes from a secret (wasm-<6 hex>, pages from
      # before the seats) are still checked and let in: README "Who joins".
      # false once every page takes a seat.
      "secret_ids" => true,
      # A seat's node ID silent this long at a table is a new page on that
      # seat (the console's door gives an idle seat to another page after
      # WS_DOOR_SEAT_IDLE, 1800 s).
      "seat_reuse_seconds" => 1800
    }.freeze
    ROOM_ENV_KEYS = {
      "ASTERISM_GAMES_ROOMS_DIR" => ["dir", :s],
      "ASTERISM_GAMES_ROOM_APPS" => ["apps", :list],
      "ASTERISM_GAMES_ROOM_MAX" => ["max", :i],
      "ASTERISM_GAMES_ROOM_NODE" => ["node", :s],
      "ASTERISM_GAMES_ROOM_ROUTER" => ["router", :s],
      "ASTERISM_GAMES_STATUS_LISTEN" => ["status_listen", :s],
      "ASTERISM_GAMES_ROOM_CREDENTIALS" => ["credentials", :s],
      "ASTERISM_GAMES_ROOM_SECRET_IDS" => ["secret_ids", :bool],
      "ASTERISM_GAMES_ROOM_SEAT_REUSE_SECONDS" => ["seat_reuse_seconds", :i]
    }.freeze

    # The permanent tables next to the rooms (README "Permanent tables"):
    # with a certificate of the host's own (a row of the console's
    # registry, e.g. "games"), the rooms' supervisor runs one more host
    # process on the registered side of the router, for the boards and the
    # browsers with a pass. Only with rooms (the supervisor); without rooms
    # the host itself takes "credentials" and "tables".
    PERMANENT_DEFAULTS = {
      "credentials" => nil,                                  # the host's .tar (none: no permanent tables)
      "router" => nil,                                       # over the certificate's router
      "node" => nil,                                         # the certificate's name
      "tables" => nil                                        # nil: the first game's tables
    }.freeze
    PERMANENT_ENV_KEYS = {
      "ASTERISM_GAMES_PERMANENT_CREDENTIALS" => ["credentials", :s],
      "ASTERISM_GAMES_PERMANENT_ROUTER" => ["router", :s],
      "ASTERISM_GAMES_PERMANENT_NODE" => ["node", :s],
      "ASTERISM_GAMES_PERMANENT_TABLES" => ["tables", :names]
    }.freeze

    # Environment variable => [key, kind]. The table ones are the games'
    # own (Game.settings), applied to every table of that game.
    ENV_KEYS = {
      "ASTERISM_GAMES_ROUTER" => ["router", :s],
      "ASTERISM_GAMES_NODE" => ["node", :s],
      "ASTERISM_GAMES_APP" => ["app", :s],
      "ASTERISM_GAMES_CREDENTIALS" => ["credentials", :s],
      "ASTERISM_GAMES_STATE_DIR" => ["state_dir", :s]
    }.freeze

    # The game a table without "game" plays: the first one registered.
    def self.default_game
      AsterismGames.games.keys.first
    end

    # The tables of the default game ([{"name", "game"}]; first: only the first).
    def self.default_tables(first: false)
      name = default_game
      names = name ? AsterismGames.game(name).tables : []
      names = names.first(1) if first
      names.map { |n| { "name" => n, "game" => name } }
    end

    # The table apps of every game (a room opening one gets the tables).
    def self.default_apps
      AsterismGames.games.values.flat_map(&:screens).uniq
    end

    attr_reader :data

    def self.load(path = ENV["ASTERISM_GAMES_CONFIG"], env = ENV)
      file = path && File.exist?(path) ? (YAML.safe_load(File.read(path)) || {}) : {}
      raise ArgumentError, "#{path}: not found" if path && !File.exist?(path)
      new(file, env)
    end

    def initialize(file = {}, env = ENV)
      @data = DEFAULTS.merge(file)
      ENV_KEYS.each { |k, (key, _)| @data[key] = env[k] if env[k] && !env[k].empty? }
      @data["tables"] = self.class.default_tables if @data["tables"].nil?
      @data["tables"] = Array(@data["tables"]).map { |t| table_options(t, env) }
      @data["rooms"] = room_options(@data["rooms"], env)
      @data["permanent"] = permanent_options(@data["permanent"], env)
      return unless @data["rooms"]
      @data["rooms"]["credentials"] = @data["permanent"]["credentials"] if @data["rooms"]["credentials"].to_s.empty? && @data["permanent"]
      @data["rooms"]["credentials"] = nil if @data["rooms"]["credentials"].to_s.empty?
    end

    # The permanent section with its defaults and the environment, or nil
    # when no certificate is given or there are no rooms (the supervisor
    # runs it).
    def permanent_options(p, env)
      p = PERMANENT_DEFAULTS.merge(p.is_a?(Hash) ? p : {})
      PERMANENT_ENV_KEYS.each do |k, (key, kind)|
        v = env[k]
        next if v.nil? || v.empty?
        p[key] = if kind == :names
                   v.split(",").map(&:strip).reject(&:empty?).map { |n| { "name" => n, "game" => self.class.default_game } }
                 else
                   v
                 end
      end
      return nil if p["credentials"].to_s.empty? || @data["rooms"].nil?
      p["node"] = nil if p["node"].to_s.empty?
      p["tables"] = self.class.default_tables if p["tables"].nil?
      p["tables"] = Array(p["tables"]).map { |t| table_options(t, env) }
      raise ArgumentError, "permanent.tables: at least one table" if p["tables"].empty?
      p
    end

    # The rooms section with its defaults and the environment, or nil when
    # no rooms directory is given.
    def room_options(r, env)
      r = ROOM_DEFAULTS.merge(r.is_a?(Hash) ? r : {})
      ROOM_ENV_KEYS.each do |k, (key, kind)|
        v = env[k]
        next if v.nil? || v.empty?
        r[key] = case kind
                 when :list then v.split(",").map(&:strip).reject(&:empty?)
                 when :i then Integer(v)
                 when :bool then %w[1 true yes].include?(v.downcase)
                 else v
                 end
      end
      return nil if r["dir"].to_s.empty?
      r["secret_ids"] = r["secret_ids"] ? true : false
      r["seat_reuse_seconds"] = r["seat_reuse_seconds"].to_i
      r["apps"] = self.class.default_apps if r["apps"].nil?
      r["apps"] = Array(r["apps"]).map(&:to_s)
      r["max"] = r["max"].to_i
      raise ArgumentError, "rooms.max must be 1 or more" if r["max"] < 1
      r["tables"] = self.class.default_tables(first: true) if r["tables"].nil?
      r["tables"] = Array(r["tables"]).map { |t| table_options(t, env) }
      r
    end

    def [](key)
      @data[key]
    end

    # A table of the settings: its name, its game and the game's settings
    # (Game.settings: seconds to ms, the text, or a Hash as it is). A game
    # nobody registered keeps its name (the host refuses it).
    def table_options(t, env)
      out = { "name" => t["name"].to_s, "game" => (t["game"] || self.class.default_game).to_s }
      klass = AsterismGames.game(out["game"])
      return out unless klass
      keys = klass.settings
      keys[:file].each do |k, (key, mul)|
        next unless t.key?(k)
        out[key] = case mul
                   when :hash then t[k].to_h
                   when nil then t[k].to_s
                   else (t[k].to_f * mul).round
                   end
      end
      keys[:env].each do |k, (key, mul)|
        v = env[k]
        next if v.nil? || v.empty?
        out[key] = mul ? (v.to_f * mul).round : v
      end
      out
    end
  end
end
