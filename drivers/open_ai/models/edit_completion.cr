# re-uses the TextCompletion responses
require "./text_completion"

module OpenAI
  # POST https://api.openai.com/v1/edits
  class CreateEditCompletion
    include JSON::Serializable

    # the model id
    # You can use the text-davinci-edit-001 or code-davinci-edit-001 model with this endpoint.
    property model : String

    # The input text to use as a starting point for the edit.
    property input : String

    # The instruction that tells the model how to edit the prompt.
    property instruction : String

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
  end
end
