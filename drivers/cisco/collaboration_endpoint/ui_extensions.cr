module Cloud_XAPI::UIExtensions
  include Cisco::CollaborationEndpoint::XAPI

  command({"UserInterface Message Alert Clear" => :msg_alert_clear})
  command({"UserInterface Message Alert Display" => :msg_alert},
    text: String,
    title_: String,
    duration_: 0..3600)

  command({"UserInterface Message Prompt Clear" => :msg_prompt_clear})

  def msg_prompt(text : String, options : Array(JSON::Any::Type), title : String? = nil, feedback_id : String? = nil, duration : Int64? = nil)
    # TODO: return a promise, then prepend a async traffic monitor so it
    # can be resolved with the response, or rejected after the timeout.
    option_map = {} of String => JSON::Any::Type
    ("Option.1".."Option.5").each_with_index do |key, i|
      break if i >= options.size
      option_map[key] = options[i]
    end

    xcommand "UserInterface Message Prompt Display",
      hash_args: Hash(String, JSON::Any::Type){
        "text"        => text,
        "title"       => title,
        "feedback_id" => feedback_id,
        "duration"    => duration,
      }.merge(option_map)
  end

  enum TextInputType
    SingleLine
    Numeric
    Password
    PIN
  end

  enum TextKeyboardState
    Open
    Closed
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

  def ui_set_value(widget : String, value : JSON::Any::Type? = nil)
    if value.nil?
      xcommand "UserInterface Extensions Widget UnsetValue",
        widget_id: widget
    else
      xcommand "UserInterface Extensions Widget SetValue",
        value: value, widget_id: widget
    end
  end

  def ui_extensions_deploy(id : String, xml_def : String)
    xcommand "UserInterface Extensions Set", xml_def, config_id: id
  end

  def ui_extensions_list
    xcommand "UserInterface Extensions List"
  end

  def ui_extensions_clear
    xcommand "UserInterface Extensions Clear"
  end
end
