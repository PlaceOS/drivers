require "placeos-driver"
require "placeos-driver/interface/sms"
require "awscr-signer"
require "uri/params"

# Documentation: https://docs.aws.amazon.com/sns/latest/api/API_Publish.html

class AWS::SnsSms < PlaceOS::Driver
  include Interface::SMS

  # Discovery Information
  generic_name :SMS
  descriptive_name "Amazon SNS - SMS service"
  uri_base "https://sns.us-west-2.amazonaws.com"

  default_settings({
    aws_access_key: "12345",
    aws_secret:     "random",
  })

  def on_load
    on_update
  end

  getter! signer : Awscr::Signer::Signers::V4

  def on_update
    access_key = setting(String, :aws_access_key)
    secret = setting(String, :aws_secret)

    # grab the bits required for the signer
    uri_parts = URI.parse(config.uri.not_nil!).host.not_nil!.split('.')
    service = uri_parts[0]
    region = uri_parts[1]

    @signer = Awscr::Signer::Signers::V4.new(service, region, access_key, secret)
  end

  def before_request(request : HTTP::Request)
    signer.sign(request)
  end

  def send_sms(
    phone_numbers : String | Array(String),
    message : String,
    format : String? = "SMS",
    source : String? = nil
  )
    phone_numbers = [phone_numbers] unless phone_numbers.is_a?(Array)

    responses = phone_numbers.map do |number|
      params = URI::Params.build do |form|
        form.add "Action", "Publish"
        form.add "PhoneNumber", number
        form.add "Message", message

        if source
          if source =~ /^\+?\d{5,14}$/
            form.add "MessageAttributes.entry.1.Name", "AWS.MM.SMS.OriginationNumber"
            form.add "MessageAttributes.entry.1.Value.DataType", "String"
            form.add "MessageAttributes.entry.1.Value.StringValue", source
          else
            form.add "MessageAttributes.entry.1.Name", "AWS.SNS.SMS.SenderID"
            form.add "MessageAttributes.entry.1.Value.DataType", "String"
            form.add "MessageAttributes.entry.1.Value.StringValue", source.gsub(' ', '-')
          end
        end
      end

      post("/?#{params}", headers: HTTP::Headers{
        "Accept" => "application/json",
      })
    end

    responses.each do |response|
      raise "request failed with #{response.status_code}: #{response.body}" unless response.success?
    end

    nil
  end
end
