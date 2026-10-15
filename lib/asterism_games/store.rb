# frozen_string_literal: true

require "json"
require "fileutils"

module AsterismGames
  # Saved states, one JSON file per game object in a directory. A write goes
  # to a temporary file first and is renamed over the old one, so a host
  # killed in the middle leaves the previous state, never half of one.
  class Store
    attr_reader :dir

    def initialize(dir)
      @dir = dir
      FileUtils.mkdir_p(dir)
    end

    def path(name)
      File.join(@dir, "#{name}.json")
    end

    def write(name, data)
      p = path(name)
      tmp = "#{p}.tmp"
      File.open(tmp, "w") do |f|
        f.write(JSON.generate(data))
        f.flush
        f.fsync
      end
      File.rename(tmp, p)
    end

    def read(name)
      p = path(name)
      return nil unless File.exist?(p)
      JSON.parse(File.read(p))
    end
  end
end
