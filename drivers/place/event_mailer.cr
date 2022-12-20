require "placeos-driver"
require "place_calendar"

class Place::EventMailer < PlaceOS::Driver
  descriptive_name "PlaceOS Event Mailer"
  generic_name :EventMonitor
  description %(Subscribe to Events and send emails to attendees)

  default_settings({
    zone_ids_to_target:       ["zone-id-here"],
    module_to_target:         "Bookings_1",
    module_status_to_scrape:  "bookings",
    event_filter:             "occurs_today",
    send_network_credentials: false,
    date_time_format:         "%c",
    time_format:              "%l:%M%p",
    date_format:              "%A, %-d %B",
    debug:                    false,
  })

  accessor staff_api : StaffAPI_1
  accessor mailer : Mailer_1
  accessor network_provider : NetworkAccess_1 # Written for Cisco ISE Driver, but ideally compatible with others

  @target_zones = [] of String
  @target_module = "Bookings_1"
  @target_status = "bookings"
  @event_filter = "occurs_today"
  @send_network_credentials = false

  # See: https://crystal-lang.org/api/0.35.1/Time/Format.html
  @date_time_format : String = "%c"
  @time_format : String = "%l:%M%p"
  @date_format : String = "%A, %-d %B"

  @debug = false
  @events = {} of String => Array(PlaceCalendar::Event) # {sys_id: [event]}

  def on_load
    on_update
  end

  def on_update
    @target_zones = setting?(Array(String), :zone_ids_to_target) || [] of String
    @target_module = setting?(String, :module_to_target) || "Bookings_1"
    @target_status = setting?(String, :module_status_to_target) || "bookings"
    @event_filter = setting?(String, :event_filter) || ""
    @send_network_credentials = setting?(Bool, :send_network_credentials) || false
    @date_time_format = setting?(String, :date_time_format) || "%c"
    @time_format = setting?(String, :time_format) || "%l:%M%p"
    @date_format = setting?(String, :date_format) || "%A, %-d %B"
    @debug = setting?(Bool, :debug) || false

    self[:events] = @events.clear
    subscribe_to_all_modules
  end

  private def subscribe_to_all_modules
    # Subscribe to the targetted state of all matching modules and update our state when they change
    subscriptions.clear
    list_target_systems.map do |sys|
      sys_id = sys["id"].to_s
      system(sys_id).subscribe(@target_module, @target_status) do |subscription, new_value|
        process_updated_events(sys_id, Array(PlaceCalendar::Event).from_json(new_value))
      end
    end
  end

  def list_target_systems
    @target_zones.map { |zone_id| list_systems_in_zone(zone_id) }.flatten
  end

  def list_systems_in_zone(zone_id : String)
    staff_api.systems(zone_id: zone_id).get.as_a
  end

  private def process_updated_events(system_id : String, events : Array(PlaceCalendar::Event))
    selected_events = apply_filter(events)
    new_events = if @events[system_id]
                   @events[system_id] - selected_events
                 else
                   selected_events
                 end
    @events[system_id] = selected_events # Store the updated list of events
    new_events.each { |event| send_event_email(event, system_id) }
  end

  private def send_event_email(event : PlaceCalendar::Event, system_id : String)
    return "Event email was already sent at #{event.extension_data[:event_mailer_email_sent_at]}" if event.extension_data[:event_mailer_email_sent_at]
    organizer_email = event.host
    organizer_name = event.attendees.find { |a| a.email == organizer_email }.try &.name || "Name Unknown"
    network_username = network_password = ""
    network_username, network_password = fetch_network_user(organizer_email.not_nil!, organizer_name.not_nil!) if @send_network_credentials

    email_data = {
      host_name:        organizer_name,
      host_email:       organizer_email,
      room_name:        event.location,
      event_title:      event.title,
      event_start:      event.event_start.to_s(@time_format),
      event_date:       event.event_end.not_nil!.to_s(@date_format),
      network_username: network_username,
      network_password: network_password,
    }
    mailer.send_template(
      to: [organizer_email],
      template: {"events", @send_network_credentials ? "welcome_with_network_credentials" : "welcome"},
      args: email_data
    )
    staff_api.patch_event_metadata(system_id, event.id, {"event_mailer_email_sent_at": Time.local}.to_json).get
  end

  private def apply_filter(events : Array(PlaceCalendar::Event))
    # Additional event filters can be added in the future
    case @event_filter
    when :occurs_today
      logger.debug { "Event filter: occurs today" } if @debug
      select_todays_events(events)
    else
      logger.debug { "Event filter: NONE" } if @debug
      events
    end
  end

  private def select_todays_events(events : Array(PlaceCalendar::Event))
    events.select do |event|
      timezone = event.timezone ? Time::Location.load(event.timezone.not_nil!) : Time::Location.local
      now = Time.local(location: timezone)
      event.event_start >= now.at_beginning_of_day && event.event_start <= now.at_end_of_day
    end
  end

  private def fetch_network_user(user_email : String, user_name : String)
    # Check if they already exist
    response = JSON.parse(network_provider.get_internal_user_by_email(user_email).get.as_s)
    logger.debug { "Response from Network Identity provider for lookup of #{user_email} was:\n #{response} } " } if @debug
    return {response["name"], response["password"]} unless response["error"]

    # Create them if they don't
    response = JSON.parse(network_provider.create_internal(user_email, user_name).get.as_s)
    logger.debug { "Response from Network Identity provider for creating user #{user_email} was:\n #{response} } " } if @debug
    {response["name"], response["password"]}
  end
end
