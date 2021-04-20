require "set"
require "./mod"

class Place::Router::SignalGraph
  module Node
    class Label
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
    end

    # Reference to the default / central node for a device
    struct Device < Ref
      def initialize(@mod)
      end

      def to_s(io)
        io << mod
      end
    end

    # Reference to a signal output from a device.
    struct DeviceOutput < Ref
      getter output : Int32 | String

      def initialize(sys, name, idx, @output)
        super sys, name, idx
      end

      def to_s(io)
        io << mod << '.' << output
      end
    end

    # Reference to a signal input to a device.
    struct DeviceInput < Ref
      getter input : Int32 | String

      def initialize(sys, name, idx, @input)
        super sys, name, idx
      end

      def to_s(io)
        io << mod << '.' << input
      end
    end

    # Virtual node representing (any) mute source
    struct Mute
      class_getter instance : self { new }
      protected def initialize; end

      def id
        0_u64
      end

      def to_s(io)
        io << "MUTE"
      end
    end
  end
end
