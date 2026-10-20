# frozen_string_literal: true

require "json"
require "monitor"
require_relative "mahjong_events"
require_relative "mahjong_phrases"
require_relative "server"

module AsterismGames
  module Commentate
    # What the pages are told (README "Commentary"): each table's last
    # spectate view and its commentary, kept here and pushed to the open
    # pages (Server). Fed by the runner (update, host_left, host_back);
    # nothing in it waits on the network, so the tests feed it directly.
    class MahjongHub
      KEEP_LINES = 100

      attr_reader :tables

      # public: hide the hands from everything that leaves this process (the
      # views lose hand and drawn, the lines are the public ones). json: an
      # IO for a JSON line per commentary line (--json), or nil.
      def initialize(public: false, table: nil, json: nil, rng: Random.new, clock: -> { Time.now }, version: nil)
        @public = public
        @want = table
        @json = json
        @rng = rng
        @clock = clock
        @version = version
        @lock = Monitor.new
        @tables = {} # id => {"host", "name", "view", "memo", "lines", "at", "gone"}
        @clients = []
        @seq = 0
      end

      def public? = @public

      # A table's id on the page: <host>/<table>.
      def self.id(host, name) = "#{host}/#{name}"

      # A spectate view arrived. Returns the lines it made.
      def update(host, name, view)
        return [] unless view.is_a?(Hash)
        id = MahjongHub.id(host, name)
        frames = []
        lines = []
        @lock.synchronize do
          t = (@tables[id] ||= { "host" => host, "name" => name, "view" => nil, "memo" => {}, "lines" => [] })
          fresh = t["view"].nil?
          was_gone = t["gone"]
          t["gone"] = false
          t["at"] = @clock.call
          evs, t["memo"] = MahjongEvents.diff(t["view"], view, t["memo"])
          evs.each do |ev|
            l = MahjongPhrases.line(ev, view, @rng)
            l = public_line(l) if @public
            next unless l
            @seq += 1
            l["id"] = @seq
            l["at"] = @clock.call.strftime("%H:%M:%S")
            l["table"] = id
            t["lines"] << l
            lines << l
          end
          t["lines"].shift while t["lines"].size > KEEP_LINES
          t["view"] = view
          out = shown(view)
          frames << [id, Server.frame("state", { "table" => id, "view" => out })]
          lines.each { |l| frames << [id, Server.frame("line", l)] }
          broadcast_status if fresh || was_gone
          frames.each { |tid, f| each_client(tid) { |c| c.push(f) } }
        end
        lines.each { |l| @json.puts(JSON.generate(json_line(l))) } if @json
        @json&.flush
        lines
      end

      # The host of a table left the network (Asterism's on_leave): the pages
      # say so; nothing stops.
      def host_left(host) = mark(host, true)
      def host_back(host) = mark(host, false)

      # Tables not heard from for stale_s (the host puts every 5 s): gone.
      def check_stale(stale_s = 15)
        @lock.synchronize do
          now = @clock.call
          changed = false
          @tables.each_value do |t|
            next if t["gone"] || t["at"].nil? || now - t["at"] < stale_s
            t["gone"] = true
            changed = true
          end
          broadcast_status if changed
        end
      end

      # ------------------------------------------------------------ the pages

      def subscribe(client)
        @lock.synchronize { @clients << client }
      end

      def unsubscribe(client)
        @lock.synchronize { @clients.delete(client) }
      end

      # The first frames of a page: who we are, its table and the lines so far.
      def hello(client)
        @lock.synchronize do
          client.table = nil if client.table && !@tables.key?(client.table) && !@tables.empty? && !want?(client.table)
          client.table ||= default_table
          out = [["status", status]]
          t = @tables[client.table]
          if t
            out << ["state", { "table" => client.table, "view" => shown(t["view"]) }]
            t["lines"].each { |l| out << ["line", l.merge("old" => true)] }
          end
          out
        end
      end

      def status
        { "public" => @public, "version" => @version, "want" => @want,
          "tables" => @tables.sort.map { |id, t| { "id" => id, "name" => t["name"], "host" => t["host"], "gone" => t["gone"] ? true : false } } }
      end

      private

      def want?(id) = @want && id.end_with?(@want)

      def default_table
        ids = @tables.keys.sort
        ids.find { |id| want?(id) } || ids.first
      end

      def mark(host, gone)
        @lock.synchronize do
          hit = @tables.values.select { |t| t["host"] == host && t["gone"] != gone }
          hit.each { |t| t["gone"] = gone }
          broadcast_status unless hit.empty?
        end
      end

      def broadcast_status
        f = Server.frame("status", status)
        # A page that had no table yet takes the first one now.
        @clients.each do |c|
          if c.table.nil? && (d = default_table)
            c.table = d
            t = @tables[d]
            c.push(Server.frame("state", { "table" => d, "view" => shown(t["view"]) })) if t["view"]
          end
          c.push(f)
        end
      end

      def each_client(id, &blk)
        @clients.each do |c|
          c.table ||= default_table
          blk.call(c) if c.table == id
        end
      end

      # The view as it leaves: without the hands with --public.
      def shown(view)
        return view unless @public && view.is_a?(Hash)
        v = view.dup
        v["seats"] = Array(view["seats"]).map { |s| s.reject { |k, _| %w[hand drawn].include?(k) } }
        v
      end

      def public_line(l)
        return nil if l["ptext"].nil?
        l.merge("text" => l["ptext"], "speech" => l["pspeech"]).reject { |k, _| %w[ptext pspeech].include?(k) }
      end

      def json_line(l)
        { "at" => l["at"], "table" => l["table"], "type" => l["type"], "prio" => l["prio"], "text" => l["text"] }
      end
    end

    # `asterism-games commentate mahjong`: the connection, the spectate
    # keys, the web server and the browser.
    module MahjongRunner
      SPECTATE = "asterism/*/spectate/*/state"
      STALE_S = 15

      module_function

      def run(opts, out: $stdout, err: $stderr)
        require "asterism"
        # A pipe or a file (--json to another tool) gets each line at once.
        out.sync = true if out.respond_to?(:sync=)
        hub = MahjongHub.new(public: opts[:public], table: table_filter(opts), json: opts[:json] ? out : nil,
                             version: AsterismGames::VERSION)
        server = Server.new(hub, port: opts[:port], log: ->(m) { err.puts("commentate: #{m}") }).start
        info = opts[:json] ? err : out
        info.puts "commentate: #{server.url} (127.0.0.1 only; Ctrl-C quits)"
        info.puts "commentate: hands hidden (--public)" if opts[:public]
        open_browser(server.url, err) if opts[:open]
        prefix = room_prefix(opts[:namespace])
        connect(opts, err) do |net|
          net.on_leave { |n| hub.host_left(n) }
          net.on_join { |n| hub.host_back(n) }
          net.start
          net.session.subscribe(SPECTATE) do |sample|
            next if sample.respond_to?(:kind) && sample.kind == :delete
            _, host, _, name, = sample.key.to_s.split("/")
            next unless wanted?(host, name, opts[:table], prefix)
            v = Asterism::Codec.unpack(sample.payload)
            hub.update(host, name, v)
          rescue StandardError => e
            err.puts "commentate: #{sample.key}: #{e.class}: #{e.message}"
          end
          stop = Thread::Queue.new
          %w[INT TERM].each { |s| trap(s) { stop << true } }
          hub.check_stale(STALE_S) until stop.pop(timeout: 2)
        end
      ensure
        server&.stop
      end

      def connect(opts, err, &blk)
        require "socket"
        node = opts[:node] || (opts[:credentials] ? nil : "commentate-#{Socket.gethostname[/\A[A-Za-z0-9_-]+/]}-#{Process.pid}")
        kw = { app: "commentate" }
        kw[:node] = node if node
        kw[:credentials] = opts[:credentials] if opts[:credentials]
        # No namespace: the spectate keys are outside every room (README
        # "Spectate"); --namespace room/01 picks that room's tables.
        Asterism.connect(opts[:locator], **kw) do |net|
          net.on_error { |e, where| err.puts "commentate: #{where}: #{e.class}: #{e.message}" }
          blk.call(net)
        end
      end

      # --namespace room/01: the room's tables are room01-<table> outside it.
      def room_prefix(ns)
        return nil if ns.to_s.empty?
        "#{ns.to_s.delete('/')}-"
      end

      # What --table / --namespace name, for the page's first choice.
      def table_filter(opts)
        t = opts[:table].to_s
        return nil if t.empty?
        parts = t.split("/")
        parts.size >= 3 ? "#{parts[0]}/#{parts[-1]}" : t
      end

      # --table: <table>, <host>/<table>, <host>/spectate/<table> or the
      # play's <host>/games/<table>.
      def wanted?(host, name, table, prefix)
        return false if host.nil? || name.nil?
        return false if prefix && !name.start_with?(prefix)
        return true if table.to_s.empty?
        parts = table.to_s.split("/")
        want = parts.last
        want = "#{prefix}#{want}" if prefix && !want.start_with?(prefix)
        return false unless name == want
        parts.size == 1 || parts.first == host
      end

      # The page in the browser: macOS open, WSL wslview or Windows' start,
      # elsewhere xdg-open. A failure only says the URL again.
      def open_browser(url, err)
        cmd = if RUBY_PLATFORM.include?("darwin") then ["open", url]
              elsif wsl?
                which("wslview") ? ["wslview", url] : ["cmd.exe", "/c", "start", "", url]
              elsif which("xdg-open") then ["xdg-open", url]
              end
        return err.puts("commentate: open #{url} in a browser") unless cmd
        # cmd.exe complains in a directory of Linux's: start it in C:.
        dir = cmd[0] == "cmd.exe" && File.directory?("/mnt/c") ? "/mnt/c" : Dir.pwd
        pid = Process.spawn(*cmd, %i[out err] => File::NULL, chdir: dir)
        Process.detach(pid)
      rescue SystemCallError
        err.puts "commentate: open #{url} in a browser"
      end

      def wsl?
        File.read("/proc/version").match?(/microsoft/i)
      rescue SystemCallError
        false
      end

      def which(cmd)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, cmd)) }
      end
    end
  end
end
