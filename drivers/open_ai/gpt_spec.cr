require "placeos-driver/spec"
require "./models/*"

DriverSpecs.mock_driver "OpenAI::GPT" do
  # long enough that the driver redacts it from the debug logs
  image = "aVZCT1J3MEs" * 30

  it "sends text and base64 image content parts" do
    message = OpenAI::Message.new(
      :user,
      [
        OpenAI::TextContent.new("what is in this image?"),
        OpenAI::ImageContent.new(image, "image/png"),
      ] of OpenAI::Content
    )

    resp = exec(:chat, model: "gpt-5.1", message: message, response_format: {type: "json_object"}, max_completion_tokens: 500)

    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!.gets_to_end)
      body["max_completion_tokens"].should eq 500
      body["response_format"]["type"].should eq "json_object"

      content = body["messages"][0]["content"]
      content[0]["type"].should eq "text"
      content[0]["text"].should eq "what is in this image?"
      content[1]["type"].should eq "image_url"
      content[1]["image_url"]["url"].should eq "data:image/png;base64,#{image}"

      response.status_code = 200
      response << {
        id:      "chatcmpl-123",
        object:  "chat.completion",
        created: 1_677_652_288,
        choices: [{
          index:         0,
          message:       {role: "assistant", content: "a cat"},
          finish_reason: "stop",
        }],
        usage: {prompt_tokens: 9, completion_tokens: 12, total_tokens: 21},
      }.to_json
    end

    choices = Array(OpenAI::MessageChoice).from_json resp.get.not_nil!.to_json
    choices.first.message.text.should eq "a cat"
    status[:usage]["total_tokens"].should eq 21
  end

  it "omits the optional fields when not provided" do
    resp = exec(:chat, model: "gpt-5.1", message: OpenAI::Message.new(:user, "hello"))

    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!.gets_to_end)
      body["messages"][0]["content"].should eq "hello"
      body.as_h.has_key?("response_format").should be_false
      body.as_h.has_key?("max_completion_tokens").should be_false

      response.status_code = 200
      response << {
        id:      "chatcmpl-124",
        object:  "chat.completion",
        created: 1_677_652_288,
        choices: [{
          index:         0,
          message:       {role: "assistant", content: "hi"},
          finish_reason: "stop",
        }],
        usage: {prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
      }.to_json
    end

    resp.get.should_not be_nil
  end
end
