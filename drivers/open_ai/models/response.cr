require "json"

module OpenAI
  # POST https://api.openai.com/v1/responses
  class CreateModelResponse
    include JSON::Serializable

    def initialize(@model : String, @input : String, @tools : Array(JSON::Any)? = nil)
    end

    property model : String
    property input : String

    # Built-in tool specs, e.g. `[{"type" => "web_search"}]` or
    # `[{"type" => "file_search", "vector_store_ids" => ["vs_..."]}]`
    @[JSON::Field(ignore_serialize: tools.nil?)]
    property tools : Array(JSON::Any)?
  end

  struct ResponseUsage
    include JSON::Serializable

    def initialize(@total_tokens, @input_tokens, @output_tokens)
    end

    getter total_tokens : Int64
    getter input_tokens : Int64
    getter output_tokens : Int64
  end

  struct ResponseContent
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter type : String
    getter text : String? = nil
  end

  struct ResponseOutput
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter type : String
    getter content : Array(ResponseContent)? = nil
  end

  struct ModelResponse
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter id : String
    getter object : String
    getter status : String
    getter model : String
    getter output : Array(ResponseOutput)
    getter usage : ResponseUsage

    # Aggregate text from `output_text` content blocks across all message items.
    # The output array can also include tool-call items (web_search, file_search, etc.)
    # which are skipped here.
    def output_text : String
      String.build do |io|
        output.each do |item|
          next unless item.type == "message"
          next unless contents = item.content
          contents.each do |part|
            next unless part.type == "output_text"
            if text = part.text
              io << text
            end
          end
        end
      end
    end
  end
end
