require "placeos-driver"
require "base64"
require "jwt"

class Cisco::Webex::InstantConnect < PlaceOS::Driver
  # Discovery Information
  generic_name :InstantConnect
  descriptive_name "Webex InstantConnect"
  uri_base "https://mtg-broker-a.wbx2.com"

  default_settings({
    bot_access_token:   "token",
    jwt_audience:       "a4d886b0-979f-4e2c-a958-3e8c14605e51",
    webex_guest_issuer: "a4d886b0",
    webex_guest_secret: "a958-3e8c14605e51",
  })

  @jwt_audience : String = "a4d886b0-979f-4e2c-a958-3e8c14605e51"
  @bot_access_token : String = ""
  @webex_guest_issuer : String = ""
  @webex_guest_secret : String = ""

  def on_update
    @webex_guest_issuer = setting?(String, :webex_guest_issuer) || ""
    @webex_guest_secret = setting?(String, :webex_guest_secret) || ""

    @audience_setting = setting?(String, :jwt_audience) || "a4d886b0-979f-4e2c-a958-3e8c14605e51"
    @bot_access_token = setting(String, :bot_access_token)
  end

  # Cisco docs on the subject:
  # * Guest JWT: https://developer.webex.com/docs/guest-issuer
  # * Testing site: https://webexsamples.github.io/browser-sdk-samples/browser-auth-jwt/
  def create_guest_bearer(user_id : String, display_name : String, expiry : Int64? = nil)
    expires_at = expiry || 12.hours.from_now.to_unix
    JWT.encode({
      "sub":  user_id,
      "name": display_name,
      "iss":  @webex_guest_issuer,
      "iat":  3.minutes.ago.to_unix,
      "exp":  expires_at,
    }, Base64.decode_string(@webex_guest_secret), :hs256)
  end

  def create_meeting(room_id : String)
    expiry = 24.hours.from_now.to_unix
    request = {
      aud:              @jwt_audience,
      provideShortUrls: true,
      jwt:              {
        # the encounter id, should be unique for each patient encounter
        sub: room_id,
        exp: expiry,
      },
    }.to_json

    get_meeting_details get_hash(request)
  end

  protected def get_meeting_details(meeting_keys)
    host_details = meeting_keys.host.first
    guest_details = meeting_keys.guest.first

    response = get("/api/v1/space/?int=jose&data=#{host_details.cipher}")
    logger.debug { "host config returned:\n#{response.body}" }
    raise "host token request failed with #{response.status_code}" if response_failed?(response)
    meeting_config = Hash(String, JSON::Any).from_json(response.body)

    response = get("/api/v1/space/?int=jose&data=#{guest_details.cipher}")
    logger.debug { "guest config returned:\n#{response.body}" }
    raise "guest token request failed with #{response.status_code}" if response_failed?(response)
    guest_token = String.from_json(response.body, root: "token")

    {
      # space_id seems to be an internal id for the meeting room
      space_id:    meeting_config["spaceId"].as_s,
      host_token:  meeting_config["token"].as_s,
      guest_token: guest_token,
      host_url:    "#{meeting_keys.base_url}#{host_details.short}",
      guest_url:   "#{meeting_keys.base_url}#{guest_details.short}",
    }
  end

  struct JoseEncryptResponse
    include JSON::Serializable

    getter host : Array(MeetingDetails)
    getter guest : Array(MeetingDetails)

    @[JSON::Field(key: "baseUrl")]
    getter base_url : String
  end

  struct MeetingDetails
    include JSON::Serializable

    getter cipher : String
    getter short : String
  end

  protected def get_hash(request : String)
    response = post("/api/v2/joseencrypt", body: request, headers: HTTP::Headers{
      "Accept"        => "application/json",
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{@bot_access_token}",
    })

    logger.debug { "get_hash returned:\n#{response.body}" }
    raise "request failed with #{response.status_code}" if response_failed?(response)

    JoseEncryptResponse.from_json(response.body)
  end

  protected def response_failed?(response)
    logger.warn { "instant connect response failure\ncode: #{response.status_code}, status: #{response.status}\nbody:\n#{response.body.inspect}" } unless response.success?
    response.status_code != 200 || response.body.nil?
  end
end
