# frozen_string_literal: true

require "socket"
require "json"

module AsterismGames
  module Commentate
    # The page's web server (README "Commentary"): HTTP/1.1 by hand on the
    # standard library's socket, listening on 127.0.0.1 only. It serves a
    # few fixed paths (the page, its script and style, the two tile sheets)
    # and /events, a stream of Server-Sent Events that pushes the table and
    # the commentary to every open page. Nothing else: no files by name, no
    # POST, and a Host header that is not this machine is refused (a page
    # elsewhere cannot reach in through a name that points here). With a
    # VOICEVOX voice (the hub's voice), also the fixed phrases'
    # files (/clip/<digest>.wav, only those of the list) and the lines'
    # sound (/voice/<digest>.wav, only the texts the hub registered:
    # never a text a page sends).
    class Server
      ASSETS = File.expand_path("assets", __dir__)
      FILES = {
        "/" => ["index.html", "text/html; charset=utf-8"],
        "/index.html" => ["index.html", "text/html; charset=utf-8"],
        "/commentate.js" => ["commentate.js", "text/javascript; charset=utf-8"],
        "/commentate.css" => ["commentate.css", "text/css; charset=utf-8"],
        "/tiles_hand.bmp" => ["tiles_hand.bmp", "image/bmp"],
        "/tiles_river.bmp" => ["tiles_river.bmp", "image/bmp"],
        "/TILES_LICENSE.txt" => ["TILES_LICENSE.txt", "text/plain; charset=utf-8"]
      }.freeze
      CLIP = %r{\A/clip/([0-9a-f]{16}\.wav)\z}
      LIVE = %r{\A/voice/([0-9a-f]{32}\.wav)\z}
      LOCAL_HOSTS = %w[127.0.0.1 localhost].freeze
      PING_S = 15
      HEAD_LIMIT = 8192
      READ_TIMEOUT_S = 10

      attr_reader :port

      # hub answers #hello(table) (the first events of a new page: an
      # array of [event, data]) and #subscribe(client) / #unsubscribe(client).
      def initialize(hub, port: 7470, tries: 20, host: "127.0.0.1", log: nil)
        @hub = hub
        @log = log
        @server = nil
        last = nil
        tries.times do |i|
          @server = TCPServer.new(host, port + i)
          break
        rescue Errno::EADDRINUSE, Errno::EACCES => e
          last = e
          raise if port.zero?
        end
        raise(last || Errno::EADDRINUSE) unless @server
        @port = @server.addr[1]
        @threads = []
      end

      def address = @server.addr[3]
      def url = "http://127.0.0.1:#{@port}/"

      def start
        @accept = Thread.new do
          loop do
            sock = @server.accept
            Thread.new(sock) { |s| serve(s) }
          rescue IOError, Errno::EBADF
            break
          rescue StandardError => e
            @log&.call("http: #{e.class}: #{e.message}")
          end
        end
        self
      end

      def stop
        @server.close
      rescue IOError
        nil
      ensure
        @accept&.kill
      end

      # ------------------------------------------------------------ one connection

      def serve(sock)
        req = read_request(sock)
        return unless req
        method, target, headers = req
        host = headers["host"].to_s.sub(/:\d+\z/, "").delete("[]")
        return respond(sock, 403, "text/plain", "not this machine\n") unless LOCAL_HOSTS.include?(host) || host == "::1"
        return respond(sock, 405, "text/plain", "GET only\n", "Allow" => "GET, HEAD") unless %w[GET HEAD].include?(method)
        path, query = target.split("?", 2)
        if path == "/events"
          events(sock, params(query))
        elsif (m = path.match(CLIP) || path.match(LIVE))
          voice = @hub.respond_to?(:voice) ? @hub.voice : nil
          body = voice && (path.start_with?("/clip/") ? voice.clip(m[1]) : voice.wav(m[1]))
          return respond(sock, 404, "text/plain", "not found\n") unless body
          respond(sock, 200, "audio/wav", method == "HEAD" ? "" : body, "Cache-Control" => "max-age=600",
                                                                "Content-Length" => body.bytesize.to_s)
        elsif (f = FILES[path])
          body = File.binread(File.join(ASSETS, f[0]))
          respond(sock, 200, f[1], method == "HEAD" ? "" : body, "Cache-Control" => "no-cache",
                                                                 "Content-Length" => body.bytesize.to_s)
        else
          respond(sock, 404, "text/plain", "not found\n")
        end
      rescue IOError, SystemCallError
        nil
      ensure
        begin
          sock.close
        rescue IOError
          nil
        end
      end

      # [method, target, {lowercase header => value}], or nil.
      def read_request(sock)
        head = +""
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READ_TIMEOUT_S
        until head.include?("\r\n\r\n") || head.include?("\n\n")
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil if left <= 0 || head.bytesize > HEAD_LIMIT
          return nil unless sock.wait_readable(left)
          chunk = sock.readpartial(1024)
          head << chunk
        end
        lines = head.split(/\r?\n/)
        method, target, = lines.shift.to_s.split(" ", 3)
        return nil unless method && target&.start_with?("/")
        headers = {}
        lines.each do |l|
          break if l.empty?
          k, v = l.split(":", 2)
          headers[k.strip.downcase] = v.to_s.strip if v
        end
        [method, target, headers]
      rescue EOFError
        nil
      end

      def params(query)
        query.to_s.split("&").to_h do |kv|
          k, v = kv.split("=", 2)
          [unescape(k), unescape(v)]
        end
      end

      def unescape(s) = s.to_s.tr("+", " ").gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding("UTF-8")

      STATUS = { 200 => "OK", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed" }.freeze

      def respond(sock, code, type, body, extra = {})
        h = { "Content-Type" => type, "Content-Length" => body.bytesize.to_s, "Connection" => "close",
              "X-Content-Type-Options" => "nosniff" }.merge(extra)
        sock.write("HTTP/1.1 #{code} #{STATUS[code]}\r\n#{h.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n")
        sock.write(body) unless body.empty?
      end

      # The stream: the hub's first events, then whatever it pushes, and a
      # comment line every PING_S so a dead page is noticed.
      def events(sock, params)
        sock.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n" \
                   "Cache-Control: no-cache\r\nConnection: keep-alive\r\nX-Content-Type-Options: nosniff\r\n\r\n")
        client = Client.new(params["table"], hide: params["hide"] == "1")
        @hub.subscribe(client)
        @hub.hello(client).each { |ev, data| sock.write(Server.frame(ev, data)) }
        loop do
          msg = client.queue.pop(timeout: PING_S)
          break if msg == :close
          sock.write(msg.nil? ? ": ping\n\n" : msg)
        end
      ensure
        @hub.unsubscribe(client) if client
      end

      # One Server-Sent Event: "event: name\ndata: json\n\n".
      def self.frame(event, data)
        "event: #{event}\ndata: #{JSON.generate(data)}\n\n"
      end

      # An open page: the table it watches (nil: the hub's choice), whether
      # it hides the hands (H: the AI then gets none), and the frames
      # waiting for it.
      class Client
        attr_accessor :table, :hide
        attr_reader :queue

        def initialize(table, hide: false)
          @table = table.to_s.empty? ? nil : table
          @hide = hide
          @queue = Thread::Queue.new
        end

        def push(frame)
          # A page that does not read (a tab asleep) is not waited for:
          # past this many frames it is closed, and it opens again.
          @queue.size > 2000 ? @queue.push(:close) : @queue.push(frame)
        end
      end
    end
  end
end
