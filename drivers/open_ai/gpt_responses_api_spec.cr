require "placeos-driver/spec"
require "./models/response"

DriverSpecs.mock_driver "OpenAI::GPTResponsesAPI" do
  # --- Plain text input, default model ---
  result = exec(:generate, input: "Tell me a story")

  expect_http_request do |request, response|
    raise "missing body" unless io = request.body
    body = JSON.parse(io.gets_to_end)
    body["model"].should eq("gpt-5.1")
    body["input"].should eq("Tell me a story")
    body.as_h.has_key?("tools").should be_false
    request.headers["Authorization"]?.should eq("Bearer 8537d5c8-a85c-4657-bc6b-7c35b1405464")

    response.status_code = 200
    response << {
      id:         "resp_1",
      object:     "response",
      created_at: 1741476542,
      status:     "completed",
      model:      "gpt-5.1",
      output:     [
        {
          type:    "message",
          id:      "msg_1",
          status:  "completed",
          role:    "assistant",
          content: [
            {type: "output_text", text: "once upon a time", annotations: [] of String},
          ],
        },
      ],
      usage: {
        input_tokens:          10_i64,
        input_tokens_details:  {cached_tokens: 0_i64},
        output_tokens:         5_i64,
        output_tokens_details: {reasoning_tokens: 0_i64},
        total_tokens:          15_i64,
      },
    }.to_json
  end

  result.get.should eq("once upon a time")

  usage = status["usage"]?
  usage.should_not be_nil
  usage.try(&.["total_tokens"]).should eq(15)

  # --- Tools + per-call model override ---
  result = exec(:generate,
    input: "What is the weather?",
    tools: [{"type" => "web_search"}],
    model: "gpt-5.4",
  )

  expect_http_request do |request, response|
    raise "missing body" unless io = request.body
    body = JSON.parse(io.gets_to_end)
    body["model"].should eq("gpt-5.4")
    body["input"].should eq("What is the weather?")
    body["tools"][0]["type"].should eq("web_search")

    response.status_code = 200
    response << {
      id:         "resp_2",
      object:     "response",
      created_at: 1741476600,
      status:     "completed",
      model:      "gpt-5.4",
      output:     [
        {
          type:   "web_search_call",
          id:     "ws_1",
          status: "completed",
        },
        {
          type:    "message",
          id:      "msg_2",
          status:  "completed",
          role:    "assistant",
          content: [
            {type: "output_text", text: "It is sunny.", annotations: [] of String},
          ],
        },
      ],
      usage: {
        input_tokens:          20_i64,
        input_tokens_details:  {cached_tokens: 0_i64},
        output_tokens:         8_i64,
        output_tokens_details: {reasoning_tokens: 0_i64},
        total_tokens:          28_i64,
      },
    }.to_json
  end

  result.get.should eq("It is sunny.")

  usage = status["usage"]?
  usage.try(&.["total_tokens"]).should eq(43)
end
