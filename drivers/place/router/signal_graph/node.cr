require "json"
require "./mod"
require "./watchable"

class Place::Router::SignalGraph
  module Node
    # Metadata tracked against each signal node.
    class Label
      include JSON::Serializable
      include Watchable

      def initialize(@ref)
      end

      def to_s(io)
        io << ref
      end

      # The `Node::Ref` used when creating this node.
      getter ref : Ref

      # `Ref` of the upstream signal source currently feeding this node.
      property source : Ref? = nil

      # Locked state. When `true` changes to signal routes that transit this
      # are blocked.
      property locked : Bool = false

      # Additional metadata passed in from settings or dynamically applied.
      # Information here is propogated to exposed state keys. May be used for
      # any information needed by a user interface or external system.
      @[JSON::Field(ignore: true)]
      property meta : Hash(String, JSON::Any) { Hash(String, JSON::Any).new }

      delegate :[], :[]?, to: meta

      # Sets a metadata property of `self`.
      def []=(key, value : JSON::Any)
        meta[key] = value
        self.notify
        value
      end

      def []=(key, value)
        self[key] = JSON::Any.new value
      end

      def []=(key, value : Array)
        self[key] = JSON::Any.new value.map { |x| JSON::Any.new x }
      end

      def []=(key, value : Hash)
        self[key] = JSON::Any.new value.transform_values { |x| JSON::Any.new x }
      end

      protected def on_to_json(json)
        @meta.try &.each do |key, value|
          json.field(key) { value.to_json(json) }
        end
      end
    end

    # Base structure for referring to a node within the graph.
    abstract struct Ref
      # Resolves a string-based node *key* to a fully-qualified reference.
      #
      # If a system component is not present within *key*, this is resolved
      # within the context of *sys*. For example:
      #
      #   Ref.resolve("Display_1:hdmi", "sys-abc123")
      #   # => DeviceInput(sys: "sys-abc123", mod: {"Display", 1}, input: "hdmi")
      #
      def self.resolve?(key : String, sys = nil)
        ref = key.includes?('/') ? key : "#{sys}/#{key}"
        {% begin %}
          {% for type in @type.subclasses %}
            {{type}}.parse?(ref) || \
          {% end %}
          nil
        {% end %}
      end

      # Node identifier for usage as the graph ID.
      def id
        self.class.hash ^ self.hash
      end

      def ==(other : Ref)
        id == other.id
      end

      def local(sys : String)
        to_s.lchop "#{sys}/"
      end

      def to_json(json)
        json.string to_s
      end

      private module ClassMethods(T)
        # Parses a string-based *ref* to {{@type}}.
        abstract def parse?(ref : String) : T?
      end

      macro inherited
        extend ClassMethods(self)
      end
    end

    # Reference to the default / central node for a device.
    #
    # These take the cannonical string form of:
    #
    #   sys-abc123/Display_1
    #   │          │       │
    #   │          │       └module index
    #   │          └module name
    #   └system
    #
    struct Device < Ref
      getter mod : Mod

      def initialize(sys, name, idx)
        @mod = Mod.new sys, name, idx
      end

      def initialize(@mod)
      end

      def to_s(io)
        io << mod
      end

      def self.parse?(ref) : self?
        if mod = Mod.parse? ref
          new mod
        end
      end
    end

    # Reference to a signal output from a device.
    #
    # These take the cannonical string form of:
    #
    #   sys-abc123/Switcher_1.1
    #   │          │        │ │
    #   │          │        │ └output
    #   │          │        └module index
    #   │          └module namme
    #   └system
    #
    struct DeviceOutput < Ref
      getter mod : Mod
      getter output : Int32 | String

      def initialize(sys, name, idx, @output)
        @mod = Mod.new sys, name, idx
      end

      def initialize(@mod, @output)
      end

      def to_s(io)
        io << mod << '.' << output
      end

      def self.parse?(ref) : self?
        m, _, o = ref.rpartition '.'
        if mod = Mod.parse? m
          output = o.to_i? || o
          new mod, output
        end
      end
    end

    # Reference to a signal input to a device.
    #
    # These take the cannonical string form of:
    #
    #   sys-abc123/Display_1:hdmi
    #   │          │       │ │
    #   │          │       │ └input
    #   │          │       └module index
    #   │          └module namme
    #   └system
    #
    struct DeviceInput < Ref
      getter mod : Mod
      getter input : Int32 | String

      def initialize(sys, name, idx, @input)
        @mod = Mod.new sys, name, idx
      end

      def initialize(@mod, @input)
      end

      def to_s(io)
        io << mod << ':' << input
      end

      def self.parse?(ref) : self?
        m, _, i = ref.rpartition ':'
        if mod = Mod.parse? m
          input = i.to_i? || i
          new mod, input
        end
      end
    end

    # Virtual node representing (any) mute source.
    #
    # This may be refernced simply as `MUTE`.
    struct Mute < Ref
      class_getter instance : self { new }

      protected def initialize
      end

      def id
        0_u64
      end

      def self.parse?(ref) : self?
        instance if ref.upcase == "MUTE"
      end

      def to_s(io)
        io << "MUTE"
      end
    end
  end
end
