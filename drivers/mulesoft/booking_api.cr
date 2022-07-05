require "placeos-driver"
require "./models"

class MuleSoft::BookingsAPI < PlaceOS::Driver
  descriptive_name "MuleSoft Bookings API"
  generic_name :Bookings
  description %(Retrieves and creates bookings using the MuleSoft API)
  uri_base "https://api.sydney.edu.au"

  default_settings({
    venue_code:         "venue code",
    base_path:          "/usyd-edu-timetable-exp-api-v1/v1/",
    polling_cron:       "*/30 7-20 * * *",
    time_zone:          "Australia/Sydney",
    ssl_key:            "private key",
    ssl_cert:           "certificate",
    ssl_auth_enabled:   false,
    username:           "basic auth username",
    password:           "basic auth password",
    basic_auth_enabled: true,
    running_a_spec:     false,
  })

  @username : String = ""
  @password : String = ""
  @base_path : String = ""
  @context : OpenSSL::SSL::Context::Client = OpenSSL::SSL::Context::Client.new
  @host : String = ""
  @venue_code : String = ""
  @bookings : Array(Booking) = [] of Booking
  @time_zone : Time::Location = Time::Location.load("Australia/Sydney")
  @ssl_auth_enabled : Bool = false
  @basic_auth_enabled : Bool = false
  @runing_a_spec : Bool = false

  def on_load
    on_update
  end

  def on_update
    schedule.clear
    @running_a_spec = !!setting(Bool, :running_a_spec)

    @username = setting(String, :username)
    @password = setting(String, :password)
    @basic_auth_enabled = !!setting?(Bool, :basic_auth_enabled)
    logger.debug { "basic_auth_enabled is #{@basic_auth_enabled}" }

    @base_path = setting(String, :base_path)
    @venue_code = setting(String, :venue_code)

    @host = URI.parse(config.uri.not_nil!).host.not_nil!

    time_zone = setting?(String, :time_zone).presence
    @time_zone = Time::Location.load(time_zone) if time_zone

    @ssl_auth_enabled = !!setting?(Bool, :ssl_auth_enabled)
    save_ssl_credentials if @ssl_auth_enabled
    logger.debug { "ssl_auth_enabled is #{@ssl_auth_enabled}" }

    schedule.in(Random.rand(60).seconds + Random.rand(1000).milliseconds) { poll_bookings }

    cron_string = setting?(String, :polling_cron).presence || "*/30 7-20 * * *"
    schedule.cron(cron_string, @time_zone) { poll_bookings(random_delay: true) }
  end

  def poll_bookings(random_delay : Bool = false)
    now = Time.local @time_zone
    from = now - 1.week
    to = now + 1.week

    logger.debug { "polling bookings #{@venue_code}, from #{from}, to #{to}, in #{@time_zone.name}" }
    if random_delay
      logger.debug { "random delay of <30seconds to reduce instantaneous Mulesoft API load" }
      sleep Random.rand(30.0)
    end
    query_bookings(@venue_code, from, to)

    check_current_booking
  end

  def check_current_booking
    now = Time.utc.to_unix
    previous_booking = nil
    current_booking = nil
    next_booking = Int32::MAX

    @bookings.each_with_index do |event, index|
      starting = event.event_start

      # All meetings are in the future
      if starting > now
        next_booking = index
        previous_booking = index - 1 if index > 0
        break
      end

      # Calculate event end time
      ending_unix = event.event_end

      # Event ended in the past
      next if ending_unix < now

      # We've found the current event
      if starting <= now && ending_unix > now
        current_booking = index
        previous_booking = index - 1 if index > 0
        next_booking = index + 1
        break
      end
    end

    if next_booking >= (@bookings.size - 1)
      next_booking = nil
    end

    self[:previous_booking] = previous_booking ? @bookings[previous_booking].to_placeos : nil
    self[:current_booking] = current_booking ? @bookings[current_booking].to_placeos : nil
    self[:next_booking] = next_booking ? @bookings[next_booking].to_placeos : nil
  end

  def query_bookings(venue_code : String, starts_at : Time = Time.local.at_beginning_of_day, ends_at : Time = Time.local.at_end_of_day)
    client = HTTP::Client.new(host: @host, tls: (@ssl_auth_enabled ? @context : nil))

    params = {
      "startDateTime" => starts_at.to_s("%FT%T"),
      "endDateTime"   => ends_at.to_s("%FT%T"),
    }.join('&') { |k, v| "#{k}=#{v}" }

    headers = HTTP::Headers{
      "Content-Type" => "application/json",
      "Accept"       => "application/json",
    }

    if @basic_auth_enabled
      headers.add("Authorization", "Basic #{Base64.strict_encode("#{@username}:#{@password}")}")
    end

    if @running_a_spec
      response = get("#{@base_path}/venues/#{venue_code}/bookings?#{params}", headers: headers)
    else
      response = client.get("#{@base_path}/venues/#{venue_code}/bookings?#{params}", headers: headers)
    end

    raise "request failed with #{response.status_code}: #{response.body}" unless (200...300).includes?(response.status_code)

    # when there's no results, it seems to return just an empty response rather than an empty array?
    if response.body.presence != nil
      results = BookingResults.from_json(response.body)

      self[:venue_code] = results.venue_code
      self[:venue_name] = results.venue_name

      @bookings = results.bookings.sort { |a, b| a.event_start <=> b.event_start }
      self[:bookings] = @bookings.map(&.to_placeos)
    else
      self[:venue_code] = nil
      self[:venue_name] = nil
      self[:bookings] = nil
    end
  end

  def query_bookings_epoch(venue_code : String, starts_at : Int32, ends_at : Int32)
    query_bookings(venue_code, Time.unix(starts_at), Time.unix(ends_at))
  end

  protected def save_ssl_credentials
    [:ssl_key, :ssl_cert].each do |key|
      raise "Required setting #{key} left blank" unless setting(String, key).presence

      File.open("./pkey-#{module_id}.#{key}", "w") do |cert|
        cert.puts setting(String, key)
      end
    end

    @context.private_key = "./pkey-#{module_id}.ssl_key"
    @context.certificate_chain = "./pkey-#{module_id}.ssl_cert"
  end
end
