# frozen_string_literal: true

require "io/console"

module AsterismGames
  module Play
    # One key at a time from a terminal (README "Playing in a terminal",
    # "Keys"): the terminal is put in raw mode, the bytes that come are
    # turned into names (:up :down :left :right :enter :space :esc :ctrl_c
    # :ctrl_q :backspace :tab, or the character typed as a String). Only on
    # a terminal: a pipe, a file and the tests keep reading lines.
    module Keys
      # ESC alone or the start of a sequence (an arrow): how long to wait
      # for the rest before taking it as ESC.
      ESC_WAIT_S = 0.05

      ARROWS = { "A" => :up, "B" => :down, "C" => :right, "D" => :left, "H" => :home, "F" => :end }.freeze
      TILDE = { "1" => :home, "2" => :insert, "3" => :delete, "4" => :end, "5" => :page_up, "6" => :page_down,
                "7" => :home, "8" => :end }.freeze
      CONTROLS = { "\r" => :enter, "\n" => :enter, " " => :space, "\t" => :tab, "\x7f" => :backspace,
                   "\b" => :backspace, "\x03" => :ctrl_c, "\x11" => :ctrl_q, "\x04" => :ctrl_d }.freeze

      module_function

      # The keys in buf (a String of the bytes read). Returns [keys, rest]:
      # rest is the start of a sequence (ESC, ESC [ 1 ; 5, a part of a UTF-8
      # character) that more bytes may complete; with final: true nothing is
      # kept (a lone ESC is :esc).
      def decode(buf, final: false)
        b = buf.b
        keys = []
        i = 0
        while i < b.bytesize
          c = b.getbyte(i)
          if c == 0x1B
            n, key = escape(b, i)
            if n.nil?
              return [keys, b.byteslice(i..)] unless final
              keys << :esc
              i += 1
              next
            end
            keys << key
            i += n
          elsif c < 0x80
            ch = c.chr
            keys << (CONTROLS[ch] || (c < 0x20 ? :"ctrl_#{(c + 0x60).chr}" : ch))
            i += 1
          else
            len = c >= 0xF0 ? 4 : (c >= 0xE0 ? 3 : (c >= 0xC0 ? 2 : 1))
            if i + len > b.bytesize
              return [keys, b.byteslice(i..)] unless final
              break
            end
            s = b.byteslice(i, len).force_encoding(Encoding::UTF_8)
            keys << (s.valid_encoding? ? s : :unknown)
            i += len
          end
        end
        [keys, "".b]
      end

      # An escape sequence at b[i]: [bytes, key], or nil when it is not
      # complete yet (more may come).
      def escape(b, i)
        return nil if i + 1 >= b.bytesize
        c1 = b.getbyte(i + 1).chr
        case c1
        when "["
          j = i + 2
          j += 1 while j < b.bytesize && b.getbyte(j).between?(0x20, 0x3F) # the parameters
          return nil if j >= b.bytesize
          final = b.getbyte(j).chr
          params = b.byteslice(i + 2, j - i - 2)
          key = final == "~" ? TILDE[params.split(";").first.to_s] : ARROWS[final]
          [j - i + 1, key || :unknown]
        when "O"
          return nil if i + 2 >= b.bytesize
          [3, ARROWS[b.getbyte(i + 2).chr] || :unknown]
        when "\e"
          [1, :esc] # ESC ESC: the first is ESC alone
        else
          [1, :esc] # ESC then a key (Alt+key): ESC, and the key after it
        end
      end

      # Reads keys from a terminal in raw mode (the caller puts it there).
      class Reader
        def initialize(io)
          @io = io
          @keys = []
        end

        # The next key, or nil when none comes within timeout seconds.
        def read(timeout = nil)
          return @keys.shift unless @keys.empty?
          return nil unless @io.wait_readable(timeout)
          buf = @io.readpartial(64)
          loop do
            keys, rest = Keys.decode(buf)
            @keys.concat(keys)
            break if rest.empty?
            # The start of a sequence: the rest within ESC_WAIT_S, or it
            # stands alone (ESC).
            if @io.wait_readable(ESC_WAIT_S)
              buf = rest + @io.readpartial(64)
            else
              @keys.concat(Keys.decode(rest, final: true)[0])
              break
            end
          end
          @keys.shift
        rescue EOFError, IOError
          :eof
        end
      end

      # Output for a terminal in raw mode: the terminal no longer turns
      # "\n" into a new line at the left (raw mode turns off its output
      # processing too), so every "\n" written goes as "\r\n".
      class CrlfOut
        def initialize(io)
          @io = io
        end

        def write(*s) = @io.write(*s.map { |x| x.to_s.gsub(/\r?\n/, "\r\n") })

        def print(*s)
          write(*s)
          nil
        end

        def puts(*lines)
          lines = lines.flatten
          return write("\n") && nil if lines.empty?
          lines.each { |l| write(l.to_s.end_with?("\n") ? l.to_s : "#{l}\n") }
          nil
        end

        def <<(s)
          write(s)
          self
        end

        def flush
          @io.flush
          self
        end

        def tty? = @io.tty?
        def winsize = @io.winsize
        def sync = @io.sync

        def sync=(v)
          @io.sync = v
        end
      end
    end
  end
end
