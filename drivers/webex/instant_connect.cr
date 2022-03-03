require "./instant_connect_models.cr"

class Webex::InstantConnect < PlaceOS::Driver
  # Discovery Information
  generic_name :InstantConnect
  descriptive_name "Webex InstantConnect"
  uri_base "https://mtg-broker-a.wbx2.com"

  default_settings({
    bot_access_token: "token",
  })

  @audience_setting = "a4d886b0-979f-4e2c-a958-3e8c14605e51"

  def create_meeting(room_id : String, meeting_parameters : String)
    expiry = 24.hours.from_now.to_unix
    payload = {
      "aud": @audience_setting,
      "jwt": {
        "sub": room_id,
        "exp": expiry,
      },
    }.to_json

    return_hash = get_hash(payload)
    host_token = get_host_token(return_hash)

    response = post("/api/v1/joseencrypt", body: meeting_parameters, headers: {
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{host_token}",
    })
    raise "create meeting request failed with #{response.status_code}" unless response.status_code == 200 && !response.body.nil?
    MeetingResponse.from_json(response.body)
  end

  def get_host_token(hash : Hash(String, String))
    response = get("api/v1/space/?int=jose&data=#{hash["host"]}")
    raise "host token request failed with #{response.status_code}" unless response.status_code == 200 && !response.body.nil?
    puts "host token response is: #{response.inspect}"

    NamedTuple(token: String).from_json(response.body)[:token]
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
