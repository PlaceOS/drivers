require "placeos-driver"
require "./models/*"

class OpenAI::GPT < PlaceOS::Driver
  descriptive_name "OpenAI GPT Gateway"
  generic_name :LLM
  uri_base "https://api.openai.com"

  default_settings({
    openai_key: "8537d5c8-a85c-4657-bc6b-7c35b1405464",
    openai_org: "856b5b85d3eb4697369",
  })

  def on_update
    openai_key = setting(String, :openai_key)
    openai_org = setting?(String, :openai_org)

    transport.before_request do |request|
      logger.debug { "requesting #{request.method} #{request.path}?#{request.query}\n#{request.headers}\n#{request.body}" }

      request.headers["Authorization"] = "Bearer #{openai_key}"
      request.headers["OpenAI-Organization"] = openai_org if openai_org
      request.headers["Content-Type"] = "application/json"
    end

    if usage = setting?(Usage, :token_usage)
      @total_tokens = usage.total_tokens
      @prompt_tokens = usage.prompt_tokens
      @completion_tokens = usage.completion_tokens
    end
  end

  @write_lock = Mutex.new
  @writing_stats = false
  getter total_tokens : Int64 = 0
  getter prompt_tokens : Int64 = 0
  getter completion_tokens : Int64 = 0

  protected def check(response)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    response
  end

  # we only need a rough details on usage so if we miss one or two requests
  # that's fine, but generally should be eventually consistent
  protected def write_stats(usage : Usage)
    @write_lock.synchronize do
      return if @writing_stats
      @writing_stats = true
    end
    define_setting(:token_usage, usage)
  ensure
    @write_lock.synchronize { @writing_stats = false }
  end

  protected def update_token(usage : Usage)
    @total_tokens += usage.total_tokens
    @prompt_tokens += usage.prompt_tokens
    @completion_tokens += usage.completion_tokens
    usage = Usage.new(@total_tokens, @prompt_tokens, @completion_tokens)
    spawn { write_stats(usage) }
    self[:usage] = usage
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
    chat = ChatCompletion.from_json response.body
    update_token chat.usage
    chat.choices
  end
end
