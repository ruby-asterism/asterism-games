# frozen_string_literal: true

require "digest"
require "securerandom"

module AsterismGames
  # The games the host can serve, by name (the "game" of a table in the
  # settings). A game registers itself with Game.register.
  def self.games
    Game.registry
  end

  # The class of a game by name, or nil.
  def self.game(name)
    Game.registry[name.to_s]
  end

  # The base of every game (README "Writing a game"). One object is one
  # table: the people at it (members, each with a token), the game's own
  # state, the views and the saved form. Time is passed in (milliseconds)
  # so tests can drive it; nothing here waits or talks to the network. The
  # host (Host) exposes the table's Remote as an Asterism object, calls
  # tick on its loop, saves the table when it is dirty and puts state_view
  # on asterism/<node>/<app>/<table>/state.
  #
  # A game declares, in its class:
  #
  #   register "name"        the name the settings use ("game: name")
  #   remote RemoteClass     the exposed object (a subclass of Remote)
  #   tables "t1", "t2"      the tables a host serves when the settings name none
  #   screens "/app/..."     the table apps a room's link may open (README "Rooms")
  #   settings file: {...}, env: {...}
  #                          the table settings the file and the environment
  #                          may give: {key => [option, multiplier]} (README "Settings")
  #   DEFAULTS               the table's options (over Game::DEFAULTS)
  #   SAVE_FORMAT            the number in the saved state; another number is not read
  #
  # and writes the rules: tick(now), public_view(now) (and spectator_view,
  # summary when they differ), to_saved(now) / restore(data, now) and the
  # methods its Remote calls.
  #
  # Members: join gives a node a token; the token is what every later call
  # of that member brings. In a room (room_id set) a joining node is checked
  # (README "Who joins"): the seats' node IDs and the host's own names are
  # bound to their callers by the router and taken as they are; other
  # callers (pages from before the seats) must bring the secret their node
  # ID comes from, while secret_ids is on.
  class Game
    SAVE_FORMAT = 1
    MAX_MEMBERS = 16
    NAME_MAX = 32

    DEFAULTS = {
      "away_ms" => 10_000,      # a member not heard from this long is away
      "room_id" => nil,         # in a room: its ID, against which joins are checked (README "Who joins")
      "trusted_nodes" => [],    # in a room: node IDs the router binds to their callers (the seats)
      "trusted_prefix" => nil,  # in a room: the host's own names (it and its bots), bound likewise
      "secret_ids" => true,     # in a room: other callers are checked with their secret
      "seat_reuse_ms" => 1_800_000 # a seat's node ID silent this long is a new page on that seat
    }.freeze

    @registry = {}

    class << self
      # name => game class (on Game itself).
      def registry
        Game.instance_variable_get(:@registry)
      end

      def register(name)
        @game_name = name.to_s
        Game.registry[@game_name] = self
      end

      def game_name = @game_name

      def remote(klass = nil)
        @remote = klass if klass
        @remote || (superclass.respond_to?(:remote) ? superclass.remote : nil)
      end

      def tables(*names)
        @tables = names.map(&:to_s) unless names.empty?
        @tables || []
      end

      def screens(*apps)
        @screens = apps.map(&:to_s) unless apps.empty?
        @screens || []
      end

      # file: / env: {key => [option, multiplier]}: a number is multiplied
      # (seconds to ms) and rounded; nil keeps the text.
      def settings(file: nil, env: nil)
        @file_settings = file.freeze if file
        @env_settings = env.freeze if env
        { file: @file_settings || {}, env: @env_settings || {} }
      end

      # The node ID a browser's secret gives in a room (the browser build
      # of before the seats worked out the same).
      def room_node_id(room_id, secret)
        "wasm-#{Digest::SHA256.hexdigest("#{room_id}:#{secret}")[0, 6]}"
      end
    end

    attr_reader :name, :opts, :ver

    def initialize(name, opts = {}, store: nil, log: nil)
      @name = name
      @opts = self.class::DEFAULTS.merge(opts.transform_keys(&:to_s))
      @store = store
      @log = log
      @ver = 1
      @now = 0
      @dirty = true
      @unsaved = false
      reset_members
    end

    # ------------------------------------------------------------ the rules (a game writes these)

    # Moves the game on (timeouts, CPU turns). Called on the host's loop
    # and after the game's own changes; never waits.
    def tick(now)
      @now = now
    end

    # What everybody may see.
    def public_view(now)
      { "v" => @ver, "t" => @name }
    end

    # What spectators see (and what the host puts on the state key).
    def spectator_view(now)
      public_view(now)
    end

    # What the host puts on asterism/<node>/<app>/<table>/state.
    def state_view(now)
      spectator_view(now)
    end

    # Counts for the host's status (GET /status of the rooms' host, README
    # "Rooms"): no names, no nodes, no tokens. "st" (the game's status),
    # "members", "humans" (members in a seat), "cpus", "away" (humans not
    # heard from); a game adds what it likes.
    def summary(now)
      { "st" => "wait", "members" => @members.size, "humans" => 0, "cpus" => 0, "away" => 0 }
    end

    # The saved form (a Hash for JSON) and back. restore gets what
    # to_saved gave, read from the store, when its "format" is SAVE_FORMAT.
    def to_saved(now)
      { "format" => self.class::SAVE_FORMAT, "name" => @name, "ver" => @ver, "members" => saved_members,
        "counts" => [@join_count] }
    end

    def restore(data, now)
      @ver = data["ver"].to_i + 1
      @members = data["members"] || {}
      @join_count = Array(data["counts"]).first.to_i
    end

    # Times read back are relative to when they were saved: a host started
    # again calls this with its own clock. Members count as just seen.
    def resume_clock(now, data = saved)
      return unless data
      @members.each_value { |m| m["seen"] = now }
      @now = now
    end

    # ------------------------------------------------------------ saving

    def changed
      @ver += 1
      @dirty = true
    end

    # Changed: to save and to put.
    def dirty?
      @dirty
    end

    # Changed in what only a member's own view shows: to save, not to put.
    def unsaved?
      @unsaved
    end

    def save(now)
      @dirty = false
      @unsaved = false
      return unless @store
      @store.write(@name, to_saved(now))
    end

    # The saved state of this table when it is of this game's format, or nil.
    def saved
      d = @store&.read(@name)
      d.is_a?(Hash) && d["format"] == self.class::SAVE_FORMAT ? d : nil
    end

    # Reads the saved state back (restore); true when there was one.
    def load_saved(now)
      d = saved
      return false unless d
      restore(d, now)
      resume_clock(now, d)
      true
    end

    # ------------------------------------------------------------ members

    # A node joins the table (or gets its membership back). Returns
    # member_reply, or {"error" => why}: "full", what join_refusal says, in
    # a room "identity" when the node ID does not come from the secret and
    # "taken" when the member has another one.
    def join(node, name, now, secret = nil)
      node = node.to_s
      bad = identity_error(node, secret)
      return { "error" => bad } if bad
      m = reused_seat(node, now)
      if m && m["key"] && m["key"] != secret_key(secret)
        return { "error" => "taken" }
      elsif m.nil?
        why = join_refusal(node)
        return { "error" => why } if why
        m = @members[node] = { "token" => SecureRandom.hex(16), "at" => @join_count += 1 }
        m["key"] = secret_key(secret) if room? && !trusted?(node)
      end
      m["name"] = clean_name(name, node)
      m["seen"] = now
      renamed(node, m["name"])
      changed
      member_reply(node)
    end

    # The caller's membership, or nil (nothing is created); in a room the
    # secret has to agree, as for join.
    def mine(node, secret = nil, now = nil)
      node = node.to_s
      bad = identity_error(node, secret)
      return { "error" => bad } if bad
      m = now ? reused_seat(node, now) : @members[node]
      return nil unless m
      return { "error" => "taken" } if m["key"] && m["key"] != secret_key(secret)
      member_reply(node)
    end

    # The member leaves the table: true, or false for an unknown token.
    def leave(token)
      node = node_of(token)
      return false unless node
      forget(node)
      changed
      true
    end

    # What join and mine answer.
    def member_reply(node)
      { "token" => @members[node]["token"] }
    end

    # Why another member cannot join now, or nil.
    def join_refusal(_node)
      "full" if @members.size >= self.class::MAX_MEMBERS
    end

    # A member's name changed (join again with another name).
    def renamed(node, name); end

    # Removes a member (leave, a spectator gone for long, a seat given to a
    # new page): a game frees what the member held, then calls super.
    def forget(node)
      @members.delete(node)
    end

    # Kept even when gone for long (expire_members): e.g. a seated member.
    def keep_member?(_node)
      false
    end

    # A call from a node: it is there.
    def touch(node, now)
      m = @members[node.to_s]
      m["seen"] = now if m
    end

    def node_of(token)
      return nil unless token.is_a?(String) && !token.empty?
      @members.each { |node, m| return node if m["token"] == token }
      nil
    end

    def member_away?(node)
      m = @members[node]
      m.nil? || m["seen"].nil? || @now - m["seen"] > @opts["away_ms"]
    end

    # Members gone for long (six times away_ms) are forgotten, unless the
    # game keeps them (keep_member?). At most once a second.
    def expire_members(now)
      return if @members.empty? || now - @expire_at.to_i < 1000
      @expire_at = now
      gone = @members.keys.select do |node|
        !keep_member?(node) && member_away?(node) && now - @members[node]["seen"].to_i > @opts["away_ms"] * 6
      end
      gone.each { |node| forget(node) }
      changed unless gone.empty?
    end

    def reset_members
      @members = {}
      @join_count = 0
    end

    def saved_members
      @members.to_h { |n, m| [n, m.reject { |k, _| k == "seen" }] }
    end

    def clean_name(name, node)
      s = name.to_s.dup.force_encoding("UTF-8")
      s = s.scrub("").delete("\u0000-\u001f").strip
      s = s.byteslice(0, NAME_MAX).scrub("") if s.bytesize > NAME_MAX
      s.empty? ? node : s
    end

    # ------------------------------------------------------------ who joins (rooms)
    #
    # With seats (the console's 0.3.0) the router binds a page's calls to
    # its seat's node ID (wasm-0103), and the host's own names to the
    # host's certificate: those callers (trusted_nodes, trusted_prefix)
    # are taken as they are, as outside a room.
    #
    # Before the seats every connection of a room held the room's one
    # certificate, so the router let any member call under any node ID. A
    # browser in a room has a secret of its own for the room, and its node
    # ID is "wasm-" and the first six hex digits of SHA-256("<room
    # ID>:<secret>"); join and mine carry the secret, and the table works
    # the ID out again. Such callers are still let in while secret_ids is
    # on (the pages of the browser build from before the seats). Outside
    # a room (no room_id) nothing is checked: a board's certificate is its
    # node ID there. The member keeps the SHA-256 of its secret: two
    # secrets that give the same six digits are told apart ("taken").

    def room?
      !@opts["room_id"].to_s.empty?
    end

    # A caller the router has bound to its name in this room.
    def trusted?(node)
      return false unless room?
      return true if Array(@opts["trusted_nodes"]).include?(node)
      prefix = @opts["trusted_prefix"].to_s
      !prefix.empty? && node.start_with?(prefix)
    end

    # The member of a node, or nil; a seat's node ID that has not called
    # for seat_reuse_ms is another page now (the door gave the seat away
    # after as long without a connection): the old member leaves and nil
    # is returned.
    def reused_seat(node, now)
      m = @members[node]
      return m unless m && trusted?(node) && Array(@opts["trusted_nodes"]).include?(node)
      return m unless m["seen"] && now - m["seen"] > @opts["seat_reuse_ms"].to_i
      @log&.call("#{self.class.game_name}: #{@name}: #{node} was silent for #{(now - m['seen']) / 60_000} min: " \
                 "a new page on that seat")
      leave(m["token"])
      nil
    end

    # Why a join or mine from node with secret is refused, or nil.
    def identity_error(node, secret)
      return nil unless room?
      return nil if trusted?(node)
      return "identity" unless @opts["secret_ids"]
      return "identity" unless secret.is_a?(String) && secret.match?(/\A[0-9a-f]{32}\z/)
      return "identity" unless node == self.class.room_node_id(@opts["room_id"], secret)
      nil
    end

    def secret_key(secret)
      secret.is_a?(String) ? Digest::SHA256.hexdigest(secret) : nil
    end
  end
end
