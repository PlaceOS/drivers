require "placeos-driver"
require "simple_retry"

class Place::EventAttendanceRecorder < PlaceOS::Driver
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

  @update_mutex = Mutex.new

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

    @[JSON::Field(key: "id")]
    property event_id : String
  end

  private def current_booking_changed(_subscription, new_value)
    logger.debug { "booking changed: #{new_value}" }
    event = (StaffEventChange?).from_json(new_value)

    apply_new_state(event.try(&.event_id), @status)
  rescue e
    logger.warn(exception: e) { "failed to parse event" }
  end

  private def people_count_changed(_subscription, new_value)
    logger.debug { "new people count #{new_value}" }
    return if new_value == "null"
    value = (Int32 | Float64).from_json(new_value).to_i
    people_counts << (value < 0 ? 0 : value)
  end

  private def status_changed(_subscription, new_value)
    logger.debug { "new room status: #{new_value}" }
    new_status = (String?).from_json(new_value) rescue new_value.to_s

    apply_new_state(booking_id, new_status)
  end

  private def apply_new_state(new_booking_id : String?, new_status : String?)
    @update_mutex.synchronize do
      logger.debug { "#apply_new_state called with new_booking_id: #{new_booking_id}, new_status: #{new_status}" }

      old_booking_id = @booking_id
      @booking_id = new_booking_id
      @status = new_status || "free"

      if old_booking_id && (new_booking_id != old_booking_id || new_status != status)
        save_booking_stats(old_booking_id, people_counts) if @should_save
        if (init_count = system[:Bookings][:people_count]?) && init_count && (init_count.as_i? || init_count.as_f).to_i > 0
          @people_counts = [(init_count.as_i? || init_count.as_f).to_i]
        else
          @people_counts = [] of Int32
        end
      end

      @should_save = true if @booking_id && @status != "free"
    end
  end

  private def save_booking_stats(event_id : String, counts : Array(Int32))
    logger.debug { "#save_booking_stats event_id: #{event_id}, counts: #{counts}" }

    if counts.empty?
      logger.warn { "no counts found for event #{event_id}" }
      min = 0
      max = 0
      median = 0
      average = 0
    else
      min = counts.min
      max = counts.max
      total = counts.reduce(0) { |acc, i| acc + i }
      average = total / counts.size
      counts.sort!
      index = (counts.size / 2).round_away.to_i - 1
      median = counts[index]
    end

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
