require "placeos-driver/spec"

DriverSpecs.mock_driver "Lightware::Switcher" do
  settings({
    basic_auth: {
      username: "admin",
      password: "secret",
    },
    input_count:  2,
    output_count: 2,
    poll_every:   60,
  })

  auth = "Basic #{Base64.strict_encode("admin:secret")}"

  it "should poll signal presence and routes" do
    exec(:query_status)

    # examples from the REST API app note 1.11.2 and 1.11.3
    {"I1" => "true", "I2" => "false"}.each do |port, value|
      expect_http_request do |request, response|
        request.method.should eq "GET"
        request.path.should eq "/api/V1/MEDIA/VIDEO/#{port}/SignalPresent"
        request.headers["Authorization"]?.should eq auth
        response.status_code = 200
        response << value
      end
    end

    {"O1" => "I1", "O2" => "0"}.each do |port, value|
      expect_http_request do |request, response|
        request.method.should eq "GET"
        request.path.should eq "/api/V1/MEDIA/VIDEO/XP/#{port}/ConnectedSource"
        response.status_code = 200
        response << value
      end
    end
    sleep 100.milliseconds

    status["input_1_sync"].should eq true
    status["input_2_sync"].should eq false
    status["video1"].should eq 1
    status["video2"].should eq 0
    status["video1_muted"].should eq false
    status["video2_muted"].should eq true
  end

  it "should switch multiple outputs in a single request" do
    resp = exec(:switch, {"2" => [1], "1" => [2]})
    expect_http_request do |request, response|
      request.method.should eq "POST"
      request.path.should eq "/api/V1/MEDIA/VIDEO/XP/switch"
      request.headers["Authorization"]?.should eq auth
      request.body.try(&.gets_to_end).should eq "I2:O1;I1:O2"
      response.status_code = 200
      response << "OK"
    end
    resp.get

    status["video1"].should eq 2
    status["video2"].should eq 1
    status["video2_muted"].should eq false
  end

  it "should clear the mute when an input is switched to a muted output" do
    resp = exec(:mute, true, 1)
    expect_http_request do |request, response|
      request.body.try(&.gets_to_end).should eq "0:O1"
      response.status_code = 200
    end
    resp.get
    status["video1_muted"].should eq true

    resp = exec(:switch, {"2" => [1]})
    expect_http_request do |request, response|
      request.body.try(&.gets_to_end).should eq "I2:O1"
      response.status_code = 200
    end
    resp.get
    status["video1"].should eq 2
    status["video1_muted"].should eq false

    # nothing remembered, so unmute makes no request and nothing changes
    exec(:unmute, 1).get
    status["video1"].should eq 2
  end

  it "should switch the audio layer" do
    resp = exec(:switch, {"I2" => ["O3"]}, "audio")
    expect_http_request do |request, response|
      request.path.should eq "/api/V1/MEDIA/AUDIO/XP/switch"
      request.body.try(&.gets_to_end).should eq "I2:O3"
      response.status_code = 200
    end
    resp.get
    status["audio3"].should eq 2
  end

  it "should route an input to all outputs" do
    resp = exec(:switch_to, 1)
    expect_http_request do |request, response|
      request.path.should eq "/api/V1/MEDIA/VIDEO/XP/switch"
      request.body.try(&.gets_to_end).should eq "I1:O1;I1:O2"
      response.status_code = 200
    end
    resp.get
    status["video1"].should eq 1
    status["video2"].should eq 1
  end

  it "should mute by unrouting and unmute by restoring the route" do
    resp = exec(:mute, true, 2)
    expect_http_request do |request, response|
      request.path.should eq "/api/V1/MEDIA/VIDEO/XP/switch"
      request.body.try(&.gets_to_end).should eq "0:O2"
      response.status_code = 200
    end
    resp.get
    status["video2"].should eq 0
    status["video2_muted"].should eq true

    resp = exec(:unmute, 2)
    expect_http_request do |request, response|
      request.path.should eq "/api/V1/MEDIA/VIDEO/XP/switch"
      request.body.try(&.gets_to_end).should eq "I1:O2"
      response.status_code = 200
    end
    resp.get
    status["video2"].should eq 1
    status["video2_muted"].should eq false
  end

  it "should clear the mute when an input is switched to a muted output" do
    resp = exec(:mute, true, 1)
    expect_http_request do |request, response|
      request.body.try(&.gets_to_end).should eq "0:O1"
      response.status_code = 200
    end
    resp.get
    status["video1_muted"].should eq true

    resp = exec(:switch, {"2" => [1]})
    expect_http_request do |request, response|
      request.body.try(&.gets_to_end).should eq "I2:O1"
      response.status_code = 200
    end
    resp.get
    status["video1"].should eq 2
    status["video1_muted"].should eq false

    # nothing remembered, so unmute makes no request and nothing changes
    exec(:unmute, 1).get
    status["video1"].should eq 2
  end

  it "should raise when the device rejects a switch" do
    resp = exec(:switch, {"5" => [1]})
    expect_http_request do |_request, response|
      # 405 is returned when I1 and I5 are routed simultaneously on UCX
      response.status_code = 405
    end
    expect_raises(PlaceOS::Driver::RemoteException) { resp.get }
    status["video1"].should eq 2
  end
end
