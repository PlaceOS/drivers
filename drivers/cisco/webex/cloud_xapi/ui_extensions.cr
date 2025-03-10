require "./models"

module CloudXAPI::UIExtensions
  include CloudXAPI::Models
  command({"UserInterface Message Alert Clear" => :msg_alert_clear})
  command({"UserInterface Message Alert Display" => :msg_alert},
    text: String,
    title_: String,
    duration_: 0..3600)

  command({"UserInterface Message Prompt Clear" => :msg_prompt_clear})

  def msg_prompt(device_id : String, text : String, options : Array(JSON::Any::Type), title : String? = nil, feedback_id : String? = nil, duration : Int64? = nil)
    option_map = {} of String => JSON::Any::Type
    ("Option.1".."Option.5").each_with_index do |key, i|
      break if i >= options.size
      option_map[key] = options[i]
    end

    command "UserInterface.Message.Prompt.Display",
      {
        "deviceId"  => device_id,
        "arguments" => {
          "text"        => text,
          "title"       => title,
          "feedback_id" => feedback_id,
          "duration"    => duration,
        }.merge(option_map),
      }.to_json
  end

  command({"UserInterface Message TextInput Clear" => :msg_text_clear})
  command({"UserInterface Message TextInput Display" => :msg_text},
    text: String,
    feedback_id: String,
    title_: String,
    duration_: 0..3600,
    input_type_: TextInputType,
    keyboard_state_: TextKeyboardState,
    place_holder_: String,
    submit_text_: String)

  def ui_set_value(device_id : String, widget : String, value : JSON::Any::Type? = nil)
    cmd = (value.nil? ? "UserInterface Extensions Widget UnsetValue" : "UserInterface Extensions Widget SetValue").tap { |v| break v.split(" ").join(".") }
    payload = {
      "deviceId"  => JSON::Any.new(device_id),
      "arguments" => JSON::Any.new({
        "widget_id" => JSON::Any.new(widget),
      }),
    } of String => JSON::Any
    payload["arguments"].as_h["value"] = JSON::Any.new(value) unless value.nil?
    command(cmd, payload.to_json)
  end

  command({"UserInterface Extensions Set" => :ui_extensions_deploy}, id: String, xml_def: String)
  command({"UserInterface Extensions List" => :ui_extensions_list})
  command({"UserInterface Extensions Clear" => :ui_extensions_clear})
end
