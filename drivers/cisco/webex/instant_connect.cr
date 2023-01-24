require "placeos-driver"

class Cisco::Webex::InstantConnect < PlaceOS::Driver
  # Discovery Information
  generic_name :InstantConnect
  descriptive_name "Webex InstantConnect"
  uri_base "https://instant.webex.com"

  default_settings({
    bot_access_token: "token",
    jwt_audience:     "a4d886b0-979f-4e2c-a958-3e8c14605e51",
    _broker:          "https://mtg-broker-a.wbx2.com",
  })

  @jwt_audience : String = "a4d886b0-979f-4e2c-a958-3e8c14605e51"
  @bot_access_token : String = ""
  @broker : String = ""

  def on_load
    on_update
  end

  def on_update
    @audience_setting = setting?(String, :jwt_audience) || "a4d886b0-979f-4e2c-a958-3e8c14605e51"
    @bot_access_token = setting(String, :bot_access_token)
    @broker = setting?(String, :broker) || config.uri.not_nil!
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
    response = get("/gen/v1/login/?int=jose&data=#{meeting_keys[:host]}")
    raise "host token request failed with #{response.status_code}" if response_failed?(response)
    meeting_config = Hash(String, String | Bool).from_json(response.body)

    response = get("/gen/v1/talk/?int=jose&data=#{meeting_keys[:guest]}")
    raise "guest token request failed with #{response.status_code}" if response_failed?(response)
    guest_token = String.from_json(response.body, root: "token")

    {
      # space_id seems to be an internal id for the meeting room
      space_id:    meeting_config["spaceId"],
      host_token:  meeting_config["token"],
      guest_token: guest_token,
    }
  end

  protected def get_hash(request : String)
    response = HTTP::Client.post(File.join(@broker, "/api/v1/joseencrypt"), body: request, headers: HTTP::Headers{
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{@bot_access_token}",
    })

    raise "request failed with #{response.status_code}" if response_failed?(response)

    response = NamedTuple(host: Array(String), guest: Array(String)).from_json(response.body)
    {
      host:  response[:host].first,
      guest: response[:guest].first,
    }
  end

  protected def response_failed?(response)
    response.status_code != 200 || response.body.nil?
  end
end
