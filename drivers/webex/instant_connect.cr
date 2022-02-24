# require "placeos-driver"

class Webex::InstantConnect < PlaceOS::Driver
  # Discovery Information
  generic_name :InstantConnect
  descriptive_name "Webex InstantConnect"
  uri_base "https://mtg-broker-a.wbx2.com/api/v1/joseencrypt"

  default_settings({
    bearer: {
      token: "Bearer bot_access_token",
    },
    bot_access_token: "token",
  })

  @audience_setting = ""

  def create_meeting(meeting_id : String)
    expiry = 24.hours.from_now.to_unix
    payload = {
      "aud": @audience_setting,
      "jwt": {
        "sub": meeting_id,
        "exp": expiry,
      },
    }.to_json

    response = post("/", body: payload, headers: {
      "Content-Type"  => "application/json",
      "Authorization" => setting String, :bot_access_token,
    })

    raise "request failed with #{response.status_code}" unless response.status_code == 201

    response_body = NamedTuple(host: Array(String), guest: Array(String)).from_json(response.body.not_nil!)

    return_hash = Hash(String, String).new
    response_body.each do |key, value|
      return_hash[key.to_s] = value.first.to_s
    end
    return_hash
  end
end
