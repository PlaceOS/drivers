require "placeos-driver"
require "./models/response"

class OpenAI::GPTResponsesAPI < PlaceOS::Driver
  descriptive_name "OpenAI GPT Responses API"
  generic_name :LLM
  description "OpenAI Responses API gateway. Supports built-in tool use such as web_search and file_search."

  uri_base "https://api.openai.com"

  default_settings({
    openai_key:    "8537d5c8-a85c-4657-bc6b-7c35b1405464",
    openai_org:    "856b5b85d3eb4697369",
    default_model: "gpt-5.1",
  })

  @default_model : String = "gpt-5.1"

  def on_update
    openai_key = setting(String, :openai_key)
    openai_org = setting?(String, :openai_org)
    @default_model = setting?(String, :default_model) || "gpt-5.1"

    transport.before_request do |request|
      logger.debug { "requesting #{request.method} #{request.path}?#{request.query}\n#{request.headers}\n#{request.body}" }

      request.headers["Authorization"] = "Bearer #{openai_key}"
      request.headers["OpenAI-Organization"] = openai_org if openai_org
      request.headers["Content-Type"] = "application/json"
    end

    if usage = setting?(ResponseUsage, :token_usage)
      @total_tokens = usage.total_tokens
      @input_tokens = usage.input_tokens
      @output_tokens = usage.output_tokens
    end
  end

  @write_lock = Mutex.new
  @writing_stats = false
  getter total_tokens : Int64 = 0
  getter input_tokens : Int64 = 0
  getter output_tokens : Int64 = 0

  protected def check(response)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    response
  end

  protected def write_stats(usage : ResponseUsage)
    @write_lock.synchronize do
      return if @writing_stats
      @writing_stats = true
    end
    define_setting(:token_usage, usage)
  ensure
    @write_lock.synchronize { @writing_stats = false }
  end

  protected def update_token(usage : ResponseUsage)
    @total_tokens += usage.total_tokens
    @input_tokens += usage.input_tokens
    @output_tokens += usage.output_tokens
    aggregated = ResponseUsage.new(@total_tokens, @input_tokens, @output_tokens)
    spawn { write_stats(aggregated) }
    self[:usage] = aggregated
  end

  # Generate a model response from a single text input.
  #
  # `tools` accepts built-in OpenAI tool specifications, e.g.:
  #   `[{"type" => "web_search"}]`
  #   `[{"type" => "file_search", "vector_store_ids" => ["vs_..."]}]`
  #
  # `model` overrides the driver-level default for this call only.
  def generate(input : String, tools : Array(JSON::Any)? = nil, model : String? = nil) : String
    request = CreateModelResponse.new(model || @default_model, input, tools)
    response = check post("/v1/responses", body: request.to_json)
    parsed = ModelResponse.from_json response.body
    update_token parsed.usage
    parsed.output_text
  end
end
