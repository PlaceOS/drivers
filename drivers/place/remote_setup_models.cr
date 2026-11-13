require "json"
require "random/secure"

# Models of the RemoteSetup driver. They match the types in
# `libs/common/src/lib/remote-setup.ts` of PlaceOS/user-interfaces.
module Place::RemoteSetupModels
  # Most characters in an ID that the driver accepts
  MAX_ID_SIZE = 128

  # Raise when an ID is empty or longer than `MAX_ID_SIZE`
  def self.check_id(name : String, value : String) : Nil
    raise ArgumentError.new("#{name} must be 1 to #{MAX_ID_SIZE} characters") unless 0 < value.size <= MAX_ID_SIZE
  end

  # Application on the device. The apps use kebab-case names, such as `booking-panel`
  enum App
    BookingPanel
    Control
    Signage

    def self.new(pull : JSON::PullParser) : self
      parse(pull.read_string.tr("-", "_"))
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(to_s.underscore.tr("_", "-"))
    end
  end

  # Configuration that remote setup applies to a device
  struct Config
    include JSON::Serializable

    # System that the device shows. For signage, the display system
    getter system_id : String
    # Signage only. Template that the display shows
    getter template_id : String?
    # Booking Panel only. Open the events view of the system
    getter event_view : Bool?

    def initialize(@system_id, @template_id = nil, @event_view = nil)
    end

    # Raise when the IDs are not in bounds
    def validate! : Nil
      RemoteSetupModels.check_id("system_id", system_id)
      template_id.try { |id| RemoteSetupModels.check_id("template_id", id) }
    end
  end

  # Device in the `devices` binding
  class Device
    include JSON::Serializable

    getter id : String
    property app : App
    # Configuration on the device. `null` when it is not set up
    @[JSON::Field(emit_null: true)]
    property config : Config?
    # Unix epoch in milliseconds of the last `register` or `complete` call
    property last_seen : Int64
    # ID of the last command that the device completed
    property last_command : String?

    def initialize(@id, @app, @config, @last_seen)
    end
  end

  enum Action
    Configure
    Clear
  end

  # Command in the `device_<id>` binding. `config` is only set for `configure`
  struct Command
    include JSON::Serializable

    getter id : String
    getter action : Action
    getter config : Config?
    # Unix epoch in milliseconds of the time the command was made
    getter issued_at : Int64

    def initialize(@action, @config, @issued_at)
      @id = Random::Secure.hex(8)
    end
  end
end
