require "placeos-driver"
require "placeos-driver/interface/mailer"
require "digest/md5"
require "placeos"
require "file"

require "./booking_model"

class Place::BookingNotifier < PlaceOS::Driver
  descriptive_name "Booking Notifier"
  generic_name :BookingNotifier
  description %(notifies users when a booking takes place)

  default_settings({
    timezone:         "Australia/Sydney",
    date_time_format: "%c",
    time_format:      "%l:%M%p",
    date_format:      "%A, %-d %B",
    debug:            false,

    booking_type:        "desk",
    disable_attachments: true,

    notify: {
      zone_id1: {
        name:                 "Sydney Building 1",
        email:                ["concierge@place.com"],
        notify_manager:       true,
        notify_booking_owner: true,
        include_network_credentials:   false
      },
      zone_id2: {
        name:                 "Melb Building",
        attachments:          {"file-name.pdf" => "https://s3/your_file.pdf"},
        notify_booking_owner: true,
      },
    },
  })

  accessor staff_api : StaffAPI_1
  accessor network_provider : NetworkAccess_1  # Written for Cisco ISE Driver, but ideally compatible with others

  # We want to use the first driver in the system that is a mailer
  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  def calendar
    system[:Calendar]
  end

  def on_load
    # Some form of asset booking has occured
    monitor("staff/booking/changed") { |_subscription, payload| parse_booking(payload) }
    on_update
  end

  # See: https://crystal-lang.org/api/latest/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"
  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")
  @debug : Bool = false

  @booking_type : String = "desk"
  @bookings_checked : UInt64 = 0_u64
  @error_count : UInt64 = 0_u64

  @disable_attachments : Bool = true

  # Zone_id => notify settings
  @notify_lookup : Hash(String, SiteDetails) = {} of String => SiteDetails

  class SiteDetails
    include JSON::Serializable

    getter name : String
    getter email : Array(String) { [] of String }
    getter attachments : Hash(String, String) { {} of String => String }
    getter notify_manager : Bool?
    getter notify_booking_owner : Bool?
    getter include_network_credentials : Bool?
  end

  def on_update
    @booking_type = setting?(String, :booking_type).presence || "desk"

    time_zone = setting?(String, :calendar_time_zone).presence || "Australia/Sydney"
    @time_zone = Time::Location.load(time_zone)
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"
    @debug = setting?(Bool, :debug) || false

    @notify_lookup = setting(Hash(String, SiteDetails), :notify)
    attach = setting?(Bool, :disable_attachments)
    @disable_attachments = attach.nil? ? true : !!attach

    schedule.clear
    schedule.every(5.minutes) { check_bookings }
  end

  # Booking id => event, timestamp
  @debounce = {} of Int64 => {String?, Int64}

  protected def parse_booking(payload)
    logger.debug { "received booking event payload: #{payload}" }
    booking_details = Booking.from_json payload

    # Ignore when a bookings state is updated
    return if {"process_state", "metadata_changed"}.includes?(booking_details.action)
    return if booking_details.action.nil?

    # Ignore the same event in a short period of time
    previous = @debounce[booking_details.id]?
    return if previous && previous[0] == booking_details.action
    @debounce[booking_details.id] = {booking_details.action, Time.utc.to_unix}

    building_zone, notify_details, attachments = get_building_name(booking_details.zones)
    return unless notify_details && building_zone && attachments

    building_key = notify_details.name.downcase.gsub(' ', '_')

    timezone = booking_details.timezone.presence || @time_zone.name
    location = Time::Location.load(timezone)

    # https://crystal-lang.org/api/0.35.1/Time/Format.html
    # date and time (Tue Apr 5 10:26:19 2016)
    starting = Time.unix(booking_details.booking_start).in(location)
    ending = Time.unix(booking_details.booking_end).in(location)

    # Ignore changes to meetings that have already ended
    return if Time.utc > ending

    attach = attachments.first?

    network_username = network_password = nil
    if notify_details.include_network_credentials
      network_username, network_password = fetch_network_user(booking_details.user_email, booking_details.user_name)
    end

    args = {
      booking_id:     booking_details.id,
      start_time:     starting.to_s(@time_format),
      start_date:     starting.to_s(@date_format),
      start_datetime: starting.to_s(@date_time_format),
      end_time:       ending.to_s(@time_format),
      end_date:       ending.to_s(@date_format),
      end_datetime:   ending.to_s(@date_time_format),
      starting_unix:  booking_details.booking_start,

      asset_id:   booking_details.asset_id,
      user_id:    booking_details.user_id,
      user_email: booking_details.user_email,
      user_name:  booking_details.user_name,
      reason:     booking_details.title,

      level_zone:    booking_details.zones.reject { |z| z == building_zone }.first?,
      building_zone: building_zone,
      building_name: notify_details.name,

      approver_name:  booking_details.approver_name,
      approver_email: booking_details.approver_email,

      booked_by_name:  booking_details.booked_by_name,
      booked_by_email: booking_details.booked_by_email,

      attachment_name: attach.try &.[](:file_name),
      attachment_url:  attach.try &.[](:uri),

      network_username: network_username,
      network_password: network_password
    }

    attachments.clear if @disable_attachments
    third_party = booking_details.user_email != booking_details.booked_by_email

    send_to = notify_details.email.dup
    send_to << booking_details.user_email if notify_details.notify_booking_owner

    if notify_details.notify_manager
      email = get_manager(booking_details.user_email)
      send_to << email if email
    end

    mailer.send_template(
      to: send_to,
      template: {"bookings", third_party ? "booked_by_notify" : "booking_notify"},
      args: args,
      attachments: attachments
    )
    staff_api.booking_state(booking_details.id, "notified").get

    @bookings_checked += 1
    self[:bookings_checked] = @bookings_checked
  rescue error
    logger.error { error.inspect_with_backtrace }
    self[:last_error] = {
      error: error.message,
      time:  Time.local.to_s,
      user:  payload,
    }
    @error_count += 1
    self[:error_count] = @error_count
  end

  def get_building_name(zones : Array(String))
    zones.each do |zone_id|
      details = @notify_lookup[zone_id]?
      if details
        attachments = details.attachments.compact_map { |n, l| get_attachment(n, l) }
        logger.debug { "attaching #{attachments.size} files" }
        return {zone_id, details, attachments}
      end
    end
    {nil, nil, nil}
  end

  protected def get_attachment(filename : String, uri : String)
    return {file_name: filename, content: "", uri: uri} if @disable_attachments

    ext = filename.split('.')[-1]
    file = Digest::MD5.base64digest(uri).gsub(/[^0-9a-zA-Z\.]/, "") + ext

    # Local cache is pre-encoded
    if File.exists?(file)
      content = File.read(file)
      logger.debug { "attachment saved locally #{filename} - #{content.bytesize}" }
      return {file_name: filename, content: content, uri: uri}
    end

    # Download the file from the internet
    buffer = IO::Memory.new
    begin
      buf = Bytes.new(64)
      HTTP::Client.get(uri) do |response|
        raise "HTTP request failed with #{response.status_code}" unless response.success?
        body_io = response.body_io
        while ((bytes = body_io.read(buf)) > 0)
          buffer.write(buf[0, bytes])
        end
      end
    rescue error
      logger.warn(exception: error) { "unable to download attachment: #{uri}" }
      return nil
    end

    encoded = Base64.strict_encode(buffer)
    File.write file, encoded

    logger.debug { "attachment downloaded #{filename} - #{encoded.bytesize}" }

    {file_name: filename, content: encoded, uri: uri}
  end

  @check_bookings_mutex = Mutex.new

  @[Security(Level::Support)]
  def check_bookings(months_from_now : Int32 = 2)
    # Clean up old debounce data
    expired = 5.minutes.ago.to_unix
    @debounce.reject! { |_, (_event, entered)| expired > entered }

    @check_bookings_mutex.synchronize do
      @notify_lookup.each do |building_zone, details|
        building_name = details.name
        email = details.email
        attachments = details.attachments.compact_map { |n, l| get_attachment(n, l) }
        building_key = building_name.downcase.gsub(' ', '_')

        perform_booking_check(building_zone, building_name, building_key, email, details.notify_booking_owner, details.notify_manager, attachments, months_from_now)
      end
    end
  end

  protected def perform_booking_check(building_zone, building_name, building_key, emails, notify_owner, notify_manager, attachments, months_from_now = 2)
    now = Time.utc.to_unix
    later = months_from_now.months.from_now.to_unix

    bookings = staff_api.query_bookings(
      type: @booking_type,
      period_start: now,
      period_end: later,
      zones: [building_zone],
      approved: false,
      rejected: false,
      created_before: 2.minutes.ago.to_unix
    ).get.as_a

    bookings = bookings + staff_api.query_bookings(
      type: @booking_type,
      period_start: now,
      period_end: later,
      zones: [building_zone],
      approved: true,
      rejected: false,
      created_before: 2.minutes.ago.to_unix
    ).get.as_a

    bookings = Array(Booking).from_json(bookings.to_json)
    logger.debug { "checking #{bookings.size} requested bookings in #{building_name}" }
    bookings.each do |booking_details|
      timezone = booking_details.timezone.presence || @time_zone.name
      location = Time::Location.load(timezone)

      starting = Time.unix(booking_details.booking_start).in(location)
      ending = Time.unix(booking_details.booking_end).in(location)

      attach = attachments.first?

      args = {
        booking_id:     booking_details.id,
        start_time:     starting.to_s(@time_format),
        start_date:     starting.to_s(@date_format),
        start_datetime: starting.to_s(@date_time_format),
        end_time:       ending.to_s(@time_format),
        end_date:       ending.to_s(@date_format),
        end_datetime:   ending.to_s(@date_time_format),
        starting_unix:  booking_details.booking_start,

        asset_id:   booking_details.asset_id,
        user_id:    booking_details.user_id,
        user_email: booking_details.user_email,
        user_name:  booking_details.user_name,
        reason:     booking_details.title,

        level_zone:    booking_details.zones.reject { |z| z == building_zone }.first?,
        building_zone: building_zone,
        building_name: building_name,

        booked_by_name:  booking_details.booked_by_name,
        booked_by_email: booking_details.booked_by_email,

        attachment_name: attach.try &.[](:file_name),
        attachment_url:  attach.try &.[](:uri),
      }

      attachments.clear if @disable_attachments

      begin
        if booking_details.process_state.nil?
          third_party = booking_details.user_email != booking_details.booked_by_email

          send_to = emails.dup
          send_to << booking_details.user_email if notify_owner

          if notify_manager
            email = get_manager(booking_details.user_email)
            send_to << email if email
          end

          mailer.send_template(
            to: send_to,
            template: {"bookings", third_party ? "booked_by_notify" : "booking_notify"},
            args: args,
            attachments: attachments
          )
          staff_api.booking_state(booking_details.id, "notified").get
        end
      rescue error
        logger.error(exception: error) { "while processing booking id #{booking_details.id}" }
      end
    end
  end

  @[Security(Level::Support)]
  def get_manager(staff_email : String)
    manager = calendar.get_user_manager(staff_email).get
    (manager["email"]? || manager["username"]).as_s
  rescue error
    logger.warn { "failed to email manager of #{staff_email}\n#{error.inspect_with_backtrace}" }
    nil
  end

  private def fetch_network_user(user_email : String, user_name : String)
    # Check if they already exist
    response = JSON.parse(network_provider.get_internal_user_by_email(user_email).get.as_s)
    logger.debug { "Response from Network Identity provider for lookup of #{user_email} was:\n #{response} } "} if @debug
    return { response["name"], response["password"] } unless response["error"]

    # Create them if they don't
    response = JSON.parse(network_provider.create_internal(user_email, user_name).get.as_s)
    logger.debug { "Response from Network Identity provider for creating user #{user_email} was:\n #{response} } "} if @debug
    { response["name"], response["password"] }
  end
end
