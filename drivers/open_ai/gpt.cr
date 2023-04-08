require "placeos-driver"
require "./models/*"

class OpenAI::GPT < PlaceOS::Driver
  descriptive_name "OpenAI GPT Gateway"
  generic_name :ChatGPT
  uri_base "https://api.openai.com"

  default_settings({
    openai_key: "8537d5c8-a85c-4657-bc6b-7c35b1405464",
    openai_org: "856b5b85d3eb4697369",
  })

  def on_load
    on_update
  end

  def on_update
    openai_key = setting(String, :openai_key)
    openai_org = setting(String, :openai_org)

    transport.before_request do |request|
      logger.debug { "requesting #{request.method} #{request.path}?#{request.query}\n#{request.headers}\n#{request.body}" }

      request.headers["Authorization"] = "Bearer #{openai_key}"
      request.headers["OpenAI-Organization"] = openai_org
      request.headers["Content-Type"] = "application/json"
    end
  end

  getter token_usage : Int64 = 0

  protected def check(response)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    response
  end

  # returns the available models for the current key
  def models
    response = check get("/v1/models")
    List(Model).from_json(response.body).data
  end

  # returns the details of the provided model id
  def model(id : String)
    response = check get("/v1/models/#{id}")
    Model.from_json response.body
  end

  # creates a completion for the chat message
  def chat(model : String, message : Message | Array(Message))
    messages = message.is_a?(Array) ? message : [message]
    chat = CreateChatCompletion.new(model, messages)
    response = check post("/v1/chat/completions", body: chat.to_json)
    ChatCompletion.from_json response.body
  end
end
