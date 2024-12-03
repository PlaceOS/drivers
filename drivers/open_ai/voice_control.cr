require "placeos-driver"
require "./models/*"

# A Voice interface that should be able to:
# * request
class OpenAI::VoiceControlInterface < PlaceOS::Driver
  descriptive_name "Voice Control Interface"
  generic_name :VoiceControl

  accessor language_model : LLM_1

  default_settings({
    llm_model_id: "gpt-3.5-turbo",

    # [{ role: "user", content: "ensure devices are powered on before use" }]
    custom_prompts: [] of OpenAI::Message,
  })

  def on_update
    @llm_model_id = setting(String, :llm_model_id)
    @custom_prompts = setting?(Array(OpenAI::Message), :custom_prompts) || [] of OpenAI::Message
  end

  getter llm_model_id : String = "gpt-3.5-turbo"
  getter custom_prompts : Array(OpenAI::Message) = [] of OpenAI::Message

  PROMPT = OpenAI::Message.new(
    :user,
    <<-MESSAGE
    
    MESSAGE
  )

  def request(text : String)
    messages = [PROMPT] + custom_prompts + [OpenAI::Message.new(:user, "The Request: #{text}")]
    choices = Array(MessageChoice).from_json language_model.chat(llm_model_id, messages).get.to_json
    # select choice (typically just the first one)
    # parse the response (prompt should ensure it responds using JSON)
    # perform request actions:
    # => loop provide any errors to the LLM and request fixes (limit 3)
    # provide text response to user as well as success or failure
  end

  alias Metadata = PlaceOS::Driver::DriverModel::Metadata

  def system_metadata
    # Display_1 => {interface: {}, notes: ""}
    metadata = {} of String => Metadata

    sys = system
    sys.modules.each do |module_name|
      1.upto(sys.count(module_name)) do |index|
        mod = sys.get(module_name, index)
        metadata["#{module_name}_#{index}"] = mod.__metadata__.llm_interface
      end
    end

    # module functions are described by JSON schema
    # modules["Display_1"] #=> {
    #  "interface": {"function": {"param": {"type": "string", "default": "value"}}},
    #  "notes": "small display near the door, on the left"
    # }
    {
      name:        sys.name,
      description: sys.description,
      modules:     metadata,
    }
  end

  # returns a hash of status values
  def module_status(module_id : String) : Hash(String, String)
    system[module_id].__status__
  end
end
