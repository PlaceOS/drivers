require "placeos-driver/spec"

DriverSpecs.mock_driver "Sony::Displays::BraviaPro" do
  settings({
    psk: "test1234",
  })

  # Test power on
  exec(:power, true)
  expect_http_request do |request, response|
    request.method.should eq("POST")
    request.path.should eq("/sony/system")
    request.headers["X-Auth-PSK"]?.should eq("test1234")
    request.headers["Content-Type"]?.should eq("application/json")

    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("setPowerStatus")
      data["params"][0]["status"].should eq("active")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [] of String, "id": 1}.to_json
  end

  expect_http_request do |request, response|
    request.method.should eq("POST")
    request.path.should eq("/sony/system")

    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("getPowerStatus")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [{"status": "active"}], "id": 2}.to_json
  end

  status[:power].should eq(true)

  # Test power off
  exec(:power, false)
  expect_http_request do |request, response|
    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["params"][0]["status"].should eq("standby")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [] of String, "id": 1}.to_json
  end

  expect_http_request do |request, response|
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [{"status": "standby"}], "id": 2}.to_json
  end

  status[:power].should eq(false)

  # Test volume setting
  exec(:volume, 75)
  expect_http_request do |request, response|
    request.path.should eq("/sony/audio")

    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("setAudioVolume")
      data["params"][0]["volume"].should eq("75")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [] of String, "id": 3}.to_json
  end

  expect_http_request do |request, response|
    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("getVolumeInformation")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [[{"target": "speaker", "volume": "75", "mute": false}]], "id": 4}.to_json
  end

  status[:volume].should eq(75)

  # Test mute
  exec(:mute, true)
  expect_http_request do |request, response|
    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("setAudioMute")
      data["params"][0]["status"].should eq(true)
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [] of String, "id": 5}.to_json
  end

  expect_http_request do |request, response|
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [[{"target": "speaker", "volume": "75", "mute": true}]], "id": 6}.to_json
  end

  status[:mute].should eq(true)

  # Test input switching
  exec(:switch_to, "hdmi1")
  expect_http_request do |request, response|
    request.path.should eq("/sony/avContent")

    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("setPlayContent")
      data["params"][0]["uri"].should eq("extInput:hdmi?port=1")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [] of String, "id": 7}.to_json
  end

  expect_http_request do |request, response|
    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("getPlayingContentInfo")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [{"uri": "extInput:hdmi?port=1", "title": "HDMI 1"}], "id": 8}.to_json
  end

  status[:input].should eq("Hdmi1")

  # Test volume query
  exec(:volume?)
  expect_http_request do |request, response|
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [[{"target": "speaker", "volume": "65", "mute": false}]], "id": 4}.to_json
  end

  status[:volume].should eq(65)
end
