require "placeos-driver/spec"

DriverSpecs.mock_driver "Sony::Camera::PtzCGI" do
  # Initialize with basic auth
  settings({
    basic_auth: {
      username: "admin",
      password: "Admin_1234",
    },
    max_pan_tilt_speed: 0x0F,
    zoom_speed:         0x07,
    zoom_max:           0x4000,
    camera_no:          0x01,
    invert_controls:    false,
  })
  
  # Set the URI base for HTTP connections
  update_settings({"uri_base" => "http://192.168.1.100"})

  puts "Testing status query"
  retval = exec(:query_status)

  # Mock the status response
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts %(AbsolutePTZF=15400,fd578,0000,cb5a&PanMovementRange=eac00,15400&PanPanoramaRange=de00,2200&PanTiltMaxVelocity=24&PtzInstance=1&TiltMovementRange=fc400,b400&TiltPanoramaRange=fc00,1200&ZoomMaxVelocity=8&ZoomMovementRange=0000,4000,7ac0&PtzfStatus=idle,idle,idle,idle&AbsoluteZoom=609)
  end

  # Verify status parsing - updated for consistent twos_complement handling
  retval.get.not_nil!["AbsoluteZoom"].should eq("609")
  status[:pan].should eq(87040)
  status[:pan_range].should eq({"min" => -87040, "max" => 87040})
  status[:tilt].should eq(-10888)
  status[:tilt_range].should eq({"min" => -15360, "max" => 46080})
  status[:zoom].should be_close(6.0, 0.1)

  puts "Testing info query"
  exec(:info?)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts %(ModelName=BRC-X1000&Serial=12345678&SoftVersion=1.0.0&ModelForm=BRC-X1000&CGIVersion=1.0)
  end

  status[:model_name].should eq("BRC-X1000")
  status[:serial].should eq("12345678")
  status[:soft_version].should eq("1.0.0")

  puts "Testing power on"
  exec(:power, true)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:power].should be_true

  puts "Testing power query"
  exec(:power?)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts %(Power=on)
  end

  status[:power].should be_true

  puts "Testing power off"
  exec(:power, false)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:power].should be_false

  puts "Testing home position"
  exec(:home)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  # Should trigger status query after home
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts %(AbsolutePTZF=0,0,1000,cb5a&PanMovementRange=eac00,15400&TiltMovementRange=fc400,b400&ZoomMovementRange=0000,4000,7ac0&PtzfStatus=idle,idle,idle,idle)
  end

  puts "Testing joystick movement"
  exec(:joystick, 50.0, 25.0)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:moving].should be_true

  puts "Testing joystick stop"
  exec(:joystick, 0.0, 0.0)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:moving].should be_false

  puts "Testing absolute pan/tilt (VISCA compatible)"
  exec(:pantilt, 0x1000_u16, 0x2000_u16, 0x0F_u8)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  puts "Testing absolute pan/tilt/zoom (CGI style)"
  exec(:pantilt, 4096, 8192, 1024)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:pan].should eq(4096)
  status[:tilt].should eq(8192)

  puts "Testing zoom to absolute position"
  exec(:zoom_to, 50.0)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:zoom].should eq(50.0)

  puts "Testing zoom in"
  exec(:zoom, "in")
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:zooming].should be_true

  puts "Testing zoom stop"
  exec(:zoom, "stop")
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:zooming].should be_false

  puts "Testing zoom query"
  exec(:zoom?)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts %(AbsoluteZoom=800)
  end

  puts "Testing move commands"
  exec(:move, "up")
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  exec(:move, "down")
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  exec(:move, "left")
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  exec(:move, "right")
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  exec(:move, "in")
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  exec(:move, "out")
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  puts "Testing stop command"
  exec(:stop)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:moving].should be_false

  puts "Testing emergency stop"
  exec(:stop, 0, true)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  puts "Testing preset save"
  exec(:save_position, "preset1")
  
  status[:presets].should contain("preset1")

  puts "Testing preset recall"
  exec(:recall, "preset1")
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  puts "Testing preset removal"
  exec(:remove_position, "preset1")
  
  status[:presets].should_not contain("preset1")

  puts "Testing PTZ auto framing enable"
  exec(:ptzautoframing, true)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:ptz_auto_framing].should be_true

  puts "Testing PTZ auto framing disable"
  exec(:ptzautoframing, false)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end

  status[:ptz_auto_framing].should be_false

  puts "Testing PTZ auto framing query"
  exec(:ptzautoframing?)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts %(PTZAutoFraming=on)
  end

  status[:ptz_auto_framing].should be_true

  puts "Testing pan/tilt position query"
  exec(:pantilt?)
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts %(AbsolutePTZF=2000,3000,1500,cb5a&PanMovementRange=eac00,15400&TiltMovementRange=fc400,b400&ZoomMovementRange=0000,4000,7ac0&PtzfStatus=idle,idle,idle,idle)
  end

  status[:pan].should eq(8192)
  status[:tilt].should eq(12288)

  puts "Testing error handling for unknown preset"
  expect_raises(Exception, "unknown preset unknown_preset") do
    exec(:recall, "unknown_preset")
  end

  puts "Testing invert controls setting"
  update_settings({invert_controls: true})
  status[:invert_controls].should be_true
  status[:inverted].should be_true

  puts "Testing joystick with inverted controls"
  exec(:joystick, 0.0, 50.0)  # Should send -50 for tilt
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts "OK"
  end
end