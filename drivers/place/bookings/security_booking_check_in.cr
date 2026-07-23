require "placeos-driver"
require "place_calendar"
require "simple_retry"
require "placeos-driver/interface/door_security"

class Place::SecurityBookingCheckin < PlaceOS::Driver
  descriptive_name "Security based Booking Checkin"
  generic_name :SecurityBookingCheckin
  description %(Checks in users to bookings based on swipe card events in the security system)

  default_settings({
    # the channel id we're looking for events on
    organization_id: "event",

    # booking types we want to check in
    booking_types: ["desk", "parking"],

    # custom field user lookup
    _custom_field: "employeeId",

    # door ids
    _filter_door_ids: {
      "1234" => "name",
    },

    # transient failures (directory, staff API) are retried
    # with exponential backoff before being treated as a real failure
    _request_retries:     3,
    _request_backoff:     2,
    _request_max_backoff: 10,
  })

  def on_update
    @custom_field = setting?(String, :custom_field)
    @booking_types = setting(Array(String), :booking_types)
    @filter_ids = setting?(Hash(String, String), :filter_door_ids) || {} of String => String

    @request_retries = setting?(Int32, :request_retries) || 3
    @request_backoff = (setting?(Int32, :request_backoff) || 2).seconds
    @request_max_backoff = (setting?(Int32, :request_max_backoff) || 10).seconds

    time_zone_string = setting?(String, :time_zone).presence || config.control_system.not_nil!.timezone.presence || "GMT"
    @time_zone = Time::Location.load(time_zone_string)
    @building_id = nil

    subscriptions.clear
    org_id = setting?(String, :organization_id) || "event"
    monitor("security/#{org_id}/door") { |_subscription, payload| door_event(payload) }
  end

  @custom_field : String? = nil
  @filter_ids : Hash(String, String) = {} of String => String
  @booking_types : Array(String) = [] of String
  @time_zone : Time::Location = Time::Location.load("GMT")

  @request_retries : Int32 = 3
  @request_backoff : Time::Span = 2.seconds
  @request_max_backoff : Time::Span = 10.seconds

  # retries transient failures with exponential backoff, the error from the
  # final attempt propagates to the caller so it can be handled as a real failure
  protected def with_retry(description : String, &block : -> T) : T forall T
    SimpleRetry.try_to(
      # +1: the initial attempt plus @request_retries retries
      max_attempts: @request_retries + 1,
      base_interval: @request_backoff,
      max_interval: @request_max_backoff,
    ) do |attempt, last_error|
      logger.warn(exception: last_error) { "retrying #{description} (attempt #{attempt})" } if last_error
      block.call
    end
  end

  accessor staff_api : StaffAPI_1
  accessor directory : Calendar_1

  getter building_id : String { get_building_id.not_nil! }

  def get_building_id : String
    building_setting = setting?(String, :building_zone_override)
    return building_setting if building_setting && building_setting.presence
    zone_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  end

  getter event_count : UInt64 = 0_u64
  getter check_ins : UInt64 = 0_u64
  getter matched_users : UInt64 = 0_u64

  @user_cache : Hash(String, String) = {} of String => String

  def lookup_custom(id : String) : String?
    if cached = @user_cache[id]?
      return cached
    end

    user = begin
      with_retry("user lookup of #{id} via #{@custom_field}") do
        directory.list_users(
          filter: "#{@custom_field} eq '#{id}'",
          additional_fields: {@custom_field},
        ).get.as_a.first?
      end
    rescue
      nil
    end

    if user
      email = user["username"].as_s
      @user_cache[id] = email.strip.downcase
    end
  end

  @[Security(Level::Administrator)]
  def door_event(json : String)
    logger.debug { "new door event detected: #{json}" }
    event = Interface::DoorSecurity::DoorEvent.from_json(json)

    if !@filter_ids.empty?
      if match = @filter_ids[event.door_id]?
        logger.debug { "found matching door: #{match}" }
      else
        return
      end
    end

    @event_count += 1_u64

    now = Time.local(@time_zone).at_beginning_of_day
    end_of_day = now.in(@time_zone).at_end_of_day - 2.hours
    building = building_id

    if user_email = event.user_email.presence
      # NOTE:: `email` is captured by the retry closures below, so it must only
      # ever be assigned a String (closured variables are not flow-typed)
      email = user_email
      if @custom_field.presence
        actual_email = lookup_custom(user_email)
        return unless actual_email
        email = actual_email
        @matched_users += 1_u64
      else
        staff_user = begin
          with_retry("user lookup of #{email}") { staff_api.user(email.strip.downcase).get }
        rescue
          nil
        end
        if staff_user
          email = staff_user["email"].as_s
          @matched_users += 1_u64
        end
      end

      @booking_types.each do |booking_type|
        # find any bookings that user may have
        bookings = with_retry("#{booking_type} booking query for #{email}") do
          staff_api.query_bookings(now.to_unix, end_of_day.to_unix, zones: {building}, type: booking_type, email: email).get.as_a
        end
        logger.debug { "found #{bookings.size} of #{booking_type} for #{email}" }

        bookings.each do |booking|
          if booking["asset_id"].as_s.starts_with?("unallocated")
            logger.debug { "  --  skipping #{booking_type} for #{email} as unallocated" }
            next
          end

          if !booking["checked_in"].as_bool?
            logger.debug { "  --  checking in #{booking_type} for #{email}" }
            begin
              with_retry("#{booking_type} check in for #{email}") do
                staff_api.booking_check_in(booking["id"], true, "security-access", instance: booking["instance"]?).get
              end
              @check_ins += 1_u64
            rescue error
              logger.warn(exception: error) { "failed to check in #{booking_type} booking #{booking["id"]} for #{email}" }
            end
          else
            logger.debug { "  --  skipping #{booking_type} for #{email} as already checked-in" }
          end
        end
      end
    end
  end
end
