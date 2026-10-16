# frozen_string_literal: true

require "json"
require "fileutils"
require "socket"
require "time"

module AsterismGames
  # Tables in the rooms of an Asterism console (G2, the console's
  # docs/rooms.md): README "Rooms".
  #
  # The console writes the open rooms to rooms.json (the file its door
  # reads) in the "rooms" volume, next to the room slots' certificates:
  #
  #   {"slots": {"01": {"room": "<uid>", "until": <Unix s>, "max": 16, "app": "/app/..."}},
  #    "revoked": [{"room": "<uid>", "until": <Unix s>}], ...}
  #   certs/room-01.tar   the slot's certificate (namespace room/01)
  #
  # A room whose link opens one of the configured apps (by default the
  # games' screens, Game.screens) gets the tables of the game whose screen
  # it opens (of rooms.tables; by default each game's first table,
  # Config.tables_for_app): this supervisor forks one host process (Host)
  # for the room, which joins the router in the room's key space
  # (namespace room/<slot>) and serves the tables there, as browsers in the
  # room see them (asterism/games/games/<table>). One process per room,
  # since the asterism gem keeps one connection a process. Other rooms
  # (another app, or an app no configured table's game shows) get nothing.
  #
  # Which certificate (console 0.3.0, its docs/rooms.md "Seats"): when
  # rooms.json lists this host's node in "hosts", the router keeps the
  # rooms' asterism/<node>... for the host's own certificate (the
  # permanent tables' games.tar, or rooms.credentials) and the process
  # joins with it; nobody in the room can write a table's keys or answer
  # its calls. Otherwise (a console before 0.3.0) it joins with the slot's
  # certificate, certs/room-<slot>.tar, as before.
  #
  # Who the tables trust (README "Who joins"): in a slot with seats
  # (rooms.json "seats"), the router binds every page's calls to its seat's
  # node ID (<seat_node_prefix><slot><seat>, wasm-0103), and the host's own
  # names (<node>..., its bots) to its certificate: those callers are taken
  # as they are; nobody else joins. A host whose trust changes (the
  # console was updated during the room) is started again.
  #
  # A room's tables are saved under state_dir/rooms/<slot>/ with the room's
  # ID (room.json). When the slot holds another room, or the room was
  # closed or has ended, the directory is removed: a new room on the slot
  # starts with an empty lobby. A host process that stops on its own is
  # started again (after 1, 2, 4 .. 30 s); a restarted supervisor finds the
  # rooms and their saved tables again.
  #
  # The permanent tables (README "Permanent tables", the "permanent"
  # settings): with a certificate of the host's own (a row of the console's
  # registry), one more host process joins the router on the registered
  # side, outside every room, and serves its tables there for the boards
  # and the browsers with a pass. Saved under state_dir/permanent/, kept
  # across restarts, never removed by the rooms' clean-up; started again
  # like a room's host.
  class Rooms
    CHECK_S = 1.0
    STOP_WAIT_S = 8
    BACKOFF_MAX_S = 30

    # The rooms that should have a host, from rooms.json's content:
    # {slot => {"room", "until", "app"}} (open, not ended, opening one of
    # the apps). nil content (no file, not readable): nil.
    def self.wanted(data, apps, now)
      return nil unless data.is_a?(Hash) && data["slots"].is_a?(Hash)
      revoked = Array(data["revoked"]).map { |r| r.is_a?(Hash) ? r["room"] : nil }.compact
      data["slots"].each_with_object({}) do |(slot, r), out|
        next unless slot.to_s.match?(/\A\d{2}\z/) && r.is_a?(Hash) && r["room"].is_a?(String)
        next if revoked.include?(r["room"]) || r["until"].to_i <= now
        next unless apps.include?(r["app"].to_s)
        out[slot.to_s] = { "room" => r["room"], "until" => r["until"].to_i, "app" => r["app"].to_s,
                           "seats" => r["seats"].to_i.clamp(0, 99) }
      end
    end

    # Whether a slot's saved tables (room.json: {"room", "until"}) are of a
    # room that is over: the slot holds another room now, the room is
    # revoked (closed), or it has ended. With no readable rooms.json nothing
    # is over (a missing file is not a closed room).
    def self.over?(saved, data, now)
      return false unless saved.is_a?(Hash) && data.is_a?(Hash) && data["slots"].is_a?(Hash)
      return true if saved["until"].to_i <= now
      revoked = Array(data["revoked"]).map { |r| r.is_a?(Hash) ? r["room"] : nil }
      return true if revoked.include?(saved["room"])
      held = data["slots"][saved["slot"].to_s]
      held.is_a?(Hash) && held["room"] != saved["room"]
    end

    attr_reader :children

    # config: Config (its "rooms" and "state_dir"); spawn: a lambda(slot,
    # child config) -> pid (tests give their own).
    def initialize(config, log: ->(m) { warn m }, spawn: nil, clock: -> { Time.now.to_f })
      @config = config
      @rooms = config["rooms"]
      @log = log
      @clock = clock
      @spawn = spawn || method(:fork_host)
      # The apps of rooms.apps that get tables (a game of rooms.tables shows them).
      @serving = @rooms["apps"].select { |a| !Config.tables_for_app(@rooms["tables"], a).empty? }
      @dir = File.join(config["state_dir"], "rooms")
      FileUtils.mkdir_p(@dir)
      @children = {} # slot => {"pid", "room", "until", "since", "restarts", "next_at"}
      @permanent = config["permanent"]
      @perm = { "restarts" => 0 } # the permanent tables' host: {"pid", "since", "restarts", "next_at", "last_exit", "waiting"}
      @mtime = nil
      @data = nil
      @read_ok = false
      @read_at = nil
      @stop = false
      @started_at = Time.now.utc
      @lock = Mutex.new
    end

    def stop!
      @stop = true
    end

    def rooms_file = File.join(@rooms["dir"], "rooms.json")
    def certs_dir = File.join(@rooms["dir"], "certs")
    def slot_dir(slot) = File.join(@dir, slot)
    def permanent_dir = File.join(@config["state_dir"], "permanent")
    attr_reader :perm

    def run
      @rooms["apps"].each do |a|
        names = Config.tables_for_app(@rooms["tables"], a).map { |t| t["name"] }
        @log.call("games: rooms opening #{a}: #{names.empty? ? 'no table (no game of rooms.tables shows it)' : names.join(', ')}")
      end
      @log.call("games: rooms from #{rooms_file} (at most #{@rooms['max']} rooms with tables)")
      if @permanent
        @log.call("games: permanent tables #{@permanent['tables'].map { |t| t['name'] }.join(', ')} " \
                  "with #{@permanent['credentials']}")
      end
      start_status_server
      until @stop
        @lock.synchronize { check }
        sleep CHECK_S
      end
      @lock.synchronize { stop_all }
      @log.call("games: rooms: stopped")
    end

    # One pass: read rooms.json when it changed, stop and remove what is
    # over, start what is wanted, start again what stopped.
    def check(now = @clock.call)
      read_file
      reap(now)
      reap_permanent(now)
      start_permanent(now)
      wanted = self.class.wanted(@data, @serving, now.to_i)
      @children.keys.each do |slot|
        c = @children[slot]
        w = wanted && wanted[slot]
        next if wanted.nil?
        if w && w["room"] == c["room"]
          next if c["trust"].nil? || c["trust"] == trust_for(slot, w)
          stop_child(slot, "the room's seats or hosts changed in rooms.json")
          next
        end
        stop_child(slot, w ? "the slot holds another room" : "the room is closed or ended")
      end
      clean_dirs(now)
      return unless wanted
      wanted.keys.sort.each do |slot|
        next if @children[slot] && @children[slot]["pid"]
        if @children[slot].nil? && running_count >= @rooms["max"]
          note_full(slot)
          next
        end
        start_child(slot, wanted[slot], now)
      end
    end

    def running_count = @children.count { |_s, c| c["pid"] || c["next_at"] }

    def read_file
      st = File.stat(rooms_file)
      return if @mtime && st.mtime == @mtime && @read_ok
      @data = JSON.parse(File.read(rooms_file))
      @mtime = st.mtime
      @read_ok = true
      @read_at = Time.now.utc
    rescue SystemCallError, JSON::ParserError => e
      @log.call("games: rooms: #{rooms_file}: #{e.class}: #{e.message}; nothing changes until it is readable") if @read_ok != false || @data
      @read_ok = false
      @data = nil
    end

    # Removes the saved tables of rooms that are over (and of slots no room
    # file knows of, once the file is readable).
    def clean_dirs(now)
      Dir.children(@dir).each do |slot|
        next if @children[slot]
        d = slot_dir(slot)
        saved = read_json(File.join(d, "room.json"))
        next unless saved.nil? ? @data : self.class.over?(saved.merge("slot" => slot), @data, now.to_i)
        FileUtils.rm_rf(d)
        @log.call("games: room #{slot}: removed the saved tables of #{saved ? "room #{saved['room']}" : 'an unknown room'}")
      end
    rescue SystemCallError => e
      @log.call("games: rooms: #{e.message}")
    end

    def start_child(slot, room, now)
      c = @children[slot] ||= { "restarts" => 0 }
      return if c["next_at"] && now < c["next_at"]
      d = slot_dir(slot)
      saved = read_json(File.join(d, "room.json"))
      if saved && saved["room"] != room["room"]
        FileUtils.rm_rf(d)
        @log.call("games: room #{slot}: room #{saved['room']} is over; its tables are removed")
      end
      FileUtils.mkdir_p(d)
      write_json(File.join(d, "room.json"), { "room" => room["room"], "until" => room["until"], "slot" => slot })
      trust = trust_for(slot, room)
      tar = trust["own"] ? @rooms["credentials"] : File.join(certs_dir, "room-#{slot}.tar")
      unless File.exist?(tar)
        @log.call("games: room #{slot}: no #{tar}; trying again later")
        c["next_at"] = now + BACKOFF_MAX_S
        return
      end
      cfg = child_config(slot, tar, d, room["room"], trust, room["app"])
      c.merge!("room" => room["room"], "until" => room["until"], "since" => Time.now.utc.iso8601, "next_at" => nil,
               "trust" => trust)
      c["pid"] = @spawn.call(slot, cfg)
      @log.call("games: room #{slot}: room #{room['room']} opens #{room['app']}: host pid #{c['pid']} " \
                "(#{trust['own'] ? "its own certificate #{File.basename(tar)}" : 'the slot certificate'}, " \
                "#{trust['seats'].size} seats; #{cfg['tables'].map { |t| t['name'] }.join(', ')})")
    end

    # Whom a room's host trusts and how it joins (from rooms.json):
    # {"own" => joins with its own certificate, "seats" => the seats' node
    # IDs, "prefix" => its own names (nil: none)}.
    def trust_for(slot, room)
      hosts = @data.is_a?(Hash) ? Array(@data["hosts"]) : []
      listed = hosts.include?(@rooms["node"])
      own = listed && !@rooms["credentials"].to_s.empty?
      if listed && !own && !@noted_no_credentials
        @noted_no_credentials = true
        @log.call("games: rooms: the console keeps #{@rooms['node']}'s names for its own certificate, but no " \
                  "rooms.credentials (or permanent.credentials) is set: the tables cannot be served in the rooms")
      end
      prefix = @data.is_a?(Hash) && @data["seat_node_prefix"].to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,20}\z/) ? @data["seat_node_prefix"] : "wasm-"
      seats = (1..room["seats"].to_i).map { |i| format("%s%s%02d", prefix, slot, i) }
      { "own" => own, "seats" => seats, "prefix" => listed ? @rooms["node"] : nil }
    end

    # room_id: the room's ID, with which its tables check who joins (README
    # "Rooms", "Who joins"); trust: trust_for's; app: what the room's link
    # opens (its game's tables; nil: every table of rooms.tables).
    def child_config(slot, tar, dir, room_id = nil, trust = { "own" => false, "seats" => [], "prefix" => nil }, app = nil)
      tables = app ? Config.tables_for_app(@rooms["tables"], app) : @rooms["tables"]
      router = @rooms["router"] || (trust["own"] && @permanent ? @permanent["router"] : nil)
      { "node" => @rooms["node"], "app" => @config["app"], "credentials" => tar,
        "credentials_router" => router, "namespace" => "room/#{slot}", "state_dir" => dir,
        "status_file" => File.join(dir, "host.json"), "tables" => tables, "room_id" => room_id,
        "trusted_nodes" => trust["seats"], "trusted_prefix" => trust["prefix"],
        "seat_reuse_ms" => @rooms["seat_reuse_seconds"].to_i * 1000 }
    end

    # The permanent tables' host (when configured and not running): its
    # certificate must be there (else it is looked for again on every pass,
    # said once in the log).
    def start_permanent(now)
      return unless @permanent && @perm["pid"].nil?
      return if @perm["next_at"] && now < @perm["next_at"]
      tar = @permanent["credentials"]
      unless File.file?(tar) && File.readable?(tar)
        @log.call("games: permanent: no readable #{tar}; the permanent tables wait for it") unless @perm["waiting"]
        @perm["waiting"] = true
        return
      end
      @perm["waiting"] = false
      FileUtils.mkdir_p(permanent_dir)
      cfg = { "node" => @permanent["node"], "app" => @config["app"], "credentials" => tar,
              "credentials_router" => @permanent["router"], "state_dir" => permanent_dir,
              "status_file" => File.join(permanent_dir, "host.json"), "tables" => @permanent["tables"] }
      @perm.merge!("since" => Time.now.utc.iso8601, "next_at" => nil)
      @perm["pid"] = @spawn.call("permanent", cfg)
      @log.call("games: permanent: host pid #{@perm['pid']} (#{@permanent['tables'].map { |t| t['name'] }.join(', ')})")
    end

    def reap_permanent(now)
      return unless @perm["pid"]
      pid, st = Process.wait2(@perm["pid"], Process::WNOHANG)
      return unless pid
      @perm["pid"] = nil
      @perm["restarts"] += 1
      delay = [2**[@perm["restarts"] - 1, 5].min, BACKOFF_MAX_S].min
      @perm["next_at"] = now + delay
      @perm["last_exit"] = st.exitstatus || "signal #{st.termsig}"
      @log.call("games: permanent: host pid #{pid} stopped (#{@perm['last_exit']}); again in #{delay} s")
    rescue Errno::ECHILD
      @perm["pid"] = nil
    end

    # who: a room's slot ("01") or "permanent".
    def fork_host(who, cfg)
      label = who == "permanent" ? "permanent" : "room #{who}"
      fork do
        @server&.close
        $PROGRAM_NAME = "asterism-games #{label}"
        host = Host.new(cfg, log: ->(m) { @log.call("#{label}: #{m}") })
        %w[INT TERM].each { |s| trap(s) { host.stop! } }
        host.run
        exit!(0)
      end
    end

    def reap(now)
      @children.each do |slot, c|
        next unless c["pid"]
        pid, st = Process.wait2(c["pid"], Process::WNOHANG)
        next unless pid
        c["pid"] = nil
        c["restarts"] += 1
        delay = [2**[c["restarts"] - 1, 5].min, BACKOFF_MAX_S].min
        c["next_at"] = now + delay
        c["last_exit"] = st.exitstatus || "signal #{st.termsig}"
        @log.call("games: room #{slot}: host pid #{pid} stopped (#{c['last_exit']}); again in #{delay} s")
      rescue Errno::ECHILD
        c["pid"] = nil
      end
    end

    def stop_child(slot, why)
      c = @children.delete(slot)
      return unless c && c["pid"]
      @log.call("games: room #{slot}: stopping host pid #{c['pid']} (#{why})")
      terminate([c["pid"]])
    end

    def stop_all
      pids = @children.values.map { |c| c["pid"] }.compact
      pids << @perm["pid"] if @perm["pid"]
      terminate(pids)
      @children.clear
      @perm["pid"] = nil
    end

    def terminate(pids)
      pids.each do |pid|
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        nil
      end
      deadline = Time.now + STOP_WAIT_S
      pids.each do |pid|
        loop do
          break if Process.wait(pid, Process::WNOHANG)
          if Time.now > deadline
            Process.kill("KILL", pid)
            Process.wait(pid)
            break
          end
          sleep 0.05
        end
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
    end

    def note_full(slot)
      @full_noted ||= {}
      return if @full_noted[slot]
      @full_noted[slot] = true
      @log.call("games: room #{slot}: no table (#{@rooms['max']} rooms have tables already; rooms.max)")
    end

    # ------------------------------------------------------------ status

    # What the console's admin page shows (GET /status): the rooms with a
    # host and their tables, as counts.
    def status
      @lock.synchronize do
        now = @clock.call
        wanted = self.class.wanted(@data, @serving, now.to_i) || {}
        rooms = @children.keys.sort.to_h do |slot|
          c = @children[slot]
          h = read_json(File.join(slot_dir(slot), "host.json")) || {}
          fresh = h["at"].to_i >= now.to_i - 10 && h["pid"] == c["pid"]
          [slot, { "room" => c["room"], "until" => c["until"], "pid" => c["pid"], "since" => c["since"],
                   "restarts" => c["restarts"], "last_exit" => c["last_exit"],
                   "state" => c["pid"] ? (fresh && h["connected"] ? "up" : "starting") : "restarting",
                   "connected" => fresh ? h["connected"] : false, "tables" => fresh ? h["tables"] : {} }]
        end
        perm = permanent_status(now)
        # Someone sits at a table and is there: an away seat (a player gone
        # without leaving) does not keep an update waiting (--when-idle).
        seated = ->(r) { r["tables"].to_h.values.any? { |t| t["humans"].to_i - t["away"].to_i > 0 } }
        { "host" => "asterism-games", "version" => AsterismGames::VERSION, "since" => @started_at.iso8601,
          "rooms_file" => { "ok" => @read_ok, "read_at" => @read_at&.iso8601 },
          "apps" => @rooms["apps"], "max" => @rooms["max"], "rooms" => rooms,
          "without_table" => (wanted.keys - rooms.keys).sort,
          "permanent" => perm,
          "busy" => rooms.values.any?(&seated) || (perm ? seated.call(perm) : false),
          "rss_kb" => rss_kb([Process.pid, @perm["pid"]].compact + @children.values.map { |c| c["pid"] }.compact) }
      end
    end

    # The permanent tables' host for the status (nil: not configured).
    # "node" is the setting (nil: the certificate's name), never read from
    # the certificate here.
    def permanent_status(now)
      return nil unless @permanent
      h = read_json(File.join(permanent_dir, "host.json")) || {}
      fresh = @perm["pid"] && h["at"].to_i >= now.to_i - 10 && h["pid"] == @perm["pid"]
      state = if @perm["pid"] then fresh && h["connected"] ? "up" : "starting"
              elsif @perm["waiting"] then "no certificate"
              else "restarting"
              end
      { "node" => fresh ? h["node"] : nil, "table_names" => @permanent["tables"].map { |t| t["name"] },
        "pid" => @perm["pid"], "since" => @perm["since"], "restarts" => @perm["restarts"],
        "last_exit" => @perm["last_exit"], "state" => state, "connected" => fresh ? h["connected"] : false,
        "tables" => fresh ? h["tables"] : {} }
    end

    def rss_kb(pids)
      pids.sum do |pid|
        File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i
      rescue SystemCallError
        0
      end
    end

    # GET /status on rooms.status_listen (host:port): one request per
    # connection, JSON. Nothing else is answered.
    def start_status_server
      listen = @rooms["status_listen"].to_s
      return if listen.empty?
      host, port = listen.split(/:(?=\d+\z)/)
      @server = TCPServer.new(host, port.to_i)
      @log.call("games: status on #{listen} (GET /status)")
      Thread.new do
        loop do
          s = @server.accept
          Thread.new(s) { |c| answer(c) }
        rescue IOError
          break
        end
      end
    end

    def answer(sock)
      line = sock.gets.to_s
      while (l = sock.gets) && l != "\r\n"; end
      ok = line.start_with?("GET /status ")
      body = ok ? JSON.generate(status) : "not found\n"
      sock.write("HTTP/1.1 #{ok ? '200 OK' : '404 Not Found'}\r\nContent-Type: #{ok ? 'application/json' : 'text/plain'}\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    rescue StandardError
      nil
    ensure
      sock.close rescue nil
    end

    private

    def read_json(path)
      JSON.parse(File.read(path))
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def write_json(path, data)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, path)
    end
  end
end
