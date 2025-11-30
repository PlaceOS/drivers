require "placeos-driver/spec"

DriverSpecs.mock_driver "Sony::Displays::BraviaRest" do
  settings({
    psk: "test1234",
  })

  # Power Control Tests
  it "should power on the display" do
    exec(:power_on)
    
    expect_http_request do |request, response|
      headers = request.headers
      headers["X-Auth-PSK"].should eq("test1234")
      headers["Content-Type"].should eq("application/json")
      
      request.path.should eq("/sony/system")
      
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setPowerStatus")
      body["params"].as_a.first["status"].should eq(true)
      
      response.status_code = 200
      response << %<{"result":[{"status":"active"}],"id":1}>
    end
    
    status[:power].should eq(true)
    status[:power_status].should eq("on")
  end

  it "should power off the display" do
    exec(:power_off)
    
    expect_http_request do |request, response|
      headers = request.headers
      headers["X-Auth-PSK"].should eq("test1234")
      
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setPowerStatus")
      body["params"].as_a.first["status"].should eq(false)
      
      response.status_code = 200
      response << %<{"result":[{"status":"standby"}],"id":2}>
    end
    
    status[:power].should eq(false)
    status[:power_status].should eq("standby")
  end

  it "should query power status" do
    exec(:query_power_status)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("getPowerStatus")
      
      response.status_code = 200
      response << %<{"result":[{"status":"active"}],"id":3}>
    end
    
    status[:power].should eq(true)
    status[:power_status].should eq("on")
  end

  # Volume Control Tests
  it "should set volume level" do
    exec(:volume, 50)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setAudioVolume")
      params = body["params"].as_a.first
      params["target"].should eq("speaker")
      params["volume"].should eq("50")
      
      response.status_code = 200
      response << %<{"result":[],"id":4}>
    end
    
    status[:volume].should eq(50)
  end

  it "should mute audio" do
    exec(:mute_on)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setAudioMute")
      body["params"].as_a.first["status"].should eq(true)
      
      response.status_code = 200
      response << %<{"result":[],"id":5}>
    end
    
    status[:audio_mute].should eq(true)
  end

  it "should unmute audio" do
    exec(:mute_off)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setAudioMute")
      body["params"].as_a.first["status"].should eq(false)
      
      response.status_code = 200
      response << %<{"result":[],"id":6}>
    end
    
    status[:audio_mute].should eq(false)
  end

  it "should query volume information" do
    exec(:query_volume_info)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("getVolumeInformation")
      
      response.status_code = 200
      response << %<{"result":[{"target":"speaker","volume":"25","mute":false}],"id":7}>
    end
    
    status[:volume].should eq(25)
    status[:audio_mute].should eq(false)
  end

  # Input Control Tests
  it "should switch to HDMI1 input using string" do
    exec(:switch_to, "hdmi1")
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setPlayContent")
      body["params"].as_a.first["uri"].should eq("extInput:hdmi?port=1")
      
      response.status_code = 200
      response << %<{"result":[],"id":8}>
    end
    
    status[:input].should eq("hdmi1")
  end

  it "should switch to HDMI1 input using enum" do
    exec(:switch_to, Sony::Displays::BraviaRest::Input::Hdmi1)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setPlayContent")
      body["params"].as_a.first["uri"].should eq("extInput:hdmi?port=1")
      
      response.status_code = 200
      response << %<{"result":[],"id":8}>
    end
    
    status[:input].should eq("hdmi1")
  end

  it "should switch to HDMI2 input" do
    exec(:hdmi2)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setPlayContent")
      body["params"].as_a.first["uri"].should eq("extInput:hdmi?port=2")
      
      response.status_code = 200
      response << %<{"result":[],"id":9}>
    end
    
    status[:input].should eq("hdmi2")
  end

  it "should query current input" do
    exec(:query_current_input)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("getPlayingContentInfo")
      
      response.status_code = 200
      response << %<{"result":[{"uri":"extInput:hdmi?port=3"}],"id":10}>
    end
    
    status[:input].should eq("hdmi3")
  end

  # Additional Functionality Tests
  it "should get system information" do
    exec(:get_system_information)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("getSystemInformation")
      
      response.status_code = 200
      response << %<{"result":[{"product":"TV","region":"US","model":"KD-55X900H"}],"id":11}>
    end
  end

  it "should send IR code" do
    exec(:send_ir_code, "AAAAAQAAAAEAAAAvAw==")
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("actIRCC")
      body["params"].as_a.first["ircc"].should eq("AAAAAQAAAAEAAAAvAw==")
      
      response.status_code = 200
      response << %<{"result":[],"id":12}>
    end
  end

  it "should get application list" do
    exec(:get_application_list)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("getApplicationList")
      
      response.status_code = 200
      response << %<{"result":[[{"title":"Netflix","uri":"netflix://"}]],"id":13}>
    end
  end

  it "should set active app" do
    exec(:set_active_app, "netflix://")
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setActiveApp")
      body["params"].as_a.first["uri"].should eq("netflix://")
      
      response.status_code = 200
      response << %<{"result":[],"id":14}>
    end
  end

  it "should get content list" do
    exec(:get_content_list, "tv")
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("getContentList")
      body["params"].as_a.first["source"].should eq("tv")
      
      response.status_code = 200
      response << %<{"result":[[{"title":"Channel 1","uri":"tv:dvbc"}]],"id":15}>
    end
  end

  it "should get scene select" do
    exec(:get_scene_select)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("getSceneSelect")
      
      response.status_code = 200
      response << %<{"result":[{"scene":"auto"}],"id":16}>
    end
  end

  it "should set scene select" do
    exec(:set_scene_select, "cinema")
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setSceneSelect")
      body["params"].as_a.first["scene"].should eq("cinema")
      
      response.status_code = 200
      response << %<{"result":[],"id":17}>
    end
  end

  # Error handling tests
  it "should handle API errors" do
    exec(:power_on)
    
    expect_http_request do |request, response|
      response.status_code = 200
      response << %<{"error":[12,"Display is Off"],"id":18}>
    end
    
    # Should not update power state on error
    status[:power]?.should be_nil
  end

  it "should handle PSK not configured" do
    # Create new driver instance without PSK
    driver = Sony::Displays::BraviaRest.new(module_id: "mod-test", settings: {} of String => String)
    driver.logger = logger
    
    # Should not make HTTP request when PSK is empty
    response = driver.power_on
    response[:success?].should eq(false)
  end

  it "should handle HTTP errors" do
    exec(:power_on)
    
    expect_http_request do |request, response|
      response.status_code = 401
      response << "Unauthorized"
    end
    
    # Should not update power state on HTTP error
    status[:power]?.should be_nil
  end

  it "should handle empty response body" do
    exec(:power_on)
    
    expect_http_request do |request, response|
      response.status_code = 200
      response << ""
    end
    
    # Should not update power state on empty response
    status[:power]?.should be_nil
  end

  it "should handle malformed JSON response" do
    exec(:query_volume_info)
    
    expect_http_request do |request, response|
      response.status_code = 200
      response << %<{"result":[{"target":"speaker","volume":null,"mute":"invalid"}],"id":23}>
    end
    
    # Should not crash on malformed data - volume should remain unchanged
    status[:volume]?.should be_nil
  end

  # Interface compliance tests
  it "should implement Powerable interface" do
    exec(:power, true)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setPowerStatus")
      body["params"].as_a.first["status"].should eq(true)
      
      response.status_code = 200
      response << %<{"result":[{"status":"active"}],"id":19}>
    end
    
    status[:power].should eq(true)
  end

  it "should implement Muteable interface" do
    exec(:mute, true)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["method"].should eq("setAudioMute")
      body["params"].as_a.first["status"].should eq(true)
      
      response.status_code = 200
      response << %<{"result":[],"id":20}>
    end
    
    status[:audio_mute].should eq(true)
  end

  it "should clamp volume values" do
    exec(:volume, 150)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      params = body["params"].as_a.first
      params["volume"].should eq("100")  # Should be clamped to 100
      
      response.status_code = 200
      response << %<{"result":[],"id":21}>
    end
    
    status[:volume].should eq(100)
  end

  it "should handle negative volume values" do
    exec(:volume, -10)
    
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      params = body["params"].as_a.first
      params["volume"].should eq("0")  # Should be clamped to 0
      
      response.status_code = 200
      response << %<{"result":[],"id":22}>
    end
    
    status[:volume].should eq(0)
  end

  it "should parse various input string formats" do
    # Test different input string formats
    result1 = exec(:switch_to, "hdmi 1")
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["params"].as_a.first["uri"].should eq("extInput:hdmi?port=1")
      response.status_code = 200
      response << %<{"result":[],"id":24}>
    end
    
    result2 = exec(:switch_to, "hdmi_2")
    expect_http_request do |request, response|
      body = JSON.parse(request.body.not_nil!)
      body["params"].as_a.first["uri"].should eq("extInput:hdmi?port=2")
      response.status_code = 200
      response << %<{"result":[],"id":25}>
    end
    
    # Test invalid input
    result3 = exec(:switch_to, "invalid_input")
    result3.should eq(false)  # Should return false for invalid inputs
  end
end