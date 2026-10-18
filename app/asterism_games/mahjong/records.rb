# frozen_string_literal: true

require "asterism_games/record_book"

module AsterismGames
  module Mahjong
    # Game records (README "Game records"): every game a table plays to its
    # end is kept as a record in the table's book (AsterismGames::RecordBook):
    # the SQLite database the host gives (state_dir/records.sqlite3, shared
    # by the rooms' and the permanent tables' hosts; the RECORDS_KEPT_DB
    # newest of a table, a room's kept when it closes; a room made from an
    # invite link lists the games of the rooms of the same link too), or
    # without the sqlite3 gem the JSON file next to the table's saved state (the
    # RECORDS_KEPT newest, a room's go with the room). A game in progress is
    # never shown; its record so far is part of the table's saved state, so
    # a host started again goes on with it. The stats (stats_answer) count
    # the players' games from the book's summaries.
    #
    # A record holds the deals, the dora indicators, every draw and discard,
    # the calls, riichi, the wins and draws and the points, in the tile
    # names of look ("1m".."9m", "0m" a red five, "1z".."7z"). The remote's
    # records and record give them out, each answer within one message a
    # board can take (RECORD_BYTES): records in pages, a game as its
    # head (record(id)) and its rounds one by one (record(id, round)), a
    # long round in parts (record(id, round, part)). Included in Table.
    module Records
      RECORDS_KEPT = 20      # the JSON form
      RECORDS_KEPT_DB = 1000 # SQLite: of a table (the rooms' tables of one name together)
      RECORDS_FORMAT = 1
      # The most an answer may take (MessagePack), leaving room under the
      # 4096 B of a board's message for the reply's frame and the key.
      RECORD_BYTES = 3300
      PAGE_READ = 24 # records read at a time for a page of records
      MOVE_NAMES = { chi: "chi", pon: "pon", daiminkan: "open_kan", ankan: "closed_kan", kakan: "added_kan" }.freeze

      # ------------------------------------------------------------ keeping

      # The book (AsterismGames::RecordBook): SQLite when the host gives a
      # database (records_db) and the sqlite3 gem is there, else the JSON
      # file of before 0.14.0. A table that finds its JSON records next to
      # a database takes them in once, and the file is renamed
      # (<table>.records.json.imported) so nothing reads it again.
      def init_records
        @rec = nil      # the game being played
        @rec_draw = nil # [seat, tile] of the last draw (a discard of it is tsumogiri)
        @book = RecordBook.open(db: @opts["records_db"], game: "mahjong", table: @name,
                                place: @opts["records_place"] || (@opts["room_id"] ? "room" : "lan"),
                                room: @opts["room_id"], group: @opts["records_group"], store: @store,
                                kept: records_kept(RECORDS_KEPT_DB), json_kept: records_kept(RECORDS_KEPT),
                                summarize: method(:record_summary), log: @log)
        import_json_records if @book.kind == "sqlite"
      end

      attr_reader :book

      def records_name
        "#{@name}.records"
      end

      def import_json_records
        path = @store&.path(records_name)
        return unless path && File.file?(path)
        d = JSON.parse(File.read(path))
        games = d.is_a?(Hash) && d["format"] == RECORDS_FORMAT ? Array(d["games"]) : []
        n = @book.import(games)
        File.rename(path, "#{path}.imported")
        @log&.call("mahjong: #{@name}: #{n} records taken into #{File.basename(@opts['records_db'].to_s)} " \
                   "(#{File.basename(path)} renamed to #{File.basename(path)}.imported)")
      rescue JSON::ParserError, SystemCallError => e
        @log&.call("mahjong: #{@name}: records: #{e.class}: #{e.message}")
      end

      def records_kept(default = RECORDS_KEPT)
        (@opts["records_kept"] || default).to_i
      end

      # A game starts (Table#start_game): its record begins.
      def record_game_start
        r = @rule.to_h
        @rec = { "started" => Time.now.to_i, "table" => @name,
                 "game" => r["game_type"].to_s.start_with?("tonpuu") ? "tonpuu" : "hanchan",
                 "rules" => rules_look, "names" => @seats.map { |s| s ? s["name"].to_s : "" },
                 "kinds" => (0..3).map { |i| seat_look(i, nil)["kind"] },
                 "ais" => @seats.map { |x| x && x["ai"] ? x["ai"].to_s : "" }, "rounds" => [] }
      end

      # A round is dealt (Table#new_round): the scores, the dora indicator
      # and the four hands as they start.
      def record_round_start
        return unless @rec
        st = @state
        @rec_draw = nil
        @rec["rounds"] << {
          "wind" => Readable::WINDS[Engine::BAKAZE.index(st.bakaze.to_s)], "number" => st.kyoku,
          "honba" => st.honba, "riichi_sticks" => st.kyoutaku, "dealer" => st.oya_seat,
          "scores" => (0..3).map { |s| st.scores[s] }, "dora_indicators" => st.dora_hyouji.map(&:to_s),
          "hands" => (0..3).map { |s| Tiles.sort(st.hands[s].tiles.map(&:to_s)) }, "moves" => []
        }
      end

      def rec_moves
        @rec && @rec["rounds"].last && @rec["rounds"].last["moves"]
      end

      # What the state was before an action (Table#apply), for record_move.
      def record_before(action)
        return nil unless rec_moves
        seat = action[:seat]
        { dora: @state.dora_hyouji.size, discard: @state.last_dahai && @state.last_dahai.dup,
          hand: seat ? @state.hands[seat].tiles.map(&:to_s) : nil }
      end

      # One action applied: its move(s) in the record.
      def record_move(action, before)
        moves = rec_moves
        return unless moves && before
        st = @state
        type = action[:type].to_sym
        seat = action[:seat]
        draw = nil
        got = nil
        case type
        when :tsumo
          if st.last_tsumo
            draw = [st.current_seat, st.last_tsumo.to_s]
            moves << [draw[0], "draw", draw[1]]
          end
        when :dahai, :riichi
          # The tile as it lies in the river (an action naming a five may
          # take the red one).
          k = st.kawas[seat].tiles.last
          tile = k ? k.tile.to_s : action[:tile].to_s
          m = [seat, type == :riichi ? "riichi" : "discard", tile]
          m << true if @rec_draw == [seat, tile] # tsumogiri: the tile just drawn
          moves << m
        when :chi, :pon, :daiminkan
          gone, got = hand_change(before[:hand], seat)
          d = before[:discard]
          moves << [seat, MOVE_NAMES[type], d ? d[:tile].to_s : nil, gone, d ? d[:seat] : nil]
        when :ankan
          gone, got = hand_change(before[:hand], seat)
          moves << [seat, "closed_kan", gone]
        when :kakan
          gone, got = hand_change(before[:hand], seat)
          moves << [seat, "added_kan", gone.first || action[:tile].to_s]
        when :kyuushu_kyuuhai
          moves << [seat, "nine_kinds"]
        when :sanchahou
          d = before[:discard]
          Array(action[:seats]).each { |s| moves << [s, "ron", d && d[:tile].to_s, d && d[:seat]] }
        end
        # A kan draws its replacement tile in the same action.
        if got && !got.empty?
          draw = [seat, got.first]
          moves << [seat, "draw", got.first]
        end
        @rec_draw = draw
        st.dora_hyouji[before[:dora]..].to_a.each { |t| moves << [-1, "dora", t.to_s] }
      end

      # How a seat's hand changed by a call: [the tiles that left it (the
      # hand before less the hand now), the tiles that came (a kan's
      # replacement draw)], as names.
      def hand_change(before, seat)
        left = @state.hands[seat].tiles.map(&:to_s)
        gone = []
        before.to_a.each do |t|
          i = left.index(t)
          if i then left.delete_at(i) else gone << t end
        end
        [Tiles.sort(gone), left]
      end

      # A round ended (Table#finish_round, after scoring): the wins, the
      # result and the points after it.
      def record_round_end(res)
        moves = rec_moves
        return unless moves
        st = @state
        Array(res["wins"]).each do |w|
          moves << (res["kind"] == "ron_agari" ? [w["winner"], "ron", w["agari"], res["from"]] : [w["winner"], "tsumo", w["agari"]])
        end
        out = { "kind" => res["kind"], "changes" => res["delta"] }
        out["from"] = res["from"] unless res["from"].nil?
        if res["wins"]
          out["wins"] = res["wins"].map do |w|
            x = { "seat" => w["winner"], "yaku" => w["yaku"], "han" => w["han"], "fu" => w["fu"],
                  "points" => w["points"], "hand" => w["hand"], "tile" => w["agari"] }
            x["yaku_han"] = w["yaku_han"] if w["yaku_han"]
            x["pao"] = w["pao"] if w["pao"]
            x
          end
          ura = Array(st.uradora_hyouji).first(st.dora_hyouji.size).map(&:to_s)
          out["ura_indicators"] = ura unless ura.empty?
        end
        out["tenpai"] = res["tenpai"] if res["tenpai"]
        out["nagashi"] = res["nagashi"] if res["nagashi"]
        out["ron_seats"] = res["ron_seats"] if res["ron_seats"]
        r = @rec["rounds"].last
        r["result"] = out
        r["end_scores"] = (0..3).map { |s| st.scores[s] }
        r["end_sticks"] = st.kyoutaku
      end

      # The game ended (Table#next_round): the record goes into the book
      # (which gives it its id and time, and keeps the newest).
      def record_game_end
        return unless @rec
        rec = @rec
        @rec = nil
        rec.delete("started")
        rec["final"] = @final
        rec["reason"] = @final_reason
        id = @book.add(rec)
        @log&.call("mahjong: #{@name}: record #{id} kept (#{rec['rounds'].size} rounds, #{@book.kind})")
      rescue StandardError => e
        @log&.call("mahjong: #{@name}: the record was not kept: #{e.class}: #{e.message}")
      end

      # What the stats count of a record (RecordBook's summary): the game,
      # and for each seat its name, kind (human, cpu, or the AI player's:
      # claude, jev), rank, score, points (x 10), and the rounds, wins,
      # deal-ins (the seat a ron came from; once a round at a double ron)
      # and riichi it had.
      def record_summary(rec)
        final = Array(rec["final"]).to_h { |seat, rank, score, pt| [seat, [rank, score, pt]] }
        rounds = Array(rec["rounds"])
        counts = (0..3).map { { "rounds" => rounds.size, "wins" => 0, "dealins" => 0, "riichi" => 0 } }
        rounds.each do |r|
          Array(r["moves"]).each { |m| counts[m[0]]["riichi"] += 1 if m[1] == "riichi" && m[0].between?(0, 3) }
          res = r["result"] || {}
          Array(res["wins"]).each { |w| counts[w["seat"]]["wins"] += 1 if w["seat"].to_i.between?(0, 3) }
          counts[res["from"]]["dealins"] += 1 if res["kind"] == "ron_agari" && res["from"].is_a?(Integer) && res["from"].between?(0, 3)
        end
        names = Array(rec["names"])
        seats = (0..3).map do |s|
          rank, score, pt = final[s]
          { "seat" => s, "name" => names[s].to_s, "kind" => record_kind(rec, s), "rank" => rank, "score" => score,
            "points" => pt, "counts" => counts[s] }
        end
        { "variant" => rec["game"], "reason" => rec["reason"], "rounds" => rounds.size, "seats" => seats }
      end

      # A seat's kind for the stats: human, cpu, or the AI player's (a
      # record before 0.14.0 has no "ais": the AI player's name tells).
      def record_kind(rec, s)
        k = Array(rec["kinds"])[s].to_s
        return k unless k == "ai"
        ai = Array(rec["ais"])[s].to_s
        return ai unless ai.empty?
        name = Array(rec["names"])[s].to_s
        AI::LABELS.find { |_k, label| name.start_with?(label) }&.first || "ai"
      end

      # ------------------------------------------------------------ the answers

      # The finished games, newest first, from the from-th: {"records" =>
      # [{"id", "at", "game", "names", "ranks", "scores"}, ...], "total",
      # "next" (the from of the next page, when there is more)}.
      def records_page(from = 0)
        total = @book.size
        from = from.to_i.clamp(0, total)
        out = { "records" => [], "total" => total }
        i = from
        full = false
        until full || i >= total
          batch = @book.list(i, PAGE_READ)
          break if batch.empty?
          batch.each do |rec, _s|
            out["records"] << record_entry(rec)
            if wire_size(out) > RECORD_BYTES
              out["records"].pop
              full = true
              break
            end
            i += 1
          end
        end
        out["next"] = i if i < total
        out
      end

      def record_entry(rec)
        ranks = [0, 0, 0, 0]
        scores = [0, 0, 0, 0]
        Array(rec["final"]).each do |seat, rank, score, _pt|
          ranks[seat] = rank
          scores[seat] = score
        end
        { "id" => rec["id"], "at" => rec["at"], "game" => rec["game"], "names" => rec["names"], "ranks" => ranks,
          "scores" => scores }
      end

      def record_of(id)
        @book.get(id)
      end

      # One game: record(id) its head, record(id, round) a round,
      # record(id, round, part) a part of a long round (README "Game records").
      def record_answer(id, round = nil, part = nil)
        rec = record_of(id)
        return { "error" => "no record" } unless rec
        return record_head(rec) if round.nil?
        r = rec["rounds"][round.to_i] if round.to_i >= 0
        return { "error" => "no round" } unless r
        parts = round_parts(rec, round.to_i, r)
        part = part.to_i
        return { "error" => "no part" } unless (0...parts.size).cover?(part)
        parts[part]
      end

      def record_head(rec)
        out = rec.slice("id", "at", "time", "table", "game", "rules", "names", "kinds", "final", "reason")
        out["rounds"] = rec["rounds"].map do |r|
          res = r["result"] || {}
          [r["wind"], r["number"], r["honba"], res["kind"], res["changes"]]
        end
        out
      end

      # A round as one answer, or in parts when it is too big for one: the
      # first part has everything but the moves past it, the others the
      # moves that follow ("move_from": the index of their first move).
      def round_parts(rec, n, r)
        head = { "id" => rec["id"], "round" => n, "of" => rec["rounds"].size }
        whole = head.merge(r).merge("part" => 0, "parts" => 1)
        return [whole] if wire_size(whole) <= RECORD_BYTES
        moves = r["moves"]
        parts = []
        first = head.merge(r.reject { |k, _| k == "moves" }).merge("part" => 0, "move_from" => 0, "moves" => [])
        cur = first
        moves.each_with_index do |m, i|
          cur["moves"] << m
          next unless wire_size(cur) > RECORD_BYTES && cur["moves"].size > 1
          cur["moves"].pop
          parts << cur
          cur = head.merge("part" => parts.size, "move_from" => i, "moves" => [m])
        end
        parts << cur
        parts.each { |p| p["parts"] = parts.size }
        parts
      end

      # What the most recent game came to (the host's @status, README
      # "Status"): its id, when, and the four in rank order as [name,
      # rank, score]. The names are those the table shows anyway.
      def last_result
        rec, = @book.last
        return nil unless rec
        list = Array(rec["final"]).sort_by { |f| f[1] }.map { |seat, rank, score, _| [rec["names"][seat].to_s, rank, score] }
        { "id" => rec["id"], "at" => rec["at"], "game" => rec["game"], "result" => list }
      end

      # ------------------------------------------------------------ stats

      STATS_VARIANTS = %w[hanchan tonpuu].freeze
      STATS_SCOPES = %w[all table].freeze

      # The players' stats (README "Stats"): days (0: every game kept, else
      # the last days), variant ("" both, "hanchan", "tonpuu"), scope ("all":
      # every game of the database, closed rooms and the other tables too;
      # "table": this table's games, in a room the room's), from (the page).
      # {"rows" => [...], "games" (how many games), "total" (rows), "next",
      # "days", "variant", "scope", "store"}. A row: "kind" (human, cpu,
      # claude, jev), "name" (a person's; the kind's label otherwise),
      # "games", "ranks" ([1st, 2nd, 3rd, 4th]), "avg_rank", "top_rate",
      # "rounds", "wins", "dealins", "riichi", "win_rate", "dealin_rate",
      # "riichi_rate" (of the rounds), "avg_score", "points" (the sum of
      # the rank points). Names and numbers only: a record itself is never
      # given out here.
      def stats_answer(days = 0, variant = "", scope = "all", from = 0, now = Time.now)
        days = days.to_i.clamp(0, 36_500)
        variant = STATS_VARIANTS.include?(variant.to_s) ? variant.to_s : ""
        scope = STATS_SCOPES.include?(scope.to_s) ? scope.to_s : "all"
        since = days.positive? ? now.to_i - (days * 86_400) : nil
        rows = @book.stat_rows(since: since, variant: variant.empty? ? nil : variant, everything: scope == "all")
        list = RecordBook.aggregate(rows).map { |e| stats_row(e) }
        out = { "rows" => [], "games" => rows.size / 4, "total" => list.size, "days" => days, "game" => variant,
                "scope" => scope, "store" => @book.kind }
        i = from.to_i.clamp(0, list.size)
        while i < list.size
          out["rows"] << list[i]
          if wire_size(out) > RECORD_BYTES
            out["rows"].pop
            break
          end
          i += 1
        end
        out["next"] = i if i < list.size
        out
      end

      def stats_row(e)
        g = e["games"]
        c = e["counts"]
        rounds = c["rounds"].to_i
        rate = ->(n) { rounds.zero? ? 0.0 : (n.to_f / rounds).round(3) }
        rank_sum = e["ranks"].each_with_index.sum { |n, i| n * (i + 1) }
        name = e["kind"] == "human" ? e["name"] : (e["kind"] == "cpu" ? "CPU" : (AI::LABELS[e["kind"]] || e["kind"].capitalize))
        { "kind" => e["kind"], "name" => name, "games" => g, "ranks" => e["ranks"],
          "avg_rank" => g.zero? ? 0.0 : (rank_sum.to_f / g).round(2), "top_rate" => g.zero? ? 0.0 : (e["ranks"][0].to_f / g).round(3),
          "rounds" => rounds, "wins" => c["wins"].to_i, "dealins" => c["dealins"].to_i, "riichi" => c["riichi"].to_i,
          "win_rate" => rate.call(c["wins"].to_i), "dealin_rate" => rate.call(c["dealins"].to_i),
          "riichi_rate" => rate.call(c["riichi"].to_i),
          "avg_score" => g.zero? ? 0 : (e["score"].to_f / g).round, "points" => (e["points"] / 10.0).round(1) }
      end

      def wire_size(obj)
        return ::Asterism::Codec.pack(obj).bytesize if defined?(::Asterism::Codec)
        JSON.generate(obj).bytesize
      end
    end
  end
end
