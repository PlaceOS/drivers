require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"
require "digest/md5"
require "placeos"
require "file"

require "./booking_model"

class Place::BookingApprovalWorkflows < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "Desk Booking Approval Workflows"
  generic_name :BookingApproval
  description %(picks an approval strategy based on configuration)

  default_settings({
    timezone:         "Australia/Sydney",
    date_time_format: "%c",
    time_format:      "%l:%M%p",
    date_format:      "%A, %-d %B",

    booking_type:        "desk",
    remind_after:        24,
    escalate_after:      48,
    disable_attachments: true,

    approval_type: {
      zone_id1: {
        name:          "Sydney Building 1",
        approval:      :notify,
        support_email: "support@place.com",
      },
      zone_id2: {
        name:          "Melb Building",
        approval:      :manager_approval,
        attachments:   {"file-name.pdf" => "https://s3/your_file.pdf"},
        support_email: "msupport@place.com",
      },
    },

    reminders: {
      crons: ["0 10 * * *", "0 14 * * *"],
      zones: {
        "Australia/Sydney" => ["zone_id1", "zone_id2"],
        "Australia/Perth"  => ["zone_id3"],
      },
    },
  })

  # bookings states:
  # * manager_contacted = manager has been emailed to approve
  # * manager_reminded  = manager has been emailed a second time to approve
  # * managers_manager  = managers manager has been emailed to approve

  accessor staff_api : StaffAPI_1

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  def on_load
    # Some form of asset booking has occured
    monitor("staff/booking/changed") { |_subscription, payload| parse_booking(payload) }

    on_update
  end

  # See: https://crystal-lang.org/api/0.35.1/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"
  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")

  @booking_type : String = "desk"
  @bookings_checked : UInt64 = 0_u64
  @error_count : UInt64 = 0_u64

  @remind_after : Time::Span = 24.hours
  @escalate_after : Time::Span = 48.hours
  @disable_attachments : Bool = true
  @notify_managers : Bool = false

  alias SiteDetails = NamedTuple(approval: String, name: String, support_email: String, attachments: Hash(String, String)?)
  alias Reminders = NamedTuple(crons: Array(String), zones: Hash(String, Array(String)))

  # Zone_id => approval type
  @approval_lookup : Hash(String, SiteDetails) = {} of String => SiteDetails

  def on_update
    @booking_type = setting?(String, :booking_type).presence || "desk"

    time_zone = setting?(String, :calendar_time_zone).presence || "Australia/Sydney"
    @time_zone = Time::Location.load(time_zone)
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"

    @remind_after = (setting?(Int32, :remind_after) || 24).hours
    @escalate_after = (setting?(Int32, :escalate_after) || 48).hours
    @notify_managers = setting?(Bool, :notify_managers) || false

    @approval_lookup = setting(Hash(String, SiteDetails), :approval_type)
    attach = setting?(Bool, :disable_attachments)
    @disable_attachments = attach.nil? ? true : !!attach

    schedule.clear
    schedule.every(5.minutes) { check_bookings }

    reminders = setting?(Reminders, :reminders) || {crons: [] of String, zones: {} of String => Array(String)}
    reminders[:crons].each do |cron|
      reminders[:zones].each do |timezone, zones|
        begin
          schedule.cron(cron, Time::Location.load(timezone)) { send_checkin_reminder(zones) }
        rescue error
          logger.warn(exception: error) { "failed to schedule reminder: #{zones} => #{timezone} : #{cron}" }
        end
      end
    end
  end

  def template_fields : Array(TemplateFields)
    time_now = Time.now.in(@timezone)

    common_fields = [
      {name: "booking_id", description: "Unique identifier for the booking"},
      {name: "start_time", description: "Booking start time (e.g., #{time_now.to_s(@time_format)})"},
      {name: "start_date", description: "Booking start date (e.g., #{time_now.to_s(@date_format)})"},
      {name: "start_datetime", description: "Booking start date and time (e.g., #{time_now.to_s(@date_time_format)})"},
      {name: "end_time", description: "Booking end time (e.g., #{time_now.to_s(@time_format)})"},
      {name: "end_date", description: "Booking end date (e.g., #{time_now.to_s(@date_format)})"},
      {name: "end_datetime", description: "Booking end date and time (e.g., #{time_now.to_s(@date_time_format)})"},
      {name: "starting_unix", description: "Booking start time as Unix timestamp"},
      {name: "desk_id", description: "Identifier of the booked desk"},
      {name: "user_id", description: "Identifier of the person the booking is for"},
      {name: "user_email", description: "Email of the person the booking is for"},
      {name: "user_name", description: "Name of the person the booking is for"},
      {name: "reason", description: "Purpose or title of the booking"},
      {name: "level_zone", description: "Zone identifier for the specific floor level"},
      {name: "building_zone", description: "Zone identifier for the building"},
      {name: "building_name", description: "Name of the building"},
      {name: "support_email", description: "Contact email for booking support"},
      {name: "approver_name", description: "Name of the person who approved/rejected the booking"},
      {name: "approver_email", description: "Email of the person who approved/rejected the booking"},
      {name: "booked_by_name", description: "Name of the person who made the booking"},
      {name: "booked_by_email", description: "Email of the person who made the booking"},
      {name: "attachment_name", description: "Name of any attached files"},
      {name: "attachment_url", description: "URL to download any attachments"},
    ]

    [
      TemplateFields.new(
        trigger: {"bookings", "group_booking_sent"},
        name: "Group booking sent",
        description: "Notification when a group booking has been created",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "approved_by"},
        name: "Booking approved by",
        description: "Notification when booking is approved by someone other than the requester",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "approved"},
        name: "Booking approved",
        description: "Notification when booking is approved",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "rejected"},
        name: "Booking rejected",
        description: "Notification when booking is rejected",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "checked_in"},
        name: "Booking checked in",
        description: "Notification when user checks in to their booking",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "cancelled_by"},
        name: "Booking cancelled by",
        description: "Notification when booking is cancelled by someone other than the booker",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "cancelled"},
        name: "Booking cancelled",
        description: "Notification when booking is cancelled by the booker",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "manager_notify_cancelled"},
        name: "Booking cancelled manager notification",
        description: "Notification to manager when their team member's booking is cancelled",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "manager_approval"},
        name: "Booking manager approval",
        description: "Request for manager to approve a booking",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "manager_contacted"},
        name: "Booking manager contacted",
        description: "Notification to user that their manager has been contacted for approval",
        fields: common_fields
      ),
      TemplateFields.new(
        trigger: {"bookings", "notify_manager"},
        name: "Booking manager notification",
        description: "Notification to manager about their team member's booking",
        fields: common_fields
      ),
    ]
  end

  # Booking id => event, timestamp
  @debounce = {} of Int64 => {String?, Int64}

  # Booker has been informed of the group booking email
  @group_email_notifications = {} of String => Int64

  protected def parse_booking(payload)
    logger.debug { "received booking event payload: #{payload}" }
    booking_details = Booking.from_json payload

    # Ignore when a bookings state is updated
    return if {"process_state", "metadata_changed"}.includes?(booking_details.action)

    # Ignore the same event in a short period of time
    previous = @debounce[booking_details.id]?
    return if previous && previous[0] == booking_details.action
    @debounce[booking_details.id] = {booking_details.action, Time.utc.to_unix}

    approval_details = get_building_name(booking_details.zones)
    return unless approval_details
    building_zone, building_name, approval_type, support_email, attachments = approval_details
    building_key = building_name.downcase.gsub(' ', '_')

    timezone = booking_details.timezone.presence || @time_zone.name
    location = Time::Location.load(timezone)

    # https://crystal-lang.org/api/0.35.1/Time/Format.html
    # date and time (Tue Apr 5 10:26:19 2016)
    starting = Time.unix(booking_details.booking_start).in(location)
    ending = Time.unix(booking_details.booking_end).in(location)

    # Ignore changes to meetings that have already ended
    return if Time.utc > ending

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

      desk_id:    booking_details.asset_id,
      user_id:    booking_details.user_id,
      user_email: booking_details.user_email,
      user_name:  booking_details.user_name,
      reason:     booking_details.title,

      level_zone:    booking_details.zones.reject { |z| z == building_zone }.first?,
      building_zone: building_zone,
      building_name: building_name,
      support_email: support_email,

      approver_name:  booking_details.approver_name,
      approver_email: booking_details.approver_email,

      booked_by_name:  booking_details.booked_by_name,
      booked_by_email: booking_details.booked_by_email,

      attachment_name: attach.try &.[](:file_name),
      attachment_url:  attach.try &.[](:uri),
    }

    attachments.clear if @disable_attachments

    case booking_details.action
    when "create", "changed"
      group_id = booking_details.extension_data["group_id"]?.try &.to_s
      if group_id && !@group_email_notifications.has_key?(group_id)
        @group_email_notifications[group_id] = Time.utc.to_unix

        mailer.send_template(
          to: booking_details.booked_by_email,
          template: {"bookings", "group_booking_sent"},
          args: args
        )
      end

      check_approval(
        booking_details,
        approval_type,
        building_key,
        attachments,
        args
      )
    when "approved"
      return if booking_details.process_state == "approval_sent"

      third_party = approval_type == "manager_approval" && booking_details.user_email != booking_details.booked_by_email
      mailer.send_template(
        to: booking_details.user_email,
        template: {"bookings", third_party ? "approved_by" : "approved"},
        args: args,
        attachments: attachments
      ).get

      staff_api.booking_state(booking_details.id, "approval_sent").get
    when "rejected", "checked_in"
      # no attachment for rejection email
      user_email = booking_details.user_email
      mailer.send_template(
        to: user_email,
        template: {"bookings", booking_details.action},
        args: args
      )
    when "cancelled"
      third_party = booking_details.approver_email && booking_details.approver_email != booking_details.user_email.downcase

      # no attachment for rejection email
      user_email = booking_details.user_email
      mailer.send_template(
        to: user_email,
        template: {"bookings", third_party ? "cancelled_by" : "cancelled"},
        args: args
      )

      if @notify_managers && (manager_email = get_manager(user_email).try(&.at(0)))
        mailer.send_template(
          to: manager_email,
          template: {"bookings", "manager_notify_cancelled"},
          args: args
        )
      end
    end

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
      details = @approval_lookup[zone_id]?
      if details
        attachments = (details[:attachments] || {} of String => String).compact_map { |n, l| get_attachment(n, l) }
        logger.debug { "attaching #{attachments.size} files" }
        return {zone_id, details[:name], details[:approval], details[:support_email], attachments}
      end
    end
    nil
  end

  protected def check_approval(
    booking_details,
    approval_type,
    building_key,
    attachments,
    args
  )
    user_email = booking_details.user_email
    state = booking_details.process_state

    logger.debug { "checking status of #{approval_type} booking #{booking_details.id} for #{booking_details.user_name}\ncurrent state: #{state}" }

    case approval_type
    when "manager_approval"
      logger.debug { "checking manager approval state: #{state}" }

      case state
      # manager needs to approve this bookings
      when nil || state.try(&.empty?)
        manager_email, manager_name = get_manager(user_email)
        if manager_email && manager_name
          logger.debug { "requesting manager approval..." }

          mailer.send_template(
            to: manager_email,
            template: {"bookings", "manager_approval"},
            args: args
          ).get

          # set the booking state
          staff_api.booking_state(booking_details.id, "manager_contacted").get

          mailer.send_template(
            to: user_email,
            template: {"bookings", "manager_contacted"},
            args: args.merge({
              manager_email: manager_email,
              manager_name:  manager_name,
            })
          )
        else
          logger.debug { "manager not found, approving booking!" }
          # approve automatically if no manager to approve
          staff_api.approve(booking_details.id).get
        end
        # we might need to remind this manager to approve or reject a booking
      when "manager_contacted"
        if booking_details.changed < @remind_after.ago
          logger.debug { "sending manager reminder email" }

          if manager_email = get_manager(user_email).try(&.at(0))
            mailer.send_template(
              to: manager_email,
              template: {"bookings", "manager_approval"},
              args: args
            ).get

            # set the booking state
            staff_api.booking_state(booking_details.id, "manager_reminded").get
          else
            logger.debug { "manager not found, approving booking!" }
            # approve automatically if no manager to approve
            staff_api.approve(booking_details.id).get
          end
        end
        # do we need to escalate the approval?
      when "manager_reminded"
        if booking_details.changed < @escalate_after.ago
          if manager_email = get_manager(user_email).try(&.at(0))
            if manager_email = get_manager(manager_email).try(&.at(0))
              logger.debug { "sending managers manager an email" }

              mailer.send_template(
                to: manager_email,
                template: {"bookings", "manager_approval"},
                args: args
              ).get

              # set the booking state
              staff_api.booking_state(booking_details.id, "managers_manager").get
            else
              # approve automatically if no manager to approve
              logger.debug { "managers manager not found, approving booking!" }
              staff_api.approve(booking_details.id).get
            end
          else
            # approve automatically if no manager to approve
            logger.debug { "manager not found, approving booking!" }
            staff_api.approve(booking_details.id).get
          end
        end
      when "managers_manager"
        if booking_details.changed > 5.days.ago
          # approve automatically if no manager approves in over 4 days
          logger.debug { "approving booking as managers have failed to approve" }
          staff_api.approve(booking_details.id).get
        end
      end
    when "notify"
      logger.debug { "approving booking and notifing manager = #{@notify_managers}" }

      # manager needs to be notified of approval
      staff_api.approve(booking_details.id).get
      # NOTE:: user will be sent email via the approval event

      if @notify_managers && (manager_email = get_manager(user_email).try(&.at(0)))
        mailer.send_template(
          to: manager_email,
          template: {"bookings", "notify_manager"},
          args: args
        )
      end
    else
      # Auto approval
      logger.debug { "approving booking as unknown approval type: #{approval_type.inspect}" }
      staff_api.approve(booking_details.id).get
      # NOTE:: user will be sent email via the approval event
    end
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

    expired = 1.hour.ago.to_unix
    @group_email_notifications.reject! { |_, entered| expired > entered }

    @check_bookings_mutex.synchronize do
      @approval_lookup.each do |building_zone, details|
        building_name = details[:name]
        approval_type = details[:approval]
        support_email = details[:support_email]
        attachments = (details[:attachments] || {} of String => String).compact_map { |n, l| get_attachment(n, l) }
        building_key = building_name.downcase.gsub(' ', '_')

        perform_booking_check(building_zone, approval_type, building_name, building_key, support_email, attachments, months_from_now)
      end
    end
  end

  protected def perform_booking_check(building_zone, approval_type, building_name, building_key, support_email, attachments, months_from_now = 2)
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

        desk_id:    booking_details.asset_id,
        user_id:    booking_details.user_id,
        user_email: booking_details.user_email,
        user_name:  booking_details.user_name,
        reason:     booking_details.title,

        level_zone:    booking_details.zones.reject { |z| z == building_zone }.first?,
        building_zone: building_zone,
        building_name: building_name,
        support_email: support_email,

        booked_by_name:  booking_details.booked_by_name,
        booked_by_email: booking_details.booked_by_email,

        attachment_name: attach.try &.[](:file_name),
        attachment_url:  attach.try &.[](:uri),
      }

      attachments.clear if @disable_attachments

      begin
        if booking_details.approved
          if booking_details.process_state != "approval_sent"
            third_party = booking_details.user_email != booking_details.booked_by_email

            mailer.send_template(
              to: booking_details.user_email,
              template: {"bookings", third_party ? "approved_by" : "approved"},
              args: args,
              attachments: attachments
            )
            staff_api.booking_state(booking_details.id, "approval_sent").get
          end
        else
          check_approval(
            booking_details,
            approval_type,
            building_key,
            attachments,
            args
          )
        end
      rescue error
        logger.error(exception: error) { "while processing booking id #{booking_details.id}" }
      end
    end
  end

  @[Security(Level::Support)]
  def get_manager(staff_email : String)
    manager = mailer.get_user_manager(staff_email).get
    {(manager["email"]? || manager["username"]).as_s, manager["name"].as_s}
  rescue error
    logger.warn { "failed to email manager of #{staff_email}\n#{error.inspect_with_backtrace}" }
    {nil, nil}
  end

  @[Security(Level::Support)]
  def users_with_invalid_desk_bookings(building_zone : String, ending : Int64)
    # [] of {zone: {id:}, metadata: {desks: {details: [{id:, groups: [] of String}]}}}
    meta_raw = staff_api.metadata_children(building_zone, "desks").get.as_a

    # Zone => Desk_id => Groups
    metadata = {} of String => Hash(String, Array(String))
    meta_raw.each do |zone|
      desks = {} of String => Array(String)
      zone_id = zone["zone"]["id"].as_s
      zone["metadata"]["desks"]["details"].as_a.each do |desk|
        desks[desk["id"].as_s] = desk["groups"].as_a.map(&.as_s.downcase)
      end
      metadata[zone_id] = desks
    end

    # User email, Desk ID, zone, booking id, starting, starting friendly
    users = [] of Tuple(String, String, String, Int64, Int64, String)

    # [] of {user_email:, zones:, asset_id:}
    bookings = staff_api.query_bookings(type: "desk", period_end: ending, zones: [building_zone], rejected: false).get.as_a
    bookings.each do |booking|
      user_email = booking["user_email"].as_s
      level_id = booking["zones"].as_a.map(&.as_s).reject(building_zone).first
      desk_id = booking["asset_id"].as_s
      booking_id = booking["id"].as_i64
      starting = booking["booking_start"].as_i64

      if desks = metadata[level_id]?
        if groups = desks[desk_id]?
          next if groups.empty?

          users_groups = mailer.get_groups(user_email).get.as_a.map { |g| g["name"].as_s.downcase }
          overlap = users_groups & groups
          if overlap.empty?
            date_friendly = Time.unix(starting).to_s(@date_format)
            users << {user_email, desk_id, level_id, booking_id, starting, date_friendly}
          end
        end
      end
    end

    logger.debug { "Email,Desk ID,Zone,Booking id,Starting,Start date\n#{users.map { |u| "#{u[0]},#{u[1]},#{u[2]},#{u[3]},#{u[4]},#{u[5]}" }.join("\n")}" }

    nil
  end

  @[Security(Level::Support)]
  def send_checkin_reminder(zones : Array(String)? = nil, timezone : String? = nil)
    time_now = Time.utc.in(timezone ? Time::Location.load(timezone) : @time_zone)
    time_now = time_now.at_beginning_of_day + 12.hours
    time_now = time_now.to_local_in(Time::Location::UTC)

    query_start = time_now.to_unix
    query_end = (time_now + 30.minutes).to_unix

    @check_bookings_mutex.synchronize do
      @approval_lookup.each do |building_zone, details|
        next if zones && !zones.includes?(building_zone)

        building_name = details[:name]
        support_email = details[:support_email]
        attachments = (details[:attachments] || {} of String => String).compact_map { |n, l| get_attachment(n, l) }
        building_key = building_name.downcase.gsub(' ', '_')

        perform_checkin_reminder(building_zone, building_name, building_key, support_email, attachments, query_start, query_end)
      end
    end
  end

  protected def perform_checkin_reminder(
    building_zone,
    building_name,
    building_key,
    support_email,
    attachments,
    start_of_day,
    time_now
  )
    bookings = staff_api.query_bookings(
      type: @booking_type,
      period_start: start_of_day,
      period_end: time_now,
      zones: [building_zone],
      approved: true,
      rejected: false,
      checked_in: false
    ).get.as_a

    logger.debug { "querying for bookings requiring a reminder, start time: #{start_of_day}, end time #{time_now}" }
    bookings = Array(Booking).from_json(bookings.to_json)
    logger.debug { "found #{bookings.size} bookings in #{building_name} requiring a reminder" }

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

        desk_id:    booking_details.asset_id,
        user_id:    booking_details.user_id,
        user_email: booking_details.user_email,
        user_name:  booking_details.user_name,
        reason:     booking_details.title,

        level_zone:    booking_details.zones.reject { |z| z == building_zone }.first?,
        building_zone: building_zone,
        building_name: building_name,
        support_email: support_email,

        booked_by_name:  booking_details.booked_by_name,
        booked_by_email: booking_details.booked_by_email,

        attachment_name: attach.try &.[](:file_name),
        attachment_url:  attach.try &.[](:uri),
      }

      attachments.clear if @disable_attachments
      mailer.send_template(
        to: booking_details.user_email,
        template: {"bookings", "checkin_reminder"},
        args: args,
        attachments: attachments
      )
    end
  end
end
