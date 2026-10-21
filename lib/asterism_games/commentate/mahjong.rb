# frozen_string_literal: true

require "json"
require "monitor"
require_relative "mahjong_events"
require_relative "mahjong_phrases"
require_relative "mahjong_sounds"
require_relative "server"
require_relative "voice"
require_relative "ai_comment"

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
      # IO for a JSON line per commentary line (--json), or nil. voice: a
      # Voice (VOICEVOX: the lines in its character's tone, each with the
      # URLs of its sound), or nil (the browser's voice; voice_note says
      # why, for the page). ai: an AIComment (the AI's one-liners), or nil
      # (ai_status says why, for the page).
      def initialize(public: false, table: nil, json: nil, rng: Random.new, clock: -> { Time.now }, version: nil,
                     voice: nil, voice_note: nil, ai: nil, ai_status: nil)
        @public = public
        @want = table
        @json = json
        @rng = rng
        @clock = clock
        @version = version
        @voice = voice
        @voice_note = voice_note
        @tone = voice ? voice.tone : "plain"
        @lock = Monitor.new
        @tables = {} # id => {"host", "name", "view", "memo", "lines", "at", "gone"}
        @clients = []
        @seq = 0
        @ai = ai
        @ai_status = ai_status || { "state" => "off", "note" => "off" }
        @ai&.attach(deliver: ->(id, text, job) { ai_line(id, text, hands: job["hands"]) },
                    changed: -> { @lock.synchronize { broadcast_status } },
                    targets: -> { ai_targets }, hands: -> { hands_for_ai? }, tone: @tone)
      end

      attr_reader :ai

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
          sounds = MahjongSounds.effects(t["view"], view)
          evs.each do |ev|
            l = MahjongPhrases.line(ev, view, @rng, tone: @tone)
            l = public_line(l) if @public
            next unless l
            l["voice"] = @voice.plan(l, @rng) if @voice
            @seq += 1
            l["id"] = @seq
            l["at"] = @clock.call.strftime("%H:%M:%S")
            l["table"] = id
            t["lines"] << l
            lines << l
          end
          t["lines"].shift while t["lines"].size > KEEP_LINES
          t["view"] = view
          frames << [id, Server.frame("state", state_frame(id, view).merge("sounds" => sounds))]
          lines.each { |l| frames << [id, Server.frame("line", l)] }
          broadcast_status if fresh || was_gone
          frames.each { |tid, f| each_client(tid) { |c| c.push(f) } }
        end
        lines.each { |l| @json.puts(JSON.generate(json_line(l))) } if @json
        @json&.flush
        @ai&.observe(id, view, lines)
        lines
      end

      # An AI's one-liner for a table (AIComment, after its fixed lines):
      # the caption as it came, the speech read as the fixed lines are
      # (SPEECH_READ, the tiles' names), marked "ai" for the page (said
      # after the fixed lines, dropped first). hands: whether the AI saw
      # the hands (then a page that hides them does not show it).
      def ai_line(id, text, hands: false)
        speech = MahjongPhrases.reading(text.delete("！").gsub(/\s+/, " ").strip)
        l = { "type" => "ai", "prio" => 0, "ai" => true, "text" => text, "speech" => speech,
              "ptext" => hands ? nil : text, "pspeech" => hands ? nil : speech, "clips" => [] }
        frames = []
        @lock.synchronize do
          t = @tables[id] or return nil
          l["voice"] = @voice.plan(l) if @voice
          @seq += 1
          l["id"] = @seq
          l["at"] = @clock.call.strftime("%H:%M:%S")
          l["table"] = id
          t["lines"] << l
          t["lines"].shift while t["lines"].size > KEEP_LINES
          frames << Server.frame("line", l)
          frames.each { |f| each_client(id) { |c| c.push(f) } }
        end
        if @json
          @json.puts(JSON.generate(json_line(l)))
          @json.flush
        end
        l
      end

      # Every few seconds (the runner): a quiet table may get a one-liner.
      def tick
        @ai&.tick
      end

      # The tables the AI comments on: those a page watches (and with
      # --json the first one): nobody watching, nothing is spent.
      def ai_targets
        @lock.synchronize do
          ids = @clients.map(&:table).compact
          ids << default_table if @json && default_table
          ids.uniq
        end
      end

      # Whether the AI may see the hands: not with --public, nor while a
      # page hides them (H).
      def hands_for_ai?
        return false if @public
        @lock.synchronize { @clients.none? { |c| c.respond_to?(:hide) && c.hide } }
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
            out << ["state", state_frame(client.table, t["view"])]
            t["lines"].each { |l| out << ["line", l.merge("old" => true)] }
          end
          out
        end
      end

      def status
        { "public" => @public, "version" => @version, "want" => @want, "voice" => voice_status,
          "ai" => @ai ? @ai.status : @ai_status,
          "tables" => @tables.sort.map { |id, t| { "id" => id, "name" => t["name"], "host" => t["host"], "gone" => t["gone"] ? true : false } } }
      end

      attr_reader :voice

      private

      def voice_status
        return @voice.status if @voice
        { "engine" => "browser", "note" => @voice_note }
      end

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
            c.push(Server.frame("state", state_frame(d, t["view"]))) if t["view"]
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

      # A "state" event: the view as it leaves, and the BGM's scene for it
      # (MahjongSounds; update adds the effects of the step).
      def state_frame(id, view)
        { "table" => id, "view" => shown(view), "bgm" => MahjongSounds.scene(view) }
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
        out = { "at" => l["at"], "table" => l["table"], "type" => l["type"], "prio" => l["prio"], "text" => l["text"] }
        out["ai"] = true if l["ai"]
        out
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
        info = opts[:json] ? err : out
        voice, note = start_voice(opts, info)
        ai, ai_status = AIComment.from_options(opts, log: ->(m) { info.puts "commentate: #{m}" })
        hub = MahjongHub.new(public: opts[:public], table: table_filter(opts), json: opts[:json] ? out : nil,
                             version: AsterismGames::VERSION, voice: voice, voice_note: note, ai: ai,
                             ai_status: ai_status)
        server = Server.new(hub, port: opts[:port], log: ->(m) { err.puts("commentate: #{m}") }).start
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
          until stop.pop(timeout: 2)
            hub.check_stale(STALE_S)
            hub.tick
          end
        end
      ensure
        server&.stop
        voice&.stop
        ai&.stop
      end

      # The VOICEVOX voice ([voice, nil]), or [nil, note] when the engine is
      # not there (the browser's voice reads). Voicevox::NotFound (no such
      # character or style) goes up: the command says what there is.
      def start_voice(opts, info, root: ClipBank.cache_root)
        url = opts[:voicevox] || Voicevox::DEFAULT_URL
        log = ->(m) { info.puts "commentate: #{m}" }
        voice = Voice.connect(url: url, speaker: opts[:speaker] || DEFAULT_SPEAKER, style: opts[:style] || DEFAULT_STYLE,
                              root: root, log: log)
        unless voice
          info.puts "commentate: no VOICEVOX at #{url}: the browser's voice reads (README \"Commentary\", \"The voice\")"
          info.puts "commentate: VOICEVOX is a free app you install yourself (it is not in this gem): " \
                    "#{Voicevox::HOME}; start it and run this again for #{opts[:speaker] || DEFAULT_SPEAKER}'s voice"
          return [nil, "missing"]
        end
        info.puts "commentate: VOICEVOX #{voice.engine_version} at #{url}: #{voice.speaker} (#{voice.style}, #{voice.id}), " \
                  "fixed phrases in #{voice.bank.dir}; credit: #{voice.credit}"
        voice.make_missing_async
        [voice, nil]
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
