require "placeos-driver"
require "placeos-driver/interface/chat_functions"
require "set"

# metadata class
require "placeos"

class Place::Campus < PlaceOS::Driver
  include Interface::ChatFunctions

  descriptive_name "LLM Campus interface"
  generic_name :Campus
  description %(provides workplace introspection functions across multiple buildings to a LLM)

  default_settings({
    # fallback if there isn't one on the zone
    time_zone:     "Australia/Sydney",
    prompt_tweaks: "",
  })

  @fallback_timezone : Time::Location = Time::Location::UTC

  def on_update
    timezone = config.control_system.not_nil!.timezone.presence || setting?(String, :time_zone).presence || "Australia/Sydney"
    @fallback_timezone = Time::Location.load(timezone)
    @capabilities = nil
  end

  # =========================
  # The LLM Interface
  # =========================

  getter capabilities : String do
    String.build do |str|
      str << "this organisation has multiple buildings - call the `buildings` function to list them and ASK THE USER which building they wish to use before booking desks, car parking, meeting rooms or inviting visitors. Do not guess the building.\n"
      str << "functions for listing the levels of a specified building (use buildings to obtain a building_id, then call levels with that id)\n"
      str << "find meeting rooms within a building, filtering by capacity and or level id\n"
      str << "my current desk, car parking and guest visitor bookings across the entire organisation (no building required)\n"
      str << "Note: when booking a meeting room, preference one on the same level or closest level to my desk booking in the same building, if I have one, unless I specify a specific level. Also try to pick a room with an appropriate capacity.\n"
      str << "once candidate meeting rooms have been found, you can include the list of resource emails when getting schedules to see which rooms are available\n"
      str << "this capability also supports managing desk bookings and inviting visitors to a building\n"
      str << "the user can only hold one desk booking for themselves per day across the entire organisation - if they already have an overlapping desk booking the request will be rejected with the existing booking's details, ask them to cancel it first\n"
      str << "when the user asks to book a desk for today, the booking start will automatically snap to the next 10 minute interval to avoid booking a time already in the past\n"
      str << "cancel any bookings made on the incorrect day.\n"
      str << "do not ask for booking confirmations, once you have enough information, be assertive and perform the requested action.\n"
      str << "use your intuition and be decisive, if the user requests the 'first floor' and there is a 'level 1' these are the same thing.\n"
      str << (setting?(String, :prompt_tweaks).presence || "")
    end
  end

  @[Description("returns desks, car parking spaces and visitors I have booked across the entire organisation. day_offset: 0 will return todays schedule, day_offset: 1 will return tomorrows schedule etc. If you provide a date, in ISO 8601 format and the correct timezone, the date will be used.")]
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
        zones: {org.id},
        user: invoked_by_user_id,
        email: me.email
      ).get.as_a.compact_map { |b| to_friendly_booking(b) }
    end
  end

  @[Description("returns the list of buildings in this organisation. The LLM MUST call this and ask the user which building they wish to use before any booking related operations.")]
  def buildings : Array(Building)
    logger.debug { "listing buildings in the organisation" }
    all_buildings.values.map { |zone| Building.new(zone) }
  end

  @[Description("returns the building details and list of levels for the specified building_id. Use this to obtain level_ids. The building_id must come from the `buildings` function.")]
  def levels(building_id : String) : Array(Zone)
    logger.debug { "getting list of levels for building #{building_id}" }
    l = all_levels(building_id)
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

  @[Description("returns the list of meeting rooms in the specified building, filtering by capacity or level")]
  def meeting_rooms(building_id : String, minimum_capacity : Int32 = 1, level_id : String? = nil)
    logger.debug { "listing meeting rooms in building #{building_id} on level #{level_id} with capacity #{minimum_capacity}" }

    # ensure the building exists
    building(building_id)

    # ensure the level id exists if provided
    if level_id
      level = all_levels(building_id).find { |l| l.id == level_id }
      raise "could not find level_id #{level_id} in building #{building_id}. Make sure you've obtained the list of levels." unless level
    end

    zone_id = level_id || building_id
    staff_api.systems(zone_id: zone_id, capacity: minimum_capacity, bookable: true).get.as_a.compact_map { |s| to_friendly_system(s) }
  end

  alias PlaceZone = PlaceOS::Client::API::Models::Zone
  alias Metadata = Hash(String, PlaceOS::Client::API::Models::Metadata)
  alias ChildMetadata = Array(NamedTuple(zone: PlaceZone, metadata: Metadata))

  @[Description("returns the list of desks available for booking in the specified building on the level and day specified. If the level has desk features then you can also filter by features.")]
  def desks(building_id : String, level_id : String, day_offset : Int32 = 0, date : Time? = nil, feature : String? = nil)
    logger.debug { "listing desks in building #{building_id} on level #{level_id}, day offset #{day_offset}" }

    # ensure the level id exists
    level = all_levels(building_id).find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in building #{building_id}. Make sure you've obtained the list of levels." unless level

    # get the list of desks for the level
    all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
    raise "no bookable desks on this level, please try another." unless all_desks
    desks = Array(Desk).from_json(all_desks.to_json)

    # calculate the offset time
    tz = building_timezone(building_id)
    if date
      starting = date.in(tz).at_beginning_of_day
    else
      now = Time.local(tz)
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

  @[Description("books an asset, such as a desk or car parking space, in the specified building for the number of days specified, starting on the day offset. For desk bookings use booking_type: desk. Optional booking_start and booking_end (ISO 8601 with timezone) override the default times; for multi-day bookings the time-of-day from each is applied to every day.")]
  def book_relative(
    building_id : String,
    booking_type : String,
    asset_id : String,
    level_id : String,
    day_offset : Int32 = 0,
    number_of_days : Int32 = 1,
    booking_start : Time? = nil,
    booking_end : Time? = nil,
  )
    logger.debug { "booking relative #{booking_type}, asset #{asset_id} in building #{building_id} on level #{level_id}, day offset #{day_offset} for num days #{number_of_days}" }

    # ensure the level id exists
    level = all_levels(building_id).find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in building #{building_id}. Make sure you've obtained the list of levels." unless level

    user_id = invoked_by_user_id
    me = current_user
    tz = building_timezone(building_id)
    current_time = Time.local(tz)
    now = current_time.at_beginning_of_day

    raise "booking in the past is not permitted" unless day_offset > 0 || (day_offset == 0 && current_time.hour < 18)

    # ensure the asset exists if we can check for it
    desk = nil
    case booking_type
    when "desk"
      all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
      raise "no desks found on level #{level_id}, ensure this id is correct" unless all_desks
      desks = Array(Desk).from_json(all_desks.to_json)
      desk = desks.find { |d| d.id == asset_id }
    end
    raise "could not find a desk with id: #{asset_id}" unless desk

    ids = (day_offset...(day_offset + number_of_days)).map do |offset|
      day_beginning = now + offset.days
      starting, ending = resolve_booking_window(day_beginning, current_time, tz, booking_start, booking_end)

      reject_existing_desk_booking(starting, ending, me.email, tz) if booking_type == "desk"

      resp = staff_api.create_booking(
        booking_type: booking_type,
        asset_id: asset_id,
        user_id: user_id,
        user_email: me.email,
        user_name: me.name,
        zones: {level_id, building_id, org.id},
        booking_start: starting.to_unix,
        booking_end: ending.to_unix,
        title: desk.name || asset_id,
        time_zone: tz.to_s,
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

  @[Description("books an asset, such as a desk or car parking space, in the specified building for the number of days specified, the start date must be in ISO 8601 format with the correct timezone. For desk bookings use booking_type: desk. Optional booking_start and booking_end (ISO 8601 with timezone) override the default times; for multi-day bookings the time-of-day from each is applied to every day.")]
  def book_on(
    building_id : String,
    booking_type : String,
    asset_id : String,
    level_id : String,
    date : Time,
    number_of_days : Int32 = 1,
    booking_start : Time? = nil,
    booking_end : Time? = nil,
  )
    logger.debug { "booking on #{booking_type}, asset #{asset_id} in building #{building_id} on level #{level_id}, date #{date} for num days #{number_of_days}" }

    # ensure the level id exists
    level = all_levels(building_id).find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in building #{building_id}. Make sure you've obtained the list of levels." unless level

    user_id = invoked_by_user_id
    me = current_user
    tz = building_timezone(building_id)
    now = date.in(tz).at_beginning_of_day
    current_time = Time.local(tz)
    raise "booking in the past is not permitted" unless current_time < now || (current_time - now) < 18.hours

    # ensure the asset exists if we can check for it
    desk = nil
    case booking_type
    when "desk"
      all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
      raise "no desks found on level #{level_id}, ensure this id is correct" unless all_desks
      desks = Array(Desk).from_json(all_desks.to_json)
      desk = desks.find { |d| d.id == asset_id }
    end
    raise "could not find a desk with id: #{asset_id}" unless desk

    ids = (0...number_of_days).map do |offset|
      day_beginning = now + offset.days
      starting, ending = resolve_booking_window(day_beginning, current_time, tz, booking_start, booking_end)

      reject_existing_desk_booking(starting, ending, me.email, tz) if booking_type == "desk"

      resp = staff_api.create_booking(
        booking_type: booking_type,
        asset_id: asset_id,
        user_id: user_id,
        user_email: me.email,
        user_name: me.name,
        zones: {level_id, building_id, org.id},
        booking_start: starting.to_unix,
        booking_end: ending.to_unix,
        title: desk.name || asset_id,
        time_zone: tz.to_s,
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

  @[Description("book a visitor to the specified building. Optional booking_start and booking_end (ISO 8601 with timezone) override the default times; for multi-day bookings the time-of-day from each is applied to every day.")]
  def invite(
    building_id : String,
    visitor_name : String,
    visitor_email : String,
    day_offset : Int32 = 0,
    date : Time? = nil,
    number_of_days : Int32 = 1,
    booking_start : Time? = nil,
    booking_end : Time? = nil,
  )
    logger.debug { "inviting visitor to building #{building_id} #{visitor_name}: #{visitor_email}, day offset #{day_offset} for num days #{number_of_days}" }

    # select a random level in the requested building
    building_levels = all_levels(building_id).select { |l| l.tags.includes?("level") }
    level = building_levels.first? || all_levels(building_id).first
    user_id = invoked_by_user_id
    me = current_user
    tz = building_timezone(building_id)
    current_time = Time.local(tz)
    now = current_time.at_beginning_of_day

    # adjust the offset if a date has been selected
    if date
      desired_date = date.in(tz).at_beginning_of_day
      day_offset = (desired_date - now).total_days.round_away.to_i
    end

    raise "booking in the past is not permitted" unless day_offset > 0 || (day_offset == 0 && current_time.hour < 16)

    visitor_email = visitor_email.downcase

    ids = (day_offset...(day_offset + number_of_days)).map do |offset|
      day_beginning = now + offset.days
      starting, ending = resolve_booking_window(day_beginning, current_time, tz, booking_start, booking_end)

      resp = staff_api.create_booking(
        booking_type: "visitor",
        asset_id: visitor_email,
        user_id: user_id,
        user_email: me.email,
        user_name: me.name,
        zones: {level.id, building_id, org.id},
        booking_start: starting.to_unix,
        booking_end: ending.to_unix,
        time_zone: tz.to_s,
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

  struct Building
    include JSON::Serializable

    getter building_id : String
    getter name : String
    getter timezone : String?

    def initialize(zone : Zone)
      @building_id = zone.id
      @name = zone.display_name.presence || zone.name
      @timezone = zone.tz
    end
  end

  struct Desk
    include JSON::Serializable

    getter id : String
    getter name : String?
    getter groups : Array(String) = [] of String
    getter features : Array(String) = [] of String
  end

  protected def to_friendly_system(system : JSON::Any) : System?
    zone_ids = system["zones"].as_a.map(&.as_s)
    bld_id = (zone_ids & all_buildings.keys).first?
    return nil unless bld_id

    the_levels = all_levels(bld_id)
    level = the_levels.find do |l|
      next nil unless l.tags.includes?("level")
      zone_ids.find { |z| z == l.id }
    end

    if level
      System.new all_buildings[bld_id], level, system
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
    getter building_id : String
    getter building_name : String
    getter map_id : String? = nil

    def initialize(building : Zone, level : Zone, system : JSON::Any)
      sys = system.as_h
      @id = sys["id"].as_s
      @name = sys["display_name"]?.try(&.as_s?) || sys["name"].as_s
      @features = sys["features"].as_a.map(&.as_s)
      @email = sys["email"]?.try &.as_s?
      @capacity = sys["capacity"].as_i
      @map_id = sys["map_id"]?.try &.as_s?
      @level_id = level.id
      @level_name = level.display_name || level.name
      @building_id = building.id
      @building_name = building.display_name || building.name
    end
  end

  protected def to_friendly_booking(booking : JSON::Any) : Booking?
    zone_ids = booking["zones"].as_a.map(&.as_s)
    bld_id = (zone_ids & all_buildings.keys).first?
    return nil unless bld_id

    the_levels = all_levels(bld_id)
    level = the_levels.find do |l|
      next nil unless l.tags.includes?("level")
      zone_ids.find { |z| z == l.id }
    end

    if level
      Booking.new all_buildings[bld_id], level, booking, building_timezone(bld_id)
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
    getter building_id : String
    getter building_name : String

    getter checked_in : Bool = false

    def initialize(building : Zone, level : Zone, book : JSON::Any, timezone : Time::Location)
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
      @building_id = building.id
      @building_name = building.display_name || building.name
    end
  end

  # Returns the start time to use for a booking on the given day.
  # For today, snaps forward to the next 10-minute interval so we never book
  # a slot that has already started. For future days, returns the start of day.
  protected def booking_start_time(day_beginning : Time, current_time : Time) : Time
    return day_beginning unless day_beginning == current_time.at_beginning_of_day

    remainder = current_time.minute % 10
    add_minutes = remainder == 0 ? 10 : (10 - remainder)
    current_time.at_beginning_of_minute + add_minutes.minutes
  end

  # Builds the {starting, ending} window for a single day of a booking.
  # If the caller supplied an explicit start/end Time, the time-of-day part is
  # applied to that day (so multi-day requests reuse the same daily window).
  # Otherwise the defaults apply: start = next-10-min for today / day start for
  # other days, end = end of day.
  protected def resolve_booking_window(day_beginning : Time, current_time : Time, tz : Time::Location, booking_start : Time?, booking_end : Time?) : {Time, Time}
    starting = if bs = booking_start
                 apply_time_of_day(day_beginning, bs.in(tz))
               else
                 booking_start_time(day_beginning, current_time)
               end

    ending = if be = booking_end
               apply_time_of_day(day_beginning, be.in(tz))
             else
               day_beginning.at_end_of_day
             end

    raise "booking end time #{ending} must be after start time #{starting}" if ending <= starting
    raise "booking start time #{starting} is in the past" if starting < current_time

    {starting, ending}
  end

  # Combines the date part of day_beginning with the time-of-day from time.
  protected def apply_time_of_day(day_beginning : Time, time : Time) : Time
    day_beginning + time.hour.hours + time.minute.minutes + time.second.seconds
  end

  # Raises if the user already has a desk booking (across any building in the
  # org) that overlaps the requested window. Only desk bookings where the user
  # is the booked-for party are considered - bookings made on behalf of someone
  # else don't count.
  protected def reject_existing_desk_booking(starting : Time, ending : Time, user_email : String, tz : Time::Location)
    existing = staff_api.query_bookings(
      type: "desk",
      period_start: starting.to_unix,
      period_end: ending.to_unix,
      zones: {org.id},
      email: user_email
    ).get.as_a

    conflicting = existing.find do |b|
      b["user_email"].as_s.downcase == user_email.downcase
    end
    return unless conflicting

    friendly = to_friendly_booking(conflicting)
    if friendly
      raise "you already have a desk booking on #{friendly.starting.to_s("%F")} for desk #{friendly.asset_id} in #{friendly.building_name} (#{friendly.level_name}) from #{friendly.starting.to_s("%H:%M")} to #{friendly.ending.to_s("%H:%M")}. Cancel that booking first if you'd like to book a different desk for the same day."
    else
      asset = conflicting["asset_id"].as_s
      s = Time.unix(conflicting["booking_start"].as_i64).in(tz)
      e = Time.unix(conflicting["booking_end"].as_i64).in(tz)
      raise "you already have a desk booking on #{s.to_s("%F")} for desk #{asset} from #{s.to_s("%H:%M")} to #{e.to_s("%H:%M")}. Cancel that booking first if you'd like to book a different desk for the same day."
    end
  end

  protected def staff_api
    system["StaffAPI_1"]
  end

  def current_user : User
    User.from_json staff_api.user(invoked_by_user_id).get.to_json
  end

  # org-wide timezone fallback - used for org-level queries like my_bookings
  getter timezone : Time::Location do
    org.time_zone || @fallback_timezone
  end

  protected def building_timezone(building_id : String) : Time::Location
    building(building_id).time_zone || timezone
  end

  struct User
    include JSON::Serializable

    getter name : String
    getter email : String
    getter groups : Array(String)
  end

  getter org : Zone { get_org }

  # cache of buildings under the org keyed by zone id
  getter all_buildings : Hash(String, Zone) do
    list = Array(Zone).from_json(staff_api.zones(tags: {"building"}).get.to_json)
    list.each_with_object({} of String => Zone) { |z, h| h[z.id] = z }
  end

  protected def building(building_id : String) : Zone
    all_buildings[building_id]? || raise "could not find building_id #{building_id} in this organisation. Use the buildings function to list available buildings."
  end

  # cache of levels per building, keyed by building_id
  @all_levels_cache = {} of String => Array(Zone)

  protected def all_levels(building_id : String) : Array(Zone)
    @all_levels_cache[building_id] ||= begin
      bld = building(building_id)
      [bld] + Array(Zone).from_json(staff_api.zones(parent: bld.id, tags: {"level"}).get.to_json).sort_by(&.name)
    end
  end

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

  # Finds the organization ID for the current location services object
  def get_org : Zone
    zones = staff_api.zones(tags: "org").get.as_a
    zone_ids = zones.map(&.[]("id").as_s)
    org_id = (zone_ids & system.zones).first

    org = zones.find! { |zone| zone["id"].as_s == org_id }
    Zone.from_json org.to_json
  rescue error
    msg = "unable to determine org zone"
    logger.warn(exception: error) { msg }
    raise msg
  end
end
