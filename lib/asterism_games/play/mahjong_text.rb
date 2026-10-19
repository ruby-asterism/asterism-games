# frozen_string_literal: true

module AsterismGames
  module Play
    # The pieces of the mahjong terminal client that need no network:
    # tiles as text (emoji or MPSZ), the width of text in a terminal, rows
    # that keep their columns whatever the terminal makes of an emoji, and
    # reading what the player types. The tile numbers and the action types
    # are the table's wire (README "Views"); the client does not load the
    # table (nor riichi_engine).
    module MahjongText
      # Action types (README "Views", "Action types").
      DAHAI = 1
      RIICHI = 2
      TSUMO = 3
      ANKAN = 4
      KAKAN = 5
      PON = 6
      CHI = 7
      DAIMINKAN = 8
      RON = 9
      SKIP = 10
      KYUUSHU = 11
      NEXT = 12
      SANCHAHOU = 13
      KANS = [ANKAN, KAKAN, DAIMINKAN].freeze

      BACK = 37
      WINDS = %w[東 南 西 北].freeze
      HONORS = %w[東 南 西 北 白 發 中].freeze
      HONOR_ALIASES = { "発" => 35, "白" => 34, "中" => 36 }.freeze
      LETTERS = ("a".."n").to_a.freeze

      # Unicode's mahjong tiles (U+1F000..): the honours (east south west
      # north red green white), the characters 1-9 (U+1F007), the bamboos
      # (U+1F010) and the circles (U+1F019); U+1F02B the back. Indexed by the
      # wire's tile numbers; a red five is the five (marked apart).
      EMOJI = begin
        m = (0..8).map { |i| (0x1F007 + i).chr(Encoding::UTF_8) }
        s = (0..8).map { |i| (0x1F010 + i).chr(Encoding::UTF_8) }
        p = (0..8).map { |i| (0x1F019 + i).chr(Encoding::UTF_8) }
        honors = [0x1F000, 0x1F001, 0x1F002, 0x1F003, 0x1F006, 0x1F005, 0x1F004].map { |c| c.chr(Encoding::UTF_8) }
        (m + [m[4]] + p + [p[4]] + s + [s[4]] + honors + [0x1F02B.chr(Encoding::UTF_8)]).freeze
      end
      EMOJI_CODE = EMOJI.each_with_index.reject { |_, i| [9, 19, 29].include?(i) }.to_h.freeze

      # The kanji style (as the table app draws a tile): two rows, the
      # number on top (一..九 for the characters, full-width １..９ for the
      # circles and the bamboos; not ①②③, which many fonts draw small) and
      # the suit below (萬 筒 索); an honour is its one character on top.
      # Every glyph is two columns wide in any terminal.
      KANJI_NUM = %w[一 二 三 四 五 六 七 八 九].freeze
      WIDE_NUM = %w[１ ２ ３ ４ ５ ６ ７ ８ ９].freeze
      SUITS = %w[萬 筒 索].freeze
      BACK_KANJI = "裏"
      STYLES = %w[emoji kanji mpsz].freeze

      module_function

      # The two rows of a tile in the kanji style: [top, bottom] ("" below
      # an honour or a back).
      def kanji_rows(code)
        return ["  ", ""] if code.nil? || code.negative?
        return [BACK_KANJI, ""] if code >= BACK
        return [HONORS[code - 30], ""] if code >= 30
        suit = code / 10
        n = code % 10
        n = 4 if n == 9
        [suit.zero? ? KANJI_NUM[n] : WIDE_NUM[n], SUITS[suit]]
      end

      def red?(code) = [9, 19, 29].include?(code)

      # A tile in MPSZ: 1m..9m, 0m the red five, ... 1z..7z.
      def mpsz(code)
        return "--" if code.nil? || code.negative?
        return "##" if code >= BACK
        return "#{code - 29}z" if code >= 30
        n = code % 10
        "#{n == 9 ? 0 : n + 1}#{%w[m p s][code / 10]}"
      end

      # A tile as the screen shows it: an emoji, or in the text style
      # MPSZ for the suits and the kanji for the honours (東 ... 中: two
      # columns like "1m", and what a Japanese player reads).
      def tile(code, style)
        return (style == "mpsz" ? "--" : " ") if code.nil? || code.negative?
        return EMOJI.fetch(code) if style == "emoji"
        return kanji_rows(code).join if style == "kanji"
        return "##" if code >= BACK
        return HONORS[code - 30] if code >= 30
        mpsz(code)
      end

      # A tile typed: 6s, 0p (the red five), 1z..7z, 東 ... 中, an emoji, or
      # the kanji style's 一萬 / ４筒 / 3索 (the five is the plain one).
      # Returns the tile number or nil.
      def parse_tile(text)
        t = text.to_s.strip
        if (m = t.match(/\A([0-9])([mps])\z/i))
          n = m[1].to_i
          base = { "m" => 0, "p" => 10, "s" => 20 }[m[2].downcase]
          return n.zero? ? base + 9 : base + n - 1
        end
        return 29 + Regexp.last_match(1).to_i if t =~ /\A([1-7])z\z/i
        return 30 + HONORS.index(t) if HONORS.include?(t)
        return HONOR_ALIASES[t] if HONOR_ALIASES.key?(t)
        if t.size == 2 && (suit = SUITS.index(t[1]))
          n = KANJI_NUM.index(t[0]) || WIDE_NUM.index(t[0]) || ("1".."9").to_a.index(t[0])
          return suit * 10 + n if n
        end
        EMOJI_CODE[t]
      end

      # Several tiles typed together: "3m4m", "34m", "3m 4m", "東東".
      def parse_tiles(text)
        out = []
        t = text.to_s.delete(" ")
        until t.empty?
          if (m = t.match(/\A([0-9]+)([mpsz])/i))
            m[1].each_char { |d| out << parse_tile("#{d}#{m[2]}") }
            t = m.post_match
          elsif t.size >= 2 && SUITS.include?(t[1])
            out << parse_tile(t[0, 2])
            t = t[2..]
          else
            out << parse_tile(t[0])
            t = t[1..]
          end
        end
        out.include?(nil) ? nil : out
      end

      # ------------------------------------------------------------ width

      # Columns a character takes in a terminal (the usual wcwidth): 0 for
      # the combining marks, the variation selectors and the joiner; 2 for
      # the East Asian wide and fullwidth ranges and the emoji shown wide
      # by default (U+1F004, the red dragon, among them; the other mahjong
      # tiles are neutral, 1); 1 for the rest.
      WIDE = [
        0x1100..0x115F, 0x2E80..0x303E, 0x3041..0x33FF, 0x3400..0x4DBF, 0x4E00..0x9FFF, 0xA000..0xA4CF,
        0xAC00..0xD7A3, 0xF900..0xFAFF, 0xFE30..0xFE4F, 0xFF00..0xFF60, 0xFFE0..0xFFE6,
        0x1F004..0x1F004, 0x1F0CF..0x1F0CF, 0x1F18E..0x1F18E, 0x1F191..0x1F19A, 0x1F200..0x1F251,
        0x1F300..0x1F64F, 0x1F680..0x1F6FF, 0x1F900..0x1F9FF, 0x20000..0x3FFFD
      ].freeze
      ZERO = [0x0300..0x036F, 0x200B..0x200F, 0xFE00..0xFE0F, 0x20D0..0x20FF].freeze

      def char_width(ch)
        c = ch.ord
        return 0 if c < 0x20 || ZERO.any? { |r| r.cover?(c) }
        WIDE.any? { |r| r.cover?(c) } ? 2 : 1
      end

      # Columns of a text, the escape sequences (\e[...m, \e[...G) not
      # counted.
      def width(text)
        text.to_s.gsub(/\e\[[0-9;]*[A-Za-z]/, "").each_char.sum { |ch| char_width(ch) }
      end

      # text cut to at most cols columns and padded to cols.
      def fit(text, cols)
        out = +""
        w = 0
        text.to_s.each_char do |ch|
          cw = char_width(ch)
          break if w + cw > cols
          out << ch
          w += cw
        end
        out << " " * (cols - w)
      end

      # One line of the screen in columns. Each part is given the columns it
      # takes; where the text's own width may be wrong (an emoji tile: a
      # font may draw it wider than the terminal counts it, a terminal may
      # count 🀄 as 1 or 2), the column is not left to the terminal: on a
      # terminal (cursor) every part after the first is put at its column
      # by CHA (ESC [ n G), so a tile drawn wider never pushes the letters
      # or the next tile along; elsewhere (a pipe, a file, the tests) the
      # part is padded with spaces by width.
      class Row
        attr_reader :col

        def initialize(cursor: false)
          @cursor = cursor
          @out = +""
          @col = 0
        end

        # Text whose width the terminal counts right (ASCII, kanji).
        def text(s)
          put(s, MahjongText.width(s))
        end

        # A part of cols columns (a tile and the room after it).
        def cell(s, cols)
          put(s, cols)
        end

        # Moves on to a column (spaces, or the cursor).
        def to(col)
          return self if col <= @col
          @out << (@cursor ? "\e[#{col + 1}G" : " " * (col - @col))
          @col = col
          self
        end

        def to_s
          @out.dup
        end

        private

        def put(s, cols)
          @out << "\e[#{@col + 1}G" if @cursor && @col.positive?
          @out << s.to_s
          pad = cols - MahjongText.width(s)
          @out << " " * pad if !@cursor && pad.positive?
          @col += cols
          self
        end
      end

      # ------------------------------------------------------------ input

      # The view's offers as options to choose from: [[type, [tiles]], ...],
      # one per thing that may be sent (a discard per tile, a riichi per
      # discard, each pon or chi pair, each kan).
      def options(view)
        out = []
        (view["a"] || []).each do |type, bytes|
          tiles = bytes.to_s.b.unpack("C*")
          case type
          when DAHAI, RIICHI then tiles.each { |t| out << [type, [t]] }
          else out << [type, tiles]
          end
        end
        out
      end

      # The member's hand with the drawn tile last: [tile, ...].
      def hand_tiles(view)
        h = view["h"].to_s.b.unpack("C*")
        dt = view["dt"].to_i
        dt >= 0 && view.key?("dt") ? h + [dt] : h
      end

      # A tile the player names: a letter of the hand (a..n, the drawn tile
      # last), or a tile typed (6s; 5s also takes the red five when the hand
      # has no other five). nil when it names none.
      def tile_of(word, view)
        hand = hand_tiles(view)
        w = word.to_s
        if w =~ /\A[a-n]\z/
          i = LETTERS.index(w)
          return i < hand.size ? hand[i] : nil
        end
        t = parse_tile(w)
        return nil unless t
        return t if hand.include?(t) || !hand.any?
        five = { 4 => 9, 14 => 19, 24 => 29 }[t]
        five && hand.include?(five) ? five : t
      end

      # Reads one line. Returns one of
      #   [:act, type, tiles]          send it (act)
      #   [:choose, type, options]     several options: show them, the next line chooses
      #   [:cmd, word, args]           a command of the client (sit, start, quit, ...)
      #   [:error, text]               why not (Japanese, for the screen)
      #   [:none]                      an empty line
      # pending: the options of a choose before ([type, options]), which a
      # number or a tile chooses from.
      COMMANDS = %w[quit exit q help ? sit stand cpu nocpu ai start rule tonpuu hanchan view auto leave tables].freeze
      WORDS = { "tsumo" => TSUMO, "ron" => RON, "pass" => SKIP, "skip" => SKIP, "kyuushu" => KYUUSHU,
                "ok" => NEXT, "next" => NEXT }.freeze

      def parse(line, view, pending = nil)
        words = line.to_s.strip.split
        return [:none] if words.empty?
        w0 = words[0].downcase
        if pending && (pick = choose(pending[1], words, view))
          return [:act, *pick]
        end
        return [:cmd, w0, words.drop(1)] if COMMANDS.include?(w0)
        return [:error, "画面がまだ無い"] unless view
        opts = options(view)
        if WORDS.key?(w0)
          type = WORDS[w0]
          o = opts.find { |t, _| t == type }
          return o ? [:act, *o] : [:error, "今はできない"]
        end
        group = case w0
                when "riichi", "reach" then opts.select { |t, _| t == RIICHI }
                when "pon" then opts.select { |t, _| t == PON }
                when "chi" then opts.select { |t, _| t == CHI }
                when "kan" then opts.select { |t, _| KANS.include?(t) }
                end
        if group
          return [:error, "今はできない"] if group.empty?
          # Alone: the one option, or a choice among several (a riichi:
          # which tile to discard with it).
          return [:act, *group[0]] if group.size == 1 && words.size == 1
          return [:choose, group[0][0], group] if words.size == 1
          pick = choose(group, words.drop(1), view)
          return pick ? [:act, *pick] : [:error, "その中には無い"]
        end
        # A tile alone: the discard.
        t = tile_of(words[0], view)
        return [:error, "? (help)"] unless t
        o = opts.find { |ty, ts| ty == DAHAI && ts == [t] }
        return [:act, *o] if o
        opts.any? { |ty, _| ty == DAHAI } ? [:error, "その牌は打てない"] : [:error, "今は打てない"]
      end

      # One of options by what was typed: its number (1..), a tile (the
      # discard of a riichi, a kan's tile) or the tiles of a pon or chi
      # (3m4m, or letters). nil when none matches.
      def choose(options, words, view)
        return nil if options.nil? || options.empty? || words.empty?
        w = words.join(" ")
        if w =~ /\A[1-9]\z/
          o = options[w.to_i - 1]
          return o && [o[0], o[1]]
        end
        tiles = if words.all? { |x| x =~ /\A[a-n]\z/ }
                  words.map { |x| tile_of(x, view) }
                elsif w =~ /\A[a-n]+\z/ && w.size > 1
                  w.chars.map { |x| tile_of(x, view) }
                else
                  parse_tiles(w)
                end
        return nil if tiles.nil? || tiles.include?(nil) || tiles.empty?
        # A five typed as 5 takes a red five offered when no plain one is.
        norm = ->(ts) { ts.map { |t| { 9 => 4, 19 => 14, 29 => 24 }.fetch(t, t) }.sort }
        exact = options.find { |_, ts| ts.sort == tiles.sort }
        exact ||= options.find { |_, ts| norm.call(ts) == norm.call(tiles) }
        exact ||= options.find { |_, ts| tiles.size == 1 && ts.include?(tiles[0]) }
        exact ||= options.find { |_, ts| tiles.size == 1 && norm.call(ts).include?(norm.call(tiles)[0]) }
        exact && [exact[0], exact[1]]
      end

      # ------------------------------------------------------------ keys

      # The keys of the table app (fmruby-core flash/app/game/mahjong):
      # C V B the first, second and third chi offered, K L J the kans.
      CHI_KEYS = %w[c v b].freeze
      KAN_KEYS = %w[k l j].freeze
      QUIT_KEYS = [:ctrl_c, :ctrl_q, "q"].freeze
      LINE_KEYS = [":", "/"].freeze

      # The hand tile a key would discard: sel when it is on the hand, else
      # the last (the drawn tile).
      def chosen(view, sel)
        n = hand_tiles(view).size
        sel.is_a?(Integer) && sel.between?(0, n - 1) ? sel : n - 1
      end

      # Whether the hand's tiles are being chosen (a discard or a riichi
      # offered): the cursor under the hand shows then.
      def choosing?(view)
        (view["a"] || []).any? { |t, _| t == DAHAI || t == RIICHI }
      end

      # The n-th offer (0: the first) of the types, in the view's order.
      def nth_offer(opts, types, n)
        opts.select { |t, _| types.include?(t) }[n]
      end

      # One key (Keys' names) as the table app reads it. sel: the chosen
      # hand tile (-1: the drawn one), pick: riichi, choosing the tile to
      # discard with it. Returns one of
      #   [:act, type, tiles]       send it
      #   [:select, i]              choose hand tile i
      #   [:pick, on]               riichi's choosing on or off
      #   [:cmd, word, args]        a command of the client (sit, start ...)
      #   [:line]                   open the line to type a command in
      #   [:quit]
      #   [:error, text]            why not (Japanese, for the screen)
      #   [:none]                   nothing
      def key_command(key, view, sel: -1, pick: false)
        k = key.is_a?(String) ? key.downcase : key
        return [:quit] if QUIT_KEYS.include?(k)
        return [:line] if LINE_KEYS.include?(k)
        return [:none] unless view.is_a?(Hash) && !view["error"]
        me = view["me"].to_i
        return lobby_key(k, view, me) if view["st"] == "wait"
        return [:none] if me.negative? || !%w[play result over].include?(view["st"])
        table_key(k, view, sel, pick)
      end

      # The lobby: 1-4 sit there, S stand, C CPUs into the empty seats and
      # Enter start (the owner's).
      def lobby_key(k, view, me)
        owner = me >= 0 && view["ow"] == me
        case k
        when "1", "2", "3", "4" then [:cmd, "sit", [k]]
        when "s" then me >= 0 ? [:cmd, "stand", []] : [:none]
        when "c" then owner ? [:cmd, "cpu", []] : [:error, "卓の主だけができる"]
        when :enter then owner ? [:cmd, "start", []] : [:none]
        else [:none]
        end
      end

      def table_key(k, view, sel, pick)
        opts = options(view)
        has = ->(type) { opts.any? { |t, _| t == type } }
        hand = hand_tiles(view)
        case k
        when :left, :right
          return [:none] if hand.empty? || !choosing?(view)
          cur = chosen(view, sel)
          [:select, (cur + (k == :left ? -1 : 1)) % hand.size]
        when :enter, :space
          return [:act, NEXT, []] if has.call(NEXT)
          return [:none] if hand.empty?
          t = hand[chosen(view, sel)]
          if pick
            o = opts.find { |ty, ts| ty == RIICHI && ts == [t] } || opts.find { |ty, _| ty == RIICHI }
            return o ? [:act, *o] : [:pick, false]
          end
          return [:none] unless has.call(DAHAI)
          o = opts.find { |ty, ts| ty == DAHAI && ts == [t] }
          o ? [:act, *o] : [:error, "その牌は打てない"]
        when :esc
          return [:pick, false] if pick
          has.call(SKIP) ? [:act, SKIP, []] : [:none]
        when "r" then has.call(RIICHI) ? [:pick, !pick] : [:error, "今はできない"]
        when "t" then offer_key(opts, [TSUMO, RON], 0)
        when "p" then offer_key(opts, [PON], 0)
        when "n" then offer_key(opts, [KYUUSHU], 0)
        when *CHI_KEYS then offer_key(opts, [CHI], CHI_KEYS.index(k))
        when *KAN_KEYS then offer_key(opts, KANS, KAN_KEYS.index(k))
        else [:none]
        end
      end

      def offer_key(opts, types, n)
        o = nth_offer(opts, types, n)
        o ? [:act, *o] : [:error, "今はできない"]
      end

      # The key of an offer, as the screen shows it ("C" for the first chi,
      # "L" for the second kan ...).
      def offer_key_name(opts, type, tiles)
        group, keys = if type == CHI then [[CHI], CHI_KEYS]
                      elsif KANS.include?(type) then [KANS, KAN_KEYS]
                      end
        return { RIICHI => "R", TSUMO => "T", RON => "T", PON => "P", KYUUSHU => "N", SKIP => "Esc",
                 NEXT => "Enter" }[type] unless group
        i = opts.select { |t, _| group.include?(t) }.index([type, tiles])
        i && i < keys.size ? keys[i].upcase : nil
      end
    end
  end
end
