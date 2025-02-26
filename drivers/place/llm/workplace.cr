require "placeos-driver"
require "placeos-driver/interface/chat_functions"
require "set"

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
      str << "this capability also supports managing desk bookings and inviting visitors to the building\n"
      str << "please cancel any bookings made on the incorrect day"
    end
  end

  @[Description("returns desks, car parking spaces and visitors I have booked. day_offset: 0 will return todays schedule, day_offset: 1 will return tomorrows schedule etc. If you provide a date, in ISO 8601 format and the correct timezone, the date will be used.")]
  def my_bookings(day_offset : Int32 = 0, date : Time? = nil)
    me = current_user

    if date
      starting = date.in(timezone).at_beginning_of_day
      logger.debug { "listing bookings for #{current_user.email}, on day #{starting}" }
    else
      logger.debug { "listing bookings for #{current_user.email}, day offset #{day_offset}" }
      now = Time.local(timezone)
      days = day_offset.days
      starting = now.at_beginning_of_day + days
    end
    ending = starting.at_end_of_day

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

  @[Description("returns the building details and list of levels. Use this to obtain level_ids")]
  def levels : Array(Zone)
    logger.debug { "getting list of levels" }
    l = all_levels
    l.each do |level|
      all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
      if all_desks
        desks = all_desks.as_a
        level.bookable_desk_count = desks.size
        features = Set(String).new
        desks.each do |desk|
          if feat = desk["features"]?
            feat.as_a.each { |f| features << f.as_s.downcase }
          end
        end
        level.desk_features = features.to_a unless features.empty?
      else
        level.bookable_desk_count = 0
      end
    end
    l
  end

  getter all_levels : Array(Zone) do
    [building] + Array(Zone).from_json(staff_api.zones(parent: building.id, tags: {"level"}).get.to_json).sort_by(&.name)
  end

  @[Description("returns the list of meeting rooms in the building filtering by capacity or level")]
  def meeting_rooms(minimum_capacity : Int32 = 1, level_id : String? = nil)
    logger.debug { "listing meeting rooms on level #{level_id} with capacity #{minimum_capacity}" }

    # ensure the level id exists if provided
    if level_id
      level = levels.find { |l| l.id == level_id }
      raise "could not find level_id #{level_id} in the building. Make sure you've obtained the list of levels." unless level
    end

    zone_id = level_id || building.id
    staff_api.systems(zone_id: zone_id, capacity: minimum_capacity, bookable: true).get.as_a.compact_map { |s| to_friendly_system(s) }
  end

  alias PlaceZone = PlaceOS::Client::API::Models::Zone
  alias Metadata = Hash(String, PlaceOS::Client::API::Models::Metadata)
  alias ChildMetadata = Array(NamedTuple(zone: PlaceZone, metadata: Metadata))

  @[Description("returns the list of desks available for booking on the level and day specified. If the level has desk features then you can also filter by features.")]
  def desks(level_id : String, day_offset : Int32 = 0, date : Time? = nil, feature : String? = nil)
    logger.debug { "listing desks on level #{level_id}, day offset #{day_offset}" }

    # ensure the level id exists
    level = levels.find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in the building. Make sure you've obtained the list of levels." unless level

    # get the list of desks for the level
    all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
    raise "no bookable desks on this level, please try another." unless all_desks
    desks = Array(Desk).from_json(all_desks.to_json)

    # calculate the offset time
    if date
      starting = date.in(timezone).at_beginning_of_day
    else
      now = Time.local(timezone)
      days = day_offset.days
      starting = now.at_beginning_of_day + days
    end
    ending = starting.at_end_of_day

    # need current user so we can filter out desks limited to certain groups
    me = current_user

    # get the current bookings for the level
    bookings = staff_api.query_bookings(type: "desk", period_start: starting.to_unix, period_end: ending.to_unix, zones: {level_id}).get.as_a
    bookings = bookings.map(&.[]("asset_id").as_s)

    # filter out desks that are not available to the user
    feature = feature.try(&.downcase)
    desks.reject! do |desk|
      next true if desk.id.in?(bookings)
      next true if feature && !desk.features.map!(&.downcase).includes?(feature)
      if !desk.groups.empty?
        (desk.groups & me.groups).empty?
      end
    end

    # need to limit the results as the LLM runs out of memory
    logger.debug { "found #{desks.size} available desks" }
    desks.sample(5)
  end

  @[Description("books an asset, such as a desk or car parking space, for the number of days specified, starting on the day offset. For desk bookings use booking_type: desk")]
  def book_relative(booking_type : String, asset_id : String, level_id : String, day_offset : Int32 = 0, number_of_days : Int32 = 1)
    logger.debug { "booking relative #{booking_type}, asset #{asset_id} on level #{level_id}, day offset #{day_offset} for num days #{number_of_days}" }

    # ensure the level id exists
    level = levels.find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in the building. Make sure you've obtained the list of levels." unless level

    user_id = invoked_by_user_id
    me = current_user
    current_time = Time.local(timezone)
    now = current_time.at_beginning_of_day

    raise "booking in the past is not permitted" unless day_offset > 0 || (day_offset == 0 && current_time.hour < 18)

    # ensure the asset exists if we can check for it
    case booking_type
    when "desk"
      all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
      raise "no desks found on level #{level_id}, ensure this id is correct" unless all_desks
      desks = Array(Desk).from_json(all_desks.to_json)
      desk = desks.find { |d| d.id == asset_id }

      raise "could not find a desk with id: #{asset_id}" unless desk
    end

    ids = (day_offset...(day_offset + number_of_days)).map do |offset|
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
      resp.get["id"].as_i64
    end
    starting = now + day_offset.days

    {
      booking_ids: ids,
      details:     "booking for #{asset_id} created on #{starting.day_of_week}, #{starting.to_s("%F")} for #{number_of_days} #{number_of_days > 1 ? "days" : "day"}",
    }
  end

  @[Description("books an asset, such as a desk or car parking space, for the number of days specified, the start date must be in ISO 8601 format with the correct timezone. For desk bookings use booking_type: desk")]
  def book_on(booking_type : String, asset_id : String, level_id : String, date : Time, number_of_days : Int32 = 1)
    logger.debug { "booking on #{booking_type}, asset #{asset_id} on level #{level_id}, date #{date} for num days #{number_of_days}" }

    # ensure the level id exists
    level = levels.find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in the building. Make sure you've obtained the list of levels." unless level

    user_id = invoked_by_user_id
    me = current_user
    now = date.in(timezone).at_beginning_of_day
    current_time = Time.local(timezone)
    raise "booking in the past is not permitted" unless current_time < now || (current_time - now) < 18.hours

    # ensure the asset exists if we can check for it
    case booking_type
    when "desk"
      all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
      raise "no desks found on level #{level_id}, ensure this id is correct" unless all_desks
      desks = Array(Desk).from_json(all_desks.to_json)
      desk = desks.find { |d| d.id == asset_id }

      raise "could not find a desk with id: #{asset_id}" unless desk
    end

    ids = (0...number_of_days).map do |offset|
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
      resp.get["id"].as_i64
    end

    {
      booking_ids: ids,
      details:     "booking for #{asset_id} created on #{now.day_of_week}, #{now.to_s("%F")} for #{number_of_days} #{number_of_days > 1 ? "days" : "day"}",
    }
  end

  @[Description("cancels the given booking ids")]
  def cancel_bookings(booking_ids : Array(Int64))
    logger.debug { "cancel bookings #{booking_ids}" }
    booking_ids.each do |booking_id|
      booking = staff_api.get_booking(booking_id).get
      user_id = invoked_by_user_id
      me = current_user
      unless (user_id == booking["user_id"]?.try(&.as_s)) || me.email.downcase.in?({booking["user_email"].as_s, booking["booked_by_email"].as_s})
        raise "can only cancel bookings owned by #{me.email} - this booking is owned by #{booking["user_email"]}"
      end
      staff_api.booking_delete(booking_id, "chatgpt")
    end
    "bookings have been removed"
  end

  @[Description("book a visitor to the building")]
  def invite(visitor_name : String, visitor_email : String, day_offset : Int32 = 0, date : Time? = nil, number_of_days : Int32 = 1)
    logger.debug { "inviting visitor to the building #{visitor_name}: #{visitor_email}, day offset #{day_offset} for num days #{number_of_days}" }

    # select a random level
    level = levels.first
    user_id = invoked_by_user_id
    me = current_user
    current_time = Time.local(timezone)
    now = current_time.at_beginning_of_day

    # adjust the offset if a date has been selected
    if date
      desired_date = date.in(timezone).at_beginning_of_day
      day_offset = (desired_date - now).total_days.round_away.to_i
    end

    raise "booking in the past is not permitted" unless day_offset > 0 || (day_offset == 0 && current_time.hour < 16)

    visitor_email = visitor_email.downcase

    ids = (day_offset...(day_offset + number_of_days)).map do |offset|
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
      resp.get["id"].as_i64
    end
    starting = now + day_offset.days

    {
      booking_ids: ids,
      details:     "invited #{visitor_email} to the office on #{starting.day_of_week}, #{starting.to_s("%F")} for #{number_of_days} #{number_of_days > 1 ? "days" : "day"}",
    }
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
    getter features : Array(String)
    getter email : String?
    getter capacity : Int32 = 0

    getter level_id : String
    getter level_name : String
    getter map_id : String? = nil

    # getter images : Array(String)

    def initialize(level : Zone, system : JSON::Any)
      sys = system.as_h
      @id = sys["id"].as_s
      @name = sys["display_name"]?.try(&.as_s?) || sys["name"].as_s
      # @description = sys["description"]?.try &.as_s? || ""
      @features = sys["features"].as_a.map(&.as_s)
      # @images = sys["images"].as_a.map(&.as_s)
      @email = sys["email"]?.try &.as_s?
      @capacity = sys["capacity"].as_i
      @map_id = sys["map_id"]?.try &.as_s?
      @level_id = level.id
      @level_name = level.display_name || level.name
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

    getter id : Int64? = nil
    getter starting : Time
    getter ending : Time

    getter booking_type : String
    getter asset_id : String
    getter user_id : String?
    getter user_email : String
    getter user_name : String
    getter level_id : String
    getter level_name : String

    # getter booked_by_email : String
    # getter booked_by_name : String

    getter checked_in : Bool = false

    def initialize(level : Zone, book : JSON::Any, timezone : Time::Location)
      b = book.as_h
      @id = b["id"].as_i64
      @starting = Time.unix(b["booking_start"].as_i64).in(timezone)
      @ending = Time.unix(b["booking_end"].as_i64).in(timezone)
      @booking_type = b["booking_type"].as_s
      @asset_id = b["asset_id"].as_s
      @user_id = b["user_id"]?.try &.as_s?
      @user_email = b["user_email"].as_s
      @user_name = b["user_name"].as_s
      @checked_in = b["checked_in"].as_bool
      @level_id = level.id
      @level_name = level.display_name || level.name

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

  class Zone
    include JSON::Serializable

    getter id : String
    getter name : String
    getter display_name : String?
    getter tags : Array(String)

    property bookable_desk_count : Int32? = nil
    property desk_features : Array(String)? = nil

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
