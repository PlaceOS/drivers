require "placeos-driver/spec"

DriverSpecs.mock_driver "Sennheiser::TCC2SSCv1" do
  settings({
    poll_interval: 30,
  })

  # Expect initial messages from connected method (updated to match new SSCV1 protocol)
  # get_osc_version
  should_send(%({"osc":{"version":null}}))
  responds(%({"osc":{"version":"1.2"}}))

  # get_device_identity (multiple calls)
  should_send(%({"device":{"identity":{"version":null}}}))
  responds(%({"device":{"identity":{"version":"1.0.0"}}}))
  should_send(%({"device":{"identity":{"vendor":null}}}))
  responds(%({"device":{"identity":{"vendor":"Sennheiser"}}}))
  should_send(%({"device":{"identity":{"product":null}}}))
  responds(%({"device":{"identity":{"product":"TCC2"}}}))
  should_send(%({"device":{"identity":{"serial":null}}}))
  responds(%({"device":{"identity":{"serial":"ABC123456"}}}))
  should_send(%({"device":{"identity":{"hw_revision":null}}}))
  responds(%({"device":{"identity":{"hw_revision":"1.0"}}}))

  # get_audio_mute_status
  should_send(%({"audio":{"mute":null}}))
  responds(%({"audio":{"mute":false}}))

  # query_device_status calls
  should_send(%({"audio":{"mute":null}}))
  responds(%({"audio":{"mute":false}}))
  should_send(%({"audio":{"room_in_use":null}}))
  responds(%({"audio":{"room_in_use":false}}))
  should_send(%({"m":{"beam":{"azimuth":null}}}))
  responds(%({"m":{"beam":{"azimuth":180}}}))
  should_send(%({"m":{"beam":{"elevation":null}}}))
  responds(%({"m":{"beam":{"elevation":45}}}))
  should_send(%({"m":{"in1":{"peak":null}}}))
  responds(%({"m":{"in1":{"peak":-25}}}))

  # Test OSC version
  exec(:get_osc_version)
  should_send(%({"osc":{"version":null}}))
  responds(%({"osc":{"version":"1.0"}}))
  status["protocol_version"]?.should eq("1.0")

  # Test OSC ping
  exec(:get_osc_ping)
  should_send(%({"osc":{"ping":null}}))
  responds(%({"osc":{"ping":"pong"}}))

  # Test mute functionality
  exec(:set_mute, true)
  should_send(%({"audio":{"mute":true}}))
  responds(%({"audio":{"mute":true}}))
  status["muted"]?.should eq(true)

  # Test unmute functionality
  exec(:set_mute, false)
  should_send(%({"audio":{"mute":false}}))
  responds(%({"audio":{"mute":false}}))
  status["muted"]?.should eq(false)

  # Test AudioMuteable interface
  exec(:mute_audio, true, 0)
  should_send(%({"audio":{"mute":true}}))
  responds(%({"audio":{"mute":true}}))
  status["muted"]?.should eq(true)

  # Test convenience mute method
  exec(:mute)
  should_send(%({"audio":{"mute":true}}))
  responds(%({"audio":{"mute":true}}))
  status["muted"]?.should eq(true)

  # Test convenience unmute method
  exec(:unmute)
  should_send(%({"audio":{"mute":false}}))
  responds(%({"audio":{"mute":false}}))
  status["muted"]?.should eq(false)

  # Test room in use detection
  exec(:get_audio_room_in_use)
  should_send(%({"audio":{"room_in_use":null}}))
  responds(%({"audio":{"room_in_use":true}}))
  status["room_in_use"]?.should eq(true)

  # Test installation type setting
  exec(:set_audio_installation_type, "suspended")
  should_send(%({"audio":{"installation_type":"suspended"}}))
  responds(%({"audio":{"installation_type":"suspended"}}))
  status["installation_type"]?.should eq("suspended")

  # Test out1 attenuation control
  exec(:set_audio_out1_attenuation, -10)
  should_send(%({"audio":{"out1":{"attenuation":-10}}}))
  responds(%({"audio":{"out1":{"attenuation":-10}}}))
  status["out1_attenuation"]?.should eq(-10)

  # Test out2 gain control
  exec(:set_audio_out2_gain, 12)
  should_send(%({"audio":{"out2":{"gain":12}}}))
  responds(%({"audio":{"out2":{"gain":12}}}))
  status["out2_gain"]?.should eq(12)

  # Test ref1 gain control
  exec(:set_audio_ref1_gain, -20)
  should_send(%({"audio":{"ref1":{"gain":-20}}}))
  responds(%({"audio":{"ref1":{"gain":-20}}}))
  status["ref1_gain"]?.should eq(-20)

  # Test metering - beam elevation
  exec(:get_meter_beam_elevation)
  should_send(%({"m":{"beam":{"elevation":null}}}))
  responds(%({"m":{"beam":{"elevation":45}}}))
  status["beam_elevation"]?.should eq(45)

  # Test metering - beam azimuth
  exec(:get_meter_beam_azimuth)
  should_send(%({"m":{"beam":{"azimuth":null}}}))
  responds(%({"m":{"beam":{"azimuth":180}}}))
  status["beam_azimuth"]?.should eq(180)

  # Test metering - input peak
  exec(:get_meter_input_peak)
  should_send(%({"m":{"in1":{"peak":null}}}))
  responds(%({"m":{"in1":{"peak":-25}}}))
  status["input_peak_level"]?.should eq(-25)

  # Test device identification
  exec(:set_device_identification_visual, true)
  should_send(%({"device":{"identification":{"visual":true}}}))
  responds(%({"device":{"identification":{"visual":true}}}))
  status["identification_visual"]?.should eq(true)

  # Test convenience identify method
  exec(:identify)
  should_send(%({"device":{"identification":{"visual":true}}}))
  responds(%({"device":{"identification":{"visual":true}}}))
  status["identification_visual"]?.should eq(true)

  # Test device name setting
  exec(:set_device_name, "MIC_A01")
  should_send(%({"device":{"name":"MIC_A01"}}))
  responds(%({"device":{"name":"MIC_A01"}}))
  status["device_name"]?.should eq("MIC_A01")

  # Test LED brightness control
  exec(:set_device_led_brightness, 3)
  should_send(%({"device":{"led":{"brightness":3}}}))
  responds(%({"device":{"led":{"brightness":3}}}))
  status["led_brightness"]?.should eq(3)

  # Test LED custom color setting
  exec(:set_device_led_custom_color, "CYAN")
  should_send(%({"device":{"led":{"custom":{"color":"CYAN"}}}}))
  responds(%({"device":{"led":{"custom":{"color":"CYAN"}}}}))
  status["led_custom_color"]?.should eq("CYAN")

  # Test beam orientation offset
  exec(:set_beam_orientation_offset, 90)
  should_send(%({"beam":{"orientation":{"offset":90}}}))
  responds(%({"beam":{"orientation":{"offset":90}}}))
  status["beam_orientation_offset"]?.should eq(90)

  # Test device restart
  exec(:device_restart)
  should_send(%({"device":{"restart":true}}))
  responds(%({"device":{"restart":true}}))

  # Test device restore
  exec(:device_restore, "FACTORY_DEFAULTS")
  should_send(%({"device":{"restore":"FACTORY_DEFAULTS"}}))
  responds(%({"device":{"restore":"FACTORY_DEFAULTS"}}))

  # Test clamping - attenuation to valid range
  exec(:set_audio_out1_attenuation, -25)
  should_send(%({"audio":{"out1":{"attenuation":-18}}}))
  responds(%({"audio":{"out1":{"attenuation":-18}}}))
  status["out1_attenuation"]?.should eq(-18)

  # Test clamping - gain to valid range
  exec(:set_audio_out2_gain, 30)
  should_send(%({"audio":{"out2":{"gain":24}}}))
  responds(%({"audio":{"out2":{"gain":24}}}))
  status["out2_gain"]?.should eq(24)

  # Test clamping - LED brightness to valid range
  exec(:set_device_led_brightness, 10)
  should_send(%({"device":{"led":{"brightness":5}}}))
  responds(%({"device":{"led":{"brightness":5}}}))
  status["led_brightness"]?.should eq(5)
end
