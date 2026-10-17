# frozen_string_literal: true

module AsterismGames
  module Mahjong
    # The table as an AI (or any program) reads it (README "Playing from a
    # program"): words instead of the screens' short keys and tile bytes,
    # and the seat's legal moves numbered, so a client picks one by its
    # number (choose). What a seat sees is exactly what its screen shows
    # (view): its own hand, the rivers, the melds, the dora indicators, the
    # scores and the help of the highest assist level; never another hand,
    # the wall or the ura dora. The host's AI players get the same (look).
    # Included in Table.
    module Readable
      WINDS = %w[east south west north].freeze
      PHASES = %w[draw discard calls end].freeze
      KINDS = { DAHAI: "discard", RIICHI: "riichi", TSUMO_AGARI: "tsumo", ANKAN: "closed_kan",
                KAKAN: "added_kan", PON: "pon", CHI: "chi", DAIMINKAN: "open_kan", RON: "ron", SKIP: "pass",
                KYUUSHU: "nine_kinds", NEXT: "next" }.to_h { |k, v| [Engine.const_get(k), v] }.freeze
      MELDS = { chi: "chi", pon: "pon", ankan: "closed_kan", daiminkan: "open_kan", kakan: "added_kan" }.freeze

      # What the text of describe says (the remote's describe returns it;
      # the AI players get it as their instructions).
      DESCRIPTION = <<~TEXT
        Riichi mahjong (four players, Mahjong Soul's rules by default) on an Asterism game host.

        How to play from a program:
        1. join(name) gives a token; every later call brings it. sit(token, -1) takes a free seat.
           The first member to sit is the owner: cpu(token, -1, true) fills the empty seats with CPUs,
           rule(token, 0, 1) makes the game east-only (0 hanchan), start(token) starts it.
        2. Loop: look(token) returns the table as your seat sees it. When "moves" is not empty it is your
           decision: choose(token, sv, n) plays the move numbered n, with the "sv" of that same look.
           "stale" means the table moved on: look again. When "moves" is empty, wait a little and look again
           (0.2-0.5 s); "deadline_ms" is how long the host still waits for you before it plays for you
           (a discard of the drawn tile, or a pass).
        3. After a round ("status": "result") and at the end ("over") a "next" move may be offered; the round
           also goes on by itself after a few seconds.
        4. points(token) tells what your hand would score: the win offered now, or for each wait of a tenpai
           hand (after each discard that leaves it tenpai, on your turn) the points by ron and by tsumo. It
           leaves out the ura dora and does not check furiten.

        Tiles: "1m".."9m" characters, "1p".."9p" circles, "1s".."9s" bamboo, "0m"/"0p"/"0s" the red fives
        (a five that is also a dora), "1z".."7z" the honours east, south, west, north, white, green, red.

        look(token) gives:
        - status: wait (the lobby), play, result (a round just ended), over (the game ended).
        - you: your seat (0-3, -1 watching). seats: the four seats in seat order, each with name, kind
          (human, cpu, ai, empty), wind (its seat wind this round), score, riichi, river, melds (type chi,
          pon, closed_kan, open_kan, added_kan, the tiles, from: the seat it came from),
          hand_count. river is the discards in order; riichi_index is the one that declared riichi,
          called_indexes those another seat took. The seat after yours plays after you.
        - round: wind (the prevalent wind), number (1-4), honba, riichi_sticks, dealer, wall_left,
          turn (the seat to act), phase (draw, discard, calls: the others may call the last discard).
        - dora_indicators: the dora is the next tile of each (9 -> 1, north -> east, red -> white).
        - last_discard: {seat, tile}. hand: your tiles, sorted, without the drawn one; drawn: the tile you just
          drew (null when none).
        - moves: what you may do now, each {n, type, tile or tiles, text}. Types: discard, riichi (declare
          riichi with that discard: 1000 points on the table, the hand is then locked), tsumo (win on your
          draw), ron (win on the last discard), pon / chi (call the last discard with those two tiles of your
          hand; chi only from the seat before you), open_kan, closed_kan, added_kan, pass (do not call),
          nine_kinds (abortive draw with nine kinds of terminals and honours), next.
        - help: on your turn, for each discard that leaves the hand tenpai, the waits as {tile: how many you
          have not seen} (tenpai); otherwise the shanten after each discard and the tiles that would bring it
          down, {tile: unseen} (accept; shanten 0 is tenpai). Counts are from what you can see only.
        - deadline_ms: the time the host still waits for you. result: at the end of a round (kind, the score
          changes, the wins with yaku, han, fu and points). final: at the end of the game, [seat, rank, score,
          points] per seat. rules: the table's rules (game, red fives, open tanyao, ...).
      TEXT

      # The table as seat sees it (-1: a member without a seat; that one
      # gets the public part only).
      def look_view(seat, now)
        v = { "table" => @name, "status" => @status, "sv" => @sv, "you" => seat }
        st = @state if @status != "wait"
        v["seats"] = (0..3).map { |s| seat_look(s, st) }
        if st
          v["round"] = { "wind" => WINDS[Engine::BAKAZE.index(st.bakaze.to_s)], "number" => st.kyoku,
                         "honba" => st.honba, "riichi_sticks" => st.kyoutaku, "dealer" => st.oya_seat,
                         "wall_left" => st.remaining_tiles, "turn" => st.current_seat,
                         "phase" => PHASES[%i[tsumo dahai naki_wait round_end].index(st.phase)] }
          v["dora_indicators"] = st.dora_hyouji.map(&:to_s)
          v["last_discard"] = st.last_dahai && { "seat" => st.last_dahai[:seat], "tile" => st.last_dahai[:tile].to_s }
          if seat >= 0
            h, d = hand_of(seat)
            v["hand"] = Tiles.unpack(h)
            v["drawn"] = d >= 0 ? Tiles.name(d) : nil
          end
        end
        v["moves"] = moves_of(seat)
        if seat >= 0 && @status == "play" && !v["moves"].empty?
          help = look_help(seat)
          v["help"] = help if help
        end
        dl = deadline_view(now, seat) if st && @deadline
        v["deadline_ms"] = dl[1] if dl && dl[0][seat] == 1 && seat >= 0
        v["result"] = result_look if @result && (@status == "result" || @status == "over")
        v["final"] = @final if @final
        v["final_reason"] = @final_reason if @final && @final_reason
        v["rules"] = rules_look
        v
      end

      # A seat's legal moves, numbered: [{"n", "type", "tile"/"tiles",
      # "text", "act" => [type, tiles]}]. The act is the host's own (left
      # out of what look shows).
      def moves_of(seat)
        out = []
        offers(seat).each do |t, ts|
          kind = KINDS[t] || t.to_s
          case t
          when Engine::DAHAI, Engine::RIICHI
            ts.uniq.each do |tile|
              text = t == Engine::DAHAI ? "discard #{tile}" : "declare riichi, discarding #{tile}"
              out << { "type" => kind, "tile" => tile, "text" => text, "act" => [t, [tile]] }
            end
          when Engine::ANKAN, Engine::KAKAN
            out << { "type" => kind, "tile" => ts[0], "text" => "#{kind.tr('_', ' ')} of #{ts[0]}", "act" => [t, ts] }
          when Engine::PON, Engine::CHI
            called = @state&.last_dahai ? @state.last_dahai[:tile].to_s : "?"
            out << { "type" => kind, "tiles" => ts, "text" => "#{kind} #{called} with #{ts.join(' ')}",
                     "act" => [t, ts] }
          else
            text = { "tsumo" => "win by tsumo", "ron" => "win by ron on #{@state&.last_dahai&.dig(:tile)}",
                     "pass" => "pass (do not call)", "open_kan" => "open kan of the last discard",
                     "nine_kinds" => "abortive draw (nine kinds of terminals and honours)",
                     "next" => "go on to the next round" }[kind] || kind
            out << { "type" => kind, "text" => text, "act" => [t, ts] }
          end
        end
        out.each_with_index { |m, i| m["n"] = i }
        out
      end

      # The look without the host's own parts (what the remote returns).
      def look_public(seat, now)
        v = look_view(seat, now)
        v["moves"] = v["moves"].map { |m| m.reject { |k, _| k == "act" } }
        v
      end

      # Plays the move numbered n of moves_of(seat) at state version sv.
      def choose(token, sv, n, now)
        seat = seat_of(token)
        return (node_of(token) ? "not seated" : "token") unless seat
        return "stale" unless sv.to_i == @sv
        m = moves_of(seat)[n.to_i] if n.is_a?(Integer) || n.to_s.match?(/\A\d+\z/)
        return "no such move" unless m
        act(token, sv.to_i, m["act"][0], m["act"][1], now)
      end

      # What the seat's hand would score (README "Playing from a program"):
      # {"now" => [the wins offered now]} or {"waits" => [...]}, each win
      # {"by", "tile", "han", "fu", "points", "yaku"} or "no_yaku". The ura
      # dora are left out (nobody sees them before a win) and furiten is not
      # checked.
      def points_of(seat)
        return { "error" => "not playing" } unless seat && seat >= 0 && @state && @status == "play"
        st = @state
        sim = Engine::API.deserialize_round_state(st.to_json)
        sim.uradora_hyouji = []
        hand = st.hands[seat].tiles.map(&:to_s)
        out = {}
        now = []
        offers(seat).each do |t, _|
          if t == Engine::TSUMO_AGARI
            now << hypothetical(sim, seat, hand, st.last_tsumo.to_s, false)
          elsif t == Engine::RON
            tile = (st.chankan_tile || st.last_dahai[:tile]).to_s
            now << hypothetical(sim, seat, hand, tile, true)
          end
        end
        out["now"] = now unless now.empty?
        melds = st.fuuros[seat].size
        bases = if hand.size % 3 == 2
                  hand.uniq.filter_map do |d|
                    rest = hand.dup
                    rest.delete_at(rest.index(d))
                    [d, rest]
                  end
                else
                  [[nil, hand]]
                end
        waits = []
        bases.each do |d, rest|
          t34 = ::Mahjong::State::Hand.new(rest.map { |n| ::Mahjong::Tiles::Tile.new(n) }).to_34
          next unless Engine.shanten(t34, melds).zero?
          ::Mahjong::Scoring::Judges::MachiJudge.machi_tile_indices(t34).sort.each do |i|
            w = ::Mahjong::Tiles::TileSet.from_index(i).to_s
            e = { "wait" => w, "ron" => hypothetical(sim, seat, rest, w, true),
                  "tsumo" => hypothetical(sim, seat, rest + [w], w, false) }
            e["discard"] = d if d
            waits << e
          end
        end
        out["waits"] = waits
        out["note"] = "without ura dora; furiten not checked; riichi only if declared"
        out
      rescue StandardError => e
        @log&.call("mahjong: #{@name}: points: #{e.class}: #{e.message}")
        { "error" => "could not work it out" }
      end

      private

      # One win as the engine would score it on a copy of the round
      # (sim) with tiles as the hand: ron on tile (tiles without it), or
      # tsumo (tiles with it).
      def hypothetical(sim, seat, tiles, tile, ron)
        sim.hands[seat] = ::Mahjong::State::Hand.new(tiles.map { |n| ::Mahjong::Tiles::Tile.new(n) })
        t = ::Mahjong::Tiles::Tile.new(tile)
        winner, sr = Engine.evaluate(sim, seat, ron, t, @rule)
        { "by" => ron ? "ron" : "tsumo", "tile" => tile, "han" => winner[:han], "fu" => winner[:fu],
          "points" => sr.display.to_s, "total" => sr.total,
          "yaku" => winner[:yaku].map { |y| y[:name].to_s } }
      rescue ::Mahjong::Errors::EngineError, ::RiichiEngine::API::InvalidActionError, ArgumentError
        { "by" => ron ? "ron" : "tsumo", "tile" => tile, "no_yaku" => true }
      end

      def seat_look(s, st)
        x = @seats[s]
        kind = if x.nil? then "empty"
               elsif x["kind"] == "human" then "human"
               elsif x["ai"] then "ai"
               else "cpu"
               end
        h = { "seat" => s, "name" => x ? x["name"].to_s : "", "kind" => kind }
        if @game
          h["score"] = st ? st.scores[s] : @game["scores"][s]
        end
        if st
          h["wind"] = WINDS[(s - st.oya_seat) % 4]
          h["riichi"] = st.riichi_flags[s] ? true : false
          tiles = st.kawas[s].tiles
          h["river"] = tiles.map { |k| k.tile.to_s }
          ri = tiles.index(&:riichi)
          h["riichi_index"] = ri if ri
          called = tiles.each_index.select { |i| tiles[i].called }
          h["called_indexes"] = called unless called.empty?
          h["melds"] = st.fuuros[s].map do |f|
            m = { "type" => MELDS[f.type] || f.type.to_s, "tiles" => f.tiles.map(&:to_s) }
            m["from"] = f.from_seat unless f.from_seat.nil?
            m
          end
          h["hand_count"] = st.hands[s].count
        end
        h
      end

      # The help of assist level 3, in words.
      def look_help(seat)
        wt, uk = assist_help(seat, offers(seat), 3)
        if wt
          list = []
          b = wt.bytes
          i = 0
          while i < b.size
            d = Tiles.name(b[i])
            n = b[i + 1]
            ws = (0...n).to_h { |j| [Tiles.name(b[i + 2 + j * 2]), b[i + 3 + j * 2]] }
            list << { "discard" => d, "waits" => ws }
            i += 2 + n * 2
          end
          return { "tenpai" => list }
        end
        return nil unless uk
        list = []
        b = uk.bytes
        i = 0
        while i < b.size
          d = Tiles.name(b[i])
          sh = b[i + 1]
          n = b[i + 2]
          acc = (0...n).to_h { |j| [Tiles.name(b[i + 3 + j * 2]), b[i + 4 + j * 2]] }
          list << { "discard" => d, "shanten" => sh, "accept" => acc }
          i += 3 + n * 2
        end
        { "shanten" => list }
      end

      def result_look
        r = @result
        out = { "kind" => r["kind"], "changes" => r["delta"] }
        out["from"] = r["from"] unless r["from"].nil?
        if r["wins"]
          out["wins"] = r["wins"].map do |w|
            { "seat" => w["winner"], "yaku" => w["yaku"], "han" => w["han"], "fu" => w["fu"],
              "points" => w["points"], "hand" => w["hand"], "tile" => w["agari"] }
          end
        end
        out["tenpai"] = r["tenpai"] if r["tenpai"]
        out
      end

      def rules_look
        r = @rule.to_h
        { "game" => r["game_type"].to_s, "red_fives" => aka_total(r["aka_dora"]), "open_tanyao" => r["kuitan"] ? true : false,
          "double_ron" => r["double_ron"] ? true : false, "tobi" => r["tobi"] ? true : false,
          "start_score" => r["initial_score"] }
      end
    end
  end
end
