require "set"
require "./mod"

class Place::Router::SignalGraph
  module Node
    class Label
      def initialize(@ref)
      end

      getter ref : Ref

      def to_s(io)
        io << ref
      end

      property source : UInt64? = nil
      property locked : Bool = false
    end

    abstract struct Ref
      getter mod : Mod

      def initialize(sys, name, idx)
        @mod = Mod.new sys, name, idx
      end

      def id
        self.class.hash ^ self.hash
      end

      def self.resolve(key : String, sys : String)
        ref = key.includes?('/') ? key : "#{sys}/#{key}"
        {% begin %}
          {% for type in @type.subclasses %}
            {{type}}.parse?(ref) || \
          {% end %}
          raise "malformed node ref: \"#{key}\""
        {% end %}
      end
    end

    # Reference to the default / central node for a device
    struct Device < Ref
      def initialize(sys, mod, idx)
        super
      end

      def initialize(@mod)
      end

      def to_s(io)
        io << mod
      end

      def self.parse?(ref)
        if mod = Mod.parse? ref
          new mod
        end
      end
    end

    # Reference to a signal output from a device.
    struct DeviceOutput < Ref
      getter output : Int32 | String

      def initialize(sys, name, idx, @output)
        super sys, name, idx
      end

      def initialize(@mod, @output)
      end

      def to_s(io)
        io << mod << '.' << output
      end

      def self.parse?(ref)
        m, _, o = ref.rpartition '.'
        if mod = Mod.parse? m
          output = o.to_i? || o
          new mod, output
        end
      end
    end

    # Reference to a signal input to a device.
    struct DeviceInput < Ref
      getter input : Int32 | String

      def initialize(sys, name, idx, @input)
        super sys, name, idx
      end

      def initialize(@mod, @input)
      end

      def to_s(io)
        io << mod << ':' << input
      end

      def self.parse?(ref)
        m, _, i = ref.rpartition ':'
        if mod = Mod.parse? m
          input = i.to_i? || i
          new mod, input
        end
      end
    end

    # Virtual node representing (any) mute source
    struct Mute < Ref
      class_getter instance : self { new }

      protected def initialize
        @mod = uninitialized Mod
      end

      def mod
        nil
      end

      def id
        0_u64
      end

      def self.parse?(ref)
        instance if ref.upcase == "MUTE"
      end

      def to_s(io)
        io << "MUTE"
      end
    end
  end
end
