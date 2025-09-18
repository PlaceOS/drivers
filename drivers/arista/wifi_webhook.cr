require "placeos-driver"

class Arista::WifiWebhook < PlaceOS::Driver
  descriptive_name "Arista Wifi Webhook Receiver"
  generic_name :Arista_Webhook

  default_settings({
    debug:      true,
  })

  def on_update
    @debug = setting?(Bool, :debug) || false
  end

  def receive_webhook(method : String, headers : Hash(String, Array(String)), body : String)
    logger.warn do
      "Received Webhook\n" +
        "Method: #{method.inspect}\n" +
        "Headers:\n#{headers.inspect}\n" +
        "Body:\n#{body.inspect}"
    end
    # Process the webhook payload as needed
  end
end
