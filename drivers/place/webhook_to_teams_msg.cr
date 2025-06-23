require "placeos-driver"

class Place::WebhookToTeamsMsg < PlaceOS::Driver
  descriptive_name "Webhook to Teams Message"
  generic_name :Webhook
  description "Receive a webhook POST and send it's body to an MS Teams Channel"

  default_settings({
    teams_channel_id: "Required",
    teams_group_id: "Required",
    prepend_text_to_message: "",
    append_text_to_message: ""
  })

  accessor staff_api : StaffAPI

  @teams_channel_id : String = "Required"
  @teams_group_id : String = "Required"
  @text_to_prepend : String = ""
  @text_to_append : String = ""

  def on_load
    on_update
  end

  def on_update
    @teams_channel_id = setting(String, :teams_channel_id) || "Required"
    @teams_group_id = setting(String, :teams_group_id) || "Required"
    @text_to_prepend = setting(String, :prepend_text_to_message) || ""
    @text_to_append = setting(String, :append_text_to_message) || ""
  end

  def receive_webhook(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "Received Webhook with Method:#{method}, \nHeaders: #{headers}, \nBody: #{body}" }
    return unless method == "POST"

    send_teams_message(body)
  end

  def send_teams_message(message : String)
    message = @text_to_prepend + message + @text_to_append
    staff_api.send_channel_message(@teams_channel_id, @teams_group_id, message)
  end
end
