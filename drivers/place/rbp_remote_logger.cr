require "placeos-driver"
require "json"

class Place::RbpRemoteLogger < PlaceOS::Driver
  descriptive_name "Log Receiver for Room Booking Panel app"
  generic_name :Logger
  description %(Recieve logs streamed from Room Booking Panel app)

  default_settings({
    enabled:         false,
    max_log_entries: 1000,
    debug:           false,
  })

  @enabled : Bool = false
  @max_log_entries : Int32 = 1000
  @debug : Bool = false
  @entries : Hash(String, Array(JSON::Any)) = {} of String => Array(JSON::Any)

  def on_load
    on_update
  end

  def on_update
    @logging_enabled = setting?(Bool, "enabled") || true
    @max_log_entries = setting?(Int32, "max_log_entries") || 1000
    @debug = setting?(Bool, "debug") || false

    self[:enabled] = @logging_enabled
  end

  def post_event(payload : JSON::Any | String)
    logger.debug { "Received: #{payload}" } if @debug

    payload = payload.to_json if payload.is_a?(JSON::Any)
    payload = payload.to_s if payload.is_a?(String)

    entry = Entry.from_json(payload)

    @entries[entry.device_id] ||= [] of JSON::Any

    @entries[entry.device_id] =
      @entries
        .[entry.device_id]
        .unshift(JSON.parse(payload))
        .truncate(0, @max_log_entries)

    self[:entries] = @entries

    entry
  end

  class Entry
    include JSON::Serializable

    property id : String
    property device_id : String
    property type : String # Enum 'network' | 'console' | 'dom'
    property subtype : String
    property timestamp : Int32
    property raw : JSON::Any
    property data : JSON::Any
    property metadata : JSON::Any
  end
end
