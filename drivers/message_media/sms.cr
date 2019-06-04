module MessageMedia; end

# Documentation: https://developers.messagemedia.com/code/messages-api-documentation/
require "engine-driver/interface/sms"

class MessageMedia::SMS < EngineDriver
  include EngineDriver::Interface::SMS

  # Discovery Information
  generic_name :SMS
  descriptive_name "MessageMedia SMS service"

  def on_load
    on_update
  end

  @username : String = ""
  @password : String = ""

  def on_update
    # NOTE:: base URI https://api.messagemedia.com
    @username = setting?(String, :username) || ""
    @password = setting?(String, :password) || ""
  end

  def send_sms(
    phone_numbers : String | Array(String),
    message : String,
    format : String? = "SMS",
    source : String? = nil
  )
    phone_numbers = [phone_numbers] unless phone_numbers.is_a?(Array)

    # Could be MMS etc
    format = format || "SMS"

    numbers = phone_numbers.map do |number|
      payload = {
        :content            => message,
        :destination_number => number,
        :format             => format,
      }
      if source
        payload[:source_number] = source.to_s
        payload[:source_number_type] = "ALPHANUMERIC"
      end
      payload
    end

    basic_auth = "Basic #{Base64.strict_encode("#{@username}:#{@password}")}"

    response = post("/v1/messages", body: {
      messages: numbers,
    }.to_json, headers: {
      "Authorization" => basic_auth,
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
    })

    raise "request failed with #{response.status_code}" unless response.status_code == 202
    nil
  end
end
