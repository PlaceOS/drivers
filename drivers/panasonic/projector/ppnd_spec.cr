require "placeos-driver/spec"

DriverSpecs.mock_driver "Panasonic::Projector::PPND" do
  # Test power on
  it "should power on the projector" do
    result = exec(:power, true)

    # First request - get auth challenge
    expect_http_request do |request, response|
      request.method.should eq("PUT")
      request.path.should eq("/api/v1/power")
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
    end

    # Second request - with auth header
    expect_http_request do |request, response|
      request.method.should eq("PUT")
      request.path.should eq("/api/v1/power")
      request.headers["Authorization"]?.should_not be_nil
      body = JSON.parse(request.body.not_nil!)
      body["state"].should eq("on")
      response.status_code = 200
      response << %{{"state":"on"}}
    end

    result.get.should eq(true)
    status[:power].should eq(true)
  end

  # Test power off
  it "should power off the projector" do
    result = exec(:power, false)

    # Auth challenge
    expect_http_request do |request, response|
      request.method.should eq("PUT")
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="abc123", opaque="def456"}
    end

    # Authenticated request
    expect_http_request do |request, response|
      request.method.should eq("PUT")
      request.headers["Authorization"]?.should_not be_nil
      body = JSON.parse(request.body.not_nil!)
      body["state"].should eq("standby")
      response.status_code = 200
      response << %{{"state":"standby"}}
    end

    result.get.should eq(false)
    status[:power].should eq(false)
  end

  # Test power query
  it "should query power status" do
    result = exec(:query_power_status)

    # Auth challenge
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/v1/power")
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="xyz789", opaque="uvw012"}
    end

    # Authenticated request
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/v1/power")
      request.headers["Authorization"]?.should_not be_nil
      response.status_code = 200
      response << %{{"state":"on"}}
    end

    result.get.should eq(true)
    status[:power].should eq(true)
  end

  # Test input switching
  it "should switch to HDMI1 input" do
    result = exec(:switch_to, "HDMI1")

    # Auth challenge
    expect_http_request do |request, response|
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="input123", opaque="input456"}
    end

    # Authenticated request
    expect_http_request do |request, response|
      request.headers["Authorization"]?.should_not be_nil
      body = JSON.parse(request.body.not_nil!)
      body["state"].should eq("HDMI1")
      response.status_code = 200
      response << %{{"state":"HDMI1"}}
    end

    result.get.should eq("HDMI1")
    status[:input].should eq("HDMI1")
  end

  # Test shutter open
  it "should open the shutter" do
    result = exec(:shutter, true)

    # Auth challenge
    expect_http_request do |request, response|
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="shutter1", opaque="shutter2"}
    end

    # Authenticated request
    expect_http_request do |request, response|
      request.headers["Authorization"]?.should_not be_nil
      body = JSON.parse(request.body.not_nil!)
      body["state"].should eq("open")
      response.status_code = 200
      response << %{{"state":"open"}}
    end

    result.get.should eq("open")
    status[:shutter_open].should eq(true)
  end

  # Test freeze on
  it "should enable freeze" do
    result = exec(:freeze, true)

    # Auth challenge
    expect_http_request do |request, response|
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="freeze1", opaque="freeze2"}
    end

    # Authenticated request
    expect_http_request do |request, response|
      request.headers["Authorization"]?.should_not be_nil
      body = JSON.parse(request.body.not_nil!)
      body["state"].should eq("on")
      response.status_code = 200
      response << %{{"state":"on"}}
    end

    result.get.should eq(true)
    status[:frozen].should eq(true)
  end

  # Test signal query
  it "should query signal information" do
    result = exec(:query_signal)

    # Auth challenge
    expect_http_request do |request, response|
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="signal1", opaque="signal2"}
    end

    # Authenticated request
    expect_http_request do |request, response|
      request.headers["Authorization"]?.should_not be_nil
      response.status_code = 200
      response << %{{"infomation":"NO SIGNAL"}}
    end

    result.get.should eq("NO SIGNAL")
    status[:no_signal].should eq(true)
  end

  # Test device information query
  it "should query device information" do
    result = exec(:query_device_info)

    # Auth challenge
    expect_http_request do |request, response|
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="device1", opaque="device2"}
    end

    # Authenticated request
    expect_http_request do |request, response|
      request.headers["Authorization"]?.should_not be_nil
      response.status_code = 200
      response << %{
        {
          "model-name": "PT-CMZ50",
          "serial-no": "ABCDE1234",
          "projector-name": "NAME1234",
          "macadress": "11-22-33-44-55-66"
        }
      }
    end

    result.get
    status[:model].should eq("PT-CMZ50")
    status[:serial_number].should eq("ABCDE1234")
  end

  # Test firmware version query
  it "should query firmware version" do
    result = exec(:query_firmware_version)

    # Auth challenge
    expect_http_request do |request, response|
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="version1", opaque="version2"}
    end

    # Authenticated request
    expect_http_request do |request, response|
      request.headers["Authorization"]?.should_not be_nil
      response.status_code = 200
      response << %{{"main-version":"1.00"}}
    end

    result.get.should eq("1.00")
    status[:firmware_version].should eq("1.00")
  end

  # Test NTP configuration
  it "should configure NTP settings" do
    result = exec(:configure_ntp, true, "time.google.com")

    # Auth challenge
    expect_http_request do |request, response|
      response.status_code = 401
      response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="ntp1", opaque="ntp2"}
    end

    # Authenticated request
    expect_http_request do |request, response|
      request.headers["Authorization"]?.should_not be_nil
      body = JSON.parse(request.body.not_nil!)
      body["ntp-sync"].should eq("on")
      body["ntp-server"].should eq("time.google.com")
      response.status_code = 200
      response << %{{"ntp-sync":"on","ntp-server":"time.google.com"}}
    end

    result.get
    status[:ntp_sync].should eq(true)
    status[:ntp_server].should eq("time.google.com")
  end
end
