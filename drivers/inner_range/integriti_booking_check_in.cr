require "placeos-driver"
require "place_calendar"
require "xml"

class InnerRange::IntegritiBookingCheckin < PlaceOS::Driver
  descriptive_name "Integriti Booking Checkin"
  generic_name :IntegritiBookingCheckin

  default_settings({
    logging_integriti: "Integriti_1",
    _lookup_integriti: "Integriti_1",

    predefined_filter: 13,
    _filter:           {
      key: "value",
    },

    # we need to extract the users name from the event logs
    # for desks we split on the card access string
    booking_types: {
      desk:    " Card Access",
      parking: " License Plate",
    },
  })

  alias Filter = Hash(String, String | Bool | Int64 | Int32 | Float64 | Float32 | Nil)

  def on_update
    @logging_integriti = setting?(String, :logging_integriti) || "Integriti_1"
    @lookup_integriti = setting?(String, :lookup_integriti) || @logging_integriti
    @booking_types = setting(Hash(String, String), :booking_types)
    time_zone_string = setting?(String, :time_zone).presence || config.control_system.not_nil!.timezone.presence || "GMT"
    @time_zone = Time::Location.load(time_zone_string)
    @predefined_filter = setting?(Int32, :predefined_filter)
    @filter = setting?(Filter, :filter) || Filter.new
    @building_id = nil
    channel = @mutex.synchronize do
      @channel.close
      @channel = Channel(Nil).new
    end
    spawn { monitor_events(channel) }
  end

  @time_zone : Time::Location = Time::Location.load("GMT")
  @mutex : Mutex = Mutex.new
  @channel : Channel(Nil) = Channel(Nil).new
  @booking_types : Hash(String, String) = {} of String => String
  @predefined_filter : Int32? = nil
  @filter : Filter = Filter.new
  @logging_integriti : String = "Integriti_1"
  @lookup_integriti : String = "Integriti_1"
  @failed_name_lookup : Set(String) = Set(String).new

  accessor staff_api : StaffAPI_1

  protected def logging_integriti
    system[@logging_integriti]
  end

  protected def lookup_integriti
    system[@lookup_integriti]
  end

  def failed_name_lookups
    @failed_name_lookup.to_a
  end

  getter building_id : String { get_building_id.not_nil! }

  def get_building_id
    building_setting = setting?(String, :building_zone_override)
    return building_setting if building_setting.presence
    zone_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    nil
  end

  getter check_ins : UInt64 = 0_u64

  # event_types: transition:
  #  DoorEvent: DoorLock, DoorTimedUnlock (triggered by UserGrantedOut)
  #             "text": "L10 Main Entry Locked by (Door Logic) (D015)",
  #                       "text": "L10 Main Entry Timed Unlocked for 00 h 00 min 05 s by R17: L10 COMMS ROOM (Door Logic) (D015)",
  #  UserAccess: UserGrantedIn, UserGrantedOut
  #              "text": "First LastName Card Access at <R01:Rdr02> into Kitchen Auto Door [Card 215]",
  #                      "First LastName License Plate access at <R06:Rdr01> into B4 Carpark Ramp Entry ANPR Camera 897799759162 [License Plate CZG456]"
  #                             "text": "Unknown User Button Access at <R17:Butt1> out of L10 Main Entry",
  # so we really only care about UserGrantedIn

  struct Event
    include JSON::Serializable

    getter event_type : String # UserAccess
    getter transition : String # UserGrantedIn
    getter time_gen_ms : String
    getter text : String # "First LastName Card Access at <R01:Rdr02> into Kitchen Auto Door [Card 215]"
  end

  TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%9N"

  getter last_changed : String = Time.utc.to_s(TIME_FORMAT)

  protected def monitor_events(channel)
    predefined_filter = @predefined_filter
    filter = @filter

    while !channel.closed?
      begin
        events_raw = predefined_filter ? logging_integriti.review_predefined_access(predefined_filter, true, last_changed, 5).get : logging_integriti.review_access(filter, true, last_changed, 5).get
        events = Array(Event).from_json(events_raw.to_json)
        next if events.empty?

        logger.debug { "found #{events.size} access events" }
        @last_changed = events[0].time_gen_ms

        now = Time.local(@time_zone).at_beginning_of_day
        end_of_day = now.in(@time_zone).at_end_of_day - 2.hours
        building = building_id

        events.each do |event|
          next unless event.transition == "UserGrantedIn"

          begin
            text = event.text
            @booking_types.each do |booking_type, split_text|
              next unless text.includes?(split_text)

              # "First LastName Card Access at <R01:Rdr02> into Kitchen Auto Door [Card 2155]"
              name = text.split(split_text, 2)[0]
              first, last = name.split(' ', 2)

              # find user email
              if email = lookup_integriti.users(first_name: first, second_name: last.strip).get.as_a.first?.try(&.[]("email").as_s?)
                staff_user = staff_api.user(email.strip.downcase).get rescue nil
                if staff_user
                  email = staff_user["email"].as_s
                end

                # find any bookings that user may have
                bookings = staff_api.query_bookings(now.to_unix, end_of_day.to_unix, zones: {building}, type: booking_type, email: email).get.as_a
                logger.debug { "found #{bookings.size} of #{booking_type} for #{email}" }

                bookings.each do |booking|
                  if !booking["checked_in"].as_bool?
                    logger.debug { "  --  checking in #{booking_type} for #{email}" }
                    @check_ins += 1_u64
                    staff_api.booking_check_in(booking["id"], true, "integriti-access", instance: booking["instance"]?)
                  else
                    logger.debug { "  --  skipping #{booking_type} for #{email} as already checked-in" }
                  end
                end
              else
                @failed_name_lookup << name
                logger.debug { "couldn't find user #{name} in integriti" }
              end

              break
            end
          rescue error
            logger.warn(exception: error) { "error parsing event: #{event.text}" }
            self[:parsing_failed] = event.text
          end
        end
      rescue error
        logger.warn(exception: error) { "failure monitoring events" }
      end
    end
  end
end
