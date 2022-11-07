require "placeos-driver"

class Place::HTTPPinger < PlaceOS::Driver
  # Discovery Information
  generic_name :Ping
  descriptive_name "Service Status Check"
  uri_base "https://192.168.0.2/api/healthcheck"

  default_settings({
    basic_auth: {
      username: "srvc_acct",
      password: "password!",
    },
    ping_every:             60,
    expected_response_code: 200,
    http_max_requests:      0,
    request_verb:           "GET",
    request_headers:        {
      "Accept" => "application/json",
    },
  })

  getter response_mismatch_count : UInt64 = 0_u64
  getter response_failure_count : UInt64 = 0_u64

  getter expected_response_code : Int32 = 200
  getter request_verb : String = "GET"
  @request_headers : HTTP::Headers = HTTP::Headers.new
  alias HeaderJSON = Hash(String, Array(String) | String)

  def on_load
    on_update
  end

  def on_update
    schedule.clear
    schedule.every((setting?(Int32, :ping_every) || 60).seconds) { check_status }
    @request_verb = setting?(String, :request_verb) || "GET"
    @expected_response_code = setting?(Int32, :expected_response_code) || 200

    request_headers = HTTP::Headers.new
    headers = setting?(HeaderJSON, :request_headers) || {} of String => Array(String) | String
    headers.each { |key, value| request_headers.add(key, value) }
    @request_headers = request_headers
  end

  def connected
    check_status
  end

  def check_status : Bool
    response = http(@request_verb, "/", headers: @request_headers)

    if response.status_code == expected_response_code
      self[:last_successful_check] = Time.utc.to_unix
      self[:last_response_code] = response.status_code
      true
    else
      self[:last_response_code] = response.status_code
      @response_mismatch_count += 1
      self[:response_mismatch_count] = @response_mismatch_count
      queue.online = false
      false
    end
  rescue error
    logger.warn(exception: error) { "HTTP service not responding" }
    @response_failure_count += 1
    self[:response_failure_count] = @response_failure_count
    self[:last_error] = error.message
    false
  end
end
