# frozen_string_literal: true

require "yaml"

module AsterismGames
  # Settings: a YAML file (ASTERISM_GAMES_CONFIG or --config), then the
  # environment over it. See README "Settings".
  class Config
    DEFAULTS = {
      "router" => "tcp/127.0.0.1:7447",
      "node" => "games",
      "app" => "games",
      "credentials" => nil,
      "state_dir" => "var/state",
      "tables" => [{ "name" => "mahjong1", "game" => "mahjong" }, { "name" => "mahjong2", "game" => "mahjong" }],
      "rooms" => nil
    }.freeze

    # The rooms of a console (README "Rooms"): given (a "rooms" section or
    # ASTERISM_GAMES_ROOMS_DIR), the host serves tables in rooms instead of
    # the tables above.
    ROOM_DEFAULTS = {
      "dir" => nil,                                          # the console's rooms volume (rooms.json, certs/)
      "apps" => ["/app/game/mahjong/mahjong.app.rb"],        # a room opening one of these gets the tables
      "max" => 3,                                            # rooms with tables at once
      "node" => "games",                                     # the host's node ID in a room
      "router" => nil,                                       # over the slot certificate's router
      "status_listen" => nil,                                # host:port for GET /status
      "tables" => [{ "name" => "mahjong1", "game" => "mahjong" }]
    }.freeze
    ROOM_ENV_KEYS = {
      "ASTERISM_GAMES_ROOMS_DIR" => ["dir", :s],
      "ASTERISM_GAMES_ROOM_APPS" => ["apps", :list],
      "ASTERISM_GAMES_ROOM_MAX" => ["max", :i],
      "ASTERISM_GAMES_ROOM_NODE" => ["node", :s],
      "ASTERISM_GAMES_ROOM_ROUTER" => ["router", :s],
      "ASTERISM_GAMES_STATUS_LISTEN" => ["status_listen", :s]
    }.freeze

    # Environment variable => [key, kind]; the table ones apply to every
    # mahjong table.
    ENV_KEYS = {
      "ASTERISM_GAMES_ROUTER" => ["router", :s],
      "ASTERISM_GAMES_NODE" => ["node", :s],
      "ASTERISM_GAMES_APP" => ["app", :s],
      "ASTERISM_GAMES_CREDENTIALS" => ["credentials", :s],
      "ASTERISM_GAMES_STATE_DIR" => ["state_dir", :s]
    }.freeze
    TABLE_ENV_KEYS = {
      "MAHJONG_TURN_SECONDS" => ["turn_ms", 1000],
      "MAHJONG_CALL_SECONDS" => ["call_ms", 1000],
      "MAHJONG_RESULT_SECONDS" => ["result_ms", 1000],
      "MAHJONG_OVER_SECONDS" => ["over_ms", 1000],
      "MAHJONG_AWAY_SECONDS" => ["away_ms", 1000],
      "MAHJONG_AWAY_WAIT_SECONDS" => ["away_wait_ms", 1000],
      "MAHJONG_CPU_MS" => ["cpu_ms", 1],
      "MAHJONG_CPU_LEVEL" => ["cpu_level", nil]
    }.freeze
    # Table keys in the file, in seconds, and the table's own (ms) names.
    TABLE_FILE_KEYS = {
      "turn_seconds" => ["turn_ms", 1000], "call_seconds" => ["call_ms", 1000],
      "result_seconds" => ["result_ms", 1000], "over_seconds" => ["over_ms", 1000],
      "away_seconds" => ["away_ms", 1000], "away_wait_seconds" => ["away_wait_ms", 1000],
      "cpu_ms" => ["cpu_ms", 1],
      "cpu_level" => ["cpu_level", nil], "humans" => ["humans", 1]
    }.freeze

    attr_reader :data

    def self.load(path = ENV["ASTERISM_GAMES_CONFIG"], env = ENV)
      file = path && File.exist?(path) ? (YAML.safe_load(File.read(path)) || {}) : {}
      raise ArgumentError, "#{path}: not found" if path && !File.exist?(path)
      new(file, env)
    end

    def initialize(file = {}, env = ENV)
      @data = DEFAULTS.merge(file)
      ENV_KEYS.each { |k, (key, _)| @data[key] = env[k] if env[k] && !env[k].empty? }
      @data["tables"] = Array(@data["tables"]).map { |t| table_options(t, env) }
      @data["rooms"] = room_options(@data["rooms"], env)
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
                 else v
                 end
      end
      return nil if r["dir"].to_s.empty?
      r["apps"] = Array(r["apps"]).map(&:to_s)
      r["max"] = r["max"].to_i
      raise ArgumentError, "rooms.max must be 1 or more" if r["max"] < 1
      r["tables"] = Array(r["tables"]).map { |t| table_options(t, env) }
      r
    end

    def [](key)
      @data[key]
    end

    def table_options(t, env)
      out = { "name" => t["name"].to_s, "game" => (t["game"] || "mahjong").to_s }
      TABLE_FILE_KEYS.each do |k, (key, mul)|
        next unless t.key?(k)
        out[key] = mul ? (t[k].to_f * mul).round : t[k].to_s
      end
      out["rule"] = t["rule"].to_h if t["rule"]
      TABLE_ENV_KEYS.each do |k, (key, mul)|
        v = env[k]
        next if v.nil? || v.empty?
        out[key] = mul ? (v.to_f * mul).round : v
      end
      out
    end
  end
end
