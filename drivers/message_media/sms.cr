module MessageMedia; end

# Documentation: https://developers.messagemedia.com/code/messages-api-documentation/
require "engine-driver/interface/sms"

class MessageMedia::SMS < EngineDriver
  include EngineDriver::Interface::SMS

  # Discovery Information
  generic_name :SMS
  descriptive_name "MessageMedia SMS service"

  default_settings({
    basic_auth: {
      username: "srvc_acct",
      password: "password!"
    }
  })

  def on_load
    on_update
  end

  def on_update
    # NOTE:: base URI https://api.messagemedia.com
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

    response = post("/v1/messages", body: {
      messages: numbers,
    }.to_json, headers: {
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
    })

    raise "request failed with #{response.status_code}" unless response.status_code == 202
    nil
  end
end
