require "placeos-driver"
require "placeos-driver/interface/chat_functions"
require "set"

# metadata class
require "placeos"
require "./nearby"

class Place::Workplace < PlaceOS::Driver
  include Interface::ChatFunctions

  descriptive_name "LLM Workplace interface"
  generic_name :Workplace
  description %(provides workplace introspection functions to a LLM)

  default_settings({
    # fallback if there isn't one on the zone
    time_zone: "Australia/Sydney",

    # how many days into the future a booking may be made (inclusive)
    max_booking_days: 14,

    # default desk booking window, local time (24 hour clock)
    booking_start_hour: 8,
    booking_end_hour:   20,
  })

  @fallback_timezone : Time::Location = Time::Location::UTC
  @max_booking_days : Int32 = 14
  @booking_start_hour : Int32 = 8
  @booking_end_hour : Int32 = 20

  def on_update
    timezone = config.control_system.not_nil!.timezone.presence || setting?(String, :time_zone).presence || "Australia/Sydney"
    @fallback_timezone = Time::Location.load(timezone)

    @max_booking_days = setting?(Int32, :max_booking_days) || 14
    @booking_start_hour = setting?(Int32, :booking_start_hour) || 8
    @booking_end_hour = setting?(Int32, :booking_end_hour) || 20

    # clear the level map data
    @level_data_cache = {} of String => Nearby
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
    [building] + Array(Zone).from_json(staff_api.zones(parent: building.id, tags: {"level"}).get_json).sort_by(&.name)
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
    desks = Array(Desk).from_json(all_desks.to_json).select!(&.bookable)

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

    logger.debug { "found #{desks.size} available desks" }
    desks
  end

  struct Colleagues
    include JSON::Serializable

    getter name : String
    getter email : String
    getter groups : Array(String) = [] of String

    getter desk_booked_on : Time? = nil
    getter desk_id : String? = nil
    getter desk_name : String? = nil
    getter desk_level_id : String? = nil

    def initialize(@name, @email, @groups = [] of String, @desk_booked_on = nil, @desk_id = nil, @desk_name = nil, @desk_level_id = nil)
    end
  end

  @[Description("returns a list of your colleagues and where are sitting today, a relative day in business hours or at a particular date and time. If the colleague has a desk it will return the date their desk is booked")]
  def colleagues(day_offset : Int32 = 0, date : Time? = nil) : Array(Colleagues)
    now = Time.local(timezone)

    if date
      starting = date.in(timezone)
    else
      days = day_offset.days
      starting = now.at_beginning_of_day + days + 12.hours
    end
    ending = starting + 1.hour

    user_id = invoked_by_user_id
    logger.debug { "obtaining list of colleagues for #{user_id}" }

    # `all_levels` leads with the building, and bookings are tagged with the
    # building zone too, so we have to ignore it to resolve the actual level
    level_ids = all_levels.select(&.tags.includes?("level")).map(&.id)

    colleagues = staff_api.metadata(user_id, "contacts").get.dig?("contacts", "details").try(&.as_a) || [] of JSON::Any
    colleagues.map do |colleague|
      colleague = colleague.as_h
      name = colleague["name"].as_s
      email = colleague["email"].as_s
      groups = colleague["groups"].as_a?.try(&.map(&.as_s)) || [] of String

      desk_id = nil
      desk_name = nil
      desk_level_id = nil

      # TODO:: speed this up using promises and map-reduce
      begin
        if booking = staff_api.query_bookings(type: "desk", period_start: starting.to_unix, period_end: ending.to_unix, email: email).get.as_a.first?
          desk_id = booking["asset_id"].as_s
          desk_name = booking.dig?("extension_data", "name").try(&.as_s?) || booking["description"]?.try(&.as_s?) || desk_id
          desk_level_id = (booking["zones"].as_a.map(&.as_s) & level_ids).first?
        end
      rescue error
        logger.error(exception: error) { "check for desks failed" }
      end

      if desk_id
        Colleagues.new(name, email, groups, starting, desk_id, desk_name, desk_level_id)
      else
        Colleagues.new(name, email, groups)
      end
    end
  end

  # level map svg data
  @level_data_cache : Hash(String, Nearby) = {} of String => Nearby

  protected def get_nearby_helper(desk_level_id : String) : Nearby
    if nearby = @level_data_cache[desk_level_id]?
      return nearby
    end

    levels = all_levels
    level = levels.find { |l| l.id == desk_level_id }
    raise "unknown level id #{desk_level_id}, must be one of #{levels.map(&.id)}" unless level

    map_id = level.map_id.presence
    raise "level #{desk_level_id} does not have a map configured" unless map_id

    map_data = begin
      response = HTTP::Client.get URI.parse(map_id)
      raise "unexpected response #{response.status_code}" unless response.success?
      response.body
    rescue error
      logger.warn(exception: error) { "failed to obtain map data for level #{desk_level_id}" }
      raise "failed to obtain map data for level #{desk_level_id}"
    end

    @level_data_cache[desk_level_id] = Nearby.new(map_data)
  end

  # Desks are booked by id, but they are drawn on the level map under their
  # map_id, so we have to translate between the two. Returns desk_id => map_id
  protected def desk_map_ids(level_id : String) : Hash(String, String)
    all_desks = staff_api.metadata(level_id, "desks").get.dig?("desks", "details")
    raise "no desks configured on level #{level_id}" unless all_desks
    Array(Desk).from_json(all_desks.to_json).to_h { |desk| {desk.id, desk.map_id} }
  end

  @[Description("given a desk_id this returns nearby desks in order of how close they are. You can provide a colleagues desk_id for instance and then pick the first id that matches one of the desks available for booking")]
  def nearby_desks(desk_level_id : String, desk_id : String) : Array(String)
    map = get_nearby_helper(desk_level_id)
    map_ids = desk_map_ids(desk_level_id)

    seated_at = map_ids[desk_id]?
    raise "could not find a desk with id '#{desk_id}' on level #{desk_level_id}, maybe you passed the desk name?" unless seated_at

    # anything drawn on the map without a desk configured can't be booked
    desk_ids = map_ids.invert
    map.find_near(seated_at, "desk").compact_map { |map_id| desk_ids[map_id]? }
  end

  struct NearbyColleagues
    include JSON::Serializable

    getter level_id : String
    getter number_of_colleagues : Int32

    # a unique list of the groups all these colleagues are in
    getter groups : Array(String) = [] of String

    # a weighted list of desks, let's say a you have 3 colleagues on a level
    # and a desk is second in the list for one colleague and 4th for the other two colleagues it
    # may appear higher in this list than the first desk in any of the individual colleagues nearby lists
    getter nearby_desks : Array(String) = [] of String

    def initialize(@level_id, @number_of_colleagues, @groups, @nearby_desks)
    end
  end

  # how many ranked desks we return per level
  NEARBY_DESK_RESULTS = 10

  @[Description("checks if your colleagues have booked desks on the day specified and ranks desks by proximity")]
  def desks_near_colleagues(day_offset : Int32 = 0, date : Time? = nil) : Array(NearbyColleagues)
    colleagues = colleagues(day_offset, date)
    seated = colleagues.select { |colleague| colleague.desk_id && colleague.desk_level_id }
    raise "none of your colleagues has booked a desk on this day" if seated.empty?

    by_level = seated.group_by { |colleague| colleague.desk_level_id.not_nil! }

    by_level.compact_map { |level_id, colleagues_on_level|
      begin
        nearby_colleagues(level_id, colleagues_on_level, day_offset, date)
      rescue error
        # a level without a map, or with no desks left, shouldn't hide the others
        logger.warn(exception: error) { "unable to rank desks on level #{level_id}" }
        nil
      end
    }.sort_by! { |level| -level.number_of_colleagues }
  end

  protected def nearby_colleagues(
    level_id : String,
    colleagues_on_level : Array(Colleagues),
    day_offset : Int32,
    date : Time?,
  ) : NearbyColleagues?
    map = get_nearby_helper(level_id)
    map_ids = desk_map_ids(level_id)

    # only rank desks the user can actually book on the day in question
    bookable = desks(level_id, day_offset, date)
    return nil if bookable.empty?

    # map_id => the desk that can be booked there
    available = bookable.to_h { |desk| {desk.map_id, desk} }

    # Borda count: every colleague ranks the available desks by proximity and
    # awards points in that order, so a desk that is a decent walk for several
    # colleagues beats one that is closest to a single colleague.
    scores = Hash(String, Int32).new(0)

    colleagues_on_level.each do |colleague|
      desk_id = colleague.desk_id.not_nil!
      seated_at = map_ids[desk_id]?
      unless seated_at
        logger.debug { "desk #{desk_id} is no longer configured on level #{level_id}" }
        next
      end

      ranked = begin
        map.find_near(seated_at, "desk", Int32::MAX)
      rescue error
        # the colleague may be sitting at a desk that isn't drawn on this map
        logger.debug { "could not locate desk #{seated_at} on the #{level_id} map: #{error.message}" }
        next
      end

      ranked.select! { |map_id| available.has_key?(map_id) }
      ranked.each_with_index { |map_id, index| scores[map_id] += ranked.size - index }
    end

    return nil if scores.empty?

    nearby = scores.to_a
      .sort_by! { |(map_id, score)| {-score, map_id} }
      .first(NEARBY_DESK_RESULTS)
      .map { |(map_id, _score)| available[map_id].id }

    groups = colleagues_on_level.flat_map(&.groups).uniq!

    NearbyColleagues.new(level_id, colleagues_on_level.size, groups, nearby)
  end

  @[Description("books an asset, such as a desk, for the number of days specified, starting on the day offset. For desk bookings use booking_type: desk")]
  def book_relative(booking_type : String, asset_id : String, level_id : String, day_offset : Int32 = 0, number_of_days : Int32 = 1)
    logger.debug { "booking relative #{booking_type}, asset #{asset_id} on level #{level_id}, day offset #{day_offset} for num days #{number_of_days}" }
    raise "parking bookings are not enabled with A.I. at this time" if booking_type.strip.downcase == "parking"

    # ensure the level id exists
    level = levels.find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in the building. Make sure you've obtained the list of levels." unless level

    user_id = invoked_by_user_id
    me = current_user
    current_time = Time.local(timezone)
    now = current_time.at_beginning_of_day

    raise "booking in the past is not permitted" unless day_offset > 0 || (day_offset == 0 && current_time.hour < 18)
    ensure_within_booking_window(day_offset + number_of_days - 1)

    # ensure the asset exists if we can check for it
    desk = nil
    case booking_type
    when "desk"
      all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
      raise "no desks found on level #{level_id}, ensure this id is correct" unless all_desks
      desks = Array(Desk).from_json(all_desks.to_json)
      desk = desks.find { |d| d.id == asset_id }

      raise "could not find a desk with id '#{asset_id}', maybe you passed the desk name?" unless desk
    end

    friendly_name = desk.try(&.name) || asset_id

    ids = (day_offset...(day_offset + number_of_days)).map do |offset|
      # calculate the offset time
      days = offset.days
      starting = now + days + @booking_start_hour.hours
      ending = now + days + @booking_end_hour.hours

      resp = staff_api.create_booking(
        booking_type: booking_type,
        asset_id: asset_id,
        asset_name: friendly_name,
        user_id: user_id,
        user_email: me.email,
        user_name: me.name,
        zones: booking_zones(level_id),
        booking_start: starting.to_unix,
        booking_end: ending.to_unix,
        description: friendly_name,
        time_zone: timezone.to_s,
        extension_data: booking_extension_data(asset_id, desk),
        utm_source: "chatgpt"
      )
      resp.get["id"].as_i64
    end
    starting = now + day_offset.days

    {
      booking_ids: ids,
      details:     "booking of asset_id '#{asset_id}' with name '#{friendly_name}' created on #{starting.day_of_week}, #{starting.to_s("%F")} for #{number_of_days} #{number_of_days > 1 ? "days" : "day"}",
    }
  end

  @[Description("books an asset, such as a desk, for the number of days specified, the start date must be in ISO 8601 format with the correct timezone. For desk bookings use booking_type: desk")]
  def book_on(booking_type : String, asset_id : String, level_id : String, date : Time, number_of_days : Int32 = 1)
    logger.debug { "booking on #{booking_type}, asset #{asset_id} on level #{level_id}, date #{date} for num days #{number_of_days}" }
    raise "parking bookings are not enabled with A.I. at this time" if booking_type.strip.downcase == "parking"

    # ensure the level id exists
    level = levels.find { |l| l.id == level_id }
    raise "could not find level_id #{level_id} in the building. Make sure you've obtained the list of levels." unless level

    user_id = invoked_by_user_id
    me = current_user
    now = date.in(timezone).at_beginning_of_day
    current_time = Time.local(timezone)
    raise "booking in the past is not permitted" unless current_time < now || (current_time - now) < 18.hours

    # days between today and the last day being booked
    days_ahead = (now - current_time.at_beginning_of_day).total_days.round_away.to_i
    ensure_within_booking_window(days_ahead + number_of_days - 1)

    # ensure the asset exists if we can check for it
    desk = nil
    case booking_type
    when "desk"
      all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
      raise "no desks found on level #{level_id}, ensure this id is correct" unless all_desks
      desks = Array(Desk).from_json(all_desks.to_json)
      desk = desks.find { |d| d.id == asset_id }

      raise "could not find a desk with id '#{asset_id}', maybe you passed the desk name?" unless desk
    end

    friendly_name = desk.try(&.name) || asset_id

    ids = (0...number_of_days).map do |offset|
      # calculate the offset time
      days = offset.days
      starting = now + days + @booking_start_hour.hours
      ending = now + days + @booking_end_hour.hours

      resp = staff_api.create_booking(
        booking_type: booking_type,
        asset_id: asset_id,
        asset_name: friendly_name,
        user_id: user_id,
        user_email: me.email,
        user_name: me.name,
        zones: booking_zones(level_id),
        booking_start: starting.to_unix,
        booking_end: ending.to_unix,
        description: friendly_name,
        time_zone: timezone.to_s,
        extension_data: booking_extension_data(asset_id, desk),
        utm_source: "chatgpt"
      )
      resp.get["id"].as_i64
    end

    {
      booking_ids: ids,
      details:     "booking of asset_id '#{asset_id}' with name '#{friendly_name}' created on #{now.day_of_week}, #{now.to_s("%F")} for #{number_of_days} #{number_of_days > 1 ? "days" : "day"}",
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
    getter name : String { id }
    getter bookable : Bool { true }
    getter groups : Array(String) = [] of String
    getter features : Array(String) = [] of String
    getter map_id : String { id }
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

  # raises if the furthest day being booked is beyond the configured window.
  # `offset` is the number of days past today of the last booking requested.
  protected def ensure_within_booking_window(offset : Int32)
    return if offset <= @max_booking_days
    raise "bookings cannot be made more than #{@max_booking_days} days in advance"
  end

  # the zones a booking is tagged with, mirroring the hierarchy the mobile app
  # submits: [org, region?, building, level]
  protected def booking_zones(level_id : String) : Array(String)
    building_zone_chain.dup << level_id
  end

  # the building's ancestor zones (region, org, ...) plus the building itself,
  # ordered top-most first. Cached as the parent chain rarely changes.
  getter building_zone_chain : Array(String) do
    chain = [building.id]
    parent_id = building.parent_id
    # walk up the tree, guarding against unexpectedly deep trees / cycles
    10.times do
      break unless parent_id
      parent = Zone.from_json(staff_api.zone(parent_id).get_json)
      chain.unshift parent.id
      parent_id = parent.parent_id
    end
    chain
  end

  # extension data mirroring the mobile app booking form so LLM bookings render
  # identically (map placement etc.) in the workplace apps. Returned as a named
  # tuple - it's serialized to JSON on the way to the staff API.
  protected def booking_extension_data(asset_id : String, desk : Desk?)
    asset_name = desk.try(&.name) || asset_id
    {
      assigned_asset_id:   asset_id,
      assigned_asset_name: asset_name,
      name:                asset_name,
      map_id:              desk.try(&.map_id) || asset_id,
      app_name:            "LLM",
    }
  end

  protected def staff_api
    system["StaffAPI_1"]
  end

  def current_user : User
    User.from_json staff_api.user(invoked_by_user_id).get_json
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
    getter parent_id : String? = nil

    @[JSON::Field(ignore_serialize: true)]
    getter map_id : String? = nil

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
