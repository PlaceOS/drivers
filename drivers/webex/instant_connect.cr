class Webex::InstantConnect < PlaceOS::Driver
  # Discovery Information
  generic_name :InstantConnect
  descriptive_name "Webex InstantConnect"
  uri_base "https://mtg-broker-a.wbx2.com"

  default_settings({
    bot_access_token: "token",
  })

  @audience_setting = "a4d886b0-979f-4e2c-a958-3e8c14605e51"

  def create_meeting(meeting_id : String)
    expiry = 24.hours.from_now.to_unix
    payload = {
      "aud": @audience_setting,
      "jwt": {
        "sub": meeting_id,
        "exp": expiry,
      },
    }.to_json

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
