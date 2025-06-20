require "placeos-driver/spec"

DriverSpecs.mock_driver "Sennheiser::TCC2SSCv1" do
  settings({
    poll_interval: 30,
  })

  # Expect initial messages from connected method
  # get_device_info
  should_send(%({"path":"/device/info","method":"get"}))
  responds(%({"path":"/device/info","status":200,"data":{"name":"TCC2-Test","firmware_version":"1.0.0"}}))
  
  # get_audio_status  
  should_send(%({"path":"/audio/status","method":"get"}))
  responds(%({"path":"/audio/status","status":200,"data":{"mute":false,"gain":-6}}))
  
  # query_device_status - get_mute_status
  should_send(%({"path":"/audio/mute","method":"get"}))
  responds(%({"path":"/audio/mute","status":200,"data":{"enabled":false}}))
  
  # query_device_status - get_gain
  should_send(%({"path":"/audio/gain","method":"get"}))
  responds(%({"path":"/audio/gain","status":200,"data":{"level":-6}}))
  
  # query_device_status - get_beam_direction
  should_send(%({"path":"/beam/direction","method":"get"}))
  responds(%({"path":"/beam/direction","status":200,"data":{"azimuth":0,"elevation":0}}))
  
  # query_device_status - get_audio_levels
  should_send(%({"path":"/audio/levels","method":"get"}))
  responds(%({"path":"/audio/levels","status":200,"data":{"input_level":-40}}))

  # Test mute functionality - Interface::AudioMuteable
  exec(:mute_audio, true)
  should_send(%({"path":"/audio/mute","method":"set","args":{"enabled":true}}))
  responds(%({"path":"/audio/mute","method":"set","status":200,"data":{"enabled":true}}))
  status[:muted]?.should eq(true)

  # Test unmute functionality
  exec(:mute_audio, false)
  should_send(%({"path":"/audio/mute","method":"set","args":{"enabled":false}}))
  responds(%({"path":"/audio/mute","method":"set","status":200,"data":{"enabled":false}}))
  status[:muted]?.should eq(false)

  # Test convenience mute method
  exec(:mute)
  should_send(%({"path":"/audio/mute","method":"set","args":{"enabled":true}}))
  responds(%({"path":"/audio/mute","status":200,"data":{"enabled":true}}))
  status[:muted]?.should eq(true)

  # Test convenience unmute method
  exec(:unmute)
  should_send(%({"path":"/audio/mute","method":"set","args":{"enabled":false}}))
  responds(%({"path":"/audio/mute","status":200,"data":{"enabled":false}}))
  status[:muted]?.should eq(false)

  # Test gain control
  exec(:set_gain, -12)
  should_send(%({"path":"/audio/gain","method":"set","args":{"level":-12}}))
  responds(%({"path":"/audio/gain","status":200,"data":{"level":-12}}))
  status[:gain_level]?.should eq(-12)
end