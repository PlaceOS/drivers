require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "place_calendar"
require "../place/booking_model"
require "./parking_rest_api_models"

# reserved parking spaces
# check if any of these have been made available
# fetch the parking bookings

class Place::Parking::Approvals < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "PlaceOS Parking Approvals"
  generic_name :ParkingApprovals
  description %(helper for handling parking bookings with orbility)

  accessor staff_api : StaffAPI_1
  accessor calendar : Calendar_1
  accessor orbility : Orbility_1
  accessor location : LocationServices_1

  protected def mailer
    system.implementing(Interface::Mailer)[0]
  end

  default_settings({
    # time in minutes
    poll_rate: 10,

    # days ahead to approve bookings
    # match the Bookings driver (shared setting) as we check events in this period
    _cache_days: 30,

    # The user model ext that contains car license plate numbers
    # returned as unmapped.car_license_ext on the user models
    car_license_ext:     "extension_8418f8b70257442aa5e75af8f2ff38a3_carLicense",
    orbility_product_id: 6,

    # calendar.get_groups("user@email") # => group.id or group.email
    auto_approval_groups: ["azure_group_email_or_id"],

    # authority to monitor
    authority_id: "authority-XX7",

    date_time_format: "%c",
    time_format:      "%l:%M%p",
    date_format:      "%A, %-d %B",
  })

  @timezone : Time::Location = Time::Location::UTC
  @poll_rate : Time::Span = 10.minutes
  @auto_approval_groups : Array(String) = [] of String
  @orbility_product_id : Int64? = nil

  # See: https://crystal-lang.org/api/0.35.1/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  # approval period, using Booking driver cache_days setting
  @approval_period : Int32 = 30

  def on_load
    monitor("staff/booking/changed") do |_subscription, payload|
      logger.debug { "received booking changed event #{payload}" }
      booking_changed Booking.from_json(payload)
    end
    on_update
  end

  def on_update
    @poll_rate = (setting?(Int32, :poll_rate) || 20).minutes
    timezone = config.control_system.not_nil!.timezone.presence || setting?(String, :time_zone).presence || "Australia/Sydney"
    @timezone = Time::Location.load(timezone)
    @auto_approval_groups = (setting?(Array(String), :auto_approval_groups) || [] of String).map do |id|
      id.includes?('@') ? id.downcase : id
    end
    @car_license_ext = setting(String, :car_license_ext)
    @orbility_product_id = setting?(Int64, :orbility_product_id)

    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"

    @approval_period = setting?(Int32, :cache_days) || 30

    schedule.clear
    schedule.every(@poll_rate) { process_parking_bookings }
  end

  class ZoneDetails
    include JSON::Serializable

    property id : String
    property name : String
    property display_name : String?
    property location : String?
    property tags : Array(String)
    property parent_id : String?
  end

  getter! car_license_ext : String
  getter building_id : String { location.building_id.get.as_s }
  getter building_zone : ZoneDetails do
    ZoneDetails.from_json staff_api.zone(building_id).get.to_json
  end

  # ===================================
  # Parking Spaces
  # ===================================

  PARKING_SPACES = "_PARKING_SPACES_"

  protected getter parking_spaces_asset_type : String do
    category = staff_api.asset_categories(hidden: true).get.as_a.find { |cat| cat["name"].as_s == PARKING_SPACES }
    raise "no parking space asset category (#{PARKING_SPACES})" unless category
    type = staff_api.asset_types(category_id: category["id"].as_s).get.as_a.find! { |cat| cat["name"].as_s == PARKING_SPACES }
    type["id"].as_s
  end

  # parking space ids that have not been assigned to anyone
  def parking_space_ids : Array(String)
    staff_api.assets(type_id: parking_spaces_asset_type, zones: {building_id}, bookable: true).get.as_a.compact_map { |json|
      assigned_to = json["assigned_to"]?.try(&.as_s?).presence
      json["id"].as_s if assigned_to.nil?
    }
  end

  # ===================================
  # Assigned desks
  # TODO:: migrate to asset version
  # ===================================

  getter building_level_ids : Array(String) do
    staff_api.zones(parent: building_id, tags: {"level"}).get.as_a.map do |zone|
      zone["id"].as_s
    end
  end

  # return users who have assigned desks
  getter assigned_desks : Array(String) do
    logger.debug { "getting list of assigned desks in this building" }
    assigned = [] of String
    building_level_ids.each do |level|
      logger.debug { " - processing level #{level}" }

      all_desks = staff_api.metadata(level, "desks").get.dig?("desks", "details")
      if all_desks
        desks = all_desks.as_a
        desks.each do |desk|
          if assignment = desk["assigned_to"]?.try(&.as_s?.presence.try(&.downcase))
            assigned << assignment
          end
        end
      end
    end

    logger.debug { " - found #{assigned.size} assignments" }
    assigned
  end

  # ===================================
  # Monitoring desk bookings
  # ===================================

  BOOKING_TYPE = "parking"

  protected def booking_changed(event)
    return unless event.booking_type == BOOKING_TYPE
    return unless event.zones.includes?(building_id)
    return if event.recurring? # this will be an allocated parking spot

    logger.debug { "booking_changed: parking request is in this building\n#{event}" }

    case event.action
    when "create"
      return if event.approved
      @sync_mutex.synchronize { check_approval(event) }
    when "cancelled", "rejected"
      @sync_mutex.synchronize { cleanup_parking(event, event.action == "rejected") }
      # when "changed"
      # we're ignoring change events
    else
      # ignore the update (approve)
      logger.debug { "booking event #{event.action} was ignored" }
      return
    end
  end

  protected def cleanup_parking(booking : Booking, rejected : Bool) : Nil
    return if booking.process_state == "reject_sent"

    if booking_id = booking.extension_data["orbility_id"]?.try(&.as_s)
      logger.info { "booking #{booking.id}, revoking free parking #{booking_id}" }
      orbility.delete_booking(booking_id)
    end

    rejection_email(booking) if rejected

    staff_api.booking_state(
      booking_id: booking.id,
      state: "reject_sent",
      instance: booking.instance,
    ).get
  end

  protected def check_approval(event : Booking) : Nil
    logger.debug { "check_approval: #{event.id} (#{event.user_email})" }

    # check if this booking can be auto-approved
    if auto_approve?(event)
      logger.debug { " - parking is auto approved" }
      if assign_parking_space(event)
        logger.debug { " - parking space assigned" }
        approve(event)
        logger.debug { " - request approved" }
        create_parking_booking(event)
        logger.debug { " - user emailed" }
      elsif event.asset_ids.first.starts_with?("unallocated")
        logger.debug { " - no parking spots available" }
        # email to say there are no parking spaces available however you have been put on a waiting list
        wait_list_email(event)
      end
    else
      logger.debug { " - requires approval" }

      # email that we're waiting for approval
      waiting_approval_emails(event)
    end
  end

  protected def auto_approve?(booking : Booking) : Bool
    # check booked_by and
    user_emails = [booking.booked_by_email.downcase, booking.user_email.downcase].uniq!

    # check if booking user is in the auto approval group
    approved_groups = @auto_approval_groups
    if !approved_groups.empty?
      groups = user_emails.flat_map do |user_email|
        # could be an external user so need to handle a bad response
        calendar.get_groups(user_email).get.as_a rescue [] of JSON::Any
      end

      groups.each do |group|
        if group["id"].as_s.in?(approved_groups)
          return true
        end

        if group_email = group["email"]?.try(&.as_s.downcase)
          return true if group_email.in?(approved_groups)
        end
      end
    end

    # check if they don't work in the building and have an event
    booked_user = user_emails[1]
    !assigned_desks.includes?(booked_user) && !location.bookings_for(booked_user).get.as_a.empty?
  end

  protected def assign_parking_space(booking : Booking) : Bool
    return false unless booking.asset_ids.first.starts_with?("unallocated")

    all_parking_spaces = parking_space_ids
    booked_assets = staff_api.query_bookings(
      type: "parking",
      period_start: booking.booking_start,
      period_end: booking.booking_end,
      zones: {building_id},
      approved: true,
    ).get.as_a.map { |book| book["asset_ids"].as_a.first.as_s }

    available = all_parking_spaces - booked_assets
    return false if available.empty?

    asset_id = available.sample
    booking.asset_id = asset_id
    booking.asset_ids = [asset_id]

    true
  end

  # approving a parking booking involves allocating a parking space
  # and then approving the booking.
  protected def approve(booking : Booking)
    staff_api.update_booking(
      booking_id: booking.id,
      asset_id: booking.asset_id,
      asset_ids: booking.asset_ids,
      instance: booking.instance,
    ).get
    staff_api.approve(booking.id, booking.instance).get
  end

  alias DirUser = ::PlaceCalendar::Member

  PLATES_DEFAULT = [] of String

  # extract users number plates from Azure
  protected def user_plates(user) : Array(String)
    license_plates = PLATES_DEFAULT
    if unmapped = user.unmapped
      license_plates = unmapped[car_license_ext]?.try(&.as_a.map(&.as_s)) || PLATES_DEFAULT
    end
    license_plates.reject! { |plate| plate.blank? || plate.size > 12 }
  end

  # creates a pre-booking and saves the parking ID to the booking
  protected def create_parking_booking(booking : Booking)
    license_plate = booking.extension_data["plate_number"]?.try(&.as_s).presence
    license_plate = nil if license_plate && license_plate.size > 12

    if license_plate.nil?
      user_json = calendar.get_user(booking.user_email, additional_fields: {car_license_ext}).get.to_json rescue nil
      license_plate = if user_json
                        user = DirUser.from_json(user_json)
                        user_plates(user).first?
                      end
    end

    booking_number = orbility.add_booking(Orbility::PreBooking.new(
      start_date: Time.unix(booking.booking_start),
      end_date: Time.unix(booking.booking_end),
      user_info: Orbility::UserInfo.new(booking.user_name, license_plate),
      access: Orbility::Access.new(:multi_pass, @orbility_product_id),
    )).get.as_s

    booking.extension_data["orbility_id"] = JSON::Any.new(booking_number)

    staff_api.update_booking(
      booking_id: booking.id,
      extension_data: booking.extension_data,
      instance: booking.instance,
    ).get

    # email QR code to user
    approved_email(booking)
  end

  # ===================================
  # Background Sync
  # ===================================

  @sync_mutex : Mutex = Mutex.new
  @sync_requests : UInt32 = 0_u32
  @syncing : Bool = false

  def process_parking_bookings
    @sync_requests += 1
    return "already processing" if @syncing

    @sync_mutex.synchronize do
      begin
        @syncing = true
        @sync_requests = 0
        query_parking_bookings
      ensure
        @syncing = false
      end
    end

    spawn { process_parking_bookings } if @sync_requests > 0
    "parking allocated"
  end

  # a backup query that runs periodically
  protected def query_parking_bookings
    # reset the list of assigned desks
    @assigned_desks = nil

    starting = Time.utc.to_unix
    ending = @approval_period.days.from_now.to_unix

    logger.debug { "polling active bookings" }

    # Grab all the active bookings (unapproved / approved)
    # sort by submission time
    bookings = Array(Booking).from_json(staff_api.query_bookings(
      type: BOOKING_TYPE,
      zones: {building_id},
      period_start: starting,
      period_end: ending,
      limit: 10_000,
    ).get.to_json).reject(&.instance).sort! { |a, b| a.created.as(Int64) <=> b.created.as(Int64) }

    bookings.each do |booking|
      if booking.asset_ids.first.starts_with?("unallocated")
        # attempt to allocate / approve them
        check_approval(booking)
      else
        # the booking state will prevent duplicate emails being sent
        if booking.extension_data.has_key?("orbility_id")
          approved_email(booking)
        else
          create_parking_booking(booking)
        end
      end
    end

    logger.debug { "polling deleted / rejected bookings" }

    # check rejected
    bookings = Array(Booking).from_json(staff_api.query_bookings(
      type: BOOKING_TYPE,
      zones: {building_id},
      period_start: starting,
      period_end: ending,
      limit: 10_000,
      rejected: true
    ).get.to_json)

    bookings.each do |booking|
      next if booking.instance
      cleanup_parking(booking, rejected: true)
    end

    # check deleted
    bookings = Array(Booking).from_json(staff_api.query_bookings(
      type: BOOKING_TYPE,
      zones: {building_id},
      period_start: starting,
      period_end: ending,
      limit: 10_000,
      deleted: true,
    ).get.to_json)

    bookings.each do |booking|
      next if booking.instance
      cleanup_parking(booking, rejected: false)
    end
  end

  # ===================================
  # Mailer templates
  # ===================================

  def template_fields : Array(TemplateFields)
    time_now = Time.utc.in(@timezone)
    common_fields = [
      {name: "visitor_email", description: "Email address of the visiting guest"},
      {name: "visitor_name", description: "Full name of the visiting guest"},
      {name: "building_name", description: "Name of the building the parking space is located"},
      {name: "parking_start", description: "Start time (e.g., #{time_now.to_s(@time_format)})"},
      {name: "parking_date", description: "Date of the visit (e.g., #{time_now.to_s(@date_format)})"},
      {name: "parking_time", description: "Number hours booking is valid for (or 'all day' for 24-hours)"},
    ]

    approval_fields = common_fields + [
      {name: "approver_name", description: "Name of the person approving the parking"},
      {name: "approver_email", description: "Email address of the approver"},
    ]

    [
      TemplateFields.new(
        trigger: {"parking_request", "approved"},
        name: "Parking Approved",
        description: "Provides the recipient a QR code for free parking at the specified time",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "wait_list"},
        name: "Parking Wait List",
        description: "Notifies the recipient that there is no parking available however they may obtain a spot if someone cancels",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "approval_required"},
        name: "Parking Approval Required",
        description: "Notifies the recipient that approval is required. Please wait for the approver to get back to you.",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "approval_request"},
        name: "Parking Approval Requested",
        description: "Notifies the approver group that someone is requesting free parking.",
        fields: approval_fields
      ),
      TemplateFields.new(
        trigger: {"parking_request", "rejected"},
        name: "Parking Approval Rejected",
        description: "Notifies the approver group that someone is requesting free parking.",
        fields: approval_fields
      ),
    ]
  end

  protected def approved_email(booking : Booking)
    return if booking.process_state == "qr_sent"

    user_email = booking.user_email
    local_start_time = Time.unix(booking.booking_start).in(@timezone)
    local_end_time = Time.unix(booking.booking_end).in(@timezone)

    if json = booking.extension_data["orbility_id"]?
      qr_content = "MPK_RES=#{json.as_s}"
      attach = [
        {
          file_name:  "qr.png",
          content:    qr_content,
          content_id: user_email,
        },
      ]
    else
      logger.warn { "no orbility booking for approved parking: #{user_email} @ #{local_start_time}" }
    end

    event_span = local_end_time - local_start_time
    event_period = if booking.all_day || event_span == 24.hours
                     "all day"
                   else
                     "#{event_span.total_hours}hours"
                   end

    mailer.send_template(
      user_email,
      {"parking_request", "approved"}, # Template selection: "visitor_invited" action, "visitor" email
      {
      visitor_email: user_email,
      visitor_name:  booking.user_name,
      building_name: building_zone.display_name.presence || building_zone.name,
      parking_start: local_start_time.to_s(@time_format),
      parking_date:  local_start_time.to_s(@date_format),
      parking_time:  event_period,
    },
      attach
    )

    staff_api.booking_state(
      booking_id: booking.id,
      state: "qr_sent",
      instance: booking.instance,
    ).get
  end

  WAITING_SENT = {"waiting_approval", "qr_sent"}

  protected def waiting_approval_emails(booking : Booking)
    return if WAITING_SENT.includes?(booking.process_state)

    user_email = booking.user_email
    local_start_time = Time.unix(booking.booking_start).in(@timezone)
    local_end_time = Time.unix(booking.booking_end).in(@timezone)

    event_span = local_end_time - local_start_time
    event_period = if booking.all_day || event_span == 24.hours
                     "all day"
                   else
                     "#{event_span.total_hours}hours"
                   end

    mailer.send_template(
      user_email,
      {"parking_request", "approval_required"},
      {
        visitor_email: user_email,
        visitor_name:  booking.user_name,
        building_name: building_zone.display_name.presence || building_zone.name,
        parking_start: local_start_time.to_s(@time_format),
        parking_date:  local_start_time.to_s(@date_format),
        parking_time:  event_period,
      }
    )

    # TODO:: send approval_request email to group leader?

    staff_api.booking_state(
      booking_id: booking.id,
      state: "waiting_approval",
      instance: booking.instance,
    ).get
  end

  WAIT_LIST_SENT = {"wait_list", "qr_sent"}

  protected def wait_list_email(booking : Booking)
    return if WAIT_LIST_SENT.includes?(booking.process_state)

    user_email = booking.user_email
    local_start_time = Time.unix(booking.booking_start).in(@timezone)
    local_end_time = Time.unix(booking.booking_end).in(@timezone)

    event_span = local_end_time - local_start_time
    event_period = if booking.all_day || event_span == 24.hours
                     "all day"
                   else
                     "#{event_span.total_hours}hours"
                   end

    mailer.send_template(
      user_email,
      {"parking_request", "wait_list"},
      {
        visitor_email: user_email,
        visitor_name:  booking.user_name,
        building_name: building_zone.display_name.presence || building_zone.name,
        parking_start: local_start_time.to_s(@time_format),
        parking_date:  local_start_time.to_s(@date_format),
        parking_time:  event_period,
      }
    )

    staff_api.booking_state(
      booking_id: booking.id,
      state: "wait_list",
      instance: booking.instance,
    ).get
  end

  protected def rejection_email(booking : Booking)
    user_email = booking.user_email
    local_start_time = Time.unix(booking.booking_start).in(@timezone)
    local_end_time = Time.unix(booking.booking_end).in(@timezone)

    event_span = local_end_time - local_start_time
    event_period = if booking.all_day || event_span == 24.hours
                     "all day"
                   else
                     "#{event_span.total_hours}hours"
                   end

    mailer.send_template(
      user_email,
      {"parking_request", "rejected"},
      {
        visitor_email:  user_email,
        visitor_name:   booking.user_name,
        building_name:  building_zone.display_name.presence || building_zone.name,
        parking_start:  local_start_time.to_s(@time_format),
        parking_date:   local_start_time.to_s(@date_format),
        parking_time:   event_period,
        approver_name:  booking.approver_name,
        approver_email: booking.approver_email.to_s,
      }
    )
  end
end
