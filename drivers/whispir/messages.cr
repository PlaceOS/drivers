require "placeos-driver"
require "placeos-driver/interface/sms"

# Documentation: https://whispir.github.io/api/#messages

class Whispir::Messages < PlaceOS::Driver
  include Interface::SMS

  # Discovery Information
  generic_name :SMS
  descriptive_name "Whispir messages service"
  uri_base "https://api.au.whispir.com"

  # For whatever reason, you need both basic auth and an API key
  default_settings({
    basic_auth: {
      username: "username",
      password: "password",
    },
    api_key: "12345",
  })

  def on_load
    on_update
  end

  @api_key : String = ""

  def on_update
    @api_key = setting(String, :api_key)
  end

  def send_sms(
    phone_numbers : String | Array(String),
    message : String,
    format : String? = "SMS",
    source : String? = nil
  )
    phone_numbers = [phone_numbers] unless phone_numbers.is_a?(Array)

    response = post("/messages?apikey=#{@api_key}", body: {
      to: phone_numbers.join(";"),
      # As far as I can tell, this field is not passed to the recipients
      subject: "PlaceOS Notification",
      body:    message,
    }.to_json, headers: {
      "Content-Type" => "application/vnd.whispir.message-v1+json",
      "Accept"       => "application/vnd.whispir.message-v1+json",
      "x-api-key"    => @api_key,
    })

    raise "request failed with #{response.status_code}" unless response.status_code == 202

    location = response.headers["Location"]?
    logger.debug { "message sent: #{location}" }

    location
  end
end
