# frozen_string_literal: true

module AsterismGames
  module Mahjong
    # Tile numbers: one byte per tile on the wire, the same order as the
    # sprite sheets of the table screen (fmruby-core tools/mahjong_tilegen.rb):
    #   0..8 1m..9m, 9 0m (red five), 10..18 1p..9p, 19 0p, 20..28 1s..9s,
    #   29 0s, 30..36 1z..7z (east south west north white green red), 37 back.
    module Tiles
      NAMES = (%w[m p s].flat_map { |s| (1..9).map { |n| "#{n}#{s}" } + ["0#{s}"] } +
               (1..7).map { |n| "#{n}z" } + ["back"]).freeze
      CODE = NAMES.each_with_index.to_h.freeze
      BACK = 37

      module_function

      def code(name)
        CODE.fetch(name.to_s)
      end

      def name(code)
        NAMES.fetch(code)
      end

      # Bytes (a binary String) of the tiles given by name.
      def pack(names)
        names.map { |n| code(n) }.pack("C*")
      end

      def unpack(bytes)
        bytes.to_s.b.unpack("C*").map { |c| name(c) }
      end

      # Sort key in the usual order (suit, then number; the red five as a five).
      def sort_key(name)
        n = name.to_s
        suit = "mpsz".index(n[1])
        num = n[0].to_i
        num = 5 if num.zero?
        [suit, num, n[0] == "0" ? 1 : 0]
      end

      def sort(names)
        names.sort_by { |n| sort_key(n) }
      end
    end
  end
end
