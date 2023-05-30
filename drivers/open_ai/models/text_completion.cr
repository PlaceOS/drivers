require "./model"

module OpenAI
  # POST https://api.openai.com/v1/completions
  class CreateTextCompletion
    include JSON::Serializable

    # the model id
    property model : String

    # The prompt(s) to generate completions for
    property prompt : String | Array(String)? = "<|endoftext|>"

    # The suffix that comes after a completion of inserted text.
    property suffix : String? = nil

    # The maximum number of tokens to generate in the completion.
    # Most models have a context length of 2048 tokens (except for the newest models, which support 4096).
    # The token count of your prompt plus max_tokens cannot exceed the model's context length.
    property max_tokens : Int32 = 16

    # What sampling temperature to use, between 0 and 2.
    # Higher values like 0.8 will make the output more random,
    # while lower values like 0.2 will make it more focused and deterministic.
    property temperature : Float64 = 1.0

    # An alternative to sampling with temperature, called nucleus sampling,
    # where the model considers the results of the tokens with top_p probability mass.
    # So 0.1 means only the tokens comprising the top 10% probability mass are considered.
    # Alter this or temperature but not both.
    property top_p : Float64 = 1.0

    # How many completions to generate for each prompt.
    @[JSON::Field(key: "n")]
    property num_completions : Int32 = 1

    # Whether to stream back partial progress.
    property stream : Bool = false

    # Include the log probabilities on the logprobs most likely tokens, as well the chosen tokens.
    property logprobs : Int32? = nil

    # Echo back the prompt in addition to the completion
    property echo : Bool = false

    # Up to 4 sequences where the API will stop generating further tokens.
    # The returned text will not contain the stop sequence.
    property stop : String | Array(String)? = nil

    # Number between -2.0 and 2.0.
    # Positive values penalize new tokens based on whether they appear in the text so far,
    # increasing the model's likelihood to talk about new topics.
    property presence_penalty : Float64 = 0.0

    # Number between -2.0 and 2.0.
    # Positive values penalize new tokens based on their existing frequency in the text so far,
    # decreasing the model's likelihood to repeat the same line verbatim.
    property frequency_penalty : Float64 = 0.0

    # Generates best_of completions server-side and returns the "best" (the one with the highest log probability per token). Results cannot be streamed.
    # best_of must be greater than num_completions
    property best_of : Int32 = 1

    # Modify the likelihood of specified tokens appearing in the completion.
    # You can use this [tokenizer tool](https://platform.openai.com/tokenizer?view=bpe) (which works for both GPT-2 and GPT-3) to convert text to token IDs
    property logit_bias : Hash(String, Float64)? = nil

    # A unique identifier representing your end-user, which can help OpenAI to monitor and detect abuse.
    property user : String? = nil
  end

  struct TextChoice
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter text : String
    getter index : Int32
    getter finish_reason : String?
  end

  struct TextCompletion
    include JSON::Serializable

    getter id : String?
    getter model : String?
    getter object : String

    @[JSON::Field(converter: Time::EpochConverter)]
    getter created : Time

    getter choices : Array(TextChoice)
    getter usage : Usage
  end
end
