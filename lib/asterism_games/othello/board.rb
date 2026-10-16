# frozen_string_literal: true

module AsterismGames
  module Othello
    # The rules of othello (8x8): a board of 64 squares (0 empty, 1 black,
    # 2 white; square = y * 8 + x), the legal moves, the discs a move
    # turns, and a game as a history of moves. Squares are written "d3"
    # (column a-h, row 1-8); "--" is a pass. Black moves first.
    class Board
      EMPTY = 0
      BLACK = 1
      WHITE = 2
      DIRS = [[-1, -1], [0, -1], [1, -1], [-1, 0], [1, 0], [-1, 1], [0, 1], [1, 1]].freeze
      COLS = "abcdefgh"

      attr_reader :cells

      def initialize(cells = nil)
        @cells = cells ? cells.dup : Array.new(64, EMPTY)
        return if cells
        @cells[27] = @cells[36] = WHITE # d4, e5
        @cells[28] = @cells[35] = BLACK # e4, d5
      end

      def self.code(sq)
        sq.nil? || sq.negative? ? "--" : "#{COLS[sq % 8]}#{sq / 8 + 1}"
      end

      # "d3" -> 19, "--" -> -1, anything else -> nil.
      def self.square(code)
        s = code.to_s.strip.downcase
        return -1 if s == "--"
        return nil unless s.match?(/\A[a-h][1-8]\z/)
        (s[1].to_i - 1) * 8 + COLS.index(s[0])
      end

      def [](sq) = @cells[sq]

      def count(color) = @cells.count(color)

      # The squares a disc of color at sq turns (empty when the move is not legal).
      def flips(sq, color)
        return [] unless sq.between?(0, 63) && @cells[sq] == EMPTY
        other = 3 - color
        x0 = sq % 8
        y0 = sq / 8
        DIRS.flat_map do |dx, dy|
          line = []
          x = x0 + dx
          y = y0 + dy
          while x.between?(0, 7) && y.between?(0, 7) && @cells[y * 8 + x] == other
            line << y * 8 + x
            x += dx
            y += dy
          end
          x.between?(0, 7) && y.between?(0, 7) && @cells[y * 8 + x] == color ? line : []
        end
      end

      def legal?(sq, color) = !flips(sq, color).empty?

      def moves(color) = (0..63).select { |sq| legal?(sq, color) }

      def any_move?(color) = (0..63).any? { |sq| legal?(sq, color) }

      # Plays a legal move: the disc and the turned ones. Returns the turned squares.
      def place(sq, color)
        turned = flips(sq, color)
        raise ArgumentError, "not legal: #{Board.code(sq)}" if turned.empty?
        @cells[sq] = color
        turned.each { |t| @cells[t] = color }
        turned
      end

      # 64 characters: "." empty, "B" black, "W" white (a1 first, row by row).
      def to_s = @cells.map { |c| ".BW"[c] }.join

      # The board's eight rows, as text.
      def rows = to_s.scan(/.{8}/)
    end

    # A match: the board, whose turn it is, the history ("d3c5--...") and
    # whether it is over. A side with no legal move passes by itself; when
    # neither side can move, the game is over.
    class Match
      attr_reader :board, :turn, :hist

      def initialize
        @board = Board.new
        @turn = Board::BLACK
        @hist = +""
        @over = false
      end

      # The match a history replays to, or nil when a move in it is not legal.
      def self.replay(hist)
        g = new
        hist.to_s.scan(/../).each do |c|
          next if c == "--" # the passes are played by themselves
          sq = Board.square(c)
          return nil unless sq && sq >= 0 && g.play(sq)
        end
        g
      end

      def over? = @over

      def n = @hist.size / 2

      def last = @hist.empty? ? nil : @hist[-2, 2]

      def moves = @over ? [] : @board.moves(@turn)

      # Plays sq for the side to move when it is legal (and the passes that
      # follow); returns whether it did.
      def play(sq)
        return false if @over || !@board.legal?(sq, @turn)
        @board.place(sq, @turn)
        @hist << Board.code(sq)
        @turn = 3 - @turn
        unless @board.any_move?(@turn)
          if @board.any_move?(3 - @turn)
            @hist << "--"
            @turn = 3 - @turn
          else
            @over = true
          end
        end
        true
      end

      # The winner by the discs: BLACK, WHITE or 0 (a draw).
      def winner
        b = @board.count(Board::BLACK)
        w = @board.count(Board::WHITE)
        if b > w then Board::BLACK elsif b < w then Board::WHITE else 0 end
      end
    end

    # The CPU: the square with the best weight (corners first, the squares
    # next to an empty corner last), then the most discs turned; ties go to
    # the first square.
    module Cpu
      WEIGHTS = [
        100, -20, 10, 5, 5, 10, -20, 100,
        -20, -50, -2, -2, -2, -2, -50, -20,
        10, -2, 1, 1, 1, 1, -2, 10,
        5, -2, 1, 0, 0, 1, -2, 5,
        5, -2, 1, 0, 0, 1, -2, 5,
        10, -2, 1, 1, 1, 1, -2, 10,
        -20, -50, -2, -2, -2, -2, -50, -20,
        100, -20, 10, 5, 5, 10, -20, 100
      ].freeze

      # The square the CPU plays for color, or nil when it has none.
      def self.choose(board, color)
        board.moves(color).max_by { |sq| [WEIGHTS[sq], board.flips(sq, color).size, -sq] }
      end
    end
  end
end
