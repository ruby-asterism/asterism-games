# frozen_string_literal: true

module AsterismGames
  # A table as an Asterism object (<node>/<app>/<table>): the methods a
  # game exposes, with their numbers of arguments (exposes), each taking
  # the caller's node ID as from: (the host exposes it with caller: :from,
  # so Asterism fills from: in from the call's key and refuses a call that
  # brings from: itself). The methods run on the host's receiving thread,
  # one at a time with the host's loop, and never wait.
  #
  #   join(name)             -> the game's member_reply, or {"error" => why}
  #   mine                   -> the same for a node that joined, or nil
  #   leave(token)           -> true / false
  #
  # A game's Remote adds its own methods (exposes) and calls mark(token,
  # from) in those a member makes: a call by a member from its own node
  # counts as a sign that it is there.
  class Remote
    class << self
      # The exposed methods: {name => number of arguments} (-1: any; the
      # arguments are not counted). Those given come first, in their order;
      # the inherited ones not given follow.
      def exposes(methods = nil)
        if methods
          inherited = superclass.respond_to?(:exposes) ? superclass.exposes : {}
          @exposes = methods.transform_keys(&:to_sym).merge(inherited.reject { |k, _| methods.key?(k) }).freeze
        end
        @exposes || (superclass.respond_to?(:exposes) ? superclass.exposes : {})
      end

      # What the methods take and do, for the meta (docs/protocol.md 5 of
      # asterism: asterism mcp and the command line show them): {name =>
      # [argument names, text]}. Inherited like exposes.
      def docs(table = nil)
        if table
          inherited = superclass.respond_to?(:docs) ? superclass.docs : {}
          @docs = inherited.merge(table.transform_keys(&:to_sym)).freeze
        end
        @docs || (superclass.respond_to?(:docs) ? superclass.docs : {})
      end

      # The object's own text in the meta.
      def object_doc(text = nil)
        @object_doc = text if text
        @object_doc || (superclass.respond_to?(:object_doc) ? superclass.object_doc : nil)
      end

      # The methods: as Asterism.expose takes them: with the names and
      # texts when the asterism gem knows them (with_docs), else the
      # numbers (asterism 0.7.1).
      def expose_methods(with_docs)
        exposes.to_h do |m, n|
          d = docs[m]
          next [m, n] unless with_docs && d
          [m, { args: d[0], doc: d[1], arity: n }]
        end
      end
    end

    exposes join: 1, mine: 0, leave: 1
    docs join: [%w[name], "Joins the table as name (or gets this node's membership back). Returns {\"token\", ...}: " \
                          "every later call brings the token. {\"error\" => why} when the table is full."],
         mine: [[], "This node's membership ({\"token\", ...}), or nil when it has not joined."],
         leave: [%w[token], "Leaves the table (a seat during a game goes to a CPU). true / false."]

    attr_reader :game

    def initialize(game, clock)
      @game = game
      @clock = clock
    end

    def join(name, from: nil)
      @game.join(from.to_s, name.to_s, now)
    end

    def mine(from: nil)
      node = from.to_s
      r = @game.mine(node, now)
      @game.touch(node, now) if r && !r["error"]
      r
    end

    def leave(token, from: nil)
      @game.leave(token)
    end

    private

    def now
      @clock.call
    end

    # A call with a member's token from that member's own node.
    def mark(token, from)
      node = @game.node_of(token)
      @game.touch(node, now) if node && node == from.to_s
    end
  end
end
