require "placeos-driver"

class Place::RbpRemoteLogger < PlaceOS::Driver
  descriptive_name "Log Receiver for Room Booking Panel app"
  generic_name :Logger
  description %(Recieve logs streamed from Room Booking Panel app)

  default_settings({
    max_log_entries:    1000,
    debug: false
  })

  @max_log_entries : UInt32 = 1000_u32
  @debug : Bool = false

  def on_load
    on_update
  end

  def on_update
    @max_log_entries = setting?(UInt32, "max_log_entries") || 1000_u32
    @debug = setting?(Bool, "debug") || false
  end

  def post_event(payload : JSON::Any)
    logger.debug { "Received: #{payload}" }
  end

end
