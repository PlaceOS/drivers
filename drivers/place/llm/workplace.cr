require "placeos-driver"
require "placeos-driver/interface/chat_functions"

# metadata class
require "placeos"

class Place::Workplace < PlaceOS::Driver
  include Interface::ChatFunctions

  descriptive_name "LLM Workplace interface"
  generic_name :Workplace
  description %(provides workplace introspection functions to a LLM)

  default_settings({
    # fallback if there isn't one on the zone
    time_zone: "Australia/Sydney",
  })

  @fallback_timezone : Time::Location = Time::Location::UTC

  def on_load
    on_update
  end

  def on_update
    timezone = config.control_system.not_nil!.timezone.presence || setting?(String, :time_zone).presence || "Australia/Sydney"
    @fallback_timezone = Time::Location.load(timezone)
  end

  # =========================
  # The LLM Interface
  # =========================

  getter capabilities : String do
    String.build do |str|
      str << "functions for listing building levels to obtain level names and level ids\n"
      str << "find meeting rooms, filtering by capacity and or level id\n"
      str << "my current desk, car parking and guest visitor bookings\n"
      str << "Note: when booking a meeting room, preference one on the same level or closest level to my desk booking, if I have one, unless I specify a specific level. Also try to pick a room with an appropriate capacity.\n"
      str << "once candidate meeting rooms have been found, you can include the list of resource emails when getting schedules to see which rooms are available\n"
      str << "this capability also supports managing desk bookings and inviting visitors to the building"
    end
  end

  @[Description("returns desks, car parking spaces and visitors I have booked. day_offset: 0 will return todays schedule, day_offset: 1 will return tomorrows schedule etc.")]
  def my_bookings(day_offset : Int32 = 0)
    logger.debug { "listing bookings for #{current_user.email}, day offset #{day_offset}" }

    me = current_user

    now = Time.local(timezone)
    days = day_offset.days
    starting = now.at_beginning_of_day + days
    ending = now.at_end_of_day + days

    {"desk", "visitor", "parking", "asset-request"}.flat_map do |booking_type|
      staff_api.query_bookings(
        type: booking_type,
        period_start: starting.to_unix,
        period_end: ending.to_unix,
        zones: {building.id},
        user: invoked_by_user_id,
        email: me.email
      ).get.as_a.compact_map { |b| to_friendly_booking(b) }
    end
  end

  @[Description("returns the building and list of levels")]
  getter levels : Array(Zone) do
    [building] + Array(Zone).from_json(staff_api.zones(parent: building.id, tags: {"level"}).get.to_json).sort_by(&.name)
  end

  @[Description("returns the list of meeting rooms in the building filtering by capacity or level")]
  def meeting_rooms(minimum_capacity : Int32 = 1, level_id : String? = nil)
    logger.debug { "listing meeting rooms on level #{level_id} with capacity #{minimum_capacity}" }
    zone_id = level_id || building.id
    staff_api.systems(zone_id: zone_id, capacity: minimum_capacity, bookable: true).get.as_a.compact_map { |s| to_friendly_system(s) }
  end

  alias PlaceZone = PlaceOS::Client::API::Models::Zone
  alias Metadata = Hash(String, PlaceOS::Client::API::Models::Metadata)
  alias ChildMetadata = Array(NamedTuple(zone: PlaceZone, metadata: Metadata))

  @[Description("returns the list of available desks on the level and day specified. Make sure to get the list of levels first for the appropriate level_id")]
  def desks(level_id : String, day_offset : Int32 = 0)
    logger.debug { "listing desks on level #{level_id}, day offset #{day_offset}" }

    # get the list of desks for the level
    all_desks = staff_api.metadata(level_id, "desks").get
    response = Metadata.from_json(all_desks.to_json).dig?("desks", "details")

    logger.debug { "found desks: #{response}\nin metadata: #{all_desks}" }

    return [] of Desk unless response

    desks = Array(Desk).from_json(response)

    # calculate the offset time
    now = Time.local(timezone)
    days = day_offset.days
    starting = now.at_beginning_of_day + days
    ending = now.at_end_of_day + days

    # need current user so we can filter out desks limited to certain groups
    me = current_user

    # get the current bookings for the level
    bookings = staff_api.query_bookings(type: "desk", period_start: starting.to_unix, period_end: ending.to_unix, zones: {level_id}).get.as_a
    bookings = bookings.map(&.[]("asset_id").as_s)

    # filter out desks that are not available to the user
    desks.reject! do |desk|
      next true if desk.id.in?(bookings)
      if !desk.groups.empty?
        (desk.groups & me.groups).empty?
      end
    end
    desks
  end

  @[Description("books an asset, such as a desk or car parking space, for the number of days specified, starting on the day offset. For desk bookings use booking_type: desk")]
  def book_relative(booking_type : String, asset_id : String, level_id : String, day_offset : Int32 = 0, number_of_days : Int32 = 1)
    logger.debug { "booking relative #{booking_type}, asset #{asset_id} on level #{level_id}, day offset #{day_offset} for num days #{number_of_days}" }

    # ensure the level id exists
    level = levels.find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in the building. Please ensure the ID matches exactly, case matters." unless level

    user_id = invoked_by_user_id
    me = current_user
    now = Time.local(timezone).at_beginning_of_day

    resp = nil
    (day_offset...number_of_days).each do |offset|
      # calculate the offset time
      days = offset.days
      starting = now + days + 8.hours
      ending = now.at_end_of_day + days - 4.hours

      resp = staff_api.create_booking(
        booking_type: booking_type,
        asset_id: asset_id,
        user_id: user_id,
        user_email: me.email,
        user_name: me.name,
        zones: {level_id, building.id},
        booking_start: starting.to_unix,
        booking_end: ending.to_unix,
        time_zone: timezone.to_s,
        utm_source: "chatgpt"
      )
    end
    resp.try &.get
    "booked!"
  end

  @[Description("books an asset, such as a desk or car parking space, for the number of days specified, the start date must be ISO 8601 formatted in the correct timezone. For desk bookings use booking_type: desk")]
  def book_on(booking_type : String, asset_id : String, level_id : String, date : Time, number_of_days : Int32 = 1)
    logger.debug { "booking on #{booking_type}, asset #{asset_id} on level #{level_id}, date #{date} for num days #{number_of_days}" }

    # ensure the level id exists
    level = levels.find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in the building. Please ensure the ID matches exactly, case matters." unless level

    user_id = invoked_by_user_id
    me = current_user
    now = date.in(timezone).at_beginning_of_day

    resp = nil
    (0...number_of_days).each do |offset|
      # calculate the offset time
      days = offset.days
      starting = now + days + 8.hours
      ending = now.at_end_of_day + days - 4.hours

      resp = staff_api.create_booking(
        booking_type: booking_type,
        asset_id: asset_id,
        user_id: user_id,
        user_email: me.email,
        user_name: me.name,
        zones: {level_id, building.id},
        booking_start: starting.to_unix,
        booking_end: ending.to_unix,
        time_zone: timezone.to_s,
        utm_source: "chatgpt"
      )
    end
    resp.try &.get
    "booked!"
  end

  @[Description("cancels a booking")]
  def cancel_booking(booking_id : Int64)
    logger.debug { "cancel booking #{booking_id}" }
    booking = staff_api.get_booking(booking_id).get
    user_id = invoked_by_user_id
    me = current_user
    unless (user_id == booking["user_id"]?.try(&.as_s)) || me.email.downcase.in?({booking["user_email"].as_s, booking["booked_by_email"].as_s})
      raise "can only cancel bookings owned by #{me.email} - this booking is owned by #{booking["user_email"]}"
    end
    staff_api.booking_delete(booking_id, "chatgpt")
  end

  @[Description("book a visitor to the building")]
  def invite(visitor_name : String, visitor_email : String, day_offset : Int32 = 0, number_of_days : Int32 = 1)
    logger.debug { "inviting visitor to the building #{visitor_name}: #{visitor_email}, day offset #{day_offset} for num days #{number_of_days}" }

    # select a random level
    level = levels.first
    user_id = invoked_by_user_id
    me = current_user
    now = Time.local(timezone).at_beginning_of_day
    visitor_email = visitor_email.downcase

    resp = nil
    (0...number_of_days).each do |offset|
      # calculate the offset time
      days = offset.days
      starting = now + days + 8.hours
      ending = now.at_end_of_day + days - 4.hours

      resp = staff_api.create_booking(
        booking_type: "visitor",
        asset_id: visitor_email,
        user_id: user_id,
        user_email: me.email,
        user_name: me.name,
        zones: {level.id, building.id},
        booking_start: starting.to_unix,
        booking_end: ending.to_unix,
        time_zone: timezone.to_s,
        utm_source: "chatgpt",

        attendees: [{
          name:  visitor_name,
          email: visitor_email,
        }]
      )
    end
    resp.try &.get
    "invited!"
  end

  # =========================
  # Support functions
  # =========================

  struct Desk
    include JSON::Serializable

    getter id : String
    getter groups : Array(String) = [] of String
    getter features : Array(String) = [] of String
  end

  protected def to_friendly_system(system : JSON::Any) : System?
    the_levels = levels

    zone_ids = system["zones"].as_a.map(&.as_s)
    level = the_levels.find do |l|
      next nil unless l.tags.includes?("level")
      zone_ids.find { |z| z == l.id }
    end

    if level
      System.new level, system
    end
  end

  struct System
    include JSON::Serializable

    getter id : String? = nil
    getter name : String
    getter display_name : String? = nil
    getter description : String
    getter features : Array(String)
    getter email : String?
    getter capacity : Int32 = 0

    getter level : Zone
    getter map_id : String? = nil
    getter images : Array(String)

    def initialize(@level : Zone, system : JSON::Any)
      sys = system.as_h
      @id = sys["id"].as_s
      @name = sys["name"].as_s
      @display_name = sys["display_name"]?.try &.as_s?
      @description = sys["description"]?.try &.as_s? || ""
      @features = sys["features"].as_a.map(&.as_s)
      @images = sys["images"].as_a.map(&.as_s)
      @email = sys["email"]?.try &.as_s?
      @capacity = sys["capacity"].as_i
      @map_id = sys["map_id"]?.try &.as_s?
    end
  end

  protected def to_friendly_booking(booking : JSON::Any) : Booking?
    the_levels = levels

    zone_ids = booking["zones"].as_a.map(&.as_s)
    level = the_levels.find do |l|
      next nil unless l.tags.includes?("level")
      zone_ids.find { |z| z == l.id }
    end

    if level
      Booking.new level, booking, timezone
    end
  end

  struct Booking
    include JSON::Serializable

    getter id : String? = nil
    getter starting : Time
    getter ending : Time

    getter booking_type : String
    getter asset_id : String
    getter user_id : String?
    getter user_email : String
    getter user_name : String
    getter level : Zone

    # getter booked_by_email : String
    # getter booked_by_name : String

    getter checked_in : Bool = false

    def initialize(@level : Zone, book : JSON::Any, timezone : Time::Location)
      b = book.as_h
      @id = b["id"].as_s
      @starting = Time.unix(b["booking_start"].as_i64).in(timezone)
      @ending = Time.unix(b["booking_end"].as_i64).in(timezone)
      @booking_type = b["booking_type"].as_s
      @asset_id = b["asset_id"].as_s
      @user_id = b["user_id"]?.try &.as_s?
      @user_email = b["user_email"].as_s
      @user_name = b["user_name"].as_s
      @checked_in = b["checked_in"].as_bool

      # @booked_by_email = b["booked_by_email"].as_s
      # @booked_by_name = b["booked_by_name"].as_s
    end
  end

  protected def staff_api
    system["StaffAPI_1"]
  end

  def current_user : User
    User.from_json staff_api.user(invoked_by_user_id).get.to_json
  end

  getter timezone : Time::Location do
    building.time_zone || @fallback_timezone
  end

  struct User
    include JSON::Serializable

    getter name : String
    getter email : String
    getter groups : Array(String)
  end

  getter building : Zone { get_building }

  struct Zone
    include JSON::Serializable

    getter id : String
    getter name : String
    getter display_name : String?
    getter tags : Array(String)

    @[JSON::Field(key: "timezone")]
    getter tz : String?

    @[JSON::Field(ignore: true)]
    getter time_zone : Time::Location? do
      if tz = @tz.presence
        Time::Location.load(tz)
      end
    end
  end

  # Finds the building ID for the current location services object
  def get_building : Zone
    zones = staff_api.zones(tags: "building").get.as_a
    zone_ids = zones.map(&.[]("id").as_s)
    building_id = (zone_ids & system.zones).first

    building = zones.find! { |zone| zone["id"].as_s == building_id }
    Zone.from_json building.to_json
  rescue error
    msg = "unable to determine building zone"
    logger.warn(exception: error) { msg }
    raise msg
  end
end
