require "placeos-driver"
require "./mist_models"
require "openssl/hmac"

class Juniper::Mist < PlaceOS::Driver
  generic_name :Mist
  descriptive_name "Juniper Mist API"
  description "Juniper Mist network API"

  uri_base "https://api.mist.com"
  default_settings({
    api_token:      "token",
    org_id:         "org_id",
    webhook_secret: "secret",
  })

  @api_token : String = ""
  @org_id : String = ""
  @webhook_secret : String = ""

  # Rate limited to 5000 requests an hour. Reset at the hourly boundry
  # This is a bit over a request a second, but we'll try and burst these
  @channel : Channel(Nil) = Channel(Nil).new(500)
  @wait_time : Time::Span = 800.milliseconds
  @queue_lock : Mutex = Mutex.new
  @queue_size = 0

  def on_load
    spawn { rate_limiter }

    # every hour we need to reset the rate limit
    schedule.cron("0 * * * *") { reset_rate_limit }
    on_update
  end

  def on_unload
    @channel.close
  end

  def on_update
    token = setting String, :api_token
    @api_token = "Token #{token}"
    @org_id = setting String, :org_id
    @webhook_secret = setting?(String, :webhook_secret) || ""
  end

  # if there is a request queued then there will not be any burst request available
  protected def reset_rate_limit
    @queue_lock.synchronize do
      if @queue_size == 0
        old_channel = @channel
        @channel = Channel(Nil).new(500)
        old_channel.close
      end
    end
  end

  protected def rate_limiter
    loop do
      break if @channel.closed?
      begin
        @channel.send(nil)
      rescue error
        logger.error(exception: error) { "issue with rate limiter" }
      ensure
        sleep @wait_time
      end
    end
  rescue
    # Possible error with logging exception, restart rate limiter silently
    spawn { rate_limiter } unless @channel.closed?
  end

  protected def request(klass : Class)
    if (@wait_time * @queue_size) > 15.seconds
      raise "wait time would be exceeded for API request, #{@queue_size} requests already queued"
    end

    @queue_lock.synchronize { @queue_size += 1 }
    @channel.receive
    @queue_lock.synchronize { @queue_size -= 1 }

    headers = HTTP::Headers{
      "Authorization" => @api_token,
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
      "User-Agent"    => "PlaceOS/2.0 PlaceTechnology",
    }

    response = yield headers

    raise "request failed with status: #{response.status_code}\n#{response.body}" unless response.success?
    klass.from_json(response.body)
  end

  @[Security(Level::Support)]
  def get_request(location : String)
    request(JSON::Any) { |headers| get(location, headers: headers) }
  end

  def sites
    request(Array(Site)) { |headers| get("/api/v1/orgs/#{@org_id}/sites", headers: headers) }
  end

  def maps(site_id : String)
    request(Array(Map)) { |headers| get("/api/v1/sites/#{site_id}/maps", headers: headers) }
  end

  EMPTY_HEADERS    = {} of String => String
  SUCCESS_RESPONSE = {HTTP::Status::OK, EMPTY_HEADERS, nil}

  def location_webhook(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "webhook received: #{method},\nheaders #{headers},\nbody size #{body.size}" }

    # validate the data came from the expected source
    validation = if signature = headers["X-Mist-Signature-v2"]?.try(&.first?)
                   OpenSSL::HMAC.hexdigest(OpenSSL::Algorithm::SHA256, @webhook_secret, body).downcase
                 elsif signature = headers["X-Mist-Signature"]?.try(&.first?)
                   OpenSSL::HMAC.hexdigest(OpenSSL::Algorithm::SHA1, @webhook_secret, body).downcase
                 else
                   logger.warn { "webhook called without validation signature" }
                   return {HTTP::Status::NOT_FOUND.to_i, EMPTY_HEADERS, ""}
                 end

    if validation != signature.downcase
      logger.warn { "validation failed, check webhook secret" }
      return {HTTP::Status::UNAUTHORIZED.to_i, EMPTY_HEADERS, ""}
    end

    # Parse the data posted
    begin
      event_data = WebhookEvent.from_json(body)
      logger.debug { "parsed mist webhook payload" }

      # We're only interested in location data at the moment
      if event_data.topic != "location"
        logger.debug { "ignoring message type: #{event_data.topic}" }
        return SUCCESS_RESPONSE
      end

      sites = Hash(String, Array(LocationEvent)).new { |hash, site| hash[site] = [] of LocationEvent }
      event_data.events.as(Array(LocationEvent)).each do |event|
        sites[event.site_id] << event
      end
      sites.each { |site, events| self[site] = events }
    rescue e
      logger.error(exception: e) { "failed to parse mist webhook payload" }
      logger.debug { "failed payload body was\n#{body}" }
    end

    # Return a 200 response
    SUCCESS_RESPONSE
  end
end
