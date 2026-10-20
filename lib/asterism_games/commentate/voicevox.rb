# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module AsterismGames
  module Commentate
    # The VOICEVOX engine's HTTP (README "Commentary", "The voice"): a free
    # Japanese speech synthesiser running on this machine (the VOICEVOX app
    # or its engine in docker). The standard library's net/http only.
    #
    #   vv = Voicevox.new("http://127.0.0.1:50021")
    #   vv.version                        # => "0.25.0" (raises Voicevox::Error when it is not there)
    #   id = vv.style_id("ずんだもん", "ノーマル")   # the number from /speakers, never assumed
    #   wav = vv.synthesize("リーチなのだ！", id)    # the WAV's bytes
    class Voicevox
      DEFAULT_URL = "http://127.0.0.1:50021"

      # The engine is not there, or said no.
      class Error < StandardError; end

      # No such character or style: the message lists what there is.
      class NotFound < Error
        attr_reader :candidates

        def initialize(message, candidates)
          super(message)
          @candidates = candidates
        end
      end

      attr_reader :url

      def initialize(url = DEFAULT_URL, open_timeout: 2, read_timeout: 60)
        @url = url.to_s.empty? ? DEFAULT_URL : url.to_s.chomp("/")
        @uri = URI(@url)
        raise Error, "#{@url}: not an http:// URL" unless @uri.is_a?(URI::HTTP) && @uri.host
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      # GET /version: the engine's version (a JSON string).
      def version
        v = JSON.parse(request(:get, "/version").force_encoding("UTF-8"))
        v.is_a?(String) ? v : v.to_s
      rescue JSON::ParserError => e
        raise Error, "#{@url}/version: #{e.message}"
      end

      # GET /speakers: [{"name", "styles" => [{"name", "id"}]}], as the engine
      # says them.
      def speakers
        list = JSON.parse(request(:get, "/speakers").force_encoding("UTF-8"))
        raise Error, "#{@url}/speakers: not a list" unless list.is_a?(Array)
        list.map do |s|
          { "name" => s["name"].to_s,
            "styles" => Array(s["styles"]).map { |st| { "name" => st["name"].to_s, "id" => st["id"] } } }
        end
      rescue JSON::ParserError => e
        raise Error, "#{@url}/speakers: #{e.message}"
      end

      # The style's number, looked up by the character's and the style's
      # names. NotFound lists the characters (or the character's styles).
      def style_id(speaker, style, list = speakers)
        s = list.find { |x| x["name"] == speaker }
        unless s
          raise NotFound.new("VOICEVOX has no character #{speaker.inspect} (there are: #{list.map { |x| x['name'] }.join(', ')})",
                             list.map { |x| x["name"] })
        end
        st = s["styles"].find { |x| x["name"] == style }
        unless st
          names = s["styles"].map { |x| x["name"] }
          raise NotFound.new("#{speaker} has no style #{style.inspect} (there are: #{names.join(', ')})", names)
        end
        st["id"]
      end

      # POST /audio_query then POST /synthesis: the WAV of text in style id.
      def synthesize(text, id)
        q = request(:post, "/audio_query?#{URI.encode_www_form(text: text, speaker: id)}", "")
        wav = request(:post, "/synthesis?#{URI.encode_www_form(speaker: id)}", q, "Content-Type" => "application/json")
        raise Error, "#{@url}/synthesis: not a WAV" unless wav.start_with?("RIFF")
        wav
      end

      private

      def request(method, path, body = nil, headers = {})
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @read_timeout if http.respond_to?(:write_timeout=)
        res = http.start do |h|
          method == :get ? h.get(path) : h.post(path, body.to_s, headers)
        end
        raise Error, "#{@url}#{path[/\A[^?]*/]}: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
        res.body.to_s.b
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "#{@url}: #{e.class}: #{e.message}"
      end
    end
  end
end
