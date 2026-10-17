# frozen_string_literal: true

require_relative "ai"

module AsterismGames
  module AI
    # The host's side of the AI players: takes the decisions the tables ask
    # for (game.ai_requests, under the host's lock), asks the deciders on
    # threads of its own (never holding the lock while an API thinks),
    # counts what they cost (Budget) and hands the answers back
    # (game.ai_answer, under the lock again, on the host's next step).
    #
    # The tables learn which AI players they may offer (game.ai_kinds=):
    # those with a decider, none once today's money is spent; then the AI
    # seats already taken are played by the CPU (game.ai_off!).
    class Hub
      attr_reader :stats, :budget, :deciders

      def initialize(deciders, budget, calls_per_game: 400, threads: 4, log: nil)
        @deciders = deciders
        @budget = budget
        @calls_per_game = calls_per_game
        @log = log
        @jobs = Queue.new
        @results = Queue.new
        @stats = Hash.new(0)
        @times = []          # ms of each answered decision (the last 5000)
        @over = nil
        @threads = Array.new(@deciders.empty? ? 0 : threads) { Thread.new { work } }
      end

      def any? = !@deciders.empty?

      # The kinds a table may offer now.
      def kinds
        return [] if @deciders.empty? || @over
        @deciders.keys
      end

      # One pass (on the host's loop, under its lock): the limit, the
      # answers that came, the new requests.
      def step(games, now)
        return if @deciders.empty?
        over = @budget.over?
        if over != @over
          @over = over
          if over
            @log&.call("games: AI players: today's limit of $#{@budget.daily_usd} is reached; " \
                       "no more AI players today, those seated are played by the CPU")
          end
        end
        k = kinds
        games.each_value do |g|
          next unless g.respond_to?(:ai_requests)
          g.ai_kinds = k
          g.ai_calls_per_game = @calls_per_game
          g.ai_off!("today's limit") if over
        end
        until @results.empty?
          table, seat, key, n = @results.pop
          g = games[table]
          g&.ai_answer(seat, key, n, now)
        end
        return if over
        games.each do |name, g|
          next unless g.respond_to?(:ai_requests)
          g.ai_requests(now).each do |r|
            @stats["asked"] += 1
            @jobs << [name, r[:seat], r[:key], r[:kind], r[:request], r[:until]]
          end
        end
      end

      # Stops the threads (the host is stopping).
      def stop
        @threads.size.times { @jobs << nil }
        @threads.each { |t| t.join(1) }
      end

      # The decision times (ms) answered so far: [count, average, max].
      def times
        return [0, 0, 0] if @times.empty?
        [@times.size, (@times.sum / @times.size.to_f).round, @times.max]
      end

      private

      def work
        while (job = @jobs.pop)
          table, seat, key, kind, request, until_ms = job
          left = (until_ms - Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)) / 1000.0
          if left <= 0
            @stats["late"] += 1
            @results << [table, seat, key, nil]
            next
          end
          n = decide(kind, request, left)
          @results << [table, seat, key, n]
        end
      rescue StandardError => e
        @log&.call("games: AI players: a worker stopped: #{e.class}")
      end

      # Asks one decider; the move number, or nil (failed).
      def decide(kind, request, left)
        d = @deciders[kind].decide(request, timeout: left)
        @budget.record(kind, d.tokens || {})
        @stats["answered"] += 1
        @stats["answered_#{kind}"] += 1
        if d.ms
          @times << d.ms
          @times.shift if @times.size > 5000
        end
        d.n
      rescue TokenError => e
        @budget.record(kind, e.tokens)
        failed(kind, e.message)
      rescue Error => e
        @budget.record_failure(kind)
        failed(kind, e.message)
      rescue StandardError => e
        # Nothing of a library's message (it could carry a request's
        # details): the class only.
        @budget.record_failure(kind)
        failed(kind, e.class.name)
      end

      def failed(kind, why)
        @stats["failed"] += 1
        @stats["failed_#{kind}"] += 1
        @log&.call("games: AI player #{kind}: #{why}; the CPU plays this move")
        nil
      end
    end
  end
end
