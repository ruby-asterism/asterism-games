# frozen_string_literal: true

module AsterismGames
  module Mahjong
    # Game records (README "Game records"): every game a table plays to its
    # end is kept as a record, the RECORDS_KEPT newest of each table, in the
    # table's place in the store (its own file "<table>.records", next to
    # the table's saved state: state_dir on a LAN, state_dir/permanent for
    # the permanent tables, state_dir/rooms/<slot> in a room, which goes
    # with the room). A game in progress is never shown; its record so far
    # is part of the table's saved state, so a host started again goes on
    # with it.
    #
    # A record holds the deals, the dora indicators, every draw and discard,
    # the calls, riichi, the wins and draws and the points, in the tile
    # names of look ("1m".."9m", "0m" a red five, "1z".."7z"). The remote's
    # records and record give them out, each answer within one message a
    # board can take (RECORD_BYTES): records in pages, a game as its
    # head (record(id)) and its rounds one by one (record(id, round)), a
    # long round in parts (record(id, round, part)). Included in Table.
    module Records
      RECORDS_KEPT = 20
      RECORDS_FORMAT = 1
      # The most an answer may take (MessagePack), leaving room under the
      # 4096 B of a board's message for the reply's frame and the key.
      RECORD_BYTES = 3300
      MOVE_NAMES = { chi: "chi", pon: "pon", daiminkan: "open_kan", ankan: "closed_kan", kakan: "added_kan" }.freeze

      # ------------------------------------------------------------ keeping

      def init_records
        @records = []   # the finished games, oldest first
        @rec_seq = 0    # the last record's id
        @rec = nil      # the game being played
        @rec_draw = nil # [seat, tile] of the last draw (a discard of it is tsumogiri)
        load_records
      end

      def records_name
        "#{@name}.records"
      end

      def load_records
        d = @store&.read(records_name)
        return unless d.is_a?(Hash) && d["format"] == RECORDS_FORMAT
        @records = Array(d["games"])
        @rec_seq = d["seq"].to_i
      rescue JSON::ParserError, SystemCallError => e
        @log&.call("mahjong: #{@name}: records: #{e.class}: #{e.message}")
      end

      def save_records
        @store&.write(records_name, { "format" => RECORDS_FORMAT, "seq" => @rec_seq, "games" => @records })
      end

      def records_kept
        (@opts["records_kept"] || RECORDS_KEPT).to_i
      end

      # A game starts (Table#start_game): its record begins.
      def record_game_start
        r = @rule.to_h
        @rec = { "started" => Time.now.to_i, "table" => @name,
                 "game" => r["game_type"].to_s.start_with?("tonpuu") ? "tonpuu" : "hanchan",
                 "rules" => rules_look, "names" => @seats.map { |s| s ? s["name"].to_s : "" },
                 "kinds" => (0..3).map { |i| seat_look(i, nil)["kind"] }, "rounds" => [] }
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

      # The game ended (Table#next_round): the record is kept, the oldest
      # beyond records_kept goes, and the records are written.
      def record_game_end
        return unless @rec
        rec = @rec
        @rec = nil
        now = Time.now
        rec["id"] = (@rec_seq += 1)
        rec["at"] = now.strftime("%Y-%m-%d %H:%M")
        rec["time"] = now.to_i
        rec["final"] = @final
        rec["reason"] = @final_reason
        @records << rec
        @records.shift while @records.size > records_kept
        save_records
        @log&.call("mahjong: #{@name}: record #{rec['id']} kept (#{rec['rounds'].size} rounds, #{@records.size} kept)")
      end

      # ------------------------------------------------------------ the answers

      # The finished games, newest first, from the from-th: {"records" =>
      # [{"id", "at", "game", "names", "ranks", "scores"}, ...], "total",
      # "next" (the from of the next page, when there is more)}.
      def records_page(from = 0)
        from = from.to_i.clamp(0, @records.size)
        out = { "records" => [], "total" => @records.size }
        list = @records.reverse
        i = from
        while i < list.size
          e = record_entry(list[i])
          out["records"] << e
          if wire_size(out) > RECORD_BYTES
            out["records"].pop
            break
          end
          i += 1
        end
        out["next"] = i if i < list.size
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
        @records.find { |r| r["id"] == id.to_i }
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
        rec = @records.last
        return nil unless rec
        list = Array(rec["final"]).sort_by { |f| f[1] }.map { |seat, rank, score, _| [rec["names"][seat].to_s, rank, score] }
        { "id" => rec["id"], "at" => rec["at"], "game" => rec["game"], "result" => list }
      end

      def wire_size(obj)
        return ::Asterism::Codec.pack(obj).bytesize if defined?(::Asterism::Codec)
        JSON.generate(obj).bytesize
      end
    end
  end
end
