module Cisco; end

module Cisco::Meraki; end

require "json"
require "openssl"

class Cisco::Meraki::CaptivePortal < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco Meraki Captive Portal"
  generic_name :CaptivePortal
  description %(
    for more information visit: https://meraki.cisco.com/lib/pdf/meraki_whitepaper_captive_portal.pdf
  )

  default_settings({
    wifi_secret:      "anything really",
    default_timezone: "Australia/Sydney",
    date_format:      "%Y%m%d",
    # duration of access in hours
    access_duration: 12,
    # Length of the clients wifi code
    code_length: 4,
    success_url: "https://company.com/welcome",
  })

  def on_load
    on_update
  end

  @wifi_secret : String = ""
  @date_format : String = "%Y%m%d"
  @success_url : String = "https://place.technology/"
  @default_timezone : Time::Location = Time::Location.load("Australia/Sydney")
  @access_duration : Time::Span = 12.hours
  @code_length : Int32 = 4

  @denied : UInt64 = 0_u64
  @granted : UInt64 = 0_u64
  @errors : UInt64 = 0_u64

  @guests : Hash(String, ChallengePayload) = {} of String => ChallengePayload

  def on_update
    @wifi_secret = setting?(String, :wifi_secret) || "anything really"
    @date_format = setting?(String, :date_format) || "%Y%m%d"
    @success_url = setting?(String, :success_url) || "https://place.technology/"
    @access_duration = (setting?(Int32, :access_duration) || 12).hours
    @code_length = setting?(Int32, :code_length) || 4

    time_zone = setting?(String, :default_timezone).presence
    @default_timezone = Time::Location.load(time_zone) if time_zone
  end

  @[Security(Level::Support)]
  def guests
    @guests
  end

  @[Security(Level::Support)]
  def lookup(mac : String)
    @guests[format_mac(mac)]
  end

  def generate_guest_data(email : String, time : Int64, time_zone : String? = nil)
    time_zone = time_zone.presence ? Time::Location.load(time_zone.not_nil!) : @default_timezone
    date = Time.unix(time).in(time_zone).to_s(@date_format)
    guest_string = "#{email.downcase}-#{date}-#{@wifi_secret}"

    OpenSSL::Digest.new("SHA256").update(guest_string).hexdigest
  end

  # Splits the SHA256 into code length and then randomly selects one
  def generate_guest_token(email : String, time : Int64, time_zone : String? = nil)
    generate_guest_data(email, time, time_zone).scan(/.{#{@code_length}}/).sample(1)[0][0]
  end

  class ChallengePayload
    include JSON::Serializable

    property ap_mac : String
    property client_ip : String
    property client_mac : String
    property base_grant_url : String
    property user_continue : String?

    # key they were provided in their invite email
    property code : String
    property email : String
    property timezone : String?

    property expires : Time? = nil
  end

  EMPTY_HEADERS = {} of String => String
  JSON_HEADERS  = {
    "Content-Type" => "application/json",
  }

  # Webhook for providing guest access
  def challenge(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "guest access attempt: #{method},\nheaders #{headers},\nbody #{body}" }

    challenge = ChallengePayload.from_json(body)

    check_code = challenge.code
    guest_codes = generate_guest_data(challenge.email, Time.utc.to_unix, challenge.timezone)
    matched = guest_codes.scan(/.{#{@code_length}}/).select { |code| code[0] == check_code }.size > 0

    if matched
      challenge.expires = @access_duration.from_now
      @guests[format_mac(challenge.client_mac)] = challenge
      @granted += 1_u64
      self[:granted_access] = @granted

      redirect_url = "#{challenge.base_grant_url}?duration=#{@access_duration.to_i}&continue_url=#{challenge.user_continue || @success_url}"
      response = {
        redirect_to: redirect_url,
      }.to_json

      logger.debug { "successful joined network #{challenge.inspect}" }

      # Redirect to the success URL
      {HTTP::Status::OK, JSON_HEADERS, response}
    else
      @denied += 1_u64
      self[:denied_access] = @denied

      logger.debug { "failed wifi access attempt by #{challenge.inspect}" }

      {HTTP::Status::NOT_ACCEPTABLE, JSON_HEADERS, "{}"}
    end
  rescue error
    @errors += 1_u64
    self[:errors] = @errors
    last_error = error.inspect_with_backtrace
    self[:last_error] = last_error
    logger.error { "failed to parse wifi challenge payload\n#{error}" }
    {HTTP::Status::INTERNAL_SERVER_ERROR, EMPTY_HEADERS, nil}
  end

  protected def format_mac(address : String)
    address.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end
end
