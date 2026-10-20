# frozen_string_literal: true

require "yaml"
require "digest"
require "fileutils"
require "monitor"
require_relative "voicevox"
require_relative "mahjong_phrases"

module AsterismGames
  module Commentate
    # The fixed phrases as WAV files (README "Commentary", "The voice"):
    # the list is the gem's (mahjong_voice.yml), the sound is made on this
    # machine by its VOICEVOX, into
    # $XDG_CACHE_HOME/asterism-games/voices/<speaker>-<style>/ (by default
    # ~/.cache/...). Nothing of it is redistributed; the directory can be
    # deleted at any time and is made again. Each file is named by the
    # digest of its phrasing, so a changed phrasing is made again and the
    # files no phrasing names any more are removed.
    class ClipBank
      LIST = File.expand_path("mahjong_voice.yml", __dir__)
      FILE = /\A[0-9a-f]{16}\.wav\z/

      attr_reader :dir, :tone

      def self.cache_root(env = ENV)
        xdg = env["XDG_CACHE_HOME"].to_s
        base = xdg.start_with?("/") ? xdg : File.join(Dir.home, ".cache")
        File.join(base, "asterism-games", "voices")
      end

      # The directory of a character's style: <speaker>-<style>, with
      # nothing in it that a file name cannot hold.
      def self.dir_for(speaker, style, root: cache_root)
        safe = ->(s) { s.to_s.gsub(%r{[/\\\x00-\x1f]}, "_").sub(/\A\.+/, "_") }
        File.join(root, "#{safe.call(speaker)}-#{safe.call(style)}")
      end

      def self.load_list(path = LIST)
        YAML.safe_load(File.read(path, encoding: "UTF-8")) || {}
      end

      # list: {key => {"word", tone => [phrasing]}}; client: a Voicevox
      # (only for make!); id: the style's number.
      def initialize(dir, tone: "plain", list: ClipBank.load_list, client: nil, id: nil, credit: nil)
        @dir = dir
        @tone = tone
        @list = list
        @client = client
        @id = id
        @credit = credit
        @lock = Monitor.new
      end

      def keys = @list.keys

      # The phrasings of a key in this tone (plain's when it has none).
      def phrasings(key)
        e = @list[key] || {}
        Array(e[@tone] || e["plain"]).map { |t| MahjongPhrases.reading(t.to_s) }.reject(&:empty?)
      end

      # The word the line's speech leaves out after the key's phrase (as
      # the speech reads it).
      def word(key)
        w = (@list[key] || {})["word"]
        w && MahjongPhrases.reading(w)
      end

      def self.file_name(text) = "#{Digest::SHA256.hexdigest(text)[0, 16]}.wav"

      # Every file the list names: {file => [key, phrasing]}.
      def wanted
        out = {}
        @list.each_key { |k| phrasings(k).each { |t| out[ClipBank.file_name(t)] = [k, t] } }
        out
      end

      def missing = wanted.keys.reject { |f| File.file?(File.join(@dir, f)) }

      def ready?(key) = !ready_files(key).empty?

      def ready_files(key)
        phrasings(key).map { |t| ClipBank.file_name(t) }.select { |f| File.file?(File.join(@dir, f)) }
      end

      # One of the key's files at random (nil: none made yet).
      def pick(key, rng = Random.new)
        fs = ready_files(key)
        fs.empty? ? nil : fs[rng.rand(fs.size)]
      end

      # The bytes of a file the list names (nil for anything else).
      def read(file)
        return nil unless file.to_s.match?(FILE) && wanted.key?(file)
        path = File.join(@dir, file)
        File.file?(path) ? File.binread(path) : nil
      end

      # Has the engine say every phrasing that has no file yet, and removes
      # the files no phrasing names. Returns [made, already there].
      # log: ->(message) for each file made.
      def make!(log: nil)
        raise ArgumentError, "make! needs the engine" unless @client && @id
        @lock.synchronize do
          FileUtils.mkdir_p(@dir)
          want = wanted
          (Dir.children(@dir).grep(FILE) - want.keys).each { |f| File.delete(File.join(@dir, f)) }
          todo = want.reject { |f, _| File.file?(File.join(@dir, f)) }
          todo.each_with_index do |(f, (key, text)), i|
            wav = @client.synthesize(text, @id)
            tmp = File.join(@dir, ".#{f}.#{Process.pid}.tmp")
            File.binwrite(tmp, wav)
            File.rename(tmp, File.join(@dir, f))
            log&.call("#{i + 1}/#{todo.size} #{key}: #{text}")
          end
          write_credits
          [todo.size, want.size - todo.size]
        end
      end

      private

      def write_credits
        return unless @credit
        File.write(File.join(@dir, "CREDITS.txt"), <<~TEXT)
          #{@credit}

          Made on this machine by its VOICEVOX engine (asterism-games commentate voices --make)
          from the phrases of asterism-games (mahjong_voice.yml). Not redistributed: anyone
          who uses these files follows VOICEVOX's terms and the character's. Delete this
          directory at any time; it is made again.
        TEXT
      end
    end

    # The lines said as they come (README "The voice"): each text the hub
    # registers gets a digest (its temporary URL /voice/<digest>.wav), the
    # engine synthesises them one by one in a thread of its own (the
    # bigger lines first, the small old ones left for when they are
    # asked), a page that asks for one waits until it is made. The same
    # text is synthesised once while it is kept: at most max_entries WAVs
    # and max_bytes, the least recently used dropped first.
    class LiveVoice
      ID = /\A[0-9a-f]{32}\z/
      STALE_S = 30
      WAIT_S = 30

      attr_reader :synthesized

      def initialize(client, id, max_entries: 200, max_bytes: 64 * 1024 * 1024, max_texts: 2000,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, log: nil)
        @client = client
        @id = id
        @max_entries = max_entries
        @max_bytes = max_bytes
        @max_texts = max_texts
        @clock = clock
        @log = log
        @lock = Monitor.new
        @cond = @lock.new_cond
        @items = {} # digest => {text, prio, at, state (:new :queued :working :done :failed), wav}
        @bytes = 0
        @synthesized = 0
        @worker = nil
        @stop = false
      end

      def digest(text) = Digest::SHA256.hexdigest("#{@id}\n#{text}")[0, 32]

      # A text to say: its digest. queue: synthesise it now (a line as it
      # comes) or only when asked (the same line with the hands hidden).
      def register(text, prio: 0, queue: true)
        d = digest(text)
        @lock.synchronize do
          it = (@items[d] ||= { "text" => text, "state" => :new, "prio" => prio })
          touch(d)
          it["at"] = @clock.call
          it["prio"] = [it["prio"].to_i, prio].max
          if queue && %i[new failed].include?(it["state"])
            it["state"] = :queued
            start_worker
            @cond.broadcast
          end
          forget_texts
        end
        d
      end

      def known?(d) = @lock.synchronize { @items.key?(d) }

      # The WAV of a digest, synthesised now if it was not (waits up to
      # wait_s). nil: unknown, or the engine failed.
      def fetch(d, wait_s: WAIT_S)
        return nil unless d.to_s.match?(ID)
        deadline = @clock.call + wait_s
        @lock.synchronize do
          it = @items[d] or return nil
          if %i[new failed].include?(it["state"])
            it["state"] = :queued
            it["prio"] = 9 # asked for: next
            it["at"] = @clock.call
            start_worker
            @cond.broadcast
          end
          until %i[done failed].include?(it["state"])
            left = deadline - @clock.call
            return nil if left <= 0
            @cond.wait(left)
          end
          return nil unless it["state"] == :done
          touch(d)
          it["wav"]
        end
      end

      def stop
        @lock.synchronize do
          @stop = true
          @cond.broadcast
        end
        @worker&.join(2)
      end

      private

      def start_worker
        return if @worker&.alive?
        @worker = Thread.new { work }
      end

      def work
        loop do
          d = it = nil
          @lock.synchronize do
            loop do
              return if @stop
              now = @clock.call
              # A small line nobody asked for, left too long: not now.
              @items.each_value do |x|
                x["state"] = :new if x["state"] == :queued && x["prio"] < 2 && now - x["at"] > STALE_S
              end
              d, it = @items.select { |_, x| x["state"] == :queued }.max_by { |_, x| [x["prio"], -x["at"]] }
              break if d
              @cond.wait(5)
            end
            it["state"] = :working
          end
          wav = nil
          begin
            wav = @client.synthesize(it["text"], @id)
          rescue StandardError => e
            @log&.call("voice: #{e.message}")
          end
          @lock.synchronize do
            if wav
              it["wav"] = wav
              it["state"] = :done
              @bytes += wav.bytesize
              @synthesized += 1
              touch(d) # the newest: never the one evicted now
              evict
            else
              it["state"] = :failed
            end
            @cond.broadcast
          end
        end
      end

      def touch(d)
        it = @items.delete(d)
        @items[d] = it if it
      end

      # The least recently used WAVs out, past the limits (their texts stay:
      # asked again, they are made again).
      def evict
        done = @items.select { |_, x| x["state"] == :done }
        while done.size > @max_entries || @bytes > @max_bytes
          d, x = done.first
          break unless d
          @bytes -= x["wav"].bytesize
          x["wav"] = nil
          x["state"] = :new
          done.delete(d)
        end
      end

      def forget_texts
        while @items.size > @max_texts
          d, x = @items.find { |_, i| %i[new failed].include?(i["state"]) }
          break unless d
          @items.delete(d)
          @bytes -= x["wav"].to_s.bytesize
        end
      end
    end

    # The voice of the commentary: VOICEVOX's character (the fixed phrases
    # and the live lines) when the engine is there, else the browser's own
    # voice (status says which, the page shows the credit).
    class Voice
      attr_reader :client, :speaker, :style, :id, :bank, :live, :tone, :engine_version

      # Looks for the engine (GET /version) and the style's number. nil
      # when the engine is not there (the browser's voice reads);
      # Voicevox::NotFound when the character or the style is not.
      def self.connect(url:, speaker:, style:, root: ClipBank.cache_root, log: nil, list: ClipBank.load_list)
        client = Voicevox.new(url)
        begin
          version = client.version
        rescue Voicevox::Error
          return nil
        end
        id = client.style_id(speaker, style)
        new(client, speaker, style, id, version: version, root: root, log: log, list: list)
      end

      def initialize(client, speaker, style, id, version: nil, root: ClipBank.cache_root, log: nil, list: ClipBank.load_list)
        @client = client
        @speaker = speaker
        @style = style
        @id = id
        @engine_version = version
        @log = log
        @tone = MahjongPhrases.tone_for(speaker)
        @bank = ClipBank.new(ClipBank.dir_for(speaker, style, root: root), tone: @tone, list: list, client: client,
                                                                            id: id, credit: credit)
        @live = LiveVoice.new(client, id, log: log)
      end

      def credit = "VOICEVOX:#{@speaker}"

      # What the page is told.
      def status
        { "engine" => "voicevox", "speaker" => @speaker, "style" => @style, "credit" => credit,
          "start" => (f = @bank.pick("start")) ? "/clip/#{f}" : nil }
      end

      # Makes the missing fixed phrases in a thread (the commentary starts
      # meanwhile; a phrase not made yet is not played).
      def make_missing_async
        n = @bank.missing.size
        return nil if n.zero?
        @log&.call("voice: making #{n} fixed phrase(s) in #{@bank.dir}")
        Thread.new do
          made, = @bank.make!
          @log&.call("voice: #{made} fixed phrase(s) made")
        rescue StandardError => e
          @log&.call("voice: the fixed phrases: #{e.message}")
        end
      end

      # The voice of a line: the fixed phrases to play first (their URLs),
      # then the rest of the line synthesised (its URL; the speech without
      # the words the phrases said). "plive": the same with the hands hidden.
      def plan(line, rng = Random.new)
        files = Array(line["clips"]).map { |k| [k, @bank.pick(k, rng)] }.select { |_, f| f }
        words = files.map { |k, _| @bank.word(k) }
        out = { "clips" => files.map { |_, f| "/clip/#{f}" } }
        s = Voice.after(line["speech"], words)
        out["live"] = s.empty? ? nil : "/voice/#{@live.register(s, prio: line['prio'].to_i)}.wav"
        if line.key?("pspeech")
          ps = line["pspeech"] && Voice.after(line["pspeech"], words)
          out["plive"] = if ps.nil? || ps.empty? then nil
                         elsif ps == s then out["live"]
                         else "/voice/#{@live.register(ps, prio: line['prio'].to_i, queue: false)}.wav"
                         end
        end
        out
      end

      # The speech without the words the fixed phrases just said, when it
      # begins with them (ロン CPU1、… after ロン！ is CPU1、…).
      def self.after(speech, words)
        s = speech.to_s.strip
        words.compact.each do |w|
          s = s.sub(/\A#{Regexp.escape(w)}(なのだ|です)?[！!、。,.\s]*/, "")
        end
        s.strip
      end

      def clip(file) = @bank.read(file)

      def wav(file)
        d = file.to_s.delete_suffix(".wav")
        @live.fetch(d)
      end

      def stop = @live.stop
    end
  end
end
