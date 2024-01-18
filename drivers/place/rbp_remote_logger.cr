require "placeos-driver"

class Place::RbpRemoteLogger < PlaceOS::Driver
  descriptive_name "Log Receiver for Room Booking Panel app"
  generic_name :Logger
  description %(Recieve logs streamed from Room Booking Panel app)

  default_settings({
    enabled: false,
    max_log_entries:    1000,
    debug: false,
  })

  @enabled : Bool = false
  @max_log_entries : Int32 = 1000
  @debug : Bool = false

  def on_load
    on_update
  end

  def on_update
    @logging_enabled = setting?(Bool, "enabled") || true
    @max_log_entries = setting?(Int32, "max_log_entries") || 1000
    @debug = setting?(Bool, "debug") || false

    self[:enabled] = @logging_enabled
  end

  def post_event(payload : String)
    logger.debug { "Received: #{payload}" }
    log_entry = LogEntry.from_json(payload)
    self[log_entry.device_id] ||= [] of JSON::Any
    self[log_entry.device_id] = self[log_entry.device_id].as_a.unshift(JSON::Any.new(log_entry.to_json)).truncate(0, @max_log_entries)
    log_entry
  end

  class LogEntry
    include JSON::Serializable
    
    property id : String
    property device_id : String
    property type : String
    property subtype : String
    property timestamp : Int32
    property raw : JSON::Any
    property data : JSON::Any
    property metadata : JSON::Any
  end
end
