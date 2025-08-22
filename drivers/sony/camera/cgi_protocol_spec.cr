require "placeos-driver/spec"

DriverSpecs.mock_driver "Sony::Camera::CGI" do
  # Test digest auth flow - first GET request for auth challenge
  retval = exec(:query_status)

  # First request should be GET to get auth challenge
  expect_http_request do |request, response|
    request.method.should eq("GET")
    request.resource.should eq("/command/inquiry.cgi?inq=ptzf")

    response.status_code = 401
    response.headers["WWW-Authenticate"] = %(Digest realm="Sony Camera", nonce="abc123", qop="auth", algorithm=MD5)
  end

  # Second request should be GET with digest auth header
  expect_http_request do |request, response|
    request.method.should eq("GET")
    request.resource.should eq("/command/inquiry.cgi?inq=ptzf")
    request.headers["Authorization"]?.should_not be_nil
    request.headers["Authorization"].should contain("Digest")

    response.status_code = 200
    response.output.puts %(AbsolutePTZF=15400,fd578,0000,cb5a&PanMovementRange=eac00,15400&PanPanoramaRange=de00,2200&PanTiltMaxVelocity=24&PtzInstance=1&TiltMovementRange=fc400,b400&TiltPanoramaRange=fc00,1200&ZoomMaxVelocity=8&ZoomMovementRange=0000,4000,7ac0&PtzfStatus=idle,idle,idle,idle&AbsoluteZoom=609)
  end

  # What the function should return (for use in making further requests)
  retval.get.not_nil!["AbsoluteZoom"].should eq("609")
  status[:pan].should eq(87040)
  status[:pan_range].should eq({"min" => -87040, "max" => 87040})

  status[:tilt].should eq(-10888)
  status[:tilt_range].should eq({"min" => -15360, "max" => 46080})
end
