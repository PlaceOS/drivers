require "placeos-driver"

class Cisco::Webex::InstantConnect < PlaceOS::Driver
  # Discovery Information
  generic_name :InstantConnect
  descriptive_name "Webex InstantConnect"
  uri_base "https://mtg-broker-a.wbx2.com"

  default_settings({
    bot_access_token: "token",
    jwt_audience:     "a4d886b0-979f-4e2c-a958-3e8c14605e51",
  })

  @jwt_audience : String = "a4d886b0-979f-4e2c-a958-3e8c14605e51"
  @bot_access_token : String = ""

  def on_load
    on_update
  end

  def on_update
    @audience_setting = setting?(String, :jwt_audience) || "a4d886b0-979f-4e2c-a958-3e8c14605e51"
    @bot_access_token = setting(String, :bot_access_token)
  end

  def create_meeting(room_id : String)
    expiry = 24.hours.from_now.to_unix
    request = {
      "aud": @jwt_audience,
      "jwt": {
        "sub": room_id,
        "exp": expiry,
      },
    }.to_json

    get_meeting_details get_hash(request)
  end

  protected def get_meeting_details(meeting_keys)
    response = get("/api/v1/space/?int=jose&data=#{meeting_keys[:host]}")
    logger.debug { "host config returned:\n#{response.body}" }
    raise "host token request failed with #{response.status_code}" if response_failed?(response)
    meeting_config = Hash(String, JSON::Any).from_json(response.body)

    response = get("/api/v1/space/?int=jose&data=#{meeting_keys[:guest]}")
    logger.debug { "guest config returned:\n#{response.body}" }
    raise "guest token request failed with #{response.status_code}" if response_failed?(response)
    guest_token = String.from_json(response.body, root: "token")

    {
      # space_id seems to be an internal id for the meeting room
      space_id:    meeting_config["spaceId"].as_s,
      host_token:  meeting_config["token"].as_s,
      guest_token: guest_token,
    }
  end

  protected def get_hash(request : String)
    response = post("/api/v1/joseencrypt", body: request, headers: HTTP::Headers{
      "Accept"        => "application/json",
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{@bot_access_token}",
    })

    logger.debug { "get_hash returned:\n#{response.body}" }
    raise "request failed with #{response.status_code}" if response_failed?(response)

    response = NamedTuple(host: Tuple(String), guest: Tuple(String)).from_json(response.body)
    {
      host:  response[:host][0],
      guest: response[:guest][0],
    }
  end

  protected def response_failed?(response)
    response.status_code != 200 || response.body.nil?
  end
end
