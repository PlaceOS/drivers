require "placeos-driver"
require "simple_retry"

class Place::UsagePusher < PlaceOS::Driver
  descriptive_name "PlaceOS Event Attendance Recorder"
  generic_name :EventAttendanceRecorder

  default_settings({
    metadata_key: "people_count",
  })

  accessor staff_api : StaffAPI_1

  # Staff API metadata key
  @metadata_key : String = "people_count"
  @system_id : String = ""
  getter count : UInt64 = 0_u64

  # Tracking meeting details
  getter status : String = "free"
  getter booking_id : String? = nil

  getter should_save : Bool = false
  getter people_counts : Array(Int32) = [] of Int32

  def on_load
    @system_id = config.control_system.not_nil!.id
    on_update
  end

  def on_update
    @metadata_key = setting?(String, :metadata_key).presence || "people_count"
  end

  bind Bookings_1, :current_booking, :current_booking_changed
  bind Bookings_1, :people_count, :people_count_changed
  bind Bookings_1, :status, :status_changed

  class StaffEventChange
    include JSON::Serializable

    property event_id : String
  end

  private def current_booking_changed(_subscription, new_value)
    logger.debug { "booking changed: #{new_value}" }
    event = (StaffEventChange?).from_json(new_value)
    apply_new_state(event.try(&.event_id), @status)
  end

  private def people_count_changed(_subscription, new_value)
    logger.debug { "new people count #{new_value}" }
    return if new_value == "null"
    people_counts << Int32.from_json(new_value)
  end

  private def status_changed(_subscription, new_value)
    logger.debug { "new room status: #{new_value}" }
    new_status = (String?).from_json(new_value)
    apply_new_state(booking_id, new_status)
  end

  private def apply_new_state(new_booking_id : String?, new_status : String?)
    if new_booking_id != booking_id || new_status != status
      save_booking_stats(booking_id.not_nil!, people_counts) if @should_save
      @people_counts = [] of Int32
    end

    @booking_id = new_booking_id
    @status = new_status || "free"
    @should_save = true if @booking_id && @status == "busy"
  end

  private def save_booking_stats(event_id : String, counts : Array(Int32))
    return logger.warn { "ignoring booking as no counts found for event #{event_id}" } if counts.empty?
    min = counts.min
    max = counts.max
    total = counts.reduce(0) { |acc, i| acc + i }
    average = total / counts.size
    counts.sort!
    index = (counts.size / 2).round_away.to_i - 1
    median = counts[index]

    @count += 1_u64
    @should_save = false

    SimpleRetry.try_to(
      max_attempts: 5,
      base_interval: 10.milliseconds,
      max_interval: 10.seconds,
    ) do
      staff_api.patch_event_metadata(@system_id, event_id, {
        @metadata_key => {
          min:     min,
          max:     max,
          median:  median,
          average: average,
        },
      }).get
    end
  end
end
