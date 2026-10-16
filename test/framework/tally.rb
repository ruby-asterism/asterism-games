# frozen_string_literal: true

require "asterism_games"

# The smallest game on the framework, for its tests: members press a
# counter until it reaches the goal; every step_ms with presses since the
# last step counts as a round. Nothing of it is mahjong's.
module Tally
  # The exposed object: join, mine and leave come from the framework.
  class Remote < AsterismGames::Remote
    exposes press: 2, view: 1, table: 0

    def press(token, n, from:)
      mark(token, from)
      @game.press(token, n.to_i, now)
    end

    def view(token, from:)
      mark(token, from)
      @game.member_view(token, now) || { "error" => "token" }
    end

    def table(from:)
      @game.public_view(now)
    end
  end

  class Table < AsterismGames::Game
    register "tally"
    remote Remote
    tables "tally1", "tally2"
    screens "/app/test/tally.app.rb"
    settings file: { "goal" => ["goal", 1], "step_seconds" => ["step_ms", 1000] },
             env: { "TALLY_GOAL" => ["goal", 1] }

    SAVE_FORMAT = 1
    DEFAULTS = AsterismGames::Game::DEFAULTS.merge("goal" => 10, "step_ms" => 1000).freeze

    attr_reader :count, :rounds

    def initialize(name, opts = {}, store: nil, log: nil)
      super
      @count = 0
      @rounds = 0
      @pressed = false
      @next_at = nil
      load_saved(0)
    end

    def press(token, n, now)
      return "token" unless node_of(token)
      return "over" if over?
      @count += n
      @pressed = true
      @next_at ||= now + @opts["step_ms"]
      changed
      "ok"
    end

    def over? = @count >= @opts["goal"]

    def tick(now)
      super
      expire_members(now)
      return unless @next_at && now >= @next_at
      @rounds += 1 if @pressed
      @pressed = false
      @next_at = over? ? nil : now + @opts["step_ms"]
      changed
    end

    def public_view(now)
      { "v" => @ver, "t" => @name, "st" => over? ? "over" : "play", "n" => @count, "goal" => @opts["goal"],
        "r" => @rounds, "mb" => @members.size }
    end

    # A member's own view: the public one and its name.
    def member_view(token, now)
      node = node_of(token) or return nil
      public_view(now).merge("me" => @members[node]["name"])
    end

    def summary(now)
      away = @members.keys.count { |n| member_away?(n) }
      super.merge("st" => over? ? "over" : "play", "humans" => @members.size, "away" => away, "n" => @count)
    end

    def to_saved(now)
      super.merge("count" => @count, "rounds" => @rounds, "next_left" => @next_at && [@next_at - now, 0].max)
    end

    def restore(data, now)
      super
      @count = data["count"].to_i
      @rounds = data["rounds"].to_i
    end

    def resume_clock(now, data = saved)
      return unless data
      @next_at = data["next_left"] && now + data["next_left"]
      super
    end
  end
end
