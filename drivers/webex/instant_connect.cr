class Webex::InstantConnect < PlaceOS::Driver
  # Discovery Information
  generic_name :InstantConnect
  descriptive_name "Webex InstantConnect"
  uri_base "https://mtg-broker-a.wbx2.com"

  default_settings({
    bot_access_token: "token",
  })

  @audience_setting = "a4d886b0-979f-4e2c-a958-3e8c14605e51"

  def create_meeting(room_id : String)
    expiry = 24.hours.from_now.to_unix
    payload = {
      "aud": @audience_setting,
      "jwt": {
        "sub": room_id,
        "exp": expiry,
      },
    }.to_json

    return_hash = get_hash(payload)
    get_meeting_details(return_hash)
  end

  def get_meeting_details(hash : Hash(String, String))
    response = get("api/v1/space/?int=jose&data=#{hash["host"]}")
    raise "host token request failed with #{response.status_code}" unless response.status_code == 200 && !response.body.nil?

    meeting_config = Hash(String, String | Bool).from_json(response.body)
    response_keys = meeting_config.keys
    response_keys.delete("token")
    response_keys.delete("spaceId")
    meeting_config = meeting_config.reject(response_keys)

    response = get("api/v1/space/?int=jose&data=#{hash["guest"]}")
    raise "guest token request failed with #{response.status_code}" unless response.status_code == 200 && !response.body.nil?

    guest_token = String.from_json(response.body, root: "token")
    meeting_config["guest_token"] = guest_token
    meeting_config
  end

  def get_hash(payload : String)
    response = post("/api/v1/joseencrypt", body: payload, headers: {
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{setting String, :bot_access_token}",
    })

    raise "request failed with #{response.status_code}" unless response.status_code == 200 && !response.body.nil?

    response_body = NamedTuple(host: Tuple(String), guest: Tuple(String)).from_json(response.body)
    return_hash = Hash(String, String).new(initial_capacity: 2)
    response_body.each do |key, value|
      return_hash[key.to_s] = value.first.to_s
    end
    return_hash
  end
end
